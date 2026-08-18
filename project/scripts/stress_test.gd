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
##
## V-Sync / FPS ceiling (see PERFORMANCE_SCALABILITY.md "Stress Test Benchmark
## Mode"): a capped V-Sync ties reported FPS to the display's own refresh rate
## (e.g. ~144 Hz), which hides the actual achievable frame rate above that
## ceiling - not useful for a performance benchmark. `_start_test()` therefore
## overrides V-Sync to `DisplayServer.VSYNC_DISABLED` and `Engine.max_fps` to
## `0` (unlimited) for the duration of the run only - captured beforehand and
## restored in `_finish_report()`, never touching `project.godot` or normal
## (non-benchmark) gameplay's presentation settings. FPS/frame-time are still
## secondary diagnostic metrics only - TIME TO SETTLE remains primary (see
## "Measurement lifecycle rewrite" above); an uncapped frame rate makes those
## secondary numbers actually meaningful, it doesn't change what's primary.
##
## RENDER FPS != PHYSICS SPEED (see SIMULATION_TIMESCALE.md "CPU Fixed
## Timestep"): `main.gd` now drives the simulation through
## `CPUSimulationBackend`, a fixed-timestep accumulator (`fixed_dt = 1/60s`,
## the project's existing Phase 2C convention) gating calls to the
## unmodified `PixelSimWorld.step_simulation()`. Physical simulation
## progress (`passes_completed`, `physical_simulation_time`, `tick_count`)
## is read from `main.cpu_backend` - its own monotonic clock, never derived
## from this script's per-frame sampling - specifically because sampling
## `sim_world.get_stats()` once per render frame would double-count
## `pass_completed` on frames where the accumulator didn't fire a tick at
## all (the stats dict simply holds the last tick's result until the next
## one runs). Wall-clock "Time to settle" and physical "simulation time" are
## reported side by side and are NOT the same number - see "Wall Clock vs
## Physical Clock" below.
##
## DO NOT TRUST AVERAGE FPS ALONE (see PERFORMANCE_SCALABILITY.md "Frame-Time
## / Stutter Instrumentation"): a report showing a very high average FPS can
## still coexist with a visibly stuttering game if the average is hiding
## periodic long frames - an arithmetic average of 1000 samples where 995 are
## fast and 5 are 60ms spikes still reads as a big number. This harness
## therefore no longer samples the smoothed `Engine.get_frames_per_second()`
## counter (a value Godot itself averages over roughly the last second,
## which is exactly the kind of smoothing that would hide a spike) - it
## derives FPS directly from each frame's own raw `delta`
## (`fps_this_frame = 1.0 / delta`), and reports the full frame-time
## distribution (median/p95/p99/max) plus explicit stutter-frame counts
## (frames slower than 16.67ms / 33.33ms / 50ms - the 60/30/20fps-equivalent
## thresholds) alongside the average. Frame-time distribution, not average
## FPS, is this harness's primary render-performance signal.
##
## SIMULATION TICK TIMING is measured the same way, but at the tick level,
## not the frame level: `CPUSimulationBackend.record_tick_samples` is turned
## on only for the duration of a measured tier (zero cost/growth in normal,
## non-benchmark gameplay - see that class's own doc comment), and each
## `step_simulation()` call is timed individually with `Time.get_ticks_usec()`
## around the call itself - not resampled from `PixelSimWorld.get_stats()`,
## since once render FPS decouples from the ~60 tick/s physics rate most
## render frames run zero ticks and a naive per-frame stats read would just
## reread the same stale cached `sim_ms` value on those frames. This also
## lets the report show the frame/simulation split (`avg frame` vs `avg
## simulation time actually spent inside that frame`, via
## `CPUSimulationBackend.last_advance_tick_usec`), so a stutter can be
## attributed to "simulation-bound" or "something else" rather than guessed.
##
## SIMULATION BACKEND: this harness only ever exercises the CPU production
## path (`main.gd` -> `CPUSimulationBackend` -> `PixelSimWorld.step_simulation()`
## -> `World::step()`). The experimental GPU backend
## (`GPUSimulationBackend`/`GPUSandPoC`, SIMULATION_TIMESCALE.md "Phase 2C")
## is NOT instantiated anywhere in `Main.tscn` and is never exercised by
## this harness - the report says so explicitly so a GPU PoC benchmark
## number is never confused with what this scene actually runs.
##
## MANUAL VALIDATION: this harness is triggered by hand (Shift+1..5) and was
## never auto-run by an agent to produce the numbers in any document - per
## PERFORMANCE_SCALABILITY.md, the final 10k-500k benchmark comparison is a
## human-run, human-observed measurement (including subjective stutter
## observation the numbers above are meant to make objectively checkable),
## not something this script or an agent fabricates on its own.

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
var main: Node # StressTest is always a direct child of Main - see main.gd's own get_node_or_null("StressTest") symmetric lookup

