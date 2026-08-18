class_name GPUSimulationBackend
extends RefCounted
## Phase 2C (SIMULATION_TIMESCALE.md): fixed-timestep + accumulator
## orchestration layer around the EXISTING, UNMODIFIED GPUSandPoC. This class
## contains zero simulation logic of its own - it only decides WHEN to call
## GPUSandPoC.step(), never HOW a cell moves (that stays entirely inside
## gpu_cellular_solver.glsl, untouched by this phase).
##
## Phase 2D (GPU_ACTIVE_REGION.md) adds OPT-IN active-region dispatch on top
## (enable_active_region()/wake_region()/run_ticks_active_region()) - the
## existing full-world advance()/run_ticks_unpaced() are completely
## unchanged and remain the default, so every Phase 2C test/benchmark stays
## valid without modification.
##
## Deliberately standalone, same experimental status as GPUSandPoC - not
## wired into PixelSimWorld/Main.tscn/any production path. See
## SIMULATION_TIMESCALE.md "GPU Integration" / "Architectural Invariants".

const PHYSICAL_TICKS_PER_SECOND := 60.0
const DEFAULT_FIXED_DT := 1.0 / PHYSICAL_TICKS_PER_SECOND
const DEFAULT_MAX_TICKS_PER_FRAME := 10
const CHUNK_SIZE := 64 # matches core/sim_config.h's CHUNK_SIZE - see GPU_ACTIVE_REGION.md

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

# --- Active Region (Phase 2D, GPU_ACTIVE_REGION.md) - opt-in, off by default ---
var active_region_enabled := false
var region_active := false    # false = fully asleep, no dispatch happens at all
var region_rect := Rect2i()   # cell-space, always chunk-aligned (see _align_region)
var region_quiet_batches := 0
const REGION_SLEEP_AFTER_QUIET_BATCHES := 1

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
	active_region_enabled = false
	region_active = false
	region_rect = Rect2i()
	region_quiet_batches = 0

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

## Margin sizing (GPU_ACTIVE_REGION.md "Wake Propagation"): material moves at
## most 1 cell/tick (unchanged solver invariant), so a batch of `ticks`
## ticks needs at least ceil(ticks/CHUNK_SIZE) chunks of margin to guarantee
## nothing exits the dispatched rect mid-batch; +1 is safety headroom, not
## load-bearing arithmetic. Callers should use a consistent tick count per
## run_ticks_active_region() call within a given active-region session -
## margin is sized to the batch just executed/about to execute, which is
## only safe if later batches don't request MORE ticks than earlier ones.
static func _margin_chunks_for(ticks: int) -> int:
	return int(ceil(float(max(ticks, 1)) / float(CHUNK_SIZE))) + 1

## Rounds `r` out to whole chunks and expands by `margin_chunks` on every
## side, clamped to the world bounds.
func _align_region(r: Rect2i, margin_chunks: int) -> Rect2i:
	var min_cx: int = int(floor(float(r.position.x) / CHUNK_SIZE)) - margin_chunks
	var min_cy: int = int(floor(float(r.position.y) / CHUNK_SIZE)) - margin_chunks
	var max_cx: int = int(ceil(float(r.position.x + r.size.x) / CHUNK_SIZE)) + margin_chunks
	var max_cy: int = int(ceil(float(r.position.y + r.size.y) / CHUNK_SIZE)) + margin_chunks
	min_cx = max(min_cx, 0)
	min_cy = max(min_cy, 0)
	max_cx = min(max_cx, gpu.width / CHUNK_SIZE)
	max_cy = min(max_cy, gpu.height / CHUNK_SIZE)
	if max_cx <= min_cx:
		max_cx = min_cx + 1
	if max_cy <= min_cy:
		max_cy = min_cy + 1
	return Rect2i(min_cx * CHUNK_SIZE, min_cy * CHUNK_SIZE, (max_cx - min_cx) * CHUNK_SIZE, (max_cy - min_cy) * CHUNK_SIZE)

## Starts active-region dispatch mode (GPU_ACTIVE_REGION.md "Activation
## Semantics"). `initial_rect` is a cell-space rect (e.g. the tight bounding
## box of the initially-seeded material, computed ONCE at setup time, not
## per tick - see "Performance"). `expected_ticks_per_batch` should match
## whatever tick count run_ticks_active_region() will actually be called
## with, so the margin is sized correctly from the start.
func enable_active_region(initial_rect: Rect2i, expected_ticks_per_batch: int = 1) -> void:
	active_region_enabled = true
	region_rect = _align_region(initial_rect, _margin_chunks_for(expected_ticks_per_batch))
	region_active = true
	region_quiet_batches = 0

