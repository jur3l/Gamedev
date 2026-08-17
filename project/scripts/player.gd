extends CharacterBody2D
## Player movement/collision is intentionally NOT resolved via Godot Physics
## against the material simulation - there are no PhysicsBody2D/CollisionShape2D
## terrain colliders, because the terrain is CA grid data, not physics bodies.
## Instead this script does simple grid-vs-AABB collision directly against
## PixelSimWorld.get_cell(). Godot's own physics/gravity integration is used
## only for the player's own body, per the spec's "physics only for real game
## objects" rule.

const GRAVITY := 900.0
const MOVE_SPEED := 160.0
const JUMP_VELOCITY := -340.0
const MAX_FALL_SPEED := 900.0
const PLAYER_SIZE := Vector2(18, 34)

# Max ledge height the player automatically climbs while walking, in
# SIMULATION CELLS (not world/screen pixels) - see PLAYER_MOVEMENT.md
# "Coordinate Units". Multiplied by simulation_cell_size at the point of use,
# so this keeps meaning "N terrain cells" even if simulation_cell_size is
# reconfigured. 0 disables auto step-up entirely.
@export var player_step_height_cells: int = 2

# Whether foreground cells that only exist as a mining-drop product (SAND,
# GRAVEL - see PLAYER_COLLISION.md) block the player. true = they collide
# exactly like any other solid terrain (the default, matches pre-existing
# behavior). false = the player passes through them; the cells themselves are
# completely unaffected (still real, simulated, falling, rendered foreground
# cells). Every other foreground material's collision is unconditional and
# ignores this setting.
@export var mined_drop_collision: bool = false

@export var sim_world_path: NodePath
var sim_world: Node

var velocity_v := Vector2.ZERO
var on_floor := false

func _ready() -> void:
	sim_world = get_node(sim_world_path)
	_create_placeholder_sprite()

func _create_placeholder_sprite() -> void:
	var img := Image.create(int(PLAYER_SIZE.x), int(PLAYER_SIZE.y), false, Image.FORMAT_RGBA8)
	img.fill(Color(0.2, 0.85, 0.95, 1.0))
	var sprite := Sprite2D.new()
	sprite.texture = ImageTexture.create_from_image(img)
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(sprite)

func _unhandled_input(event: InputEvent) -> void:
	var camera := get_node_or_null("Camera2D") as Camera2D
	if camera == null or not (event is InputEventMouseButton):
		return
	var zoom_step := 0.1
	if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
		camera.zoom = (camera.zoom + Vector2.ONE * zoom_step).clamp(Vector2(0.3, 0.3), Vector2(4.0, 4.0))
	elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
		camera.zoom = (camera.zoom - Vector2.ONE * zoom_step).clamp(Vector2(0.3, 0.3), Vector2(4.0, 4.0))

func _physics_process(delta: float) -> void:
	if sim_world == null:
		return

	velocity_v.y = min(velocity_v.y + GRAVITY * delta, MAX_FALL_SPEED)

	var dir := 0.0
	if Input.is_action_pressed("move_left"):
		dir -= 1.0
	if Input.is_action_pressed("move_right"):
		dir += 1.0
	velocity_v.x = dir * MOVE_SPEED

	if on_floor and Input.is_action_just_pressed("jump"):
		velocity_v.y = JUMP_VELOCITY

	_move_and_collide(delta)

func _is_blocking(cell_x: int, cell_y: int) -> bool:
	var mat: int = sim_world.get_cell(cell_x, cell_y)
	if mat == sim_world.MATERIAL_AIR or mat == sim_world.MATERIAL_WATER:
		return false
	if sim_world.is_mining_drop_material(mat):
		return mined_drop_collision
	return true # normal foreground material - unconditional, unchanged rule

func _rect_blocked(top_left: Vector2) -> bool:
	var cell_size: int = sim_world.get_simulation_cell_size()
	var rect := Rect2(top_left, PLAYER_SIZE)
	var x0 := int(floor(rect.position.x / cell_size))
	var y0 := int(floor(rect.position.y / cell_size))
	var x1 := int(floor((rect.position.x + rect.size.x - 0.01) / cell_size))
	var y1 := int(floor((rect.position.y + rect.size.y - 0.01) / cell_size))
	for cy in range(y0, y1 + 1):
		for cx in range(x0, x1 + 1):
			if _is_blocking(cx, cy):
				return true
	return false

## Attempts to climb a small ledge that just blocked a flat horizontal
## sub-step. `horizontal_target` is the player-CENTER position after that
## blocked sub-step (same y as the player's current position, x moved by the
## sub-step). Tries progressively taller lifts, in whole simulation cells,
## from 1 up to player_step_height_cells, and returns the first raised center
## position where BOTH of these hold, or null if none within the configured
## limit work (obstacle is a real wall, not a small step):
##   1. Headroom: lifting straight up from the CURRENT position by that much
##      isn't itself blocked (no ceiling in the way of the lift itself).
##   2. The horizontal target, at that same raised height, is fully clear for
##      the whole PLAYER_SIZE bounding box (this single box-vs-grid check
##      covers both "is there room above the ledge" and "does the box end up
##      inside solid terrain" - a full-box check inherently answers both).
## Uses the SMALLEST height that clears it - never overstepping the ledge.
## The full obstacle height is what's tested (the whole PLAYER_SIZE box at
## each candidate height), not just whatever pixel the flat move first hit,
## so a slope/staircase is only climbable while each individual rise is
## within the limit, never by summing several rises into one bigger step.
func _try_step_up(horizontal_target: Vector2) -> Variant:
	if sim_world == null or player_step_height_cells <= 0:
		return null
	var cell_size: int = sim_world.get_simulation_cell_size()
	for h in range(1, player_step_height_cells + 1):
		var lift := Vector2(0, -h * cell_size)
		if _rect_blocked(position + lift - PLAYER_SIZE * 0.5):
			continue # something overhead blocks lifting the player this high here
		if _rect_blocked(horizontal_target + lift - PLAYER_SIZE * 0.5):
			continue # still blocked (or no headroom) at the target x at this height
		return horizontal_target + lift
	return null

func _move_and_collide(delta: float) -> void:
	var motion := velocity_v * delta

	# Horizontal, stepped 1px at a time so we never tunnel through a thin wall.
	# Capping step-up per 1px sub-step (rather than once for the whole frame's
	# motion) is what makes a staircase of small ledges climbable while a
	# single tall wall - approached across the same number of sub-steps -
	# still stays blocked: every sub-step re-checks the SAME configured
	# height limit, so there is no way to accumulate past it within a frame.
	var steps_x := int(ceil(abs(motion.x)))
	var step_x := 0.0 if steps_x == 0 else motion.x / steps_x
	for i in range(steps_x):
		var new_pos := position + Vector2(step_x, 0)
		if _rect_blocked(new_pos - PLAYER_SIZE * 0.5):
			var stepped_pos = _try_step_up(new_pos)
			if stepped_pos != null:
				position = stepped_pos
				continue
			velocity_v.x = 0
			break
		position = new_pos

	# Vertical.
	var steps_y := int(ceil(abs(motion.y)))
	var step_y := 0.0 if steps_y == 0 else motion.y / steps_y
	on_floor = false
	for i in range(steps_y):
		var new_pos := position + Vector2(0, step_y)
		if _rect_blocked(new_pos - PLAYER_SIZE * 0.5):
			if step_y > 0:
				on_floor = true
			velocity_v.y = 0
			break
		position = new_pos
