class_name GPUActiveRegionTests
extends RefCounted
## Phase 2D (GPU_ACTIVE_REGION.md "Correctness") - 10 active-region/wake/
## sleep scenarios, layered on top of the existing persisted
## gpu_solver_tests.gd (which must still pass unmodified against the same,
## additively-extended shader). Shares backends across the whole run - see
## gpu_solver_tests.gd's own doc comment for why (rapid RenderingDevice
## recreation, not dispatch volume, crashed the process during Phase 2C).

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

## Writes a single cell directly into whichever buffer currently holds the
## latest state - simulates a mining/spawn write without a full
## reset_grid() (which would also reset the active region/clock). Reaches
## into GPUSandPoC's "private" RID fields, consistent with gpu_solver_
## tests.gd's own established pattern for this exact need.
func _write_cell(gpu: GPUSandPoC, x: int, y: int, mat: int) -> void:
	var buf: RID = gpu._buf_a if gpu._current_is_a else gpu._buf_b
	var bytes := PackedByteArray()
	bytes.resize(4)
	bytes.encode_u32(0, mat)
	gpu._rd.buffer_update(buf, (y * gpu.width + x) * 4, 4, bytes)

func _read_cell(backend: GPUSimulationBackend, x: int, y: int) -> int:
	var data := backend.read_back()
	return data[y * backend.gpu.width + x]

func _count_material(backend: GPUSimulationBackend, mat: int) -> int:
	var data := backend.read_back()
	var n := 0
	for v in data:
		if v == mat:
			n += 1
	return n

const W := 256
const H := 256

func test_1_single_active_chunk(backend: GPUSimulationBackend) -> void:
	backend.reset_grid(W, H, _grid(W, H))
	_write_cell(backend.gpu, 100, 20, MAT_SAND)
	backend.enable_active_region(Rect2i(100, 20, 1, 1), 5)
	var chunks_before := backend.region_chunk_count()
	var total_chunks := (W / 64) * (H / 64)
	_check(chunks_before < total_chunks, "test_1_single_active_chunk: initial region (%d chunks) is smaller than the full world (%d chunks) even at this small test-world size" % [chunks_before, total_chunks])
	backend.run_ticks_active_region(5)
	_check(_read_cell(backend, 100, 25) == MAT_SAND, "test_1_single_active_chunk: fell exactly 5 rows via active-region dispatch")

func test_2_falling_across_chunks(backend: GPUSimulationBackend) -> void:
	backend.reset_grid(W, H, _grid(W, H))
	_write_cell(backend.gpu, 100, 1, MAT_SAND)
	backend.enable_active_region(Rect2i(100, 1, 1, 1), 70)
	backend.run_ticks_active_region(70)
	_check(_read_cell(backend, 100, 71) == MAT_SAND, "test_2_falling_across_chunks: crossed the y=64 chunk boundary correctly via active-region dispatch (no full-world fallback needed)")

func test_3_horizontal_water_propagation(backend: GPUSimulationBackend) -> void:
	backend.reset_grid(W, H, _grid(W, H))
	_write_cell(backend.gpu, 100, 20, MAT_WATER)
	for x in range(W):
		_write_cell(backend.gpu, x, 21, MAT_STONE) # blocked below everywhere - must spread sideways
	backend.enable_active_region(Rect2i(100, 20, 1, 1), 30)
	backend.run_ticks_active_region(30)
	_check(_count_material(backend, MAT_WATER) == 1, "test_3_horizontal_water_propagation: exactly 1 water cell conserved while spreading sideways across chunks under active-region dispatch")

func test_4_activation_chain(backend: GPUSimulationBackend) -> void:
	backend.reset_grid(W, H, _grid(W, H))
	for y in range(1, 11):
		_write_cell(backend.gpu, 100, y, MAT_SAND) # 10-cell vertical stack
	backend.enable_active_region(Rect2i(100, 1, 1, 10), 50)
	backend.run_ticks_active_region(50)
	_check(_count_material(backend, MAT_SAND) == 10, "test_4_activation_chain: mass conserved through a multi-row collapse tracked by active-region dispatch")

func test_5_sleep_after_settle(backend: GPUSimulationBackend) -> void:
	backend.reset_grid(W, H, _grid(W, H))
	_write_cell(backend.gpu, 100, 20, MAT_SAND)
	_write_cell(backend.gpu, 100, 21, MAT_STONE)
	_write_cell(backend.gpu, 99, 21, MAT_STONE)
	_write_cell(backend.gpu, 101, 21, MAT_STONE) # fully boxed - can't move at all
	backend.enable_active_region(Rect2i(100, 20, 1, 1), 1)
	backend.run_ticks_active_region(1)
	_check(backend.region_active == false, "test_5_sleep_after_settle: region sleeps after one quiet batch (nothing moved)")

