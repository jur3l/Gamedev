extends Node
## Built-in stress test (spec section 21): Shift+1..5 spawn 10k/50k/100k/250k/
## 500k SAND cells above the terrain and let them fall freely, while sampling
## FPS/sim-ms for a measurement window. Re-runnable at any time.

const TIERS := {
	KEY_1: 10000,
	KEY_2: 50000,
	KEY_3: 100000,
	KEY_4: 250000,
	KEY_5: 500000,
}
const MEASURE_DURATION := 6.0

@export var sim_world_path: NodePath
var sim_world: Node

var measuring := false
var elapsed := 0.0
var fps_samples: Array = []
var sim_ms_samples: Array = []
var last_report := ""
var last_cell_count := 0

func _ready() -> void:
	sim_world = get_node(sim_world_path)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.shift_pressed and TIERS.has(event.keycode):
		_start_test(TIERS[event.keycode])

func _start_test(cell_count: int) -> void:
	var world_cells: Vector2i = sim_world.get_world_size_cells()
	var margin := 10
	var width: int = world_cells.x - margin * 2
	var height: int = int(ceil(float(cell_count) / width))
	height = min(height, world_cells.y / 3) # keep it inside the sky band

	var placed := 0
	var y := margin
	while placed < cell_count and y < margin + height:
		var remaining := cell_count - placed
		var row_w: int = min(width, remaining)
		sim_world.fill_rect(margin, y, row_w, 1, sim_world.MATERIAL_SAND)
		placed += row_w
		y += 1

	last_cell_count = placed
	measuring = true
	elapsed = 0.0
	fps_samples.clear()
	sim_ms_samples.clear()
	last_report = ""
	print("[StressTest] spawned %d SAND cells, measuring for %.1fs..." % [placed, MEASURE_DURATION])

func _process(delta: float) -> void:
	if not measuring:
		return
	elapsed += delta
	fps_samples.append(Engine.get_frames_per_second())
	var stats: Dictionary = sim_world.get_stats()
	sim_ms_samples.append(stats.get("sim_ms", 0.0))

	if elapsed >= MEASURE_DURATION:
		measuring = false
		_finish_report()

func _finish_report() -> void:
	if fps_samples.is_empty():
		return
	var avg_fps := 0.0
	var min_fps := INF
	for f in fps_samples:
		avg_fps += f
		min_fps = min(min_fps, f)
	avg_fps /= fps_samples.size()

	var avg_sim := 0.0
	var max_sim := 0.0
	for s in sim_ms_samples:
		avg_sim += s
		max_sim = max(max_sim, s)
	avg_sim /= sim_ms_samples.size()

	var stats: Dictionary = sim_world.get_stats()
	last_report = "Stress test result (%d SAND cells):\navg FPS=%.1f  min FPS=%.1f\navg sim=%.3fms  max sim=%.3fms\nactive chunks=%d/%d" % [
		last_cell_count, avg_fps, min_fps, avg_sim, max_sim, stats.get("active_chunks", 0), stats.get("total_chunks", 0)
	]
	print("[StressTest] " + last_report.replace("\n", " | "))

func get_report_text() -> String:
	if measuring:
		return "Stress test running... %.1fs / %.1fs (%d cells)" % [elapsed, MEASURE_DURATION, last_cell_count]
	return last_report
