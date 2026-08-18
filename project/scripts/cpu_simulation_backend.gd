class_name CPUSimulationBackend
extends RefCounted
## Production fixed-timestep + accumulator wrapper around the CPU reference
## simulation (PixelSimWorld.step_simulation() -> World::step()). See
## SIMULATION_TIMESCALE.md "CPU Fixed Timestep" for the full writeup.
##
## Problem this fixes: PixelSimWorld::step_simulation(delta)'s own `delta`
## parameter was received and never used (confirmed directly in the C++
## source) - World::step() is a resumable, budget-capped row scan (bounded by
## `simulation_budget_ms` of REAL wall-clock CPU time per call, via
## std::chrono::steady_clock), invoked once per render frame by main.gd's old
## `_process(delta): sim_world.step_simulation(delta)`. That meant render FPS
## directly controlled how many step_simulation() calls - and therefore how
## much budgeted CPU scanning time - happened per real second: more frames
## meant faster physics. Confirmed both by reading the code and empirically
## (the 10k stress tier's time-to-settle dropped from 3.10s at ~240 FPS
## (V-Sync capped) to 1.39s uncapped (~337 FPS avg) with zero simulation code
## changed - see PERFORMANCE_SCALABILITY.md "Stress Test Benchmark Mode").
##
## Fix: the SAME fixed-timestep-accumulator pattern already used by the
## experimental GPU backend (GPUSimulationBackend, Phase 2C,
## SIMULATION_TIMESCALE.md) - `fixed_dt = 1/60s` (this project's existing
## convention, not reinvented - see GPUSimulationBackend.DEFAULT_FIXED_DT),
## applied here to gate calls to the UNMODIFIED, EXISTING
## PixelSimWorld.step_simulation() instead of GPUSandPoC.step(). Real elapsed
## time accumulates; step_simulation() only fires often enough to keep pace
## with fixed_dt, capped by `max_ticks_per_frame` (backlog absorbs the rest,
## exactly like the GPU backend - never a longer per-tick dt, never derived
## from frame count).
##
## `simulation_budget_ms` is UNCHANGED and untouched by this class - it still
## bounds how much REAL CPU time a single step_simulation() call may spend
## scanning (a work-per-call throttle, unaffected by this fix), it does not
## define the physical timestep. The two compose: this accumulator decides
## HOW OFTEN to call step_simulation() (now capped at ~60/sec regardless of
## render FPS), `simulation_budget_ms` still decides how much a single call
## is allowed to do before yielding (World::step()'s budget/resume behavior,
## completely unmodified - zero C++ files touched by this fix).
##
## Determinism: PROJECT_ARCHITECTURE.md §7 already documents that
## `simulation_budget_ms` "changes how many rows get processed per step()
## call, but not the order or outcome of any given row" - i.e. World::step()
## always resumes exactly where it left off (`resume_y_`), so slicing the
## same cumulative work across more-or-fewer, larger-or-smaller
## step_simulation() calls does not change what the simulation computes, only
## how many real-time call boundaries it's spread across. This is what makes
## capping call *frequency* here a correct, non-invasive fix rather than a
## simulation-logic change.
##
## Per-tick wall-clock instrumentation (see PERFORMANCE_SCALABILITY.md
## "Frame-Time / Stutter Instrumentation"): `sim_ms` from
## PixelSimWorld.get_stats() is a CPU-internal-only figure (time spent inside
## World::step()'s own budgeted row scan) and, worse, once render FPS
## decouples from the ~60 tick/s physics rate, most render frames run ZERO
## ticks - a naive per-render-frame sampling of get_stats() would just
## re-read the same stale cached value on every one of those frames, which is
## not a meaningful "simulation cost" sample. This class instead times each
## step_simulation() call directly with Time.get_ticks_usec(), immediately
## around the call, so a "simulation tick" sample always corresponds to an
## actual tick that ran, never a resample of stale state.
##
## `last_advance_tick_usec`/`last_advance_ticks` are always maintained (cheap
## - one Time.get_ticks_usec() pair per tick, no array growth) so any caller
## running after this frame's advance() can read "how much of this frame's
## budget was simulation" without opting into anything. `tick_duration_samples`
## (the full per-tick history, needed for percentiles) is gated behind
## `record_tick_samples` (default false, zero cost/growth in normal gameplay)
## - stress_test.gd turns it on only for the duration of a measured tier.

