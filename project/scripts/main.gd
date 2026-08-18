extends Node2D
## Test-scene orchestrator: generates the world, drives the simulation step
## through a fixed-timestep accumulator (see CPUSimulationBackend -
## SIMULATION_TIMESCALE.md "CPU Fixed Timestep"), and holds the (deliberately
## minimal, per spec section 13) resource counters that mining feeds into.
##
## RENDER FPS != PHYSICS SPEED: `_process(delta)` used to call
## `sim_world.step_simulation(delta)` directly, once per render frame - since
## step_simulation() is itself a real-wall-clock-time-budgeted call
## (`simulation_budget_ms`), calling it more often (higher render FPS) meant
## strictly more simulation work got done per real second. `cpu_backend` now
## gates those calls through a fixed-timestep accumulator, so physics
## advances at a constant rate independent of render FPS - see
## CPUSimulationBackend's own doc comment for the full rationale.
##
## GPU PRODUCTION WIRING (SIMULATION_TIMESCALE.md "GPU Production Wiring"):
## `gpu_bridge` computes SAND+WATER MOVEMENT on the GPU, syncing results back
## into `sim_world` before `cpu_backend` runs - see GPUProductionBridge's own
## doc comment for the full per-frame contract. ORDERING RULE: `gpu_bridge.
## advance()` MUST run BEFORE `cpu_backend.advance()` every frame, so CPU's
## reaction/GRAVEL/LAVA pass always sees this frame's fresh GPU-computed
## SAND/WATER positions, never last frame's. Everything else (reactions,
## GRAVEL/LAVA, mining, building, player collision, rendering) stays 100%
## CPU, unchanged - see GPUProductionBridge's class doc comment for scope.

@onready var sim_world: Node = $PixelSimWorld
@onready var chunk_renderer: Node2D = $ChunkRenderer
@onready var player: CharacterBody2D = $Player
@onready var particles: Node2D = $Particles

var resources := {}
var cpu_backend: CPUSimulationBackend
var gpu_bridge: GPUProductionBridge

func _ready() -> void:
	sim_world.world_seed = 1337
	sim_world.simulation_budget_ms = 4.0
	sim_world.init_world()
	sim_world.generate_test_terrain()

	cpu_backend = CPUSimulationBackend.new(sim_world)
	gpu_bridge = GPUProductionBridge.new(sim_world, sim_world.world_seed)

	# Drop the player just above the generated surface, roughly mid-world.
	var world_cells: Vector2i = sim_world.get_world_size_cells()
	var cell_size: int = sim_world.get_simulation_cell_size()
	var spawn_cell_x := world_cells.x / 2
	var spawn_cell_y := 4
	for y in range(world_cells.y):
		if sim_world.get_cell(spawn_cell_x, y) != sim_world.MATERIAL_AIR:
			spawn_cell_y = max(0, y - 6)
			break
	player.position = Vector2(spawn_cell_x * cell_size, spawn_cell_y * cell_size)

func _process(delta: float) -> void:
	# ORDERING RULE - see class doc comment "GPU PRODUCTION WIRING": the GPU
	# bridge must sync SAND/WATER's new positions into sim_world BEFORE
	# cpu_backend's own step runs, so CPU's reaction/GRAVEL/LAVA pass never
	# reacts against stale, pre-sync positions.
	gpu_bridge.advance(delta)
	cpu_backend.advance(delta)

func _exit_tree() -> void:
	if gpu_bridge:
		gpu_bridge.cleanup()

func add_resource(material_id: int, amount: int) -> void:
	resources[material_id] = get_resource(material_id) + amount

func get_resource(material_id: int) -> int:
	return resources.get(material_id, 0)

func get_stress_test_report() -> String:
	var st = get_node_or_null("StressTest")
	if st:
		return st.get_report_text()
	return ""
