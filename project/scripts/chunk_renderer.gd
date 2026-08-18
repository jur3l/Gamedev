extends Node2D
## Chunk-based GPU rendering: one Sprite2D + one small texture per RESIDENT
## chunk, never per cell, and never for the whole world regardless of
## visibility. Each simulation cell becomes exactly one texel; the sprite is
## then scaled up by simulation_cell_size and drawn with nearest-neighbor
## filtering for a crisp pixel-art look.
##
## Touched-rect partial update (PERFORMANCE_SCALABILITY.md "Rendering
## Scaling"): measurement showed the C++ pixel-gen + PackedByteArray
## marshalling step (not Image.set_data, not ImageTexture.update) is the
## dominant per-dirty-chunk render cost, and it always re-serialized the
## full 4096-cell chunk even when only a handful of cells actually changed.
## World::consume_render_dirty_rect() (via get_and_clear_dirty_render_chunks())
## also reports each dirty chunk's touched sub-rect, so a small change only
## marshals/blits that sub-rect. ImageTexture.update() has no partial variant
## in Godot 4.7.1's API (confirmed against this project's
## api_dump/extension_api.json - only whole-Image update() and
## RenderingServer.texture_2d_update() exist, both full-image), so the GPU
## upload itself is still a full-chunk cost every dirty frame regardless of
## rect size - only the CPU-side pixel-gen/marshal/set_data steps shrink.
##
## Visibility-based lazy chunk rendering (PERFORMANCE_SCALABILITY.md "Phase 1
## - Lazy Rendering"): SIMULATION chunk state (the C++ World's Chunk objects)
## always exists for the whole world and is completely unaffected by
## anything in this file - simulation, sleeping, activation, mining, and
## reactions all keep working identically whether a chunk has a Sprite2D or
## not. RENDER RESOURCE (Sprite2D + Image + ImageTexture) is a separate,
## much narrower concept: it exists only for "resident" chunks - the
## camera's currently-visible chunk region plus a configurable preload
## margin - and is created/released as the camera moves. This is what keeps
## GPU texture memory bounded by what's actually on screen (plus margin)
## instead of by total world size - see PERFORMANCE_SCALABILITY.md's memory
## audit for why this mattered (GPU texture memory, ~21.3 KB/chunk measured,
## was the single largest per-chunk memory cost in the old eager-creation
## design).

@export var sim_world_path: NodePath
var sim_world: Node

var chunk_size := 64
var cell_size := 4
var world_chunks_x := 0
var world_chunks_y := 0

# A touched rect covering this fraction (or more) of the chunk's cells falls
# back to a full-chunk update - two smaller round trips (get_chunk_pixels_rect
# + blit_rect) cost more than one full get_chunk_pixels + set_data once the
# "small change" assumption stops holding. See PERFORMANCE_SCALABILITY.md
# "Before/After Benchmarks" for the measurement behind this choice.
const FULL_UPDATE_AREA_FRACTION := 0.5

# --- Phase 1: Visibility-based Lazy Chunk Rendering ---
# How far beyond the camera's exact viewport (in chunks) a render resource
# stays resident. Exists specifically so ordinary camera movement near a
# chunk boundary doesn't thrash create/destroy/create/destroy every frame -
# see PERFORMANCE_SCALABILITY.md "Phase 1" "Camera Movement Test".
@export var preload_margin_chunks: int = 2

# Vector2i -> {sprite: Sprite2D, image: Image, texture: ImageTexture}.
# ONLY contains entries for currently-resident chunks - this is the single
# source of truth for "does this chunk have a render resource right now."
var sprites := {}

# Current resident region, chunk coordinates, inclusive. Empty (zero size)
# until the first _process() call establishes it against the real camera
# position - see _ready()'s note on why residency isn't computed there.
var resident_rect := Rect2i()

# --- Perf-audit instrumentation (PERFORMANCE_SCALABILITY.md) ---
# Additive stage timing so the render pipeline's cost can be broken down into
# its real stages instead of one blended FPS number. Does not change
# rendering behavior - read-only bookkeeping.
var last_dirty_scan_usec := 0
var last_dirty_count := 0
var last_partial_count := 0
var last_full_count := 0
var last_marshal_usec := 0   # get_chunk_pixels()/get_chunk_pixels_rect(): C++ pixel gen + marshalling
var last_setdata_usec := 0   # Image.set_data() (full path)
var last_blit_usec := 0      # Image.create_from_data() + Image.blit_rect() (partial path)
var last_update_usec := 0    # ImageTexture.update() - CPU-side call that triggers the GPU upload
var last_residency_usec := 0 # _update_residency() cost (create/release), 0 on frames residency didn't change
var last_created_count := 0
var last_released_count := 0