func test_6_wake_after_new_material(backend: GPUSimulationBackend) -> void:
	backend.reset_grid(W, H, _grid(W, H))
	_check(backend.region_active == false, "test_6_wake_after_new_material: starts fully asleep (no material seeded)")
	_write_cell(backend.gpu, 150, 20, MAT_SAND)
	backend.wake_region(Rect2i(150, 20, 1, 1), 5)
	_check(backend.region_active == true, "test_6_wake_after_new_material: wake_region() resumes an asleep backend")
	backend.run_ticks_active_region(5)
	_check(_read_cell(backend, 150, 25) == MAT_SAND, "test_6_wake_after_new_material: newly woken material actually falls")

func test_7_mining_wake(backend: GPUSimulationBackend) -> void:
	var initial := _grid(W, H)
	initial[_idx(W, 100, 20)] = MAT_STONE # support
	initial[_idx(W, 100, 19)] = MAT_SAND  # resting on the support
	backend.reset_grid(W, H, initial)
	_check(backend.region_active == false, "test_7_mining_wake: settled/unmined world starts with no active region")
	_write_cell(backend.gpu, 100, 20, MAT_AIR) # simulated mining: remove the support
	backend.wake_region(Rect2i(100, 19, 1, 2), 5) # mining command -> affected-region activation
	backend.run_ticks_active_region(5)
	_check(_read_cell(backend, 100, 24) == MAT_SAND, "test_7_mining_wake: newly-unsupported SAND correctly falls after a simulated mining wake")

func test_8_boundary_wake(backend: GPUSimulationBackend) -> void:
	backend.reset_grid(W, H, _grid(W, H))
	_write_cell(backend.gpu, 0, 5, MAT_SAND) # at the world's left edge
	backend.enable_active_region(Rect2i(0, 5, 1, 1), 10)
	_check(backend.region_rect.position.x == 0, "test_8_boundary_wake: region rect clamped to the world's left edge, not negative")
	backend.run_ticks_active_region(10)
	_check(_read_cell(backend, 0, 15) == MAT_SAND, "test_8_boundary_wake: edge-adjacent material simulated correctly without an out-of-bounds rect")

func test_9_active_inactive_transition(backend: GPUSimulationBackend) -> void:
	backend.reset_grid(W, H, _grid(W, H))
	var all_cycles_slept := true
	for cycle in range(3):
		_write_cell(backend.gpu, 120, 20, MAT_SAND)
		_write_cell(backend.gpu, 120, 21, MAT_STONE)
		_write_cell(backend.gpu, 119, 21, MAT_STONE)
		_write_cell(backend.gpu, 121, 21, MAT_STONE)
		backend.wake_region(Rect2i(120, 20, 1, 1), 1)
		backend.run_ticks_active_region(1) # boxed -> settles immediately -> quiet -> sleeps
		if backend.region_active != false:
			all_cycles_slept = false
		_write_cell(backend.gpu, 120, 20, MAT_AIR) # clean up before the next cycle
	_check(all_cycles_slept, "test_9_active_inactive_transition: repeated wake -> settle -> sleep cycles behave consistently every time")

func test_10_deterministic_repeatability(b1: GPUSimulationBackend, b2: GPUSimulationBackend) -> void:
	var initial := _grid(W, H)
	for x in range(90, 110):
		initial[_idx(W, x, 20)] = MAT_SAND
	for x in range(W):
		initial[_idx(W, x, 100)] = MAT_STONE
	b1.reset_grid(W, H, initial)
	b2.reset_grid(W, H, initial)
	b1.enable_active_region(Rect2i(90, 20, 20, 1), 40)
	b2.enable_active_region(Rect2i(90, 20, 20, 1), 40)
	b1.run_ticks_active_region(40)
	b2.run_ticks_active_region(40)
	var d1 := b1.read_back()
	var d2 := b2.read_back()
	_check(d1 == d2, "test_10_deterministic_repeatability: two independent active-region runs, same seed, byte-identical final state")

func run_all() -> Dictionary:
	checks = 0
	failures = 0
	log_lines.clear()

	var backend := GPUSimulationBackend.new()
	backend.init(2024)
	if backend.gpu.available:
		test_1_single_active_chunk(backend)
		test_2_falling_across_chunks(backend)
		test_3_horizontal_water_propagation(backend)
		test_4_activation_chain(backend)
		test_5_sleep_after_settle(backend)
		test_6_wake_after_new_material(backend)
		test_7_mining_wake(backend)
		test_8_boundary_wake(backend)
		test_9_active_inactive_transition(backend)
	else:
		_check(false, "shared backend: GPU unavailable")
	backend.cleanup()

	var b1 := GPUSimulationBackend.new()
	var b2 := GPUSimulationBackend.new()
	b1.init(555)
	b2.init(555)
	if b1.gpu.available and b2.gpu.available:
		test_10_deterministic_repeatability(b1, b2)
	b1.cleanup()
	b2.cleanup()

	return {
		"checks": checks,
		"failures": failures,
		"log_lines": log_lines,
	}
