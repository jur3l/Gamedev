extends Node
## Built-in stress test: Shift+1..5 spawn 10k/50k/100k/250k/500k SAND cells
## above the terrain and let them fall freely, measuring REAL wall-clock
## TIME TO FULLY SETTLE - not a fixed measurement window. Re-runnable at
## any time.
##
## Measurement lifecycle rewrite (see PERFORMANCE_SCALABILITY.md "Stress
## Test Measurement Methodology"): the previous version stopped and
## reported after a fixed MEASURE_DURATION = 6.0s regardless of whether the
## spawned SAND had actually finished falling - fine for light tiers (10k
## settles in a few seconds) but meaningless for heavier ones (500k takes
## tens of seconds), since the report only ever reflected the first 6
## seconds of a much longer process. The primary metric is now TIME TO
## SETTLE, with FPS/sim-ms collected over the WHOLE settle duration, not
## just an early window.
##
## Settled definition: `active_chunks == 0`, the same stable-state signal
## SIMULATION_ACTIVATION.md's own chunk sleep/dirty model already provides
## (a chunk goes to sleep exactly when a full pass finds zero activity in
## it - see World::step()/Chunk::end_pass()). This is a correct completion
## signal in this test's context (nothing external - no mining, no player,
## no reactions - writes to the world while a tier is settling, so a fully
## quiet pass cannot spontaneously become active again on its own). A
## SETTLE_CONFIRMATION_FRAMES streak of consecutive zero-reads is required
## before declaring SETTLED anyway, as cheap extra insurance against a
## single-frame false read, not because the underlying signal is expected
## to be unreliable.
##
## Safety timeout (MAX_TEST_DURATION): NOT a measurement window - a
## runaway/stuck-simulation guard only, generous enough that no legitimate
## tier should ever approach it under normal operation.
##
## Test isolation (see PERFORMANCE_SCALABILITY.md "Stress Test Isolation"):
## running tiers back-to-back on the SAME World instance means each tier's
## SAND falls onto the previous tier's already-settled pile, not onto fresh
## terrain - a different initial condition per tier that invalidates
## cross-tier comparison. This script cannot safely reset itself mid-run
## (Godot's scene-reload lifecycle would free this very node), so isolation
## is the CALLER's responsibility: run each tier from a genuinely fresh
## scene (stop_scene()/play_scene() restart, or get_tree().
## reload_current_scene() before calling _start_test() again) - see
## PERFORMANCE_SCALABILITY.md for exactly how the recorded benchmark below
## was produced. What THIS script does guarantee is that it can tell you
## whether isolation actually held: `_start_test()` records `active_chunks`
## immediately before spawning (0 on a truly fresh, already-quiet world -
## see "Settled definition" above) and marks the whole run `test_valid =
## false`, with an explicit warning in the report, if it wasn't.

const TIERS := {
	KEY_1: 10000,
	KEY_2: 50000,
	KEY_3: 100000,
	KEY_4: 250000,
	KEY_5: 500000,
}

const MAX_TEST_DURATION := 120.0
const SETTLE_CONFIRMATION_FRAMES := 5

@export var sim_world_path: NodePath
var sim_world: Node

var measuring := false
var elapsed := 0.0
var fps_samples: Array = []
var sim_ms_samples: Array = []
var zero_active_streak := 0
var passes_completed := 0
var peak_active_chunks := 0
var settled := false
var timed_out := false
var settle_wall_seconds := 0.0

var last_report := ""
var last_cell_count := 0
var active_chunks_before_spawn := -1
var test_valid := true
var history: Array[Dictionary] = [] # completed tier results, for the summary table

func _ready() -> void:
	sim_world = get_node(sim_world_path)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.shift_pressed and TIERS.has(event.keycode):
		_start_test(TIERS[event.keycode])

func _start_test(cell_count: int) -> void:
	# Isolation check (see the class doc comment "Test isolation" and
	# PERFORMANCE_SCALABILITY.md "Stress Test Isolation") - a real, fresh
	# scene will already be quiet at this point (terrain generation's own
	# writes have long since settled by the time a human/harness gets
	# around to calling this), so active_chunks_before_spawn == 0 is the
	# expected, normal outcome, not a special case to engineer for.
	var stats_before: Dictionary = sim_world.get_stats()
	active_chunks_before_spawn = stats_before.get("active_chunks", -1)
	test_valid = (active_chunks_before_spawn == 0)

	print("=== STRESS TEST START ===")
	print("Tier: %d" % cell_count)
	print("World Seed: %d" % sim_world.world_seed)
	print("Existing Active Chunks Before Spawn: %d" % active_chunks_before_spawn)
	print("Test Valid: %s" % ("YES" if test_valid else "NO - active_chunks was not 0 before spawn (this scene carries state from a previous test; run from a fresh scene for a comparable result)"))
	print("Timer: RESET")

	# Spawn geometry deliberately unchanged from the original harness - same
	# wide-slab shape, same margin, same math - only the measurement
	# lifecycle below this point is new.
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
	zero_active_streak = 0
	passes_completed = 0
	peak_active_chunks = 0
	settled = false
	timed_out = false
	settle_wall_seconds = 0.0
	last_report = ""
	print("[StressTest] spawned %d SAND cells, measuring wall-clock time to fully settle (safety timeout %.0fs)..." % [placed, MAX_TEST_DURATION])

