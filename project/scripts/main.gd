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

@onready var sim_world: Node = $PixelSimWorld
@onready var chunk_renderer: Node2D = $ChunkRenderer
@onready var player: CharacterBody2D = $Player
@onready var particles: Node2D = $Particles

var resources := {}
var cpu_backend: CPUSimulationBackend

func _ready() -> void:
	sim_world.world_seed = 1337
	sim_world.simulation_budget_ms = 4.0
	sim_world.init_world()
	sim_world.generate_test_terrain()

	cpu_backend = CPUSimulationBackend.new(sim_world)

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
	cpu_backend.advance(delta)

func add_resource(material_id: int, amount: int) -> void:
	resources[material_id] = get_resource(material_id) + amount

func get_resource(material_id: int) -> int:
	return resources.get(material_id, 0)

func get_stress_test_report() -> String:
	var st = get_node_or_null("StressTest")
	if st:
		return st.get_report_text()
	return ""
