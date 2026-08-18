class_name GPUProductionBridge
extends RefCounted
## Wires the experimental GPU simulation (GPUSimulationBackend/GPUSandPoC,
## Phase 2A-2D) into ACTUAL PRODUCTION GAMEPLAY as the mover of SAND+WATER
## cells only - see SIMULATION_TIMESCALE.md "GPU Production Wiring" for the
## full architecture writeup this class implements.
##
## SCOPE: GPU computes SAND+WATER MOVEMENT only. Reactions (the Material
## Reaction System), GRAVEL/LAVA movement, mining, building, player
## collision, and rendering all stay 100% CPU, unchanged - this bridge only
## decides WHO moves SAND/WATER, and keeps `sim_world` (PixelSimWorld/World)
## as the single, authoritative source of truth every other system already
## reads. GPU-owned reactions are deliberately NOT enabled (the GPU rule
## table is never configured by this bridge, so it stays at its default
## identity/no-op table) - see gpu_sand_poc.gd's MAT_DIRT..MAT_LAVA block
## for why that avoids a dual-computation hazard (both CPU and GPU
## independently computing the same reaction the same tick).
##
## PER-FRAME CONTRACT (advance(), called once per render frame):
##   1. If the active region is awake, re-read its CURRENT material state
##      fresh from `sim_world` and upload it to the GPU buffer (write_rect).
##      `sim_world` is re-asserted as ground truth for obstacles/reaction-
##      driven changes every dispatched frame - no fragile "what changed
##      since last sync" delta-tracking is needed, since mining/building/
##      reactions all already go through the ordinary set_cell() path and
##      this bridge simply re-reads whatever is there.
##   2. Advance GPUSimulationBackend's fixed-timestep accumulator via
##      advance_active_region(), which dispatches only the active region.
##   3. If a dispatch actually happened this frame, read back the SAME
##      region that was just dispatched (captured BEFORE step 2, since
##      GPUSimulationBackend may shrink/grow region_rect for the NEXT
##      dispatch as a side effect of this one - reading back the
##      just-dispatched region, not the adjusted one, is what guarantees a
##      cell's final settled value is never lost on the exact tick its
##      region goes quiet), translate to CPU ids, and write into
##      `sim_world` (set_materials_rect) - only cells that actually changed
##      get set_cell()'d, reusing all of sim_world's existing wake/dirty/
##      render/neighbor-activation bookkeeping "for free".
##
## ORDERING RULE (see main.gd): _process() MUST call bridge.advance(delta)
## BEFORE cpu_backend.advance(delta), every frame, no exceptions - so CPU's
## own step() (reactions + GRAVEL/LAVA movement) always sees THIS frame's
## fresh GPU-computed SAND/WATER positions, never a stale one from last
## frame. Reversing this order would let CPU react against last frame's
## SAND/WATER positions, a real (if usually harmless) staleness bug.
##
## mining_building.gd calls wake_region() after any mine/build action near
## existing SAND/WATER (or unconditionally - Phase 2D's own sleep logic
## puts a quiet region back to sleep on its own) - this only grows/wakes the
## active region; the actual state re-sync happens automatically via step 1
## above, so no delta-payload plumbing is needed from the caller.

const CPU_MATERIAL_COUNT := 12 # matches core/material.h's MaterialType::COUNT

