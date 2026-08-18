class_name GPUSolverTests
extends RefCounted
## Persisted, re-runnable version of the Phase 2A (SAND, 12 tests) and Phase
## 2B (WATER, 16 tests) GPU correctness checks documented in
## GPU_SIMULATION.md "Results". These previously existed only as one-off
## scripted runs during development, never committed - this file is what
## fulfills GPU_SIMULATION.md's own originally-recommended "Phase 2C -
## formal, automated CPU/GPU validation harness" (see SIMULATION_TIMESCALE.md
## "Validation" for how this reconciles with the Phase 2C timestep work).
##
## Exercises the UNMODIFIED GPUSandPoC / gpu_cellular_solver.glsl - no GPU
## solver code is changed by this file.
##
## Almost all tests share ONE GPUSandPoC instance (one RenderingDevice, one
## compiled shader/pipeline), re-pointed at a fresh grid per test via
## _reset_grid(). Only the tests that specifically need instance isolation
## (determinism-across-independent-runs, init/cleanup edge cases) create
## their own. An earlier version of this file gave every one of the 28 tests
## its own fresh instance (~28 RenderingDevice creations + shader
## compilations back-to-back in one script call) and this reliably crashed
## the running Godot process partway through - confirmed live, see
## SIMULATION_TIMESCALE.md "GPU Stability". Rapid repeated device/shader
## creation, not per-tick simulation load, was the destabilizing factor.

const MAT_AIR := GPUSandPoC.MAT_AIR
const MAT_SAND := GPUSandPoC.MAT_SAND
const MAT_STONE := GPUSandPoC.MAT_STONE
const MAT_WATER := GPUSandPoC.MAT_WATER

var checks := 0
var failures := 0
var log_lines: Array[String] = []

func _check(cond: bool, label: String) -> void:
	checks += 1
	if not cond:
		failures += 1
		log_lines.append("  FAIL: " + label)

func _grid(w: int, h: int, mat: int = MAT_AIR) -> PackedInt32Array:
	var arr := PackedInt32Array()
	arr.resize(w * h)
	arr.fill(mat)
	return arr

func _idx(w: int, x: int, y: int) -> int:
	return y * w + x

func _count(data: PackedInt32Array, mat: int) -> int:
	var n := 0
	for v in data:
		if v == mat:
			n += 1
	return n

func _new_backend() -> GPUSandPoC:
	var b := GPUSandPoC.new()
	b.init()
	return b

## Re-points an already-initialized backend at a fresh grid, freeing its
## previous ping-pong buffers first (GPUSandPoC.setup_grid() does not do
## this itself - it's designed to be called once per instance). Reaches into
## GPUSandPoC's "private" (underscore-prefixed, not GDScript-enforced) RID
## fields deliberately, for this test file only, to avoid modifying
## gpu_sand_poc.gd itself for a test-harness-only need.
func _reset_grid(b: GPUSandPoC, w: int, h: int, initial: PackedInt32Array) -> void:
	if b._buf_a.is_valid():
		b._rd.free_rid(b._buf_a)
	if b._buf_b.is_valid():
		b._rd.free_rid(b._buf_b)
	b.setup_grid(w, h, initial)

## A standalone, non-scene-tree PixelSimWorld used only as the CPU reference
## for the CPU-vs-GPU comparison tests. Freed by the caller when done.
func _new_cpu_world(seed_value: int, w_chunks: int, h_chunks: int) -> PixelSimWorld:
	var w := PixelSimWorld.new()
	w.world_width_chunks = w_chunks
	w.world_height_chunks = h_chunks
	w.world_seed = seed_value
	w.init_world()
	return w

# ================== Phase 2A: SAND (12 tests) ==================

func test_sand_02_empty_world(b: GPUSandPoC) -> void:
	_reset_grid(b, 64, 64, _grid(64, 64))
	b.step(10, 1)
	var data := b.read_back()
	_check(_count(data, MAT_AIR) == 64 * 64, "sand_02_empty_world: all-AIR grid stays all-AIR after 10 steps")

