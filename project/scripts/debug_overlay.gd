extends CanvasLayer
## Performance + debug overlay (section 19/22 of the spec): FPS, frame/sim/render
## timings, chunk activity counts, cell counts, material update rate, plus a
## togglable world-space chunk-boundary/active-chunk debug view.

@export var sim_world_path: NodePath
@export var main_path: NodePath
@export var chunk_renderer_path: NodePath
@export var mining_building_path: NodePath

var sim_world: Node
var main: Node
var chunk_renderer: Node2D
var mining_building: Node

var label: Label
var chunk_overlay: Node2D
var show_chunk_debug := false

var material_tooltip: Label
var show_material_inspector := false

var render_ms := 0.0

func _ready() -> void:
	sim_world = get_node(sim_world_path)
	main = get_node(main_path)
	chunk_renderer = get_node(chunk_renderer_path)
	mining_building = get_node(mining_building_path)

	label = Label.new()
	label.add_theme_font_size_override("font_size", 14)
	label.position = Vector2(10, 10)
	label.add_theme_color_override("font_color", Color(1, 1, 1))
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)
	add_child(label)

	chunk_overlay = Node2D.new()
	chunk_overlay.z_index = 500
	chunk_overlay.draw.connect(_draw_chunk_overlay)
	# Needs to live in world space, alongside the chunk renderer, not this CanvasLayer.
	chunk_renderer.get_parent().add_child.call_deferred(chunk_overlay)

	material_tooltip = Label.new()
	material_tooltip.add_theme_font_size_override("font_size", 14)
	material_tooltip.add_theme_color_override("font_color", Color(1, 1, 0.8))
	material_tooltip.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	material_tooltip.add_theme_constant_override("shadow_offset_x", 1)
	material_tooltip.add_theme_constant_override("shadow_offset_y", 1)
	material_tooltip.visible = false
	add_child(material_tooltip)

func _process(_delta: float) -> void:
	if Input.is_action_just_pressed("toggle_debug_view"):
		show_chunk_debug = not show_chunk_debug
	if Input.is_action_just_pressed("toggle_material_inspector"):
		show_material_inspector = not show_material_inspector

	_update_material_tooltip()

	var stats: Dictionary = sim_world.get_stats()
	var text := ""
	text += "FPS: %d (%.2f ms/frame)\n" % [Engine.get_frames_per_second(), 1000.0 / max(Engine.get_frames_per_second(), 1)]
	text += "Simulation: %.3f ms | pass complete: %s\n" % [stats.get("sim_ms", 0.0), stats.get("pass_completed", false)]
	text += "Chunks: active=%d sleeping=%d total=%d\n" % [stats.get("active_chunks", 0), stats.get("sleeping_chunks", 0), stats.get("total_chunks", 0)]
	var residency: Dictionary = chunk_renderer.get_residency_stats()
	text += "Render resources: resident=%d/%d (%.1f%%)\n" % [
		residency.get("resident_count", 0), residency.get("total_chunks", 0),
		100.0 * residency.get("resident_count", 0) / max(residency.get("total_chunks", 1), 1)
	]
	text += "Cells: total=%s evaluated/step=%d moved/step=%d\n" % [_fmt(stats.get("total_cells", 0)), stats.get("cells_evaluated", 0), stats.get("cells_moved", 0)]
	text += "Reactions: checks/step=%d executed/step=%d\n" % [stats.get("reaction_checks", 0), stats.get("reactions_executed", 0)]
	text += "\nIron Ore: %d   Copper Ore: %d\n" % [main.get_resource(sim_world.MATERIAL_IRON_ORE), main.get_resource(sim_world.MATERIAL_COPPER_ORE)]
	text += "\n[F1] toggle chunk debug view   [9] toggle material inspector\n"
	text += "[1] wood [2] metal [3] water [4] lava   LMB mine / RMB build\n"
	text += "Mining tool: %s, size=%d   [ ] resize   [T] toggle shape\n" % [mining_building.mining_shape_name(), mining_building.mining_size]
	text += "[1-5 with Shift] stress test tiers: 10k/50k/100k/250k/500k sand"
	if main.has_method("get_stress_test_report"):
		var report: String = main.get_stress_test_report()
		if report != "":
			text += "\n\n" + report
	label.text = text

	if chunk_overlay:
		chunk_overlay.queue_redraw()

func _fmt(n) -> String:
	return str(n)

func _update_material_tooltip() -> void:
	if not show_material_inspector:
		material_tooltip.visible = false
		return
	var camera := get_viewport().get_camera_2d()
	if camera == null:
		material_tooltip.visible = false
		return

	var world_pos: Vector2 = camera.get_global_mouse_position()
	var cell_size: int = sim_world.get_simulation_cell_size()
	var cell_x := int(floor(world_pos.x / cell_size))
	var cell_y := int(floor(world_pos.y / cell_size))

	var material_id: int = sim_world.get_cell(cell_x, cell_y)
	var material_name: String = sim_world.get_material_name(material_id)

	material_tooltip.text = "%s  (%d, %d)" % [material_name, cell_x, cell_y]
	material_tooltip.position = get_viewport().get_mouse_position() + Vector2(16, 16)
	material_tooltip.visible = true

func _draw_chunk_overlay() -> void:
	if not show_chunk_debug or chunk_overlay == null:
		return
	var world_chunks: Vector2i = sim_world.get_world_size_chunks()
	var active: Array = sim_world.get_active_chunk_coords()
	var active_set := {}
	for c in active:
		active_set[c] = true

	# Resident region (Phase 1 - Lazy Rendering): drawn as a bright outline
	# so it's visually obvious which chunks currently hold a render resource
	# (Sprite2D/Image/ImageTexture) vs. which are simulation-only. Iterating
	# the world's full chunk grid here (like the active-chunk pass above) is
	# this debug view's own, pre-existing cost - toggled off by default (F1),
	# not something Phase 1 needed to change.
	var residency: Dictionary = chunk_renderer.get_residency_stats()
	var resident_rect: Rect2i = residency.get("resident_rect", Rect2i())

	var chunk_size: int = sim_world.get_chunk_size()
	var cell_size: int = sim_world.get_simulation_cell_size()
	var px := chunk_size * cell_size

	for cy in range(world_chunks.y):
		for cx in range(world_chunks.x):
			var coord := Vector2i(cx, cy)
			var rect := Rect2(Vector2(cx * px, cy * px), Vector2(px, px))
			var is_active: bool = active_set.has(coord)
			var is_resident: bool = resident_rect.has_point(coord)
			var color: Color
			if is_active:
				color = Color(1, 0.3, 0.3, 0.9)
			elif is_resident:
				color = Color(0.3, 0.9, 1.0, 0.5) # resident (has render resource), simulation-idle
			else:
				color = Color(0.3, 0.3, 0.3, 0.35) # non-resident, simulation-only
			chunk_overlay.draw_rect(rect, color, false, 1.0)
