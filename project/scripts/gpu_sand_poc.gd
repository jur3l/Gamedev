class_name GPUSandPoC
extends RefCounted
## GPU simulation feasibility PoC (GPU_SIMULATION.md): Phase 2A (SAND) +
## Phase 2B (WATER) + Phase 2D (GPU_ACTIVE_REGION.md - rect-based partial
## dispatch via step_region(), plus a GPU-computed activity bounds buffer).
## EXPERIMENTAL - not the production simulation backend. Wraps a LOCAL
## RenderingDevice (RenderingServer.create_local_rendering_device()) running
## a ping-pong compute-shader solver (shaders/gpu_cellular_solver.glsl).
##
## Class name kept as GPUSandPoC across Phase 2B (not renamed) - it is a
## thin, material-agnostic buffer/dispatch/readback wrapper (setup_grid/step/
## read_back all just move PackedInt32Array material IDs around); only the
## shader gained WATER-specific behavior. Renaming it would have been pure
## churn for no behavioral reason, and the request's own instruction was to
## reuse this infrastructure, not introduce a second one - see
## GPU_SIMULATION.md "Phase 2B" for why the shader itself WAS renamed
## (gpu_sand_solver.glsl -> gpu_cellular_solver.glsl) while this class was not.
##
## Deliberately standalone: a RefCounted, not a Node, not wired into
## PixelSimWorld, Main.tscn, or the production render pipeline in any way -
## see PROJECT_ARCHITECTURE.md's "GPU PoC is EXPERIMENTAL, CPU stays
## PRODUCTION/REFERENCE" framing. Instantiate, use, and let it go out of
## scope (or call cleanup() explicitly) - nothing else in the game depends
## on this class existing.
##
## GPU-unavailable is a normal, non-fatal outcome (see init()) - the CPU
## backend (the real PixelSimWorld/World) is completely unaffected either way.

const SHADER_PATH := "res://shaders/gpu_cellular_solver.glsl"
const MAT_AIR := 0
const MAT_SAND := 1
const MAT_STONE := 2
const MAT_WATER := 3

var available := false
var width := 0
var height := 0

var _rd: RenderingDevice
var _shader_rid: RID
var _pipeline_rid: RID
var _buf_a: RID
var _buf_b: RID
var _current_is_a := true # which buffer currently holds the latest state
var _bounds_buf: RID # Phase 2D (GPU_ACTIVE_REGION.md) - 16-byte atomic min/max activity bbox

# --- Perf instrumentation (GPU_SIMULATION.md "Performance") ---
# Populated by step()/read_back() - kept as separate numbers per the
# request's explicit "GPU compute time != GPU + readback time" requirement.
var last_compute_usec := 0
var last_readback_usec := 0

func init() -> bool:
	_rd = RenderingServer.create_local_rendering_device()
	if _rd == null:
		available = false
		print("[GPUSandPoC] GPU backend unavailable: could not create a local RenderingDevice")
		return false

	if not ResourceLoader.exists(SHADER_PATH):
		available = false
		print("[GPUSandPoC] GPU backend unavailable: shader resource not found at %s" % SHADER_PATH)
		return false

	var shader_file: RDShaderFile = load(SHADER_PATH)
	if shader_file == null:
		available = false
		print("[GPUSandPoC] GPU backend unavailable: failed to load shader resource")
		return false

	var spirv: RDShaderSPIRV = shader_file.get_spirv()
	if spirv.compile_error_compute != "":
		available = false
		print("[GPUSandPoC] GPU backend unavailable: shader compile error: %s" % spirv.compile_error_compute)
		return false

	_shader_rid = _rd.shader_create_from_spirv(spirv)
	if not _shader_rid.is_valid():
		available = false
		print("[GPUSandPoC] GPU backend unavailable: shader_create_from_spirv failed")
		return false

	_pipeline_rid = _rd.compute_pipeline_create(_shader_rid)
	if not _pipeline_rid.is_valid():
		available = false
		print("[GPUSandPoC] GPU backend unavailable: compute_pipeline_create failed")
		return false

	available = true
	print("[GPUSandPoC] GPU backend initialized")
	return true