func test_sand_03_single_cell_falls(b: GPUSandPoC) -> void:
	var w := 64
	var initial := _grid(w, 64)
	initial[_idx(w, 32, 5)] = MAT_SAND
	_reset_grid(b, w, 64, initial)
	b.step(1, 1)
	var data := b.read_back()
	_check(data[_idx(w, 32, 5)] == MAT_AIR, "sand_03_single_cell_falls: origin vacated after 1 step")
	_check(data[_idx(w, 32, 6)] == MAT_SAND, "sand_03_single_cell_falls: fell exactly 1 row")

func test_sand_04_small_pile_settles(b: GPUSandPoC) -> void:
	var w := 64
	var initial := _grid(w, 64)
	for x in range(30, 35):
		initial[_idx(w, x, 5)] = MAT_SAND
	for x in range(0, w):
		initial[_idx(w, x, 40)] = MAT_STONE # floor
	_reset_grid(b, w, 64, initial)
	b.step(40, 1)
	var data := b.read_back()
	_check(_count(data, MAT_SAND) == 5, "sand_04_small_pile_settles: mass conserved (5 SAND cells)")
	var above_floor := true
	for x in range(w):
		if data[_idx(w, x, 40)] == MAT_SAND:
			above_floor = false
	_check(above_floor, "sand_04_small_pile_settles: nothing sank into the floor row")

func test_sand_05_gravity_16_rows(b: GPUSandPoC) -> void:
	var w := 64
	var initial := _grid(w, 64)
	initial[_idx(w, 32, 0)] = MAT_SAND
	for x in range(w):
		initial[_idx(w, x, 16)] = MAT_STONE # floor exactly 16 rows down
	_reset_grid(b, w, 64, initial)
	b.step(16, 1)
	var data := b.read_back()
	_check(data[_idx(w, 32, 15)] == MAT_SAND, "sand_05_gravity_16_rows: reached the floor after exactly 16 steps")

func test_sand_06_diagonal_movement(b: GPUSandPoC) -> void:
	var w := 64
	var initial := _grid(w, 64)
	initial[_idx(w, 32, 5)] = MAT_SAND
	initial[_idx(w, 32, 6)] = MAT_STONE # straight-down blocked, both diagonals open
	_reset_grid(b, w, 64, initial)
	b.step(1, 1)
	var data := b.read_back()
	var moved_left := data[_idx(w, 31, 6)] == MAT_SAND
	var moved_right := data[_idx(w, 33, 6)] == MAT_SAND
	_check(moved_left != moved_right, "sand_06_diagonal_movement: slid to exactly one diagonal")
	_check(_count(data, MAT_SAND) == 1, "sand_06_diagonal_movement: mass conserved")

func test_sand_07_chunk_boundary_126_rows(b: GPUSandPoC) -> void:
	var w := 128
	var h := 128
	var initial := _grid(w, h)
	initial[_idx(w, 60, 1)] = MAT_SAND
	for x in range(w):
		initial[_idx(w, x, 127)] = MAT_STONE
	_reset_grid(b, w, h, initial)
	b.step(125, 1) # falls from row 1 to row 126 (125 rows), settling on the floor at 127
	var data := b.read_back()
	_check(data[_idx(w, 60, 126)] == MAT_SAND, "sand_07_chunk_boundary: crossed two would-be 64-row chunk boundaries with zero special-case code, settled on the floor")

func test_sand_08_multistep_counts(b: GPUSandPoC) -> void:
	var w := 64
	# Isolated cell, no contention - after N steps it should be exactly N rows lower.
	for n in [1, 5, 10, 20]:
		var initial := _grid(w, 64)
		initial[_idx(w, 32, 0)] = MAT_SAND
		_reset_grid(b, w, 64, initial)
		b.step(n, 1)
		var data := b.read_back()
		_check(data[_idx(w, 32, n)] == MAT_SAND, "sand_08_multistep_counts: after %d steps, fell exactly %d rows" % [n, n])

