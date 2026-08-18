class_name CPUFPSIndependenceTest
extends RefCounted
## FPS-independence validation for the CPU production simulation path (see
## SIMULATION_TIMESCALE.md "CPU Fixed Timestep" / "FPS Independence"). Proves
## - or disproves - that CPUSimulationBackend's fixed-timestep accumulator
## makes physical simulation state depend only on elapsed PHYSICAL time
## (tick_count * fixed_dt), never on render FPS/frame count. Mirrors
## GPUSimulationBackend's own measure_fps_independence()
## (gpu_timestep_benchmark.gd), applied to the CPU reference path instead of
## the GPU PoC.
##
## Uses a small, standalone World (not the full production terrain/scene) so
## a full-grid state comparison is cheap, and drives it with a CONSTANT
## synthetic delta = 1/cadence per call - never real engine frame timing or
## an actual monitor refresh rate (per the request's explicit instruction) -
## so results are reproducible independent of this machine's display.
##
## PROJECT_ARCHITECTURE.md §7 already documents that `simulation_budget_ms`
## "changes how many rows get processed per step() call, but not the order
## or outcome of any given row" - i.e. determinism should hold regardless of
## how the same cumulative work is sliced across calls. This test exercises
## that claim directly (byte-exact grid comparison) rather than just
## trusting the comment - see run()'s report for whether it actually held.

const WORLD_CHUNKS_X := 2
const WORLD_CHUNKS_Y := 3
const CHUNK_SIZE := 64
const WORLD_W := WORLD_CHUNKS_X * CHUNK_SIZE   # 128
const WORLD_H := WORLD_CHUNKS_Y * CHUNK_SIZE   # 192
const FLOOR_Y := WORLD_H - 8
const SAND_CELL_COUNT := 1500
const SAND_MARGIN := 4
const SEED := 4242

const CADENCES: Array[float] = [60.0, 120.0, 240.0, 500.0]
const CHECKPOINT_SECONDS: Array[float] = [1.0, 2.0]

static func _build_world() -> PixelSimWorld:
	var w := PixelSimWorld.new()
	w.world_width_chunks = WORLD_CHUNKS_X
	w.world_height_chunks = WORLD_CHUNKS_Y
	w.world_seed = SEED
	w.simulation_budget_ms = 4.0
	w.init_world()
	w.fill_rect(0, FLOOR_Y, WORLD_W, WORLD_H - FLOOR_Y, w.MATERIAL_STONE)

	var width := WORLD_W - SAND_MARGIN * 2
	var height: int = int(ceil(float(SAND_CELL_COUNT) / width))
	var placed := 0
	var y := SAND_MARGIN
	while placed < SAND_CELL_COUNT and y < SAND_MARGIN + height:
		var remaining := SAND_CELL_COUNT - placed
		var row_w: int = min(width, remaining)
		w.fill_rect(SAND_MARGIN, y, row_w, 1, w.MATERIAL_SAND)
		placed += row_w
		y += 1
	return w

## One combined full-grid scan - the grid snapshot AND the SAND mass count
## come from the same set of get_cell() reads, not two separate passes.
static func _snapshot(w: PixelSimWorld) -> Dictionary:
	var grid := PackedInt32Array()
	grid.resize(WORLD_W * WORLD_H)
	var sand_mass := 0
	var sand_id: int = w.MATERIAL_SAND
	for y in range(WORLD_H):
		for x in range(WORLD_W):
			var m: int = w.get_cell(x, y)
			grid[y * WORLD_W + x] = m
			if m == sand_id:
				sand_mass += 1
	return {"grid": grid, "sand_mass": sand_mass}

