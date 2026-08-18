extends Node2D
## GPU Preview Sandbox — a standalone, isolated scene that lets the existing
## GPU simulation PoC (GPUSimulationBackend/GPUSandPoC, Phase 2A/2B/2C —
## SIMULATION_TIMESCALE.md) actually drive a LIVE, watchable simulation
## end-to-end: init -> fixed-timestep accumulator advance() -> read_back() ->
## render, at interactive frame rates, in a real running Godot scene.
##
## Deliberately NOT wired into Main.tscn / production gameplay. Per the
## user's own explicit scope choice, this answers a narrower question than
## "port the whole game to GPU": does the GPU solver actually simulate
## SAND+WATER live, visibly, in a real scene — not a headless benchmark
## script. Everything CPU-only and out of scope stays exactly that: no LAVA,
## no Material Reaction System, no mining, no player collision, no
## Background/Foreground. Production Main.tscn/CPUSimulationBackend/
## PixelSimWorld are completely untouched by this file's existence.
##
## World/material conventions reused, not reinvented: MAT_AIR/MAT_SAND/
## MAT_STONE/MAT_WATER (GPUSandPoC), the same wide-slab spawn shape
## GPUTimestepBenchmark.build_slab()/stress_test.gd already use. Colors match
## the CPU production materials' own defined colors (material.cpp) so this
## preview looks like the same game, not a different art style.
##
## Rendering: the GPU buffer is read back and converted to an Image every
## frame — genuinely reading GPU-resident state, not reusing any CPU render
## path (chunk_renderer.gd is untouched and irrelevant here; this scene has
## no PixelSimWorld at all). One RGBA8 pixel per cell; the Sprite2D is scaled
## up for on-screen display rather than expanding the pixel data itself.

const MAT_AIR := GPUSandPoC.MAT_AIR
const MAT_SAND := GPUSandPoC.MAT_SAND
const MAT_STONE := GPUSandPoC.MAT_STONE
const MAT_WATER := GPUSandPoC.MAT_WATER
const MAX_MATERIALS := GPUSandPoC.MAX_MATERIALS

const WORLD_W := 320 # multiple of 8 — GPUSandPoC.setup_grid()'s own constraint
const WORLD_H := 200
const FLOOR_HEIGHT := 20
const CELL_PIXEL_SIZE := 4 # display-only scale; the GPU buffer/Image stay 1 cell = 1 pixel

const SEED_VALUE := 1337 # same convention as main.gd's world_seed — arbitrary but fixed

@onready var sprite: Sprite2D = $Sprite2D
@onready var status_label: Label = $CanvasLayer/StatusLabel
@onready var stats_label: Label = $CanvasLayer/StatsLabel

var backend: GPUSimulationBackend
var image: Image
var texture: ImageTexture
var _color_u32: PackedInt32Array = []
var _last_sand_count := 0
var _last_water_count := 0
var _wall_time := 0.0

func _ready() -> void:
	RenderingServer.set_default_clear_color(Color8(24, 20, 18, 255))
	_build_color_table()

	sprite.centered = false
	sprite.scale = Vector2(CELL_PIXEL_SIZE, CELL_PIXEL_SIZE)
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

	backend = GPUSimulationBackend.new()
	if not backend.init(SEED_VALUE):
		status_label.text = "GPU backend unavailable on this machine/driver (see GPUSandPoC.init()'s own log line above). This preview has no CPU fallback by design — the production CPU path (Main.tscn) is a separate scene, entirely unaffected by this."
		stats_label.text = ""
		set_process(false)
		return

	image = Image.create(WORLD_W, WORLD_H, false, Image.FORMAT_RGBA8)
	texture = ImageTexture.create_from_image(image)
	sprite.texture = texture

	status_label.text = "GPU PREVIEW SANDBOX — SAND+WATER, GPUSimulationBackend (Phase 2C). Production Main.tscn/CPU path is untouched by this scene.\n1 = light SAND | 2 = medium SAND | 3 = heavy SAND | W = SAND+WATER | R = restart current tier"
	_start_tier(1500, 0)

func _exit_tree() -> void:
	if backend != null:
		backend.cleanup()
		backend = null