## Allocates the double-buffered grid and uploads `initial` (one uint32 per
## cell, row-major, width*height entries - MAT_AIR/MAT_SAND/MAT_STONE).
## width/height must be multiples of 8 (the shader's local_size_x/y).
func setup_grid(w: int, h: int, initial: PackedInt32Array) -> bool:
	if not available:
		return false
	if w % 8 != 0 or h % 8 != 0:
		push_error("GPUSandPoC.setup_grid: width/height must be multiples of 8")
		return false
	if initial.size() != w * h:
		push_error("GPUSandPoC.setup_grid: initial data size mismatch")
		return false

	width = w
	height = h
	var bytes := _int32_array_to_bytes(initial)
	_buf_a = _rd.storage_buffer_create(bytes.size(), bytes)
	var empty := PackedByteArray()
	empty.resize(bytes.size())
	_buf_b = _rd.storage_buffer_create(empty.size(), empty)
	_bounds_buf = _rd.storage_buffer_create(16, _sentinel_bounds_bytes())
	_current_is_a = true
	return true

static func _sentinel_bounds_bytes() -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(16)
	b.encode_u32(0, 0xFFFFFFFF) # min_x
	b.encode_u32(4, 0xFFFFFFFF) # min_y
	b.encode_u32(8, 0) # max_x
	b.encode_u32(12, 0) # max_y
	return b

## Advances the simulation by `steps` steps (ping-ponging the two buffers),
## seeded by `seed`, starting the step counter at `start_step` (so a
## multi-call sequence keeps distinct RNG draws per step - mirrors the CPU's
## own current_pass_id_-driven behavior, see the shader's hash_u32()).
## Records ONE submit()+sync() for the whole batch (recording N dispatches
## with barriers between them) - this is deliberately how a real per-frame
## driver would batch work, not N separate CPU<->GPU round trips; see
## GPU_SIMULATION.md "Performance" for why per-step sync would misrepresent
## GPU compute cost.
##
## Dispatches the FULL configured width/height - identical dispatch shape to
## before Phase 2D's rect support existed. For a partial-region dispatch see
## step_region() below (GPU_ACTIVE_REGION.md).
func step(steps: int, seed: int, start_step: int = 0) -> void:
	_dispatch_batch(steps, seed, start_step, 0, 0, width, height)

## Phase 2D (GPU_ACTIVE_REGION.md): identical to step(), except the dispatch
## only covers [rect_x, rect_x+rect_w) x [rect_y, rect_y+rect_h) - rect_w/
## rect_h must be multiples of 8 (the shader's local_size_x/y), same
## constraint setup_grid() already has on width/height. Movement rules are
## byte-for-byte identical to step()'s - only which cells get dispatched
## differs.
func step_region(steps: int, seed: int, start_step: int, rect_x: int, rect_y: int, rect_w: int, rect_h: int) -> void:
	_dispatch_batch(steps, seed, start_step, rect_x, rect_y, rect_w, rect_h)

func _dispatch_batch(steps: int, seed: int, start_step: int, rect_x: int, rect_y: int, rect_w: int, rect_h: int) -> void:
	if not available or steps <= 0:
		last_compute_usec = 0
		return

	var t0 := Time.get_ticks_usec()
	_rd.buffer_update(_bounds_buf, 0, 16, _sentinel_bounds_bytes()) # reset once per BATCH, not per tick
	var group_x := rect_w / 8
	var group_y := rect_h / 8

	for i in range(steps):
		var read_buf := _buf_a if _current_is_a else _buf_b
		var write_buf := _buf_b if _current_is_a else _buf_a

		var uniform_read := RDUniform.new()
		uniform_read.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		uniform_read.binding = 0
		uniform_read.add_id(read_buf)

		var uniform_write := RDUniform.new()
		uniform_write.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		uniform_write.binding = 1
		uniform_write.add_id(write_buf)

		var uniform_bounds := RDUniform.new()
		uniform_bounds.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		uniform_bounds.binding = 2
		uniform_bounds.add_id(_bounds_buf)

		var uniform_set := _rd.uniform_set_create([uniform_read, uniform_write, uniform_bounds], _shader_rid, 0)

		var push_constant := PackedByteArray()
		push_constant.resize(32) # 8x uint32: width, height, step_index, seed, rect_x, rect_y, rect_w, rect_h
		push_constant.encode_u32(0, width)
		push_constant.encode_u32(4, height)
		push_constant.encode_u32(8, start_step + i)
		push_constant.encode_u32(12, seed)
		push_constant.encode_u32(16, rect_x)
		push_constant.encode_u32(20, rect_y)
		push_constant.encode_u32(24, rect_w)
		push_constant.encode_u32(28, rect_h)

		var list := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(list, _pipeline_rid)
		_rd.compute_list_bind_uniform_set(list, uniform_set, 0)
		_rd.compute_list_set_push_constant(list, push_constant, push_constant.size())
		_rd.compute_list_dispatch(list, group_x, group_y, 1)
		_rd.compute_list_end()

		_rd.free_rid(uniform_set) # uniform sets are cheap/disposable per dispatch in this PoC

		_current_is_a = not _current_is_a

		if i < steps - 1:
			_rd.barrier(RenderingDevice.BARRIER_MASK_COMPUTE, RenderingDevice.BARRIER_MASK_COMPUTE)

	_rd.submit()
	_rd.sync()
	last_compute_usec = Time.get_ticks_usec() - t0