func _ready() -> void:
	sim_world = get_node(sim_world_path)
	chunk_size = sim_world.get_chunk_size()
	cell_size = sim_world.get_simulation_cell_size()
	var wc: Vector2i = sim_world.get_world_size_chunks()
	world_chunks_x = wc.x
	world_chunks_y = wc.y
	# Deliberately does NOT create any sprites or compute residency here: at
	# this point in scene setup the active camera may still be at its scene-
	# file default position, not the real spawn point main.gd assigns once
	# every node is ready. The first _process() call (which runs only after
	# all _ready() calls, including main.gd's player-placement one, have
	# completed) establishes correct residency from the very first frame -
	# no wasted work at the wrong location.

func _compute_resident_rect() -> Rect2i:
	var cam := get_viewport().get_camera_2d()
	if cam == null:
		# No active camera (e.g. a camera-less test harness) - fall back to
		# "the whole world is resident", matching this system's pre-Phase-1
		# behavior so nothing breaks in a camera-less context.
		return Rect2i(0, 0, world_chunks_x, world_chunks_y)

	var viewport_size: Vector2 = get_viewport().get_visible_rect().size
	var visible_world_size: Vector2 = viewport_size / cam.zoom
	var top_left: Vector2 = cam.global_position - visible_world_size * 0.5
	var bottom_right: Vector2 = cam.global_position + visible_world_size * 0.5

	var chunk_px := chunk_size * cell_size
	var min_cx := int(floor(top_left.x / chunk_px)) - preload_margin_chunks
	var min_cy := int(floor(top_left.y / chunk_px)) - preload_margin_chunks
	var max_cx := int(floor(bottom_right.x / chunk_px)) + preload_margin_chunks
	var max_cy := int(floor(bottom_right.y / chunk_px)) + preload_margin_chunks

	min_cx = clamp(min_cx, 0, max(world_chunks_x - 1, 0))
	min_cy = clamp(min_cy, 0, max(world_chunks_y - 1, 0))
	max_cx = clamp(max_cx, 0, max(world_chunks_x - 1, 0))
	max_cy = clamp(max_cy, 0, max(world_chunks_y - 1, 0))

	return Rect2i(min_cx, min_cy, max_cx - min_cx + 1, max_cy - min_cy + 1)

# CREATE/RELEASE/RECREATE lifecycle (PERFORMANCE_SCALABILITY.md "Phase 1 -
# Render Resource Lifecycle"):
#   CREATE   - a chunk enters the resident region for the first time (or
#              after being released): allocate Sprite2D+Image+ImageTexture,
#              then immediately do a FULL rebuild from live simulation state.
#   KEEP     - a chunk stays resident across frames: untouched by this
#              function; the normal dirty-chunk loop in _process() keeps its
#              texture current via the existing partial/full update path.
#   RELEASE  - a chunk leaves the resident region: free its Sprite2D (Image/
#              ImageTexture are RefCounted and release automatically once
#              the `sprites` entry holding their last reference is erased).
#              Simulation state for that chunk is completely untouched - it
#              keeps simulating exactly as before, just with nothing
#              consuming its pixels into a texture.
#   RECREATE - identical code path to CREATE. A chunk becoming resident again
#              after being released has no reason to be treated specially:
#              its simulation state may have changed arbitrarily while
#              non-resident (see _process()'s dirty-chunk loop for why no
#              partial-update history survives that gap), so a full rebuild
#              is always correct and never redundant here.
func _update_residency(new_rect: Rect2i) -> void:
	if new_rect == resident_rect:
		last_created_count = 0
		last_released_count = 0
		return

	var t0 := Time.get_ticks_usec()
	var created := 0
	var released := 0

	# RELEASE: resident before, not resident now.
	for coord in sprites.keys().duplicate():
		if not new_rect.has_point(coord):
			_release_chunk_sprite(coord)
			released += 1

	# CREATE / RECREATE: resident now, not already resident.
	for cy in range(new_rect.position.y, new_rect.position.y + new_rect.size.y):
		for cx in range(new_rect.position.x, new_rect.position.x + new_rect.size.x):
			var coord := Vector2i(cx, cy)
			if not sprites.has(coord):
				_create_chunk_sprite(coord)
				created += 1

	resident_rect = new_rect
	last_residency_usec = Time.get_ticks_usec() - t0
	last_created_count = created
	last_released_count = released

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
	_full_rebuild_chunk(coord)

func _release_chunk_sprite(coord: Vector2i) -> void:
	var entry = sprites.get(coord)
	if entry == null:
		return
	entry.sprite.queue_free()
	sprites.erase(coord)
	# `entry` (and the Image/ImageTexture it held) goes out of scope here -
	# both are RefCounted, so this was their last reference and they free
	# (and release the GPU texture) without any explicit call.

