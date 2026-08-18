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

	# Cheap peek at whether this frame will actually fire a tick, so an
	## idle-region OR a between-ticks frame (render FPS far exceeding the
	# fixed 60 ticks/sec, exactly the asymmetry SIMULATION_TIMESCALE.md's CPU
	# section already documents) doesn't pay for a redundant upload.
	var will_tick: bool = (backend.accumulator + real_delta) >= backend.fixed_dt
	var dispatch_region := _region # the region about to be dispatched, captured BEFORE it can change

	if will_tick and backend.region_active and dispatch_region.size.x > 0 and dispatch_region.size.y > 0:
		var upload := _translate_cpu_to_gpu(sim_world.get_materials_rect(
			dispatch_region.position.x, dispatch_region.position.y, dispatch_region.size.x, dispatch_region.size.y
		))
		backend.gpu.write_rect(dispatch_region.position.x, dispatch_region.position.y, dispatch_region.size.x, dispatch_region.size.y, upload)

	var result: Dictionary = backend.advance_active_region(real_delta)

	if result.get("dispatched", false):
		var gpu_ints := backend.gpu.read_rect(dispatch_region.position.x, dispatch_region.position.y, dispatch_region.size.x, dispatch_region.size.y)
		var cpu_bytes := _translate_gpu_to_cpu(gpu_ints)
		sim_world.set_materials_rect(dispatch_region.position.x, dispatch_region.position.y, dispatch_region.size.x, dispatch_region.size.y, cpu_bytes)

	_region = backend.region_rect
	return result

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