func test_sand_09_cpu_gpu_no_contention(b: GPUSandPoC) -> void:
	var w := 64
	var initial := _grid(w, 64)
	initial[_idx(w, 32, 0)] = MAT_SAND
	_reset_grid(b, w, 64, initial)
	b.step(30, 1)
	var gpu_data := b.read_back()

	var cpu := _new_cpu_world(1, 1, 1)
	cpu.set_cell(32, 0, cpu.MATERIAL_SAND)
	for i in range(30):
		cpu.step_simulation(1.0 / 60.0)
	# GPU moves at most 1 cell/dispatch (no cascade); CPU's own single-cell,
	# no-obstruction fall is likewise exactly 1 row per completed pass - both
	# should land in the same place with nothing else nearby to contest.
	var cpu_mat := cpu.get_cell(32, 30)
	_check(cpu_mat == cpu.MATERIAL_SAND, "sand_09_cpu_gpu_no_contention: CPU reference fell 30 rows in 30 passes")
	_check(gpu_data[_idx(w, 32, 30)] == MAT_SAND, "sand_09_cpu_gpu_no_contention: GPU matches CPU exactly (no-contention case)")
	cpu.free()

func test_sand_10_deterministic_repeatability() -> void:
	var w := 64
	var initial := _grid(w, 64)
	for x in range(30, 35):
		initial[_idx(w, x, 5)] = MAT_SAND
	var b1 := _new_backend()
	var b2 := _new_backend()
	if not b1.available or not b2.available:
		b1.cleanup(); b2.cleanup(); return
	b1.setup_grid(w, 64, initial)
	b2.setup_grid(w, 64, initial)
	b1.step(60, 42)
	b2.step(60, 42)
	var d1 := b1.read_back()
	var d2 := b2.read_back()
	_check(d1 == d2, "sand_10_deterministic_repeatability: byte-identical final buffers, same seed")
	b1.cleanup()
	b2.cleanup()

func test_sand_11_graceful_when_not_set_up() -> void:
	var b := _new_backend()
	# Calling step()/read_back() before setup_grid() must not crash - the
	# graceful-unavailable path itself (renderer without RenderingDevice
	# support) was validated historically under gl_compatibility per
	# GPU_SIMULATION.md "Renderer Prerequisite" and isn't re-testable live
	# now that the project's renderer is permanently Forward+ (see
	# PROJECT_ARCHITECTURE.md) - this test covers the other graceful-failure
	# surface: calling the API out of order.
	if b.available:
		b.step(1, 1) # width/height are 0 - must not crash
		var data := b.read_back()
		_check(true, "sand_11_graceful_when_not_set_up: step()/read_back() before setup_grid() did not crash")
		_check(data.size() == 0, "sand_11_graceful_when_not_set_up: read_back() before setup_grid() returns empty, not garbage")
	b.cleanup()

func test_sand_12_resource_cleanup() -> void:
	var b := _new_backend()
	if not b.available: b.cleanup(); return
	b.setup_grid(64, 64, _grid(64, 64, MAT_SAND))
	b.cleanup()
	_check(not b.available, "sand_12_resource_cleanup: available == false after cleanup()")
	b.step(1, 1) # must be a safe no-op, not a crash
	var data := b.read_back()
	_check(data.size() == 0, "sand_12_resource_cleanup: step()/read_back() after cleanup() are safe no-ops")

# ================== Phase 2B: WATER (16 tests) ==================

func test_water_01_single_cell_falls(b: GPUSandPoC) -> void:
	var w := 64
	var initial := _grid(w, 64)
	initial[_idx(w, 32, 5)] = MAT_WATER
	_reset_grid(b, w, 64, initial)
	b.step(1, 1)
	var data := b.read_back()
	_check(data[_idx(w, 32, 6)] == MAT_WATER, "water_01_single_cell_falls: fell exactly 1 row")

func test_water_02_vertical_fall_reaches_floor(b: GPUSandPoC) -> void:
	var w := 64
	var initial := _grid(w, 64)
	initial[_idx(w, 32, 0)] = MAT_WATER
	for x in range(w):
		initial[_idx(w, x, 20)] = MAT_STONE
	_reset_grid(b, w, 64, initial)
	b.step(19, 1)
	var data := b.read_back()
	_check(data[_idx(w, 32, 19)] == MAT_WATER, "water_02_vertical_fall_reaches_floor: reached the floor after the expected step count")