var measuring := false
var elapsed := 0.0
var fps_samples: Array = [] # instantaneous 1.0/delta per frame - NOT Engine.get_frames_per_second() (see class doc comment)
var frame_time_samples: Array = [] # ms, raw per-frame delta - not the smoothed Engine.get_frames_per_second() value
var frame_sim_ms_samples: Array = [] # ms of simulation actually spent inside THIS frame (CPUSimulationBackend.last_advance_tick_usec), 0 on frames with zero ticks
var sim_ms_samples: Array = [] # legacy PixelSimWorld.get_stats() sim_ms per frame - diagnostic only, kept for continuity; see frame_sim_ms_samples/tick timing below for the trustworthy per-tick signal
var frames_over_16_67ms := 0 # slower than 60fps-equivalent
var frames_over_33_33ms := 0 # slower than 30fps-equivalent
var frames_over_50ms := 0
var zero_active_streak := 0
var peak_active_chunks := 0
var settled := false
var timed_out := false
var settle_wall_seconds := 0.0

var last_report := ""
var last_cell_count := 0
var active_chunks_before_spawn := -1
var test_valid := true
var history: Array[Dictionary] = [] # completed tier results, for the summary table

# Physics-clock snapshots (see class doc comment "RENDER FPS != PHYSICS
# SPEED") - main.cpu_backend's counters are monotonic for the whole scene
# lifetime, not per-tier, so this script snapshots them at tier start and
# reports the delta. Under genuine isolation (test_valid == true) this delta
# equals the raw counter (fresh scene -> backend starts at 0 anyway), but
# snapshotting is still the correct approach rather than relying on that -
# see the "no fake reset" isolation philosophy in PERFORMANCE_SCALABILITY.md
# "Stress Test Isolation".
var _tick_count_at_start := 0
var _simulation_time_at_start := 0.0
var _passes_completed_at_start := 0
var peak_backlog_ticks := 0 # sampled max during measurement - NOT a delta of cpu_backend's own cumulative max (see _process())

# V-Sync/FPS-cap override state - captured in _start_test(), restored in
# _finish_report(), so a benchmark run never leaves normal gameplay's
# presentation settings changed. -1 means "no test has overridden it yet".
var original_vsync_mode: int = -1
var original_max_fps: int = -1

