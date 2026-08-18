class_name GPUActiveRegionBenchmark
extends RefCounted
## Phase 2D benchmark harness (GPU_ACTIVE_REGION.md "Workload Validation").
## Measures: fixed-world + varying-active-chunk-count sweep, world-size
## scaling with a fixed small active region, a CPU / GPU-full-world (Phase
## 2C) / GPU-active-region (Phase 2D) tier comparison, and CPU-side
## active-region bookkeeping overhead measured separately from GPU compute.

const CHUNK_SIZE := 64
const MAT_AIR := GPUSandPoC.MAT_AIR
const MAT_SAND := GPUSandPoC.MAT_SAND

## Builds a roughly-square rect of exactly `chunk_count` chunks (as square as
## possible), filling the middle third of it with a SAND slab so the
## measurement reflects genuine per-cell compute + atomic-bounds-write cost,
## not an empty-region no-op.
static func build_region_with_chunks(gpu_w: int, gpu_h: int, chunk_count: int) -> Dictionary:
	var side := int(ceil(sqrt(float(chunk_count))))
	var chunks_w := side
	var chunks_h := int(ceil(float(chunk_count) / float(chunks_w)))
	var rect_w := chunks_w * CHUNK_SIZE
	var rect_h := chunks_h * CHUNK_SIZE
	rect_w = min(rect_w, gpu_w)
	rect_h = min(rect_h, gpu_h)
	var rect_x := (gpu_w - rect_w) / 2
	var rect_y := (gpu_h - rect_h) / 2
	# Align to chunk boundaries.
	rect_x = (rect_x / CHUNK_SIZE) * CHUNK_SIZE
	rect_y = (rect_y / CHUNK_SIZE) * CHUNK_SIZE
	return {"rect_x": rect_x, "rect_y": rect_y, "rect_w": rect_w, "rect_h": rect_h}

## Fills the middle rows of a rect (within a full-world buffer) with SAND -
## used to seed both the active-chunk-count sweep and the world-scaling test
## with genuine, non-trivial per-cell work.
static func seed_region_sand(buffer: PackedInt32Array, gpu_w: int, rect_x: int, rect_y: int, rect_w: int, rect_h: int, fill_rows: int) -> void:
	var start_y: int = rect_y + max((rect_h - fill_rows) / 2, 0)
	for y in range(start_y, min(start_y + fill_rows, rect_y + rect_h)):
		for x in range(rect_x, rect_x + rect_w):
			buffer[y * gpu_w + x] = MAT_SAND

## Active-chunk-count sweep (GPU_ACTIVE_REGION.md §7): fixed world, varying
## active region size, direct step_region() calls (bypassing the
## auto-tracking backend for precise, repeatable region-size control).
static func measure_active_chunks(gpu: GPUSandPoC, world_w: int, world_h: int, chunk_count: int, ticks: int, seed_value: int) -> Dictionary:
	var region := build_region_with_chunks(world_w, world_h, chunk_count)
	var rect_x: int = region["rect_x"]
	var rect_y: int = region["rect_y"]
	var rect_w: int = region["rect_w"]
	var rect_h: int = region["rect_h"]

	var initial := PackedInt32Array()
	initial.resize(world_w * world_h)
	initial.fill(MAT_AIR)
	seed_region_sand(initial, world_w, rect_x, rect_y, rect_w, rect_h, max(rect_h / 4, 8))

	if gpu._buf_a.is_valid():
		gpu._rd.free_rid(gpu._buf_a)
	if gpu._buf_b.is_valid():
		gpu._rd.free_rid(gpu._buf_b)
	gpu.setup_grid(world_w, world_h, initial)

	var t0 := Time.get_ticks_usec()
	gpu.step_region(ticks, seed_value, 0, rect_x, rect_y, rect_w, rect_h)
	var wall_usec := Time.get_ticks_usec() - t0
	var actual_chunks: int = (rect_w / CHUNK_SIZE) * (rect_h / CHUNK_SIZE)
	var physical_seconds: float = ticks * GPUSimulationBackend.DEFAULT_FIXED_DT
	var wall_seconds: float = wall_usec / 1000000.0
	return {
		"requested_chunks": chunk_count,
		"actual_chunks": actual_chunks,
		"rect": region,
		"wall_seconds": wall_seconds,
		"compute_usec": gpu.last_compute_usec,
		"real_time_ratio": (physical_seconds / wall_seconds) if wall_seconds > 0.0 else INF,
	}

## World-size scaling (GPU_ACTIVE_REGION.md §8/§22): grow the WORLD buffer
## while holding the active region fixed - the whole point of this feature
## is that GPU compute cost should stay flat here.
static func measure_world_scaling(gpu: GPUSandPoC, world_w: int, world_h: int, active_chunks: int, ticks: int, seed_value: int) -> Dictionary:
	var r := measure_active_chunks(gpu, world_w, world_h, active_chunks, ticks, seed_value)
	r["world_cells"] = world_w * world_h
	r["world_w"] = world_w
	r["world_h"] = world_h
	return r

## GPU-active-region tier measurement (GPU_ACTIVE_REGION.md §9): seeds the
## SAME slab geometry GPUTimestepBenchmark.build_slab() (Phase 2C) uses,
## computes its tight bounding box ONCE at setup time (not per tick - see
## "Activation Semantics"), enables active-region tracking from that rect,
## and times `ticks` ticks through the auto-tracking backend
## (run_ticks_active_region()) - the full, integrated Phase 2D system, not
## a hand-picked rect.
static func measure_gpu_active_region_tier(backend: GPUSimulationBackend, world_w: int, world_h: int, cell_count: int, ticks: int) -> Dictionary:
	var initial: PackedInt32Array = GPUTimestepBenchmark.build_slab(world_w, world_h, cell_count)
	backend.reset_grid(world_w, world_h, initial)

	# The tight bounding box is known analytically from build_slab()'s own
	# geometry formula (GPUTimestepBenchmark.MARGIN, slab width/height) -
	# computed directly instead of an O(world size) GDScript scan over
	# millions of cells, which this phase's own "no per-cell CPU scan" rule
	# (GPU_ACTIVE_REGION.md §13) argues against anyway, even at setup time.
	var margin: int = GPUTimestepBenchmark.MARGIN
	var slab_width: int = world_w - margin * 2
	var slab_height: int = int(ceil(float(cell_count) / float(slab_width)))
	slab_height = min(slab_height, world_h / 3)
	backend.enable_active_region(Rect2i(margin, margin, slab_width, slab_height), ticks)
	var t0 := Time.get_ticks_usec()
	var result := backend.run_ticks_active_region(ticks)
	var wall_usec := Time.get_ticks_usec() - t0
	return {
		"cell_count": cell_count,
		"wall_seconds": wall_usec / 1000000.0,
		"compute_usec": result.get("compute_usec", 0),
		"initial_chunks": backend.region_chunk_count(),
	}