func _full_rebuild_chunk(coord: Vector2i) -> void:
	var entry = sprites.get(coord)
	if entry == null:
		return
	var bytes: PackedByteArray = sim_world.get_chunk_pixels(coord.x, coord.y)
	if bytes.is_empty():
		return
	entry.image.set_data(chunk_size, chunk_size, false, Image.FORMAT_RGBA8, bytes)
	entry.texture.update(entry.image)

func _process(_delta: float) -> void:
	if sim_world == null:
		return

	# Dirty-chunk update FIRST, residency update SECOND - deliberate order.
	# get_and_clear_dirty_render_chunks() unconditionally scans and clears
	# EVERY chunk's render-dirty flag/touched-rect every frame, resident or
	# not (PROJECT_ARCHITECTURE.md §6) - this is exactly what makes "offscreen
	# simulation changes cost nothing to render" work for free: an offscreen
	# chunk's dirty state is drained here with sprites.get(coord) == null, so
	# the loop below just `continue`s past it, no texture touched. If a
	# chunk becomes newly resident later in this same frame (residency step,
	# below), _create_chunk_sprite() does its own full get_chunk_pixels()
	# read of current ground-truth state - so running residency second never
	# loses or duplicates work, it just means a newly-resident chunk's first
	# frame is a full rebuild, never a redundant partial update on top of one.
	var t0 := Time.get_ticks_usec()
	var dirty_chunks: Array = sim_world.get_and_clear_dirty_render_chunks()
	var t1 := Time.get_ticks_usec()
	var marshal_usec := 0
	var setdata_usec := 0
	var blit_usec := 0
	var update_usec := 0
	var partial_count := 0
	var full_count := 0

	for entry_info in dirty_chunks:
		var coord: Vector2i = entry_info["coord"]
		var entry = sprites.get(coord)
		if entry == null:
			continue # offscreen / non-resident - dirty state already drained above, no texture cost

		var use_full: bool = entry_info["full"]
		var rect_area := 0
		if not use_full:
			rect_area = int(entry_info["w"]) * int(entry_info["h"])
			if rect_area >= chunk_size * chunk_size * FULL_UPDATE_AREA_FRACTION:
				use_full = true

		if use_full:
			var ta := Time.get_ticks_usec()
			var bytes: PackedByteArray = sim_world.get_chunk_pixels(coord.x, coord.y)
			var tb := Time.get_ticks_usec()
			marshal_usec += tb - ta
			if bytes.is_empty():
				continue
			entry.image.set_data(chunk_size, chunk_size, false, Image.FORMAT_RGBA8, bytes)
			var tc := Time.get_ticks_usec()
			setdata_usec += tc - tb
			entry.texture.update(entry.image)
			var td := Time.get_ticks_usec()
			update_usec += td - tc
			full_count += 1
		else:
			var rx: int = entry_info["x"]
			var ry: int = entry_info["y"]
			var rw: int = entry_info["w"]
			var rh: int = entry_info["h"]
			var ta := Time.get_ticks_usec()
			var bytes: PackedByteArray = sim_world.get_chunk_pixels_rect(coord.x, coord.y, rx, ry, rw, rh)
			var tb := Time.get_ticks_usec()
			marshal_usec += tb - ta
			if bytes.is_empty():
				continue
			var patch := Image.create_from_data(rw, rh, false, Image.FORMAT_RGBA8, bytes)
			entry.image.blit_rect(patch, Rect2i(0, 0, rw, rh), Vector2i(rx, ry))
			var tc := Time.get_ticks_usec()
			blit_usec += tc - tb
			entry.texture.update(entry.image)
			var td := Time.get_ticks_usec()
			update_usec += td - tc
			partial_count += 1

	last_dirty_scan_usec = t1 - t0
	last_dirty_count = dirty_chunks.size()
	last_partial_count = partial_count
	last_full_count = full_count
	last_marshal_usec = marshal_usec
	last_setdata_usec = setdata_usec
	last_blit_usec = blit_usec
	last_update_usec = update_usec

	_update_residency(_compute_resident_rect())

func get_render_timings() -> Dictionary:
	return {
		"dirty_scan_usec": last_dirty_scan_usec,
		"dirty_count": last_dirty_count,
		"partial_count": last_partial_count,
		"full_count": last_full_count,
		"marshal_usec": last_marshal_usec,
		"setdata_usec": last_setdata_usec,
		"blit_usec": last_blit_usec,
		"update_usec": last_update_usec,
		"residency_usec": last_residency_usec,
		"created_count": last_created_count,
		"released_count": last_released_count,
	}

func get_residency_stats() -> Dictionary:
	return {
		"resident_count": sprites.size(),
		"resident_rect": resident_rect,
		"total_chunks": world_chunks_x * world_chunks_y,
	}

func get_chunk_world_rect(coord: Vector2i) -> Rect2:
	var px := chunk_size * cell_size
	return Rect2(Vector2(coord.x * px, coord.y * px), Vector2(px, px))