func _build_color_table() -> void:
	# One packed RGBA8 u32 per material id, precomputed once — avoids
	# per-cell Color object allocation in the per-frame render loop below.
	# Index by material id (0..MAX_MATERIALS-1); anything not explicitly set
	# (including MAT_AIR and the Phase 2E MAT_REACT_TEST_A/B, never spawned
	# by this scene) defaults to fully transparent.
	_color_u32.resize(MAX_MATERIALS)
	_color_u32.fill(0)
	_color_u32[MAT_SAND] = _pack_rgba(218, 190, 97, 255)   # matches material.cpp SAND
	_color_u32[MAT_STONE] = _pack_rgba(120, 120, 120, 255) # matches material.cpp STONE
	_color_u32[MAT_WATER] = _pack_rgba(60, 120, 220, 180)  # matches material.cpp WATER (translucent)

static func _pack_rgba(r: int, g: int, b: int, a: int) -> int:
	return r | (g << 8) | (b << 16) | (a << 24)

func _unhandled_input(event: InputEvent) -> void:
	if backend == null:
		return
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_1: _start_tier(1500, 0)
			KEY_2: _start_tier(6000, 0)
			KEY_3: _start_tier(15000, 0)
			KEY_W: _start_tier(6000, 6000)
			KEY_R: _start_tier(_last_sand_count, _last_water_count)

## Floor of STONE + a SAND slab on the left half of the sky + an optional
## WATER pool on the right half — deliberately adjacent (not far apart) so
## the two visibly interact (SAND displacing into WATER, WATER spreading
## under/around the SAND pile) once both are falling, per MATERIALS.md's own
## documented SAND/GRAVEL-vs-WATER density-displacement rule, exercised here
## live instead of just in a correctness test.
func _build_grid(sand_count: int, water_count: int) -> PackedInt32Array:
	var arr := PackedInt32Array()
	arr.resize(WORLD_W * WORLD_H)
	arr.fill(MAT_AIR)
	for y in range(WORLD_H - FLOOR_HEIGHT, WORLD_H):
		for x in range(WORLD_W):
			arr[y * WORLD_W + x] = MAT_STONE
	var mid := WORLD_W / 2
	_fill_slab(arr, MAT_SAND, 8, mid - 4, sand_count)
	_fill_slab(arr, MAT_WATER, mid + 4, WORLD_W - 8, water_count)
	return arr

func _fill_slab(arr: PackedInt32Array, mat: int, x_start: int, x_end: int, count: int) -> void:
	var width := x_end - x_start
	if width <= 0 or count <= 0:
		return
	var placed := 0
	var y := 4
	var y_limit := WORLD_H - FLOOR_HEIGHT - 2
	while placed < count and y < y_limit:
		var remaining := count - placed
		var row_w: int = min(width, remaining)
		for x in range(x_start, x_start + row_w):
			arr[y * WORLD_W + x] = mat
		placed += row_w
		y += 1

func _start_tier(sand_count: int, water_count: int) -> void:
	var initial := _build_grid(sand_count, water_count)
	backend.reset_grid(WORLD_W, WORLD_H, initial)
	_last_sand_count = sand_count
	_last_water_count = water_count
	_wall_time = 0.0

func _process(delta: float) -> void:
	if backend == null or backend.gpu == null or not backend.gpu.available:
		return
	_wall_time += delta
	var adv := backend.advance(delta)
	var data := backend.read_back()
	_render(data)
	_update_stats(adv)

func _render(data: PackedInt32Array) -> void:
	var bytes := PackedByteArray()
	bytes.resize(data.size() * 4)
	for i in range(data.size()):
		bytes.encode_u32(i * 4, _color_u32[data[i]])
	image.set_data(WORLD_W, WORLD_H, false, Image.FORMAT_RGBA8, bytes)
	texture.update(image)

func _update_stats(adv: Dictionary) -> void:
	var m: Dictionary = backend.get_metrics()
	var ratio: float = (m.simulation_time / _wall_time) if _wall_time > 0.0 else 0.0
	stats_label.text = (
		"Simulation backend: GPU (GPUSimulationBackend / GPUSandPoC) — NOT the production CPU path\n" +
		"World: %dx%d cells | this tier: sand=%d water=%d\n" % [WORLD_W, WORLD_H, _last_sand_count, _last_water_count] +
		"Physical sim time: %.2fs | ticks executed: %d | backlog: %d (max seen %d)\n" % [m.simulation_time, m.ticks_executed, m.backlog_ticks, m.max_backlog_ticks_seen] +
		"GPU compute this frame: %d us | ticks this frame: %d | wall/physical ratio: %.2f\n" % [adv.compute_usec, adv.ticks_this_frame, ratio] +
		"Render FPS: %.0f (this scene's own render loop, not a benchmark measurement)" % Engine.get_frames_per_second()
	)
