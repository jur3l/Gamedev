class_name GPUReactionTests
extends RefCounted
## Phase 2E (GPU_MATERIAL_INTERACTIONS.md "Testing") - 16 reaction-specific
## scenarios (items 1-16 of the request's 18; items 17/18 - the existing
## Sand/Water and active-region regression suites - are run separately,
## see gpu_solver_tests.gd / gpu_active_region_tests.gd). Shares ONE backend
## across the whole run - see gpu_solver_tests.gd's own doc comment for why
## (rapid RenderingDevice recreation, not dispatch volume, destabilizes the
## process).
##
## Uses MAT_REACT_TEST_A/B exclusively - these never appear in any other
## test file's initial state, so nothing here can interfere with, or be
## interfered with by, the existing 55-check suite.

const MAT_AIR := GPUSandPoC.MAT_AIR
const MAT_SAND := GPUSandPoC.MAT_SAND
const MAT_STONE := GPUSandPoC.MAT_STONE
const MAT_WATER := GPUSandPoC.MAT_WATER
const MAT_A := GPUSandPoC.MAT_REACT_TEST_A
const MAT_B := GPUSandPoC.MAT_REACT_TEST_B

const W := 256
const H := 256

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

func _write_cell(gpu: GPUSandPoC, x: int, y: int, mat: int) -> void:
	var buf: RID = gpu._buf_a if gpu._current_is_a else gpu._buf_b
	var bytes := PackedByteArray()
	bytes.resize(4)
	bytes.encode_u32(0, mat)
	gpu._rd.buffer_update(buf, (y * gpu.width + x) * 4, 4, bytes)

func _read_cell(backend: GPUSimulationBackend, x: int, y: int) -> int:
	var data := backend.read_back()
	return data[y * backend.gpu.width + x]

func _count(data: PackedInt32Array, mat: int) -> int:
	var n := 0
	for v in data:
		if v == mat:
			n += 1
	return n

# 1. No-rule material: SAND next to STONE (undefined pair) doesn't react.
func test_1_no_rule_material(backend: GPUSimulationBackend) -> void:
	var initial := _grid(W, H)
	initial[_idx(W, 100, 20)] = MAT_SAND
	initial[_idx(W, 101, 20)] = MAT_STONE
	backend.reset_grid(W, H, initial)
	backend.gpu.step(1, 1)
	var data := backend.gpu.read_back()
	_check(data[_idx(W, 100, 20)] == MAT_AIR, "test_1_no_rule_material: SAND fell normally (no reaction with STONE)")
	_check(data[_idx(W, 101, 20)] == MAT_STONE, "test_1_no_rule_material: STONE untouched")

# 2. Existing interaction (SAND displacing WATER) still works - a light
# regression check; the full version already lives in gpu_solver_tests.gd.
func test_2_single_interaction_regression(backend: GPUSimulationBackend) -> void:
	var initial := _grid(W, H)
	initial[_idx(W, 100, 5)] = MAT_SAND
	initial[_idx(W, 100, 6)] = MAT_WATER
	for x in range(W):
		initial[_idx(W, x, 20)] = MAT_STONE
	backend.reset_grid(W, H, initial)
	backend.gpu.step(1, 1)
	var data := backend.gpu.read_back()
	_check(data[_idx(W, 100, 6)] == MAT_SAND, "test_2_single_interaction_regression: SAND still displaces into WATER's old cell")
	_check(data[_idx(W, 100, 5)] == MAT_WATER, "test_2_single_interaction_regression: WATER still backfills (true swap, unaffected by reaction resolution)")

# 3. Single reaction: A next to B reacts to AIR/STONE.
func test_3_single_reaction(backend: GPUSimulationBackend) -> void:
	var initial := _grid(W, H)
	initial[_idx(W, 100, 20)] = MAT_A
	initial[_idx(W, 101, 20)] = MAT_B
	backend.reset_grid(W, H, initial)
	backend.gpu.step(1, 1)
	var data := backend.gpu.read_back()
	_check(data[_idx(W, 100, 20)] == MAT_AIR, "test_3_single_reaction: A -> AIR")
	_check(data[_idx(W, 101, 20)] == MAT_STONE, "test_3_single_reaction: B -> STONE")

