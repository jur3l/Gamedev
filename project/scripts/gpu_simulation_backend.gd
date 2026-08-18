class_name GPUSimulationBackend
extends RefCounted
## Phase 2C (SIMULATION_TIMESCALE.md): fixed-timestep + accumulator
## orchestration layer around the EXISTING, UNMODIFIED GPUSandPoC. This class
## contains zero simulation logic of its own - it only decides WHEN to call
## GPUSandPoC.step(), never HOW a cell moves (that stays entirely inside
## gpu_cellular_solver.glsl, untouched by this phase).
##
## Deliberately standalone, same experimental status as GPUSandPoC - not
## wired into PixelSimWorld/Main.tscn/any production path. See
## SIMULATION_TIMESCALE.md "GPU Integration" / "Architectural Invariants".

const PHYSICAL_TICKS_PER_SECOND := 60.0
const DEFAULT_FIXED_DT := 1.0 / PHYSICAL_TICKS_PER_SECOND
const DEFAULT_MAX_TICKS_PER_FRAME := 10

var gpu: GPUSandPoC
var fixed_dt: float = DEFAULT_FIXED_DT
var max_ticks_per_frame: int = DEFAULT_MAX_TICKS_PER_FRAME
var seed: int = 1

# --- Simulation clock (SIMULATION_TIMESCALE.md "Fixed Timestep") ---
var simulation_time := 0.0   # physical simulated seconds elapsed (ticks_executed * fixed_dt)
var accumulator := 0.0
var tick_counter := 0        # monotonic tick index fed to the GPU as start_step - never reset,
                              # never derived from frame count (this is what makes FPS independence hold)

# --- Backlog / throughput accounting ("Backlog") ---
var ticks_executed := 0
var backlog_ticks := 0             # current, i.e. floor(accumulator / fixed_dt) after this frame's capped loop
var max_backlog_ticks_seen := 0
var _backlog_sample_sum := 0.0
var _backlog_sample_count := 0

# --- Timing breakdown ("No Hidden CPU Bottleneck") ---
var total_compute_usec := 0
var total_readback_usec := 0
var total_orchestration_usec := 0  # advance()'s own cost, minus GPU compute time

func init(seed_value: int) -> bool:
	seed = seed_value
	gpu = GPUSandPoC.new()
	return gpu.init()

func setup_grid(w: int, h: int, initial: PackedInt32Array) -> bool:
	if gpu == null or not gpu.available:
		return false
	return gpu.setup_grid(w, h, initial)

## Re-points this backend at a fresh grid AND resets the simulation clock
## (simulation_time/accumulator/tick_counter/backlog counters) - for reusing
## one backend (one RenderingDevice/shader) across several benchmark runs
## instead of creating a new one per run. GPUSandPoC.setup_grid() itself does
## not free a previous grid's buffers (designed for one-call-per-instance
## use) - freeing them here, in the one place that needs repeated grid
## resets, avoids reaching into GPUSandPoC's internals from multiple
## call sites. See SIMULATION_TIMESCALE.md "GPU Stability" for why reusing
## one device across a benchmark run (rather than creating one per tier)
## matters here too.
func reset_grid(w: int, h: int, initial: PackedInt32Array) -> bool:
	if gpu == null or not gpu.available:
		return false
	if gpu._buf_a.is_valid():
		gpu._rd.free_rid(gpu._buf_a)
	if gpu._buf_b.is_valid():
		gpu._rd.free_rid(gpu._buf_b)
	var ok := gpu.setup_grid(w, h, initial)
	if ok:
		reset_clock()
	return ok

func reset_clock() -> void:
	simulation_time = 0.0
	accumulator = 0.0
	tick_counter = 0
	ticks_executed = 0
	backlog_ticks = 0
	max_backlog_ticks_seen = 0
	_backlog_sample_sum = 0.0
	_backlog_sample_count = 0
	total_compute_usec = 0
	total_readback_usec = 0
	total_orchestration_usec = 0

## Standard fixed-timestep accumulator loop (SIMULATION_TIMESCALE.md
## "Accumulator"). `real_delta` is the ONLY input driving how much physical
## simulation happens - this is the direct fix for step_simulation(delta)
## discarding delta entirely (SIMULATION_TIMESCALE_INVESTIGATION.md).
## Batches every tick this frame into ONE GPUSandPoC.step() call (one
## submit()/sync()), never N per-tick round trips. Never reads back GPU
## state - see "GPU Integration" for why.
func advance(real_delta: float) -> Dictionary:
	var t_start := Time.get_ticks_usec()
	accumulator += real_delta

	var ticks_this_frame := 0
	while accumulator >= fixed_dt and ticks_this_frame < max_ticks_per_frame:
		accumulator -= fixed_dt
		ticks_this_frame += 1

	var compute_usec := 0
	if ticks_this_frame > 0:
		gpu.step(ticks_this_frame, seed, tick_counter)
		compute_usec = gpu.last_compute_usec
		tick_counter += ticks_this_frame
		ticks_executed += ticks_this_frame
		simulation_time += ticks_this_frame * fixed_dt
		total_compute_usec += compute_usec

	backlog_ticks = int(floor(accumulator / fixed_dt))
	if backlog_ticks > max_backlog_ticks_seen:
		max_backlog_ticks_seen = backlog_ticks
	_backlog_sample_sum += backlog_ticks
	_backlog_sample_count += 1

	var t_total := Time.get_ticks_usec() - t_start
	var orchestration_usec := t_total - compute_usec
	total_orchestration_usec += orchestration_usec

	return {
		"ticks_this_frame": ticks_this_frame,
		"backlog_ticks": backlog_ticks,
		"compute_usec": compute_usec,
		"orchestration_usec": orchestration_usec,
	}

## Direct, unpaced tick execution - bypasses the accumulator entirely. Used
## for the GPU Capacity / hardware-throughput measurement (SIMULATION_
## TIMESCALE.md "GPU Capacity"), which deliberately measures raw GPU
## throughput independent of any assumed frame cadence.
func run_ticks_unpaced(count: int) -> Dictionary:
	if count <= 0:
		return {"ticks_executed": 0, "compute_usec": 0}
	gpu.step(count, seed, tick_counter)
	tick_counter += count
	ticks_executed += count
	simulation_time += count * fixed_dt
	total_compute_usec += gpu.last_compute_usec
	return {"ticks_executed": count, "compute_usec": gpu.last_compute_usec}

func read_back() -> PackedInt32Array:
	var t0 := Time.get_ticks_usec()
	var data := gpu.read_back()
	total_readback_usec += Time.get_ticks_usec() - t0
	return data

## Cumulative summary - see SIMULATION_TIMESCALE.md "Backlog" / "Real-Time
## Ratio" for field definitions.
func get_metrics() -> Dictionary:
	var avg_backlog := 0.0
	if _backlog_sample_count > 0:
		avg_backlog = _backlog_sample_sum / _backlog_sample_count
	return {
		"simulation_time": simulation_time,
		"ticks_executed": ticks_executed,
		"ticks_requested": ticks_executed + backlog_ticks,
		"backlog_ticks": backlog_ticks,
		"max_backlog_ticks_seen": max_backlog_ticks_seen,
		"avg_backlog_ticks": avg_backlog,
		"total_compute_usec": total_compute_usec,
		"total_readback_usec": total_readback_usec,
		"total_orchestration_usec": total_orchestration_usec,
	}

func cleanup() -> void:
	if gpu != null:
		gpu.cleanup()
		gpu = null