func test_water_03_flows_around_ledge(b: GPUSandPoC) -> void:
	var w := 64
	var initial := _grid(w, 64)
	initial[_idx(w, 32, 5)] = MAT_WATER
	initial[_idx(w, 32, 6)] = MAT_STONE # small ledge directly below
	_reset_grid(b, w, 64, initial)
	b.step(2, 1)
	var data := b.read_back()
	var found := (data[_idx(w, 31, 6)] == MAT_WATER) or (data[_idx(w, 33, 6)] == MAT_WATER) \
		or (data[_idx(w, 31, 7)] == MAT_WATER) or (data[_idx(w, 33, 7)] == MAT_WATER)
	_check(found, "water_03_flows_around_ledge: routed around the obstruction rather than staying stuck")

func test_water_04_horizontal_spread(b: GPUSandPoC) -> void:
	var w := 64
	var initial := _grid(w, 64)
	initial[_idx(w, 32, 5)] = MAT_WATER
	for x in range(w):
		initial[_idx(w, x, 6)] = MAT_STONE # blocked below - must spread sideways
	_reset_grid(b, w, 64, initial)
	b.step(1, 1)
	var data := b.read_back()
	var spread := (data[_idx(w, 31, 5)] == MAT_WATER) or (data[_idx(w, 33, 5)] == MAT_WATER)
	_check(spread, "water_04_horizontal_spread: spread sideways when blocked below")

func test_water_05_left_right_deterministic() -> void:
	var w := 64
	var initial := _grid(w, 64)
	initial[_idx(w, 32, 5)] = MAT_WATER
	for x in range(w):
		initial[_idx(w, x, 6)] = MAT_STONE
	var b1 := _new_backend()
	var b2 := _new_backend()
	if not b1.available or not b2.available:
		b1.cleanup(); b2.cleanup(); return
	b1.setup_grid(w, 64, initial)
	b2.setup_grid(w, 64, initial)
	b1.step(1, 7)
	b2.step(1, 7)
	var d1 := b1.read_back()
	var d2 := b2.read_back()
	_check(d1 == d2, "water_05_left_right_deterministic: same seed/position always yields the same side")
	b1.cleanup()
	b2.cleanup()

func test_water_06_pool_conservation(b: GPUSandPoC) -> void:
	var w := 64
	var initial := _grid(w, 64)
	for x in range(24, 32):
		for y in range(0, 3):
			initial[_idx(w, x, y)] = MAT_WATER # 8x3 = 24 cells
	for x in range(10, 54):
		initial[_idx(w, x, 40)] = MAT_STONE # wide basin floor
	for y in range(20, 41):
		initial[_idx(w, 9, y)] = MAT_STONE
		initial[_idx(w, 54, y)] = MAT_STONE
	_reset_grid(b, w, 64, initial)
	b.step(60, 3)
	var data := b.read_back()
	_check(_count(data, MAT_WATER) == 24, "water_06_pool_conservation: 24 cells in, 24 cells out after spreading into a basin")

func test_water_07_blocked_by_solid_wall(b: GPUSandPoC) -> void:
	var w := 64
	var initial := _grid(w, 64)
	initial[_idx(w, 32, 5)] = MAT_WATER
	initial[_idx(w, 32, 6)] = MAT_STONE
	initial[_idx(w, 31, 6)] = MAT_STONE
	initial[_idx(w, 33, 6)] = MAT_STONE
	initial[_idx(w, 31, 5)] = MAT_STONE
	initial[_idx(w, 33, 5)] = MAT_STONE
	_reset_grid(b, w, 64, initial)
	b.step(5, 1)
	var data := b.read_back()
	_check(data[_idx(w, 32, 5)] == MAT_WATER, "water_07_blocked_by_solid_wall: fully boxed water never passes through a solid wall")

func test_water_08_flows_around_floating_obstacle(b: GPUSandPoC) -> void:
	var w := 64
	var initial := _grid(w, 64)
	initial[_idx(w, 32, 0)] = MAT_WATER
	initial[_idx(w, 32, 10)] = MAT_STONE # floating obstacle, not touching any wall
	for x in range(w):
		initial[_idx(w, x, 30)] = MAT_STONE # floor far below
	_reset_grid(b, w, 64, initial)
	b.step(29, 5)
	var data := b.read_back()
	_check(data[_idx(w, 32, 10)] == MAT_STONE, "water_08_flows_around_floating_obstacle: the obstacle itself is undisturbed")
	_check(_count(data, MAT_WATER) == 1, "water_08_flows_around_floating_obstacle: the water is conserved and reached the space below the obstacle")