# CPU MaterialType id -> GPU MAT_* id. Every CPU material needs a GPU id, not
# just SAND/WATER/STONE - see gpu_sand_poc.gd's MAT_DIRT..MAT_LAVA block for
# why (SAND/WATER need to see DIRT/ores/wood/metal/GRAVEL/MUD/LAVA as
# obstacles too, at zero shader cost). Index = CPU MaterialId, value = GPU id.
const CPU_TO_GPU: PackedInt32Array = [
	GPUSandPoC.MAT_AIR,        # 0  AIR
	GPUSandPoC.MAT_SAND,       # 1  SAND
	GPUSandPoC.MAT_DIRT,       # 2  DIRT
	GPUSandPoC.MAT_STONE,      # 3  STONE
	GPUSandPoC.MAT_IRON_ORE,   # 4  IRON_ORE
	GPUSandPoC.MAT_COPPER_ORE, # 5  COPPER_ORE
	GPUSandPoC.MAT_WATER,      # 6  WATER
	GPUSandPoC.MAT_WOOD,       # 7  WOOD
	GPUSandPoC.MAT_METAL,      # 8  METAL
	GPUSandPoC.MAT_GRAVEL,     # 9  GRAVEL
	GPUSandPoC.MAT_MUD,        # 10 MUD
	GPUSandPoC.MAT_LAVA,       # 11 LAVA
]

var sim_world: Node
var backend: GPUSimulationBackend
var world_w := 0
var world_h := 0
var available := false

var _gpu_to_cpu: PackedInt32Array = [] # inverse of CPU_TO_GPU, size MAX_MATERIALS
var _region := Rect2i() # cell-space active region, mirrors backend.region_rect

# --- Per-stage timing instrumentation (regression investigation - see
# SIMULATION_TIMESCALE.md "GPU Production Wiring: Regression Investigation").
# Measurement only, added around the EXISTING calls in advance() below -
# zero behavior/timing change to the pipeline itself, just Time.get_ticks_
# usec() calls bracketing each stage so "where does the time actually go"
# can be answered with evidence instead of assumed. All *_usec fields are
# this-frame-only (0 on a frame that didn't dispatch); the total_* fields
# accumulate across the whole session, same convention as
# GPUSimulationBackend's own total_compute_usec/total_readback_usec.
var last_region_w := 0
var last_region_h := 0
var last_dispatched := false
var last_upload_translate_usec := 0  # CPU: get_materials_rect() result -> GPU ids (GDScript loop)
var last_upload_write_usec := 0      # GPU: write_rect() - one buffer_update() RD call per region row
var last_dispatch_usec := 0          # GPU: step_region() compute+submit+sync (see GPUSandPoC.last_compute_usec - the RD API does not expose compute-only vs. sync-wait separately, see doc note below)
var last_download_read_usec := 0     # GPU: read_rect() - one buffer_get_data() RD call per region row
var last_download_translate_usec := 0 # CPU: GPU ids -> PackedByteArray (GDScript loop)
var last_cpu_writeback_usec := 0     # CPU: set_materials_rect() - per-cell get_material()+set_cell() in C++
var last_advance_total_usec := 0     # wall time for the whole advance() call, this frame

var total_upload_translate_usec := 0
var total_upload_write_usec := 0
var total_dispatch_usec := 0
var total_download_read_usec := 0
var total_download_translate_usec := 0
var total_cpu_writeback_usec := 0
var total_advance_usec := 0        # sum of last_advance_total_usec on DISPATCHED frames only - see avg_advance_total_usec
var total_advance_usec_all_frames := 0 # sum across EVERY advance() call, dispatched or not - whole-session wall cost of this bridge existing at all, including idle-frame no-op overhead
var dispatched_frame_count := 0 # frames where an actual GPU dispatch + full round-trip happened
var total_frame_count := 0      # every advance() call, dispatched or not

func _init(p_sim_world: Node, seed_value: int) -> void:
	sim_world = p_sim_world
	_build_gpu_to_cpu_table()

	var size: Vector2i = sim_world.get_world_size_cells()
	world_w = size.x
	world_h = size.y

	backend = GPUSimulationBackend.new()
	available = backend.init(seed_value)
	if not available:
		push_error("[GPUProductionBridge] GPU backend unavailable - SAND/WATER stay on the CPU path (set_movement_externally_owned was never called)")
		return

	var initial := _translate_cpu_to_gpu(sim_world.get_materials_rect(0, 0, world_w, world_h))
	backend.setup_grid(world_w, world_h, initial)

	for cpu_mat in [sim_world.MATERIAL_SAND, sim_world.MATERIAL_WATER]:
		sim_world.set_movement_externally_owned(cpu_mat, true)

	# Active region starts asleep (GPUSimulationBackend's own field defaults:
	# region_active=false, region_rect=Rect2i()) - the first wake_region()
	# call (mining_building.gd, after a mine/build action) bootstraps it.
	# generate_test_terrain() does not currently place any SAND/WATER, so
	# starting asleep is correct; if that ever changes, an initial
	# wake_region() call covering the placed area would need to be added here.