func _ready() -> void:
	sim_world = get_node(sim_world_path)
	main = get_parent()

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

	# V-Sync/FPS-cap override (see class doc comment "V-Sync / FPS ceiling")
	# - scoped to this test's lifetime only, restored in _finish_report().
	original_vsync_mode = DisplayServer.window_get_vsync_mode()
	original_max_fps = Engine.max_fps
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0

	# Runtime validation (not just "we called the setter") - re-query both
	# right after setting them, since some platform/fullscreen combinations
	# can silently refuse to disable V-Sync.
	var actual_vsync_mode: int = DisplayServer.window_get_vsync_mode()
	var vsync_ok: bool = (actual_vsync_mode == DisplayServer.VSYNC_DISABLED)
	var fps_cap_ok: bool = (Engine.max_fps == 0)
	var refresh_rate: float = DisplayServer.screen_get_refresh_rate()

	print("=== BENCHMARK CONFIGURATION ===")
	print("Simulation backend: CPU (World::step via CPUSimulationBackend)")
	print("GPU backend: NOT WIRED INTO PRODUCTION GAMEPLAY (GPUSimulationBackend/GPUSandPoC are not instantiated in Main.tscn)")
	print("V-Sync: %s" % ("OFF" if vsync_ok else "FAILED TO DISABLE (mode=%d) - reported FPS may still be ceiling-capped by the display" % actual_vsync_mode))
	print("Display refresh rate: %.1f Hz" % refresh_rate)
	print("FPS limit: %s" % ("NONE / UNLIMITED" if fps_cap_ok else "%d (unexpected - Engine.max_fps was not 0)" % Engine.max_fps))

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
	frame_time_samples.clear()
	frame_sim_ms_samples.clear()
	sim_ms_samples.clear()
	frames_over_16_67ms = 0
	frames_over_33_33ms = 0
	frames_over_50ms = 0
	zero_active_streak = 0
	peak_active_chunks = 0
	peak_backlog_ticks = 0
	settled = false
	timed_out = false
	settle_wall_seconds = 0.0
	last_report = ""

	# Physics-clock snapshot - see the field doc comment above.
	_tick_count_at_start = main.cpu_backend.tick_count
	_simulation_time_at_start = main.cpu_backend.simulation_time
	_passes_completed_at_start = main.cpu_backend.passes_completed

	# Per-tick timing instrumentation (see class doc comment "SIMULATION TICK
	# TIMING") - opt-in on CPUSimulationBackend, scoped to exactly this tier's
	# duration so normal gameplay never pays for it and a tier's sample array
	# never mixes in ticks from a previous tier or from ordinary play.
	main.cpu_backend.record_tick_samples = true
	main.cpu_backend.tick_duration_samples.clear()

	print("[StressTest] spawned %d SAND cells, measuring wall-clock time to fully settle (safety timeout %.0fs)..." % [placed, MAX_TEST_DURATION])