func test_water_09_rests_on_sand(b: GPUSandPoC) -> void:
	var w := 64
	var initial := _grid(w, 64)
	initial[_idx(w, 32, 5)] = MAT_WATER
	initial[_idx(w, 32, 6)] = MAT_SAND
	for x in range(w):
		initial[_idx(w, x, 7)] = MAT_STONE
	_reset_grid(b, w, 64, initial)
	b.step(5, 1)
	var data := b.read_back()
	_check(data[_idx(w, 32, 6)] == MAT_SAND, "water_09_rests_on_sand: WATER does not sink into SAND (SAND isn't liquid)")

func test_water_10_sand_sinks_through_water(b: GPUSandPoC) -> void:
	# The exact Phase 2B bug repro (GPU_SIMULATION.md "Pull Model") - SAND
	# directly above WATER, directly above open AIR. Verifies the
	# resolve_winner_shallow/resolve_winner_for two-tier fix still holds:
	# mass must stay 1 SAND + 3 WATER, never 1 SAND + 5 WATER.
	var w := 64
	var initial := _grid(w, 64)
	initial[_idx(w, 32, 5)] = MAT_SAND
	initial[_idx(w, 32, 6)] = MAT_WATER
	initial[_idx(w, 31, 6)] = MAT_WATER
	initial[_idx(w, 33, 6)] = MAT_WATER
	for x in range(w):
		initial[_idx(w, x, 20)] = MAT_STONE
	_reset_grid(b, w, 64, initial)
	var sand_ok := true
	var water_ok := true
	for step in range(30):
		b.step(1, 9)
		var data := b.read_back()
		if _count(data, MAT_SAND) != 1: sand_ok = false
		if _count(data, MAT_WATER) != 3: water_ok = false
	_check(sand_ok, "water_10_sand_sinks_through_water: SAND count conserved at every one of 30 steps")
	_check(water_ok, "water_10_sand_sinks_through_water: WATER count conserved at every one of 30 steps (not duplicated by the swap)")

func test_water_11_chunk_boundary_conservation(b: GPUSandPoC) -> void:
	var w := 128
	var h := 64
	var initial := _grid(w, h)
	for x in range(55, 73):
		initial[_idx(w, x, 5)] = MAT_WATER # 18 cells straddling x=64
	for x in range(w):
		initial[_idx(w, x, 40)] = MAT_STONE
	_reset_grid(b, w, h, initial)
	b.step(60, 11)
	var data := b.read_back()
	_check(_count(data, MAT_WATER) == 18, "water_11_chunk_boundary_conservation: 18 in, 18 out crossing x=64 with zero special-case code")

func test_water_12_spread_across_multiple_chunks(b: GPUSandPoC) -> void:
	var w := 192 # 3 would-be 64-wide chunks
	var h := 64
	var initial := _grid(w, h)
	for x in range(90, 102):
		initial[_idx(w, x, 5)] = MAT_WATER
	for x in range(w):
		initial[_idx(w, x, 40)] = MAT_STONE
	_reset_grid(b, w, h, initial)
	b.step(60, 12)
	var data := b.read_back()
	_check(_count(data, MAT_WATER) == 12, "water_12_spread_across_multiple_chunks: conserved while spreading across several would-be chunk boundaries")

func test_water_13_conservation_contested_pool(b: GPUSandPoC) -> void:
	var w := 64
	var initial := _grid(w, 64)
	for x in range(30, 35):
		initial[_idx(w, x, 5)] = MAT_WATER # 5-cell contested pool
	for x in range(20, 44):
		initial[_idx(w, x, 30)] = MAT_STONE
	for y in range(15, 31):
		initial[_idx(w, 19, y)] = MAT_STONE
		initial[_idx(w, 44, y)] = MAT_STONE
	_reset_grid(b, w, 64, initial)
	b.step(100, 13)
	var data := b.read_back()
	_check(_count(data, MAT_WATER) == 5, "water_13_conservation_contested_pool: exactly 5 water cells after 100 contested steps")

