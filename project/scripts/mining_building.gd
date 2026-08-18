extends Node
## Left mouse = mine (configurable-shape/size area removal -> AIR/mined_drop,
## ore -> resource counter). Right mouse = build (single cell, grid-snapped
## placement of WOOD/METAL/WATER/LAVA). Purely reads/writes the simulation
## grid through PixelSimWorld - no physics bodies are created for mined or
## placed material.
##
## GPU PRODUCTION WIRING: mining can drop SAND (from DIRT) and building can
## place WATER directly - both are GPU-owned-movement materials (see
## GPUProductionBridge). After either action, main.gpu_bridge.wake_region()
## is called so the GPU active region actually covers the affected area -
## harmless to call even when nothing GPU-relevant is there (Phase 2D's own
## sleep logic settles a quiet region back down on its own).

const DEFAULT_MINING_SIZE := 8
const MIN_MINING_SIZE := 1
const MAX_MINING_SIZE := 24

@export var sim_world_path: NodePath
@export var camera_path: NodePath
@export var main_path: NodePath
@export var particles_path: NodePath

var sim_world: Node
var camera: Camera2D
var main: Node
var particles: Node2D

var is_mining := false
var build_material: int = 0 # set in _ready once PixelSimWorld constants exist

# Configurable mining tool - shape and size are independent knobs, both
# adjustable at runtime; shape uses the same PixelSimWorld.SHAPE_* constants
# the C++ core's World::mine_area() understands.
var mining_shape: int = 0
var mining_size: int = DEFAULT_MINING_SIZE

var cursor_preview: Node2D

func _ready() -> void:
	sim_world = get_node(sim_world_path)
	camera = get_node(camera_path)
	main = get_node(main_path)
	particles = get_node(particles_path)
	build_material = sim_world.MATERIAL_WOOD
	mining_shape = sim_world.SHAPE_CIRCLE

	cursor_preview = Node2D.new()
	cursor_preview.z_index = 400
	cursor_preview.draw.connect(_draw_cursor_preview)
	camera.get_parent().get_parent().add_child.call_deferred(cursor_preview) # into world space (Main), not under the moving Player/Camera

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			is_mining = event.pressed
		elif event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			_build_at_cursor()
	elif event is InputEventKey and event.pressed:
		if event.keycode == KEY_1:
			build_material = sim_world.MATERIAL_WOOD
		elif event.keycode == KEY_2:
			build_material = sim_world.MATERIAL_METAL
		elif event.keycode == KEY_3:
			build_material = sim_world.MATERIAL_WATER
		elif event.keycode == KEY_4:
			build_material = sim_world.MATERIAL_LAVA

func _process(_delta: float) -> void:
	if Input.is_action_just_pressed("mining_size_increase"):
		mining_size = min(mining_size + 1, MAX_MINING_SIZE)
	if Input.is_action_just_pressed("mining_size_decrease"):
		mining_size = max(mining_size - 1, MIN_MINING_SIZE)
	if Input.is_action_just_pressed("toggle_mining_shape"):
		mining_shape = sim_world.SHAPE_SQUARE if mining_shape == sim_world.SHAPE_CIRCLE else sim_world.SHAPE_CIRCLE

	if is_mining:
		_mine_at_cursor()

	if cursor_preview:
		cursor_preview.queue_redraw()

func _cursor_cell() -> Vector2i:
	var mouse_world: Vector2 = get_viewport().get_camera_2d().get_global_mouse_position()
	var cell_size: int = sim_world.get_simulation_cell_size()
	return Vector2i(int(floor(mouse_world.x / cell_size)), int(floor(mouse_world.y / cell_size)))

func mining_shape_name() -> String:
	return "square" if mining_shape == sim_world.SHAPE_SQUARE else "circle"

func _mine_at_cursor() -> void:
	var cell := _cursor_cell()
	var result: Dictionary = sim_world.mine_area(cell.x, cell.y, mining_size, mining_shape)
	if result.is_empty() or int(result.get("total_removed", 0)) == 0:
		return
	var counts: Dictionary = result.get("counts", {})
	for material_id in counts.keys():
		if material_id == sim_world.MATERIAL_IRON_ORE or material_id == sim_world.MATERIAL_COPPER_ORE:
			main.add_resource(material_id, counts[material_id])
	if particles:
		var cell_size: int = sim_world.get_simulation_cell_size()
		particles.spawn_dust(Vector2(cell.x * cell_size, cell.y * cell_size))
	if main.gpu_bridge:
		main.gpu_bridge.wake_region(cell.x, cell.y, mining_size + 2)

func _build_at_cursor() -> void:
	var cell := _cursor_cell()
	var placed: bool = sim_world.place_cell(cell.x, cell.y, build_material)
	if not placed:
		return
	if particles:
		var cell_size: int = sim_world.get_simulation_cell_size()
		particles.spawn_build_puff(Vector2(cell.x * cell_size, cell.y * cell_size))
	if main.gpu_bridge:
		main.gpu_bridge.wake_region(cell.x, cell.y, 4)

func _draw_cursor_preview() -> void:
	if cursor_preview == null or camera == null:
		return
	var cell_size: int = sim_world.get_simulation_cell_size()
	var cell := _cursor_cell()
	var color := Color(1, 1, 1, 0.8)
	if mining_shape == sim_world.SHAPE_SQUARE:
		var half := mining_size * cell_size
		var top_left := Vector2(cell.x * cell_size - half, cell.y * cell_size - half)
		var size := Vector2(half * 2 + cell_size, half * 2 + cell_size)
		cursor_preview.draw_rect(Rect2(top_left, size), color, false, 1.5)
	else:
		var center := Vector2((cell.x + 0.5) * cell_size, (cell.y + 0.5) * cell_size)
		cursor_preview.draw_arc(center, mining_size * cell_size, 0, TAU, 32, color, 1.5)