## Runs the SAME initial scenario at each of CADENCES, advancing with a
## constant synthetic delta = 1/cadence, and compares tick_count / physical
## state at each checkpoint (physical simulated seconds, not wall-clock).
static func run() -> Dictionary:
	var results := {}
	for cadence in CADENCES:
		var w := _build_world()
		var backend := CPUSimulationBackend.new(w)
		var frame_delta: float = 1.0 / cadence
		var checkpoints := {}
		var next_checkpoint_idx := 0
		var frame_idx := 0
		var max_frames: int = int(ceil(CHECKPOINT_SECONDS[-1] * cadence)) + 5
		while next_checkpoint_idx < CHECKPOINT_SECONDS.size() and frame_idx < max_frames:
			backend.advance(frame_delta)
			frame_idx += 1
			var target: float = CHECKPOINT_SECONDS[next_checkpoint_idx]
			if backend.simulation_time >= target - 1e-9:
				var snap := _snapshot(w)
				checkpoints[target] = {
					"tick_count": backend.tick_count,
					"simulation_time": backend.simulation_time,
					"backlog_ticks": backend.backlog_ticks,
					"max_backlog_ticks_seen": backend.max_backlog_ticks_seen,
					"grid": snap.grid,
					"sand_mass": snap.sand_mass,
					"active_chunks": w.get_stats().get("active_chunks", 0),
				}
				next_checkpoint_idx += 1
		results[cadence] = {"checkpoints": checkpoints, "frames_used": frame_idx}
	return _compare(results)

static func _compare(results: Dictionary) -> Dictionary:
	var report := {
		"cadences": CADENCES,
		"checkpoints": {},
		"all_grids_equal": true,
		"all_tick_counts_equal": true,
		"all_mass_conserved": true,
	}
	var base_cadence: float = CADENCES[0]
	for target in CHECKPOINT_SECONDS:
		var base_cp: Dictionary = results[base_cadence].checkpoints.get(target, {})
		var cp_report := {
			"tick_counts": {}, "sand_mass": {}, "grid_equal_to_base": {}, "active_chunks": {},
		}
		for cadence in CADENCES:
			var cp: Dictionary = results[cadence].checkpoints.get(target, {})
			cp_report.tick_counts[cadence] = cp.get("tick_count", -1)
			cp_report.sand_mass[cadence] = cp.get("sand_mass", -1)
			cp_report.active_chunks[cadence] = cp.get("active_chunks", -1)
			var grid_eq: bool = (cp.get("grid", PackedInt32Array()) == base_cp.get("grid", PackedInt32Array()))
			cp_report.grid_equal_to_base[cadence] = grid_eq
			if not grid_eq:
				report.all_grids_equal = false
			if cp.get("tick_count", -1) != base_cp.get("tick_count", -1):
				report.all_tick_counts_equal = false
			if cp.get("sand_mass", -1) != base_cp.get("sand_mass", -1):
				report.all_mass_conserved = false
		report.checkpoints[target] = cp_report
	return report

## Renders the request's §29 "FPS Independence Validation" table plus a
## byte-exact-equality summary.
static func format_report(report: Dictionary) -> String:
	var lines: Array[String] = []
	lines.append("=== FPS INDEPENDENCE VALIDATION ===")
	lines.append("| Render FPS | Physics ticks/sec | Physical state @ 1s | Physical state @ 2s | Settled @ 2s |")
	lines.append("|---:|---:|---|---|:---:|")
	for cadence in report.cadences:
		var cp1: Dictionary = report.checkpoints.get(1.0, {})
		var cp2: Dictionary = report.checkpoints.get(2.0, {})
		var ticks_1s: int = cp1.get("tick_counts", {}).get(cadence, -1)
		var eq1: bool = cp1.get("grid_equal_to_base", {}).get(cadence, false)
		var eq2: bool = cp2.get("grid_equal_to_base", {}).get(cadence, false)
		var active_2s: int = cp2.get("active_chunks", {}).get(cadence, -1)
		lines.append("| %d | %d | %s | %s | %s |" % [
			int(cadence), ticks_1s,
			"IDENTICAL to base" if eq1 else "DIFFERS from base",
			"IDENTICAL to base" if eq2 else "DIFFERS from base",
			"yes" if active_2s == 0 else "no",
		])
	lines.append("")
	lines.append("All tick counts equal across cadences: %s" % ("YES" if report.all_tick_counts_equal else "NO"))
	lines.append("All grid states byte-exact equal across cadences: %s" % ("YES" if report.all_grids_equal else "NO"))
	lines.append("SAND mass conserved across cadences: %s" % ("YES" if report.all_mass_conserved else "NO"))
	return "\n".join(lines)
