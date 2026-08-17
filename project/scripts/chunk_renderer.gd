extends Node2D
## Chunk-based GPU rendering: one Sprite2D + one small texture per CHUNK, never
## per cell. Each simulation cell becomes exactly one texel; the sprite is then
## scaled up by simulation_cell_size and drawn with nearest-neighbor filtering
## for a crisp pixel-art look. Only chunks flagged render-dirty by the C++
## core get their texture re-uploaded each frame.

@export var sim_world_path: NodePath
var sim_world: Node

var chunk_size := 64
var cell_size := 4
var sprites := {} # Vector2i -> {sprite: Sprite2D, image: Image, texture: ImageTexture}

func _ready() -> void:
	sim_world = get_node(sim_world_path)
	chunk_size = sim_world.get_chunk_size()
	cell_size = sim_world.get_simulation_cell_size()
	var world_chunks: Vector2i = sim_world.get_world_size_chunks()

	for cy in range(world_chunks.y):
		for cx in range(world_chunks.x):
			_create_chunk_sprite(Vector2i(cx, cy))

func _create_chunk_sprite(coord: Vector2i) -> void:
	var image := Image.create(chunk_size, chunk_size, false, Image.FORMAT_RGBA8)
	var texture := ImageTexture.create_from_image(image)

	var sprite := Sprite2D.new()
	sprite.texture = texture
	sprite.centered = false
	sprite.position = Vector2(coord.x * chunk_size * cell_size, coord.y * chunk_size * cell_size)
	sprite.scale = Vector2(cell_size, cell_size)
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(sprite)

	sprites[coord] = {"sprite": sprite, "image": image, "texture": texture}

func _process(_delta: float) -> void:
	if sim_world == null:
		return
	var dirty_chunks: Array = sim_world.get_and_clear_dirty_render_chunks()
	for coord in dirty_chunks:
		var entry = sprites.get(coord)
		if entry == null:
			continue
		var bytes: PackedByteArray = sim_world.get_chunk_pixels(coord.x, coord.y)
		if bytes.is_empty():
			continue
		entry.image.set_data(chunk_size, chunk_size, false, Image.FORMAT_RGBA8, bytes)
		entry.texture.update(entry.image)

func get_chunk_world_rect(coord: Vector2i) -> Rect2:
	var px := chunk_size * cell_size
	return Rect2(Vector2(coord.x * px, coord.y * px), Vector2(px, px))