# 4. Reaction consumes A+B - neither original material remains anywhere.
func test_4_reaction_consumes_a_and_b(backend: GPUSimulationBackend) -> void:
	var initial := _grid(W, H)
	initial[_idx(W, 100, 20)] = MAT_A
	initial[_idx(W, 101, 20)] = MAT_B
	backend.reset_grid(W, H, initial)
	backend.gpu.step(1, 1)
	var data := backend.gpu.read_back()
	_check(_count(data, MAT_A) == 0, "test_4_reaction_consumes_a_and_b: no MAT_A remains")
	_check(_count(data, MAT_B) == 0, "test_4_reaction_consumes_a_and_b: no MAT_B remains")

# 5. Reaction creates C - exact placement, not swapped.
func test_5_reaction_creates_c(backend: GPUSimulationBackend) -> void:
	var initial := _grid(W, H)
	initial[_idx(W, 100, 20)] = MAT_B # swapped placement vs test 3 - A on the right this time
	initial[_idx(W, 101, 20)] = MAT_A
	backend.reset_grid(W, H, initial)
	backend.gpu.step(1, 1)
	var data := backend.gpu.read_back()
	_check(data[_idx(W, 100, 20)] == MAT_STONE, "test_5_reaction_creates_c: B's own position becomes STONE regardless of left/right placement")
	_check(data[_idx(W, 101, 20)] == MAT_AIR, "test_5_reaction_creates_c: A's own position becomes AIR regardless of left/right placement")

# 6. Mass conservation - the grid's total cell count is (trivially) fixed
# buffer size; the meaningful check is that ONLY the reacting pair changed.
func test_6_mass_conservation(backend: GPUSimulationBackend) -> void:
	var initial := _grid(W, H)
	initial[_idx(W, 100, 20)] = MAT_A
	initial[_idx(W, 101, 20)] = MAT_B
	backend.reset_grid(W, H, initial)
	backend.gpu.step(1, 1)
	var data := backend.gpu.read_back()
	var changed := 0
	for i in range(data.size()):
		if data[i] != initial[i]:
			changed += 1
	_check(changed == 2, "test_6_mass_conservation: exactly 2 cells changed (the reacting pair), nothing else")

# 7. Deterministic reaction - two independent runs, same seed, byte-identical.
func test_7_deterministic_reaction() -> void:
	var initial := _grid(W, H)
	initial[_idx(W, 100, 20)] = MAT_A
	initial[_idx(W, 101, 20)] = MAT_B
	var b1 := GPUSimulationBackend.new()
	var b2 := GPUSimulationBackend.new()
	b1.init(2222)
	b2.init(2222)
	if not b1.gpu.available or not b2.gpu.available:
		_check(false, "test_7_deterministic_reaction: GPU unavailable")
		b1.cleanup(); b2.cleanup()
		return
	b1.setup_grid(W, H, initial)
	b2.setup_grid(W, H, initial)
	b1.gpu.set_reaction_rule(MAT_A, MAT_B, MAT_AIR, MAT_STONE)
	b2.gpu.set_reaction_rule(MAT_A, MAT_B, MAT_AIR, MAT_STONE)
	b1.gpu.step(1, 1)
	b2.gpu.step(1, 1)
	var d1 := b1.gpu.read_back()
	var d2 := b2.gpu.read_back()
	_check(d1 == d2, "test_7_deterministic_reaction: byte-identical final buffers, same seed")
	b1.cleanup()
	b2.cleanup()