## External wake trigger (GPU_ACTIVE_REGION.md "Activation Semantics" /
## "Player / Mining") - the GPU-side analog of a mining/spawn command
## touching a region. Safe to call whether the region is currently asleep or
## already active; merges with any existing active rect.
func wake_region(rect: Rect2i, expected_ticks_per_batch: int = 1) -> void:
	var aligned := _align_region(rect, _margin_chunks_for(expected_ticks_per_batch))
	region_rect = aligned.merge(region_rect) if region_active else aligned
	active_region_enabled = true
	region_active = true
	region_quiet_batches = 0

## Active-region equivalent of run_ticks_unpaced() - dispatches only over
## the current active rect (GPUSandPoC.step_region()), then updates the rect
## for the NEXT batch from the GPU-computed activity bounds (GPU_ACTIVE_
## REGION.md "GPU Data Structures" / "Sleeping"). If the region is currently
## fully asleep, no GPU work happens at all, but physical time still passes
## (nothing is happening, so nothing needs to happen - mirrors a settled CPU
## chunk not being scanned while the game clock still advances).
func run_ticks_active_region(count: int) -> Dictionary:
	if count <= 0 or not active_region_enabled:
		return {"ticks_executed": 0, "compute_usec": 0, "dispatched": false, "region_active": region_active}

	if not region_active:
		tick_counter += count
		ticks_executed += count
		simulation_time += count * fixed_dt
		return {"ticks_executed": count, "compute_usec": 0, "dispatched": false, "region_active": false}

	gpu.step_region(count, seed, tick_counter, region_rect.position.x, region_rect.position.y, region_rect.size.x, region_rect.size.y)
	var compute_usec := gpu.last_compute_usec
	tick_counter += count
	ticks_executed += count
	simulation_time += count * fixed_dt
	total_compute_usec += compute_usec

	var t0 := Time.get_ticks_usec()
	var bounds := gpu.read_bounds()
	total_readback_usec += Time.get_ticks_usec() - t0

	if not bounds.has_activity:
		region_quiet_batches += 1
		if region_quiet_batches >= REGION_SLEEP_AFTER_QUIET_BATCHES:
			region_active = false
	else:
		region_quiet_batches = 0
		var tight := Rect2i(bounds.min_x, bounds.min_y, int(bounds.max_x) - int(bounds.min_x) + 1, int(bounds.max_y) - int(bounds.min_y) + 1)
		region_rect = _align_region(tight, _margin_chunks_for(count))

	return {
		"ticks_executed": count,
		"compute_usec": compute_usec,
		"dispatched": true,
		"region_active": region_active,
		"region_rect": region_rect,
	}

## GPU Production Bridge (SIMULATION_TIMESCALE.md "GPU Production Wiring"):
## identical accumulator shape to advance() above, but drives
## run_ticks_active_region() instead of gpu.step() (full-world) - for a
## caller that wants fixed-timestep pacing together with Phase 2D's
## bounded-region dispatch. Reuses the SAME accumulator/tick_counter/backlog
## fields advance() uses, so metrics stay unified regardless of which
## dispatch mode produced them. Never call this and advance()/
## run_ticks_unpaced() on the same backend instance in the same run - both
## would fight over one accumulator. Caller must have already called
## enable_active_region()/wake_region() at least once (this method never
## does so itself - see GPUProductionBridge).
func advance_active_region(real_delta: float) -> Dictionary:
	var t_start := Time.get_ticks_usec()
	accumulator += real_delta

	var ticks_this_frame := 0
	while accumulator >= fixed_dt and ticks_this_frame < max_ticks_per_frame:
		accumulator -= fixed_dt
		ticks_this_frame += 1

	# run_ticks_active_region() already updates tick_counter/ticks_executed/
	# simulation_time/total_compute_usec internally (same contract as when
	# called directly) - not duplicated here.
	var region_result := {}
	if ticks_this_frame > 0:
		region_result = run_ticks_active_region(ticks_this_frame)

	backlog_ticks = int(floor(accumulator / fixed_dt))
	if backlog_ticks > max_backlog_ticks_seen:
		max_backlog_ticks_seen = backlog_ticks
	_backlog_sample_sum += backlog_ticks
	_backlog_sample_count += 1

	var compute_usec: int = region_result.get("compute_usec", 0)
	var t_total := Time.get_ticks_usec() - t_start
	var orchestration_usec := t_total - compute_usec
	total_orchestration_usec += orchestration_usec

	return {
		"ticks_this_frame": ticks_this_frame,
		"backlog_ticks": backlog_ticks,
		"compute_usec": compute_usec,
		"orchestration_usec": orchestration_usec,
		"dispatched": region_result.get("dispatched", false),
		"region_active": region_result.get("region_active", region_active),
	}

func region_chunk_count() -> int:
	if not region_active:
		return 0
	return (region_rect.size.x / CHUNK_SIZE) * (region_rect.size.y / CHUNK_SIZE)

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
