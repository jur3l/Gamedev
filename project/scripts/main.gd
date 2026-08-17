extends Node2D
## Test-scene orchestrator: generates the world, drives the simulation step
## with a fixed budget every frame, and holds the (deliberately minimal, per
## spec section 13) resource counters that mining feeds into.

@onready var sim_world: Node = $PixelSimWorld
@onready var chunk_renderer: Node2D = $ChunkRenderer
@onready var player: CharacterBody2D = $Player
@onready var particles: Node2D = $Particles

var resources := {}

func _ready() -> void:
	sim_world.world_seed = 1337
	sim_world.simulation_budget_ms = 4.0
	sim_world.init_world()
	sim_world.generate_test_terrain()

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
	sim_world.step_simulation(delta)

func add_resource(material_id: int, amount: int) -> void:
	resources[material_id] = get_resource(material_id) + amount

func get_resource(material_id: int) -> int:
	return resources.get(material_id, 0)

func get_stress_test_report() -> String:
	var st = get_node_or_null("StressTest")
	if st:
		return st.get_report_text()
	return ""