func _process(delta: float) -> void:
	if not measuring:
		return
	elapsed += delta
	var frame_ms: float = delta * 1000.0
	var fps: float = 1.0 / delta if delta > 0.0 else 0.0
	fps_samples.append(fps)
	frame_time_samples.append(frame_ms)
	if frame_ms > 50.0:
		frames_over_50ms += 1
	if frame_ms > 33.33:
		frames_over_33_33ms += 1
	if frame_ms > 16.67:
		frames_over_16_67ms += 1

	# Simulation time actually spent inside THIS frame (StressTest._process()
	# runs after Main._process() -> cpu_backend.advance() in the same frame,
	# since StressTest is a child of Main - see class doc comment "SIMULATION
	# TICK TIMING"). 0 on frames where the accumulator didn't fire a tick.
	frame_sim_ms_samples.append(main.cpu_backend.last_advance_tick_usec / 1000.0)

	var stats: Dictionary = sim_world.get_stats()
	var sim_ms: float = stats.get("sim_ms", 0.0)
	sim_ms_samples.append(sim_ms)
	var active_chunks: int = stats.get("active_chunks", 0)
	if active_chunks > peak_active_chunks:
		peak_active_chunks = active_chunks

	# Backlog is sampled here (current value, own running max) rather than
	# read from main.cpu_backend.max_backlog_ticks_seen directly, because
	# that field is cumulative for the backend's whole lifetime - a delta
	# against it would be wrong (see the peak_backlog_ticks field doc
	# comment: subtracting two running-max snapshots does not recover the
	# max seen strictly between them).
	var current_backlog: int = main.cpu_backend.backlog_ticks
	if current_backlog > peak_backlog_ticks:
		peak_backlog_ticks = current_backlog

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

	# Stop recording per-tick samples for this tier (see _start_test()) -
	# normal, non-benchmark gameplay resumes zero-cost immediately.
	main.cpu_backend.record_tick_samples = false

	# FPS (derived from raw per-frame delta - see class doc comment "DO NOT
	# TRUST AVERAGE FPS ALONE"). avg is still reported, but is explicitly NOT
	# the primary signal - frame-time distribution below is.
	var avg_fps := 0.0
	var min_fps := INF
	var max_fps := 0.0
	for f in fps_samples:
		avg_fps += f
		min_fps = min(min_fps, f)
		max_fps = max(max_fps, f)
	avg_fps /= fps_samples.size()
	var sorted_fps: Array = fps_samples.duplicate()
	sorted_fps.sort()
	var median_fps: float = _percentile(sorted_fps, 0.5)

	var avg_sim := 0.0
	var max_sim := 0.0
	for s in sim_ms_samples:
		avg_sim += s
		max_sim = max(max_sim, s)
	avg_sim /= sim_ms_samples.size()

	# Frame time (raw per-frame delta, ms) - the diagnostic that actually
	# shows render/frame cost once the display-refresh ceiling is removed
	# (see class doc comment "V-Sync / FPS ceiling"), distinct from
	# avg_sim/max_sim above (simulation-only cost, a subset of frame cost).
	# THIS is the primary render-performance signal (class doc comment "DO
	# NOT TRUST AVERAGE FPS ALONE") - a single average is not enough, so the
	# full distribution plus explicit stutter-frame counts are reported.
	var avg_frame_ms := 0.0
	var max_frame_ms := 0.0
	for t in frame_time_samples:
		avg_frame_ms += t
		max_frame_ms = max(max_frame_ms, t)
	avg_frame_ms /= frame_time_samples.size()
	var sorted_frame_times: Array = frame_time_samples.duplicate()
	sorted_frame_times.sort()
	var median_frame_ms: float = _percentile(sorted_frame_times, 0.5)
	var p95_frame_ms: float = _percentile(sorted_frame_times, 0.95)
	var p99_frame_ms: float = _percentile(sorted_frame_times, 0.99)

	# Frame vs. simulation split (see class doc comment "SIMULATION TICK
	# TIMING") - how much of the average frame's own cost was simulation vs.
	# everything else (rendering, engine overhead, this harness itself).
	var avg_frame_sim_ms := 0.0
	for fs in frame_sim_ms_samples:
		avg_frame_sim_ms += fs
	if not frame_sim_ms_samples.is_empty():
		avg_frame_sim_ms /= frame_sim_ms_samples.size()
	var avg_frame_remainder_ms: float = max(avg_frame_ms - avg_frame_sim_ms, 0.0)

	# Simulation TICK timing (not per-frame - see class doc comment) - one
	# sample per step_simulation() call that actually ran during this tier,
	# timed directly with Time.get_ticks_usec() inside CPUSimulationBackend.
	var tick_samples: Array = main.cpu_backend.tick_duration_samples
	var avg_tick_ms := 0.0
	var max_tick_ms := 0.0
	var median_tick_ms := 0.0
	var p95_tick_ms := 0.0
	var p99_tick_ms := 0.0
	if not tick_samples.is_empty():
		for tck in tick_samples:
			avg_tick_ms += tck
			max_tick_ms = max(max_tick_ms, tck)
		avg_tick_ms /= tick_samples.size()
		var sorted_ticks: Array = tick_samples.duplicate()
		sorted_ticks.sort()
		median_tick_ms = _percentile(sorted_ticks, 0.5)
		p95_tick_ms = _percentile(sorted_ticks, 0.95)
		p99_tick_ms = _percentile(sorted_ticks, 0.99)

	# Runtime re-validation (see class doc comment "V-Sync / FPS ceiling") -
	# confirm nothing else flipped V-Sync back on mid-test, before restoring
	# it to whatever normal (non-benchmark) gameplay had before this test.
	var vsync_still_off: bool = (DisplayServer.window_get_vsync_mode() == DisplayServer.VSYNC_DISABLED)
	if original_vsync_mode >= 0:
		DisplayServer.window_set_vsync_mode(original_vsync_mode)
	if original_max_fps >= 0:
		Engine.max_fps = original_max_fps

	var result_word := "SETTLED" if settled else "TIMEOUT (did not settle within %.0fs - possible stuck simulation)" % MAX_TEST_DURATION

	# Physical simulation clock (see class doc comment "RENDER FPS != PHYSICS
	# SPEED") - read from main.cpu_backend, the fixed-timestep accumulator
	# that now gates every step_simulation() call. Deltas against the
	# _start_test() snapshot isolate just this tier's contribution.
	var physics_tick_count: int = main.cpu_backend.tick_count - _tick_count_at_start
	var physical_simulation_time: float = main.cpu_backend.simulation_time - _simulation_time_at_start
	var passes_completed: int = main.cpu_backend.passes_completed - _passes_completed_at_start
	var physics_ticks_per_sec: float = (physics_tick_count / settle_wall_seconds) if settle_wall_seconds > 0.0 else 0.0

	var validity_note := ""
	if not test_valid:
		validity_note = "\n** WARNING: TEST INVALID - started with active_chunks=%d (not 0). This scene carries state from a previous test; result is not valid for cross-tier comparison. **" % active_chunks_before_spawn
	var vsync_note := ""
	if not vsync_still_off:
		vsync_note = "\n** WARNING: V-Sync was re-enabled mid-test (not by this script) - FPS/frame-time numbers above may be display-refresh-capped. **"

	last_report = "Stress test result (%d SAND cells):\nResult: %s\nTime to settle (wall-clock): %.2f sec\nPhysical simulation time: %.2f sec (%d fixed-timestep ticks @ %.4fs each, %.1f ticks/sec)\nCPU passes completed: %d\navg FPS=%.1f  median FPS=%.1f  min FPS=%.1f  max FPS=%.1f\navg frame=%.3fms  median frame=%.3fms  p95 frame=%.3fms  p99 frame=%.3fms  max frame=%.3fms\nframes>16.67ms=%d  frames>33.33ms=%d  frames>50ms=%d\navg sim tick=%.3fms  median=%.3fms  p95=%.3fms  p99=%.3fms  max=%.3fms\navg frame-sim-time=%.3fms  avg frame-remainder=%.3fms\npeak active chunks=%d/1344  peak backlog=%d ticks%s%s" % [
		last_cell_count, result_word, settle_wall_seconds, physical_simulation_time, physics_tick_count, main.cpu_backend.fixed_dt, physics_ticks_per_sec, passes_completed,
		avg_fps, median_fps, min_fps, max_fps,
		avg_frame_ms, median_frame_ms, p95_frame_ms, p99_frame_ms, max_frame_ms,
		frames_over_16_67ms, frames_over_33_33ms, frames_over_50ms,
		avg_tick_ms, median_tick_ms, p95_tick_ms, p99_tick_ms, max_tick_ms,
		avg_frame_sim_ms, avg_frame_remainder_ms,
		peak_active_chunks, peak_backlog_ticks, validity_note, vsync_note
	]
	print("[StressTest] " + last_report.replace("\n", " | "))

	print("=== STRESS TEST RESULT ===")
	print("Sand: %d" % last_cell_count)
	print("Simulation backend: CPU")
	print("GPU backend: NOT WIRED INTO GAMEPLAY")
	print("Fresh scene: %s" % ("YES" if test_valid else "NO"))
	print("V-Sync: %s" % ("OFF" if vsync_still_off else "RE-ENABLED (unexpected)"))
	print("FPS limit: UNLIMITED")
	print("Settled: %s" % ("YES" if settled else "NO (TIMEOUT)"))
	print("")
	print("Time to settle: %.2f sec" % settle_wall_seconds)
	print("Physical simulation time: %.2f sec" % physical_simulation_time)
	print("Physics ticks: %d" % physics_tick_count)
	print("Physics ticks/sec: %.1f" % physics_ticks_per_sec)
	print("")
	print("---- FRAME PACING ----")
	print("Average FPS: %.1f" % avg_fps)
	print("Median FPS: %.1f" % median_fps)
	print("Minimum FPS: %.1f" % min_fps)
	print("Maximum FPS: %.1f" % max_fps)
	print("Average frame: %.3f ms" % avg_frame_ms)
	print("P95 frame: %.3f ms" % p95_frame_ms)
	print("P99 frame: %.3f ms" % p99_frame_ms)
	print("Max frame: %.3f ms" % max_frame_ms)
	print("Frames > 16.67 ms: %d" % frames_over_16_67ms)
	print("Frames > 33.33 ms: %d" % frames_over_33_33ms)
	print("Frames > 50 ms: %d" % frames_over_50ms)
	print("")
	print("---- SIMULATION ----")
	print("Average simulation tick: %.3f ms" % avg_tick_ms)
	print("P95 simulation tick: %.3f ms" % p95_tick_ms)
	print("P99 simulation tick: %.3f ms" % p99_tick_ms)
	print("Max simulation tick: %.3f ms" % max_tick_ms)
	print("Average frame-sim-time (sim time spent inside an average frame): %.3f ms" % avg_frame_sim_ms)
	print("Average frame remainder (frame - sim): %.3f ms" % avg_frame_remainder_ms)
	print("Peak active chunks: %d" % peak_active_chunks)
	print("Peak backlog: %d ticks" % peak_backlog_ticks)
	print("=== END STRESS TEST RESULT ===")

	history.append({
		"cell_count": last_cell_count,
		"settled": settled,
		"timed_out": timed_out,
		"test_valid": test_valid,
		"vsync_off": vsync_still_off,
		"settle_wall_seconds": settle_wall_seconds,
		"physical_simulation_time": physical_simulation_time,
		"physics_tick_count": physics_tick_count,
		"physics_ticks_per_sec": physics_ticks_per_sec,
		"passes_completed": passes_completed,
		"peak_backlog_ticks": peak_backlog_ticks,
		"avg_fps": avg_fps,
		"median_fps": median_fps,
		"min_fps": min_fps,
		"max_fps": max_fps,
		"avg_frame_ms": avg_frame_ms,
		"median_frame_ms": median_frame_ms,
		"max_frame_ms": max_frame_ms,
		"p95_frame_ms": p95_frame_ms,
		"p99_frame_ms": p99_frame_ms,
		"frames_over_16_67ms": frames_over_16_67ms,
		"frames_over_33_33ms": frames_over_33_33ms,
		"frames_over_50ms": frames_over_50ms,
		"avg_sim_ms": avg_sim,
		"max_sim_ms": max_sim,
		"avg_tick_ms": avg_tick_ms,
		"median_tick_ms": median_tick_ms,
		"p95_tick_ms": p95_tick_ms,
		"p99_tick_ms": p99_tick_ms,
		"max_tick_ms": max_tick_ms,
		"avg_frame_sim_ms": avg_frame_sim_ms,
		"avg_frame_remainder_ms": avg_frame_remainder_ms,
		"peak_active_chunks": peak_active_chunks,
	})