const DEFAULT_FIXED_DT := 1.0 / 60.0       # matches GPUSimulationBackend.DEFAULT_FIXED_DT - reused, not reinvented
const DEFAULT_MAX_TICKS_PER_FRAME := 10    # matches GPUSimulationBackend.DEFAULT_MAX_TICKS_PER_FRAME - same backlog-cap convention

var sim_world: Object
var fixed_dt: float = DEFAULT_FIXED_DT
var max_ticks_per_frame: int = DEFAULT_MAX_TICKS_PER_FRAME

# --- Simulation clock (mirrors GPUSimulationBackend's clock fields) ---
var accumulator := 0.0
var simulation_time := 0.0   # physical simulated seconds elapsed (tick_count * fixed_dt)
var tick_count := 0          # monotonic, never reset, never derived from frame count - this is what makes FPS independence hold

# --- Backlog / throughput accounting ---
var backlog_ticks := 0             # floor(accumulator / fixed_dt) after this frame's capped loop
var max_backlog_ticks_seen := 0

# --- CPU progress signal (see stress_test.gd "Settled definition") ---
var passes_completed := 0    # incremented only for ticks that ACTUALLY ran and reported pass_completed=true this call - never resampled from a stale get_stats() read (see class doc comment)

var last_stats: Dictionary = {}

# --- Per-tick wall-clock instrumentation (see class doc comment above) ---
var last_advance_tick_usec := 0   # sum of THIS advance() call's own step_simulation() wall time - always maintained, cheap
var last_advance_ticks := 0       # ticks that actually ran in the most recent advance() call
var record_tick_samples := false  # opt-in - stress_test.gd only, off by default so normal gameplay never grows this array
var tick_duration_samples: Array[float] = []  # ms per tick, only appended while record_tick_samples is true

func _init(p_sim_world: Object) -> void:
	sim_world = p_sim_world

## Standard fixed-timestep accumulator loop - `real_delta` (the render
## frame's own delta) is the ONLY input driving how much physical simulation
## happens this frame. Returns a snapshot dict for callers that want it
## in-line; full cumulative state is also available on this object's own
## fields (tick_count, simulation_time, backlog_ticks, passes_completed).
func advance(real_delta: float) -> Dictionary:
	accumulator += real_delta
	var ticks_this_frame := 0
	last_advance_tick_usec = 0
	while accumulator >= fixed_dt and ticks_this_frame < max_ticks_per_frame:
		accumulator -= fixed_dt
		var tick_start_usec := Time.get_ticks_usec()
		var stats: Dictionary = sim_world.step_simulation(fixed_dt)
		var tick_usec := Time.get_ticks_usec() - tick_start_usec
		last_advance_tick_usec += tick_usec
		if record_tick_samples:
			tick_duration_samples.append(tick_usec / 1000.0)
		last_stats = stats
		if stats.get("pass_completed", false):
			passes_completed += 1
		ticks_this_frame += 1
		tick_count += 1
	last_advance_ticks = ticks_this_frame

	if ticks_this_frame > 0:
		simulation_time += ticks_this_frame * fixed_dt

	backlog_ticks = int(floor(accumulator / fixed_dt))
	if backlog_ticks > max_backlog_ticks_seen:
		max_backlog_ticks_seen = backlog_ticks

	return {
		"ticks_this_frame": ticks_this_frame,
		"tick_count": tick_count,
		"simulation_time": simulation_time,
		"backlog_ticks": backlog_ticks,
		"passes_completed": passes_completed,
	}

## Last Dictionary returned by the underlying PixelSimWorld.step_simulation()
## call (sim_ms/active_chunks/etc.) - same shape as PixelSimWorld.get_stats(),
## kept here too so callers don't need a separate reference to sim_world just
## to read it.
func get_stats() -> Dictionary:
	return last_stats

## Resets the clock/backlog/pass state (NOT sim_world itself - that's the
## caller's responsibility, e.g. via a fresh scene / fresh PixelSimWorld).
func reset_clock() -> void:
	accumulator = 0.0
	simulation_time = 0.0
	tick_count = 0
	backlog_ticks = 0
	max_backlog_ticks_seen = 0
	passes_completed = 0
	last_stats = {}
	last_advance_tick_usec = 0
	last_advance_ticks = 0
	tick_duration_samples.clear()