func _build_gpu_to_cpu_table() -> void:
	_gpu_to_cpu.resize(GPUSandPoC.MAX_MATERIALS)
	_gpu_to_cpu.fill(0) # default AIR - defensive; the GPU rule table is never
	# configured by this bridge (see class doc comment), so GPU should never
	# actually produce an id outside CPU_TO_GPU's value set.
	for cpu_id in range(CPU_MATERIAL_COUNT):
		_gpu_to_cpu[CPU_TO_GPU[cpu_id]] = cpu_id

func _translate_cpu_to_gpu(cpu_bytes: PackedByteArray) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(cpu_bytes.size())
	for i in range(cpu_bytes.size()):
		out[i] = CPU_TO_GPU[cpu_bytes[i]]
	return out

func _translate_gpu_to_cpu(gpu_ints: PackedInt32Array) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(gpu_ints.size())
	for i in range(gpu_ints.size()):
		out[i] = _gpu_to_cpu[gpu_ints[i]]
	return out

## Per-frame entry point - see class doc comment "PER-FRAME CONTRACT" and
## "ORDERING RULE" above. Safe to call every frame even while the active
## region is asleep (a cheap no-op: no upload/dispatch/download happens).
func advance(real_delta: float) -> Dictionary:
	if not available:
		return {}

	var t_advance_start := Time.get_ticks_usec()
	last_upload_translate_usec = 0
	last_upload_write_usec = 0
	last_dispatch_usec = 0
	last_download_read_usec = 0
	last_download_translate_usec = 0
	last_cpu_writeback_usec = 0
	last_dispatched = false

	# Cheap peek at whether this frame will actually fire a tick, so an
	## idle-region OR a between-ticks frame (render FPS far exceeding the
	# fixed 60 ticks/sec, exactly the asymmetry SIMULATION_TIMESCALE.md's CPU
	# section already documents) doesn't pay for a redundant upload.
	var will_tick: bool = (backend.accumulator + real_delta) >= backend.fixed_dt
	var dispatch_region := _region # the region about to be dispatched, captured BEFORE it can change
	last_region_w = dispatch_region.size.x
	last_region_h = dispatch_region.size.y

	if will_tick and backend.region_active and dispatch_region.size.x > 0 and dispatch_region.size.y > 0:
		var t0 := Time.get_ticks_usec()
		var upload := _translate_cpu_to_gpu(sim_world.get_materials_rect(
			dispatch_region.position.x, dispatch_region.position.y, dispatch_region.size.x, dispatch_region.size.y
		))
		last_upload_translate_usec = Time.get_ticks_usec() - t0

		t0 = Time.get_ticks_usec()
		backend.gpu.write_rect(dispatch_region.position.x, dispatch_region.position.y, dispatch_region.size.x, dispatch_region.size.y, upload)
		last_upload_write_usec = Time.get_ticks_usec() - t0

	var result: Dictionary = backend.advance_active_region(real_delta)
	# GPUSandPoC.last_compute_usec (surfaced here as result.compute_usec) is
	# submit()+sync() wall time - the RD API gives no way to separately time
	# "GPU actually computing" vs. "CPU blocked waiting for GPU completion"
	# from GDScript; see the doc note this instrumentation's findings get
	# written up under for why that matters here.
	last_dispatch_usec = result.get("compute_usec", 0)

	if result.get("dispatched", false):
		last_dispatched = true
		var t0 := Time.get_ticks_usec()
		var gpu_ints := backend.gpu.read_rect(dispatch_region.position.x, dispatch_region.position.y, dispatch_region.size.x, dispatch_region.size.y)
		last_download_read_usec = Time.get_ticks_usec() - t0

		t0 = Time.get_ticks_usec()
		var cpu_bytes := _translate_gpu_to_cpu(gpu_ints)
		last_download_translate_usec = Time.get_ticks_usec() - t0

		t0 = Time.get_ticks_usec()
		sim_world.set_materials_rect(dispatch_region.position.x, dispatch_region.position.y, dispatch_region.size.x, dispatch_region.size.y, cpu_bytes)
		last_cpu_writeback_usec = Time.get_ticks_usec() - t0

		dispatched_frame_count += 1
		total_upload_translate_usec += last_upload_translate_usec
		total_upload_write_usec += last_upload_write_usec
		total_dispatch_usec += last_dispatch_usec
		total_download_read_usec += last_download_read_usec
		total_download_translate_usec += last_download_translate_usec
		total_cpu_writeback_usec += last_cpu_writeback_usec

	_region = backend.region_rect
	last_advance_total_usec = Time.get_ticks_usec() - t_advance_start
	total_frame_count += 1
	total_advance_usec_all_frames += last_advance_total_usec
	if last_dispatched:
		total_advance_usec += last_advance_total_usec # dispatched-frames-only sum - see avg_advance_total_usec
	return result