func _process(delta: float) -> void:
	if not measuring:
		return
	elapsed += delta
	var fps := Engine.get_frames_per_second()
	fps_samples.append(fps)

	var stats: Dictionary = sim_world.get_stats()
	var sim_ms: float = stats.get("sim_ms", 0.0)
	sim_ms_samples.append(sim_ms)
	if stats.get("pass_completed", false):
		passes_completed += 1
	var active_chunks: int = stats.get("active_chunks", 0)
	if active_chunks > peak_active_chunks:
		peak_active_chunks = active_chunks

	if active_chunks == 0:
		zero_active_streak += 1
	else:
		zero_active_streak = 0

	if zero_active_streak >= SETTLE_CONFIRMATION_FRAMES:
		measuring = false
		settled = true
		timed_out = false
		settle_wall_seconds = elapsed
		_finish_report()
		return

	if elapsed >= MAX_TEST_DURATION:
		measuring = false
		settled = false
		timed_out = true
		settle_wall_seconds = elapsed
		_finish_report()
		return

func _finish_report() -> void:
	if fps_samples.is_empty():
		return
	var avg_fps := 0.0
	var min_fps := INF
	var max_fps := 0.0
	for f in fps_samples:
		avg_fps += f
		min_fps = min(min_fps, f)
		max_fps = max(max_fps, f)
	avg_fps /= fps_samples.size()

	var avg_sim := 0.0
	var max_sim := 0.0
	for s in sim_ms_samples:
		avg_sim += s
		max_sim = max(max_sim, s)
	avg_sim /= sim_ms_samples.size()

	var result_word := "SETTLED" if settled else "TIMEOUT (did not settle within %.0fs - possible stuck simulation)" % MAX_TEST_DURATION

	# "Physical simulation time" (seconds, independent of wall-clock/FPS) is
	# only a defined quantity for the fixed-timestep GPU backend (Phase 2C,
	# SIMULATION_TIMESCALE.md) - the CPU production path this test actually
	# exercises has no fixed_dt/tick concept (confirmed directly in
	# GPU_GAMEPLAY_INTEGRATION_AUDIT.md: PixelSimWorld::step_simulation()
	# never uses its own `delta` parameter). `passes_completed` is reported
	# instead, as the CPU path's own natural unit of physical progress (one
	# full bottom-to-top sweep - see PROJECT_ARCHITECTURE.md §7), NOT
	# converted into a fake "seconds" number.
	var validity_note := ""
	if not test_valid:
		validity_note = "\n** WARNING: TEST INVALID - started with active_chunks=%d (not 0). This scene carries state from a previous test; result is not valid for cross-tier comparison. **" % active_chunks_before_spawn

	last_report = "Stress test result (%d SAND cells):\nResult: %s\nTime to settle (wall-clock): %.2f sec\nCPU passes completed: %d (no fixed-timestep physical-time unit on this path - see GPU_GAMEPLAY_INTEGRATION_AUDIT.md)\navg FPS=%.1f  min FPS=%.1f  max FPS=%.1f\navg sim=%.3fms  max sim=%.3fms\npeak active chunks=%d/1344%s" % [
		last_cell_count, result_word, settle_wall_seconds, passes_completed, avg_fps, min_fps, max_fps, avg_sim, max_sim, peak_active_chunks, validity_note
	]
	print("[StressTest] " + last_report.replace("\n", " | "))

	print("=== STRESS TEST COMPLETE ===")
	print("Sand: %d" % last_cell_count)
	print("Settled: %s" % ("YES" if settled else "NO (TIMEOUT)"))
	print("Time to Settle: %.2f sec" % settle_wall_seconds)
	print("Test Valid: %s" % ("YES" if test_valid else "NO"))

	history.append({
		"cell_count": last_cell_count,
		"settled": settled,
		"timed_out": timed_out,
		"test_valid": test_valid,
		"settle_wall_seconds": settle_wall_seconds,
		"passes_completed": passes_completed,
		"avg_fps": avg_fps,
		"min_fps": min_fps,
		"max_fps": max_fps,
		"avg_sim_ms": avg_sim,
		"max_sim_ms": max_sim,
		"peak_active_chunks": peak_active_chunks,
	})

func get_report_text() -> String:
	if measuring:
		return "Stress test running... %.1fs elapsed (%d cells), waiting for settle (active_chunks streak=%d/%d, safety timeout %.0fs)" % [
			elapsed, last_cell_count, zero_active_streak, SETTLE_CONFIRMATION_FRAMES, MAX_TEST_DURATION
		]
	return last_report

## Markdown-style summary table across every tier run so far this session -
## the request's explicit "Time to settle" comparison, not a fixed-window
## average. "Fresh Scene" reflects whether THIS script could confirm
## isolation held (active_chunks_before_spawn == 0), not a guarantee this
## script can make on its own - see the class doc comment "Test isolation".
func get_summary_table() -> String:
	if history.is_empty():
		return ""
	var lines: Array[String] = []
	lines.append("| Sand | Fresh Scene | Settled | Time to settle | Avg FPS | Min FPS | Avg Sim ms | Peak Active |")
	lines.append("|---:|:---:|:---:|---:|---:|---:|---:|---:|")
	for h in history:
		var settled_word := "yes" if h["settled"] else "TIMEOUT"
		var fresh_word := "yes" if h["test_valid"] else "NO (INVALID)"
		lines.append("| %s | %s | %s | %.2fs | %.1f | %.1f | %.3f | %d |" % [
			_fmt_count(h["cell_count"]), fresh_word, settled_word, h["settle_wall_seconds"],
			h["avg_fps"], h["min_fps"], h["avg_sim_ms"], h["peak_active_chunks"]
		])
	return "\n".join(lines)

func _fmt_count(n: int) -> String:
	if n >= 1000:
		return "%dk" % (n / 1000)
	return str(n)