func _percentile(sorted_values: Array, p: float) -> float:
	if sorted_values.is_empty():
		return 0.0
	var idx: int = clampi(int(ceil(p * sorted_values.size())) - 1, 0, sorted_values.size() - 1)
	return sorted_values[idx]

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
	lines.append("| Sand | Fresh Scene | V-Sync | Settled | Time to settle | Physical sim time | Ticks | Ticks/sec | Avg FPS | Median FPS | Min FPS | Max FPS | Avg Frame ms | P95 Frame ms | P99 Frame ms | Max Frame ms | >16.67ms | >33.33ms | >50ms | Avg Tick ms | P99 Tick ms | Max Tick ms | Peak Active | Peak Backlog |")
	lines.append("|---:|:---:|:---:|:---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
	for h in history:
		var settled_word := "yes" if h["settled"] else "TIMEOUT"
		var fresh_word := "yes" if h["test_valid"] else "NO (INVALID)"
		var vsync_word := "OFF" if h.get("vsync_off", false) else "ON (unexpected)"
		lines.append("| %s | %s | %s | %s | %.2fs | %.2fs | %d | %.1f | %.1f | %.1f | %.1f | %.1f | %.3f | %.3f | %.3f | %.3f | %d | %d | %d | %.3f | %.3f | %.3f | %d | %d |" % [
			_fmt_count(h["cell_count"]), fresh_word, vsync_word, settled_word, h["settle_wall_seconds"],
			h.get("physical_simulation_time", 0.0), h.get("physics_tick_count", 0), h.get("physics_ticks_per_sec", 0.0),
			h["avg_fps"], h.get("median_fps", 0.0), h["min_fps"], h["max_fps"],
			h["avg_frame_ms"], h.get("p95_frame_ms", 0.0), h.get("p99_frame_ms", 0.0), h["max_frame_ms"],
			h.get("frames_over_16_67ms", 0), h.get("frames_over_33_33ms", 0), h.get("frames_over_50ms", 0),
			h.get("avg_tick_ms", 0.0), h.get("p99_tick_ms", 0.0), h.get("max_tick_ms", 0.0),
			h["peak_active_chunks"], h.get("peak_backlog_ticks", 0)
		])
	return "\n".join(lines)

func _fmt_count(n: int) -> String:
	if n >= 1000:
		return "%dk" % (n / 1000)
	return str(n)
