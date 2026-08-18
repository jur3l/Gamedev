class_name GPUTimestepBenchmark
extends RefCounted
## Phase 2C benchmark harness (SIMULATION_TIMESCALE.md "Workload
## Validation"). Builds the same slab spawn geometry as stress_test.gd for
## 10k/50k/100k/250k/500k SAND, against the same world dimensions
## (3072x1792 cells = PixelSimWorld's 48x28-chunk default, so the GPU and
## CPU paths are directly comparable), and measures:
##   - GPU hardware capacity (real-time ratio, unpaced - "GPU Capacity")
##   - CPU comparison at the same tiers ("CPU vs GPU Comparison")
##   - accumulator/backlog behavior at a given render FPS ("Backlog")
##   - FPS independence (same physical result at 30/60/120fps - "FPS Independence")

const WORLD_W := 3072
const WORLD_H := 1792
const MARGIN := 10

const MAT_AIR := GPUSandPoC.MAT_AIR
const MAT_SAND := GPUSandPoC.MAT_SAND

## Mirrors stress_test.gd's _start_test() slab geometry exactly, but builds a
## PackedInt32Array directly instead of calling fill_rect() on a World - see
## SIMULATION_TIMESCALE.md "Initial state" / the request's §9.
static func build_slab(w: int, h: int, cell_count: int) -> PackedInt32Array:
	var arr := PackedInt32Array()
	arr.resize(w * h)
	arr.fill(MAT_AIR)
	var width := w - MARGIN * 2
	var height: int = int(ceil(float(cell_count) / float(width)))
	height = min(height, h / 3)
	var placed := 0
	var y := MARGIN
	while placed < cell_count and y < MARGIN + height:
		var remaining := cell_count - placed
		var row_w: int = min(width, remaining)
		for x in range(MARGIN, MARGIN + row_w):
			arr[y * w + x] = MAT_SAND
		placed += row_w
		y += 1
	return arr

## GPU Capacity (hardware-throughput) measurement for one tier - unpaced, no
## accumulator involved. Directly answers "can the GPU produce 1.0s of
## physical simulation time faster than 1.0s of real (wall-clock) time" -
## SIMULATION_TIMESCALE.md "GPU Capacity" / the request's core §2 question.
static func measure_gpu_capacity(backend: GPUSimulationBackend, cell_count: int) -> Dictionary:
	var initial := build_slab(WORLD_W, WORLD_H, cell_count)
	backend.reset_grid(WORLD_W, WORLD_H, initial)
	var ticks_for_1s := int(GPUSimulationBackend.PHYSICAL_TICKS_PER_SECOND)
	var t0 := Time.get_ticks_usec()
	var result := backend.run_ticks_unpaced(ticks_for_1s)
	var wall_usec := Time.get_ticks_usec() - t0
	var wall_seconds := wall_usec / 1000000.0
	var physical_seconds: float = ticks_for_1s * backend.fixed_dt
	var ratio := (physical_seconds / wall_seconds) if wall_seconds > 0.0 else INF
	return {
		"cell_count": cell_count,
		"physical_seconds": physical_seconds,
		"wall_seconds": wall_seconds,
		"compute_usec": result.compute_usec,
		"real_time_ratio": ratio,
	}

## CPU reference at the same tier/geometry/world size, timing 60
## step_simulation() calls (the direct analog of 60 GPU ticks - both are "60
## units of the respective per-frame simulation primitive") via the real
## PixelSimWorld/World, standalone (not added to the scene tree).
static func measure_cpu(cell_count: int, seed_value: int) -> Dictionary:
	var w := PixelSimWorld.new()
	w.world_width_chunks = WORLD_W / 64
	w.world_height_chunks = WORLD_H / 64
	w.world_seed = seed_value
	w.simulation_budget_ms = 4.0
	w.init_world()

	var width := WORLD_W - MARGIN * 2
	var height: int = int(ceil(float(cell_count) / float(width)))
	height = min(height, WORLD_H / 3)
	var placed := 0
	var y := MARGIN
	while placed < cell_count and y < MARGIN + height:
		var remaining := cell_count - placed
		var row_w: int = min(width, remaining)
		w.fill_rect(MARGIN, y, row_w, 1, w.MATERIAL_SAND)
		placed += row_w
		y += 1

	var ticks := 60
	var total_sim_ms := 0.0
	var t0 := Time.get_ticks_usec()
	for i in range(ticks):
		var stats: Dictionary = w.step_simulation(1.0 / 60.0)
		total_sim_ms += stats.get("sim_ms", 0.0)
	var wall_usec := Time.get_ticks_usec() - t0
	var wall_seconds := wall_usec / 1000000.0
	w.free()
	return {
		"cell_count": cell_count,
		"wall_seconds": wall_seconds,
		"avg_sim_ms": total_sim_ms / ticks,
		"ticks": ticks,
	}

## Accumulator/backlog validation at a given assumed render FPS - drives
## GPUSimulationBackend.advance() with synthetic per-frame deltas until 1.0s
## of physical simulation time has been produced (or a safety frame cap is
## hit). See SIMULATION_TIMESCALE.md "Backlog" / "Accumulator".
static func measure_accumulator_backlog(backend: GPUSimulationBackend, cell_count: int, fps: float) -> Dictionary:
	var initial := build_slab(WORLD_W, WORLD_H, cell_count)
	backend.reset_grid(WORLD_W, WORLD_H, initial)
	var frame_delta := 1.0 / fps
	var frames := 0
	var max_frames := 2000
	while backend.simulation_time < 1.0 and frames < max_frames:
		backend.advance(frame_delta)
		frames += 1
	var metrics := backend.get_metrics()
	metrics["fps"] = fps
	metrics["frames_used"] = frames
	metrics["intended_wall_time"] = frames * frame_delta
	metrics["design_real_time_ratio"] = (metrics["simulation_time"] / metrics["intended_wall_time"]) if metrics["intended_wall_time"] > 0.0 else 0.0
	return metrics

## FPS independence: same tick sequence should run regardless of assumed
## render FPS (30/60/120), producing an identical final GPU state, as long
## as backlog never becomes the binding constraint. See SIMULATION_
## TIMESCALE.md "FPS Independence".
static func measure_fps_independence(backend: GPUSimulationBackend, cell_count: int) -> Dictionary:
	var initial := build_slab(WORLD_W, WORLD_H, cell_count)
	var final_states := {}
	var ticks_per_fps := {}
	var max_backlog_per_fps := {}
	var fps_list: Array[float] = [30.0, 60.0, 120.0]
	for fps in fps_list:
		backend.reset_grid(WORLD_W, WORLD_H, initial)
		var frame_delta: float = 1.0 / fps
		var frames := 0
		while backend.simulation_time < 1.0 and frames < 2000:
			backend.advance(frame_delta)
			frames += 1
		final_states[fps] = backend.read_back()
		ticks_per_fps[fps] = backend.ticks_executed
		max_backlog_per_fps[fps] = backend.max_backlog_ticks_seen
	var eq_30_60: bool = final_states[30.0] == final_states[60.0]
	var eq_60_120: bool = final_states[60.0] == final_states[120.0]
	return {
		"ticks_per_fps": ticks_per_fps,
		"max_backlog_per_fps": max_backlog_per_fps,
		"eq_30_60": eq_30_60,
		"eq_60_120": eq_60_120,
		"all_equal": eq_30_60 and eq_60_120,
	}