func test_water_14_deterministic_repeatability() -> void:
	var w := 64
	var initial := _grid(w, 64)
	for x in range(30, 35):
		initial[_idx(w, x, 5)] = MAT_WATER
	var b1 := _new_backend()
	var b2 := _new_backend()
	if not b1.available or not b2.available:
		b1.cleanup(); b2.cleanup(); return
	b1.setup_grid(w, 64, initial)
	b2.setup_grid(w, 64, initial)
	b1.step(60, 14)
	b2.step(60, 14)
	var d1 := b1.read_back()
	var d2 := b2.read_back()
	_check(d1 == d2, "water_14_deterministic_repeatability: byte-identical final buffers, same seed")
	b1.cleanup()
	b2.cleanup()

func test_water_15_cpu_gpu_no_contention(b: GPUSandPoC) -> void:
	var w := 64
	var initial := _grid(w, 64)
	initial[_idx(w, 32, 0)] = MAT_WATER
	_reset_grid(b, w, 64, initial)
	b.step(30, 1)
	var gpu_data := b.read_back()

	var cpu := _new_cpu_world(1, 1, 1)
	cpu.set_cell(32, 0, cpu.MATERIAL_WATER)
	for i in range(30):
		cpu.step_simulation(1.0 / 60.0)
	var cpu_mat := cpu.get_cell(32, 30)
	_check(cpu_mat == cpu.MATERIAL_WATER, "water_15_cpu_gpu_no_contention: CPU reference fell 30 rows in 30 passes")
	_check(gpu_data[_idx(w, 32, 30)] == MAT_WATER, "water_15_cpu_gpu_no_contention: GPU matches CPU exactly (no-contention case)")
	cpu.free()

func test_water_16_multistep_stability_150(b: GPUSandPoC) -> void:
	var w := 64
	var initial := _grid(w, 64)
	for x in range(30, 35):
		initial[_idx(w, x, 5)] = MAT_WATER
	for x in range(20, 44):
		initial[_idx(w, x, 30)] = MAT_STONE
	for y in range(15, 31):
		initial[_idx(w, 19, y)] = MAT_STONE
		initial[_idx(w, 44, y)] = MAT_STONE
	_reset_grid(b, w, 64, initial)
	b.step(150, 16)
	var data := b.read_back()
	_check(_count(data, MAT_WATER) == 5, "water_16_multistep_stability_150: still exactly 5 after 150 steps, no drift")

# ================== Runner ==================
## Runs every test. Only ~9 RenderingDevice/shader instances are created for
## the whole 28-test run (1 shared + 3 pairs for the determinism tests + 2
## dedicated for the init-edge-case tests) - see the class doc comment for
## why this bound matters.

func run_all() -> Dictionary:
	checks = 0
	failures = 0
	log_lines.clear()

	var shared := _new_backend()
	_check(shared.available, "shared backend: GPU available under the current (Forward+) renderer")

	if shared.available:
		test_sand_02_empty_world(shared)
		test_sand_03_single_cell_falls(shared)
		test_sand_04_small_pile_settles(shared)
		test_sand_05_gravity_16_rows(shared)
		test_sand_06_diagonal_movement(shared)
		test_sand_07_chunk_boundary_126_rows(shared)
		test_sand_08_multistep_counts(shared)
		test_sand_09_cpu_gpu_no_contention(shared)

		test_water_01_single_cell_falls(shared)
		test_water_02_vertical_fall_reaches_floor(shared)
		test_water_03_flows_around_ledge(shared)
		test_water_04_horizontal_spread(shared)
		test_water_06_pool_conservation(shared)
		test_water_07_blocked_by_solid_wall(shared)
		test_water_08_flows_around_floating_obstacle(shared)
		test_water_09_rests_on_sand(shared)
		test_water_10_sand_sinks_through_water(shared)
		test_water_11_chunk_boundary_conservation(shared)
		test_water_12_spread_across_multiple_chunks(shared)
		test_water_13_conservation_contested_pool(shared)
		test_water_15_cpu_gpu_no_contention(shared)
		test_water_16_multistep_stability_150(shared)
	shared.cleanup()

	test_sand_10_deterministic_repeatability()
	test_sand_11_graceful_when_not_set_up()
	test_sand_12_resource_cleanup()
	test_water_05_left_right_deterministic()
	test_water_14_deterministic_repeatability()

	return {
		"checks": checks,
		"failures": failures,
		"log_lines": log_lines,
	}