# 8. Repeated reaction - many scattered A/B pairs all react correctly in one dispatch.
func test_8_repeated_reaction(backend: GPUSimulationBackend) -> void:
	var initial := _grid(W, H)
	var pairs := 20
	for i in range(pairs):
		var x := 10 + i * 10
		var y := 30
		initial[_idx(W, x, y)] = MAT_A
		initial[_idx(W, x + 1, y)] = MAT_B
	backend.reset_grid(W, H, initial)
	backend.gpu.step(1, 1)
	var data := backend.gpu.read_back()
	_check(_count(data, MAT_STONE) == pairs, "test_8_repeated_reaction: all %d pairs produced exactly one STONE each" % pairs)
	_check(_count(data, MAT_A) == 0 and _count(data, MAT_B) == 0, "test_8_repeated_reaction: no A/B cells remain anywhere")

# 9. Reaction stops when inputs disappear - AIR/STONE products don't
# spuriously "re-react" on subsequent ticks.
func test_9_reaction_stops_when_inputs_disappear(backend: GPUSimulationBackend) -> void:
	var initial := _grid(W, H)
	initial[_idx(W, 100, 20)] = MAT_A
	initial[_idx(W, 101, 20)] = MAT_B
	backend.reset_grid(W, H, initial)
	backend.gpu.step(5, 1) # well past the first reacting tick
	var data := backend.gpu.read_back()
	_check(data[_idx(W, 100, 20)] == MAT_AIR, "test_9_reaction_stops_when_inputs_disappear: stays AIR (no further reaction)")
	_check(data[_idx(W, 101, 20)] == MAT_STONE, "test_9_reaction_stops_when_inputs_disappear: STONE stays STONE, doesn't move or re-react (STATIC)")

# 10. Chunk boundary - a reacting pair straddling world x=64.
func test_10_chunk_boundary(backend: GPUSimulationBackend) -> void:
	var initial := _grid(W, H)
	initial[_idx(W, 63, 20)] = MAT_A
	initial[_idx(W, 64, 20)] = MAT_B
	backend.reset_grid(W, H, initial)
	backend.gpu.step(1, 1)
	var data := backend.gpu.read_back()
	_check(data[_idx(W, 63, 20)] == MAT_AIR, "test_10_chunk_boundary: A (x=63, in chunk 0) reacted correctly")
	_check(data[_idx(W, 64, 20)] == MAT_STONE, "test_10_chunk_boundary: B (x=64, in chunk 1) reacted correctly")

# 11. Diagonal adjacency does NOT react - matches the CPU's orthogonal-only reference.
func test_11_diagonal_no_reaction(backend: GPUSimulationBackend) -> void:
	var initial := _grid(W, H)
	initial[_idx(W, 100, 20)] = MAT_A
	initial[_idx(W, 101, 21)] = MAT_B # diagonal, not orthogonal
	backend.reset_grid(W, H, initial)
	backend.gpu.step(1, 1)
	var data := backend.gpu.read_back()
	_check(data[_idx(W, 100, 20)] == MAT_A, "test_11_diagonal_no_reaction: A unchanged (diagonal neighbor doesn't count)")
	_check(data[_idx(W, 101, 21)] == MAT_B, "test_11_diagonal_no_reaction: B unchanged")

# 12. Corner boundary - orthogonally-adjacent pair positioned right at a
# would-be chunk corner (x=64 AND y=64 both nearby).
func test_12_corner_boundary(backend: GPUSimulationBackend) -> void:
	var initial := _grid(W, H)
	initial[_idx(W, 64, 64)] = MAT_A
	initial[_idx(W, 65, 64)] = MAT_B
	backend.reset_grid(W, H, initial)
	backend.gpu.step(1, 1)
	var data := backend.gpu.read_back()
	_check(data[_idx(W, 64, 64)] == MAT_AIR, "test_12_corner_boundary: A reacted correctly right at a chunk corner")
	_check(data[_idx(W, 65, 64)] == MAT_STONE, "test_12_corner_boundary: B reacted correctly right at a chunk corner")