## Snapshot of this-frame + cumulative-average per-stage costs, for a
## debug overlay or a diagnostic script to print without reaching into
## every field individually. See the *_usec field doc comments above for
## what each stage actually measures.
func get_stage_metrics() -> Dictionary:
	var avg := func(total: int) -> float:
		return (float(total) / dispatched_frame_count) if dispatched_frame_count > 0 else 0.0
	return {
		"region_w": last_region_w,
		"region_h": last_region_h,
		"region_cells": last_region_w * last_region_h,
		"dispatched_frame_count": dispatched_frame_count,
		"last_dispatched": last_dispatched,
		"last_upload_translate_usec": last_upload_translate_usec,
		"last_upload_write_usec": last_upload_write_usec,
		"last_dispatch_usec": last_dispatch_usec,
		"last_download_read_usec": last_download_read_usec,
		"last_download_translate_usec": last_download_translate_usec,
		"last_cpu_writeback_usec": last_cpu_writeback_usec,
		"last_advance_total_usec": last_advance_total_usec,
		"avg_upload_translate_usec": avg.call(total_upload_translate_usec),
		"avg_upload_write_usec": avg.call(total_upload_write_usec),
		"avg_dispatch_usec": avg.call(total_dispatch_usec),
		"avg_download_read_usec": avg.call(total_download_read_usec),
		"avg_download_translate_usec": avg.call(total_download_translate_usec),
		"avg_cpu_writeback_usec": avg.call(total_cpu_writeback_usec),
		"avg_advance_total_usec": avg.call(total_advance_usec), # dispatched frames only
		"total_frame_count": total_frame_count, # every advance() call this session, dispatched or not
		"avg_advance_usec_all_frames": (float(total_advance_usec_all_frames) / total_frame_count) if total_frame_count > 0 else 0.0, # includes idle no-op frames - shows the bridge's TRUE average per-frame cost across a whole session, not just its cost when active
	}

## Called by mining_building.gd (or any future world-changing feature) after
## a write that might introduce/expose SAND or WATER - the GPU-side analog
## of activate_affected_neighbors() waking a CPU chunk. `radius` in cells.
func wake_region(cell_x: int, cell_y: int, radius: int) -> void:
	if not available:
		return
	var rect := Rect2i(cell_x - radius, cell_y - radius, radius * 2, radius * 2)
	backend.wake_region(rect, GPUSimulationBackend.DEFAULT_MAX_TICKS_PER_FRAME)
	_region = backend.region_rect

func cleanup() -> void:
	if backend != null:
		backend.cleanup()
		backend = null
	available = false