## Phase 2D (GPU_ACTIVE_REGION.md "GPU -> CPU Synchronization"): reads back
## ONLY the 16-byte bounds buffer (never cell state) - the tight bounding box
## of every cell that changed across the most recently dispatched batch.
## Measured separately from compute, same discipline as read_back().
func read_bounds() -> Dictionary:
	if not available:
		return {"has_activity": false}
	var bytes := _rd.buffer_get_data(_bounds_buf)
	var min_x := bytes.decode_u32(0)
	var min_y := bytes.decode_u32(4)
	var max_x := bytes.decode_u32(8)
	var max_y := bytes.decode_u32(12)
	return {
		"has_activity": min_x <= max_x and min_y <= max_y,
		"min_x": min_x,
		"min_y": min_y,
		"max_x": max_x,
		"max_y": max_y,
	}

## Reads back the current (latest) buffer as a flat PackedInt32Array.
## Measured separately from step() - see the request's "GPU compute time
## != GPU + readback time" requirement.
func read_back() -> PackedInt32Array:
	if not available:
		return PackedInt32Array()
	var t0 := Time.get_ticks_usec()
	var buf := _buf_a if _current_is_a else _buf_b
	var bytes := _rd.buffer_get_data(buf)
	last_readback_usec = Time.get_ticks_usec() - t0
	return _bytes_to_int32_array(bytes)

func cleanup() -> void:
	if _rd == null:
		return
	if _buf_a.is_valid():
		_rd.free_rid(_buf_a)
	if _buf_b.is_valid():
		_rd.free_rid(_buf_b)
	if _bounds_buf.is_valid():
		_rd.free_rid(_bounds_buf)
	if _pipeline_rid.is_valid():
		_rd.free_rid(_pipeline_rid)
	if _shader_rid.is_valid():
		_rd.free_rid(_shader_rid)
	_buf_a = RID()
	_buf_b = RID()
	_bounds_buf = RID()
	_pipeline_rid = RID()
	_shader_rid = RID()
	# _rd itself is RefCounted (Godot 4.7.1 API: RenderingDevice inherits
	# RefCounted) - releasing the last reference (setting it null) frees it;
	# no explicit "free the device" call exists or is needed.
	_rd = null
	available = false

## Phase 2D: uses the built-in bulk conversion (PackedInt32Array.
## to_byte_array(), same little-endian layout the manual per-element
## encode_u32() loop this replaced produced - verified against the existing
## Sand/Water correctness suite) instead of a GDScript-level per-element
## loop. Purely a performance fix, same observable byte output - needed to
## make huge-world setup_grid() calls (GPU_ACTIVE_REGION.md "World Scaling",
## up to ~100M cells) practical; a manual loop at that scale would take
## GDScript tens of seconds to minutes just to serialize the initial buffer.
static func _int32_array_to_bytes(arr: PackedInt32Array) -> PackedByteArray:
	return arr.to_byte_array()

static func _bytes_to_int32_array(bytes: PackedByteArray) -> PackedInt32Array:
	return bytes.to_int32_array()