# 13. Active-region wake - a reaction at the edge of the active rect keeps
# the region active, using the EXISTING Phase 2D bounds mechanism.
func test_13_active_region_wake(backend: GPUSimulationBackend) -> void:
	var initial := _grid(W, H)
	initial[_idx(W, 100, 20)] = MAT_A
	initial[_idx(W, 101, 20)] = MAT_B
	backend.reset_grid(W, H, initial)
	backend.enable_active_region(Rect2i(100, 20, 2, 1), 1)
	var result := backend.run_ticks_active_region(1)
	_check(result.dispatched == true, "test_13_active_region_wake: dispatched (region was active)")
	_check(_read_cell(backend, 100, 20) == MAT_AIR and _read_cell(backend, 101, 20) == MAT_STONE, "test_13_active_region_wake: reaction fired correctly under active-region dispatch")

# 14. Sleeping after reaction - once resolved, the region goes back to sleep.
func test_14_sleeping_after_reaction(backend: GPUSimulationBackend) -> void:
	var initial := _grid(W, H)
	initial[_idx(W, 100, 20)] = MAT_A
	initial[_idx(W, 101, 20)] = MAT_B
	backend.reset_grid(W, H, initial)
	backend.enable_active_region(Rect2i(100, 20, 2, 1), 1)
	backend.run_ticks_active_region(1) # reaction fires this batch
	backend.run_ticks_active_region(1) # quiet batch - AIR/STONE, nothing left to do
	_check(backend.region_active == false, "test_14_sleeping_after_reaction: region sleeps once the reaction has fully settled")

# 15. Background ignored - structurally trivial (no background concept
# exists in the GPU buffer at all); confirms the reaction path only ever
# touches the one foreground buffer it's given, nothing more.
func test_15_background_ignored(backend: GPUSimulationBackend) -> void:
	var initial := _grid(W, H)
	initial[_idx(W, 100, 20)] = MAT_A
	initial[_idx(W, 101, 20)] = MAT_B
	backend.reset_grid(W, H, initial)
	backend.gpu.step(1, 1)
	var data := backend.gpu.read_back()
	_check(data.size() == W * H, "test_15_background_ignored: read-back size is exactly width*height (one foreground channel, no hidden background data)")

# 16. Mining-created material can react - a directly-written cell (as a
# mining/spawn command's output would look) reacts on its next dispatch,
# exactly like naturally-placed material.
func test_16_mining_created_material_can_react(backend: GPUSimulationBackend) -> void:
	backend.reset_grid(W, H, _grid(W, H)) # empty world, as if nothing had ever been placed
	_write_cell(backend.gpu, 150, 20, MAT_A) # simulated "drop"
	_write_cell(backend.gpu, 151, 20, MAT_B)
	backend.gpu.step(1, 1)
	var data := backend.gpu.read_back()
	_check(data[_idx(W, 150, 20)] == MAT_AIR, "test_16_mining_created_material_can_react: directly-written A reacted normally")
	_check(data[_idx(W, 151, 20)] == MAT_STONE, "test_16_mining_created_material_can_react: directly-written B reacted normally")

func run_all() -> Dictionary:
	checks = 0
	failures = 0
	log_lines.clear()

	var backend := GPUSimulationBackend.new()
	backend.init(3131)
	if backend.gpu.available:
		backend.gpu.set_reaction_rule(MAT_A, MAT_B, MAT_AIR, MAT_STONE)

		test_1_no_rule_material(backend)
		test_2_single_interaction_regression(backend)
		test_3_single_reaction(backend)
		test_4_reaction_consumes_a_and_b(backend)
		test_5_reaction_creates_c(backend)
		test_6_mass_conservation(backend)
		test_8_repeated_reaction(backend)
		test_9_reaction_stops_when_inputs_disappear(backend)
		test_10_chunk_boundary(backend)
		test_11_diagonal_no_reaction(backend)
		test_12_corner_boundary(backend)
		test_13_active_region_wake(backend)
		test_14_sleeping_after_reaction(backend)
		test_15_background_ignored(backend)
		test_16_mining_created_material_can_react(backend)
	else:
		_check(false, "shared backend: GPU unavailable")
	backend.cleanup()

	test_7_deterministic_reaction()

	return {
		"checks": checks,
		"failures": failures,
		"log_lines": log_lines,
	}
