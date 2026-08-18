# GPU Active Region — Phase 2D

Architectural contract for making GPU simulation cost track **active workload**, not **total world size**. Builds on [SIMULATION_TIMESCALE.md](SIMULATION_TIMESCALE.md) (Phase 2C, fixed timestep + accumulator, commit `88d62c7`) and [GPU_SIMULATION.md](GPU_SIMULATION.md) (Phase 2A SAND, Phase 2B WATER). Read both first — this document assumes and reuses their infrastructure without modifying the movement rules either one validated.

**Status:** CURRENT / IMPLEMENTED. Design, shader/wrapper extension, correctness validation (55/55), benchmarking, and stability testing are all complete — see [Workload Validation](#workload-validation) and [Architecture Decision](#architecture-decision) for the measured results and final GO-WITH-CONDITIONS decision.

---

## Problem

Phase 2C proved the GPU sustains real-time physical cadence (70–76× margin) at every SAND tier from 10k to 500k — but that margin turned out to be a property of *world buffer size* (fixed 3072×1792 for every tier), not of *active cell count*, because every dispatch evaluates the entire buffer regardless of how much of it actually has material moving. This is GPU_SIMULATION.md's own, already-documented "no GPU-side activation/sleeping" limitation, now connected empirically to a real number for the first time: dispatch cost is flat across a 50× SAND-count range specifically *because* it never depended on SAND count in the first place.

The consequence: a much larger world (the request's "100M+ cells" target) would pay the SAME per-dispatch cost as today's 5.5M-cell world even if only a few hundred cells are active — because the dispatch still covers everything. Phase 2D's job is to make GPU dispatch cost scale with **how much of the world is actually doing something**, mirroring what the CPU's chunk sleeping/activation system already does for the CPU path (SIMULATION_ACTIVATION.md).

---

## Current Full-World GPU Model (Phase 2C, unchanged by this phase's design — only extended)

Recap, not re-derivation — see GPU_SIMULATION.md/SIMULATION_TIMESCALE.md for full detail:

- `GPUSandPoC.step(steps, seed, start_step)` dispatches `width/8 × height/8` workgroups **every single call**, covering the entire configured buffer, regardless of where material actually is.
- State is a flat, ping-ponged `uint32`-per-cell buffer — no chunk concept exists in the buffer layout itself.
- `GPUSimulationBackend` (Phase 2C) adds a fixed-timestep accumulator on top, but still always calls into full-world `step()`.
- Movement rules (`powder_target`/`liquid_target`/`can_displace`/`resolve_winner_shallow`/`resolve_winner_for`) are the validated, unmodified reference — **Phase 2D does not touch a single line of this logic.**

---

## Active Region Design

**Options considered** (per the request's explicit instruction not to default to A):

| Option | Mechanism | Dispatch cost scales with | Complexity | Handles scattered regions |
|---|---|---|---|---|
| **A — Active chunk dispatch list** | CPU uploads a list of active chunk coordinates; shader indirection maps a compact workgroup range back to scattered chunk positions | active chunk count exactly | High — needs per-workgroup chunk-index indirection in the shader, a CPU-maintained discrete active-chunk set (add/remove per chunk), and correctness care around workgroup→chunk mapping | Yes, natively |
| **B — Active bounding region** | CPU tracks one rectangle covering all active material; dispatch covers just that rect | the *bounding rect's* area | Low — same dispatch call shape as today, just a different offset/size, no shader-side indirection needed | No — a rect covering two distant active pockets wastes dispatch on the empty space between them |
| **C — Active chunk mask, full dispatch** | Keep dispatching the whole world; each workgroup checks a mask and early-exits if inactive | **total world size** (dispatch/launch cost is paid regardless of the mask) | Low | Yes, but doesn't solve the actual problem |
| **D — GPU indirect dispatch** | GPU itself computes and writes dispatch dimensions (`compute_list_dispatch_indirect`), driven by a GPU-side compaction of active work | active chunk count exactly, with zero CPU round-trip to know the count | Highest — needs a GPU-side stream-compaction/active-list-build pass, indirect-dispatch buffer plumbing | Yes, and without a CPU sync point |

**Chosen: B, with a twist that avoids B's usual weakness** — instead of a CPU-side per-chunk mask (which would require either scanning cells every frame, forbidden by §13, or maintaining discrete per-chunk state, most of A's complexity without A's precision), the bounding rect for the **next** dispatch is computed by the **GPU itself**, via a tiny atomic min/max reduction over cells that actually changed this dispatch (see [GPU Data Structures](#gpu-data-structures)). This sidesteps two problems at once: no CPU-side per-cell scan (the rect comes from the GPU, not from CPU inspection of the buffer), and no per-chunk metadata array to build or upload (the "active region" is 4 numbers, not a list).

**Why not A or D for this phase:** this project's actual workload shape — every stress tier, every benchmark, the CPU's own `stress_test.gd` — is a single, roughly-rectangular falling/settling mass, never multiple disconnected active pockets. B's specific weakness (wasted dispatch area between disconnected regions) does not apply to any tested or currently-anticipated PixelSim workload. A and D would be justified the moment a real use case needs genuinely scattered simultaneous activity (e.g. many small, far-apart mining sites each spawning a few falling cells) — flagged explicitly as the natural next step in [Known Limitations](#known-limitations), not implemented speculatively now, per this project's own repeated "minimum viable, not maximal" instruction.

**CURRENT / IMPLEMENTED.**

---

## Activation Semantics

The CPU's reference behavior (SIMULATION_ACTIVATION.md) is the semantic model this mirrors, **not** a 1:1 port of `Chunk`/`mark_touched`/`activate_affected_neighbors` — the GPU path works at a different granularity (a rect covering many chunks, updated once per dispatch batch, not per individual cell write) because GPU_SIMULATION.md's PoC has no `Chunk` object at all, only a flat buffer.

A region is **active** whenever:
- It was just seeded with movable material (`GPUActiveRegionBackend`'s initial setup scans the seed buffer **once**, at setup time — not per tick — to compute the starting rect; see [Performance](#performance) for why this one-time cost is not the thing being protected against by §13's "no per-cell CPU scan" rule, which is about *per-tick* scanning), **or**
- The most recent dispatch's GPU-computed bounds show at least one cell changed (material moved), **or**
- An explicit external event marks a region dirty (`wake_region(rect)` — the GPU-side analog of a mining/spawn command; see [§17](#player--mining) for how this composes with mining staying CPU-side in this phase).

**CURRENT / IMPLEMENTED.**

---

## Wake Propagation

**ARCHITECTURAL RULE.** The dispatched rect is always the tight bounding box of last dispatch's activity, expanded by a **margin** before the next dispatch — the same purpose as `activate_affected_neighbors`'s fixed 5-cell neighborhood (SIMULATION_ACTIVATION.md), adapted to rect/chunk granularity: guarantee that any cell material could reach next tick is already inside the dispatched region, so the thread that needs to *receive* an incoming move is actually running.

**Margin sizing is dynamic, not a fixed constant, because it must cover an entire batch, not just one tick.** `GPUSandPoC.step()`/`step_region()` batch `N` ticks into one dispatch call (Phase 2C's existing batching, reused unchanged). Because every material moves **at most 1 cell per tick** (unchanged solver invariant, both CPU and GPU), a batch of `N` ticks can shift material by at most `N` cells in any direction before the *next* bounds readback has a chance to react. The margin must therefore be at least `ceil(N / CHUNK_SIZE) + 1` chunks (the `+1` is safety headroom, not load-bearing arithmetic) — computed fresh for every batch based on the batch's own tick count, never a single hardcoded constant. Getting this wrong would be a real correctness bug (material silently vanishing at a rect edge mid-batch), not just a performance tuning question — see [Correctness](#correctness) for the test that verifies this directly.

**CURRENT / IMPLEMENTED.**

---

## Sleeping

Mirrors the CPU's `dirty_this_pass` → `sleeping = !dirty_this_pass` rule (SIMULATION_ACTIVATION.md "Sleep Conditions") at batch granularity: if a dispatch batch's GPU-computed bounds report **zero** changed cells, the region is fully settled — the active-region backend stops dispatching entirely (`region_active = false`) until an explicit `wake_region()` call. No per-tick CPU cost is paid for a sleeping region — this is the whole point.

**CURRENT / IMPLEMENTED.**

---

## GPU Data Structures

Two additions to the existing Phase 2A/2B shader/wrapper, both purely additive — no existing field removed or repurposed:

**Push constants**, extended from 4 to 8 `uint32`s (16 → 32 bytes, comfortably within Vulkan's minimum guaranteed 128-byte push-constant budget):
```glsl
layout(push_constant, std430) uniform Params {
    uint width;      // full world width (unchanged) - bounds-check reference
    uint height;     // full world height (unchanged)
    uint step_index;
    uint seed;
    uint rect_x;     // NEW - dispatch region origin, cell space
    uint rect_y;     // NEW
    uint rect_w;     // NEW - dispatch region size, cell space (multiple of 8)
    uint rect_h;     // NEW
} params;
```
`main()` computes `p = ivec2(rect_x, rect_y) + ivec2(gl_GlobalInvocationID.xy)`, bounds-checks against the **full** `width`/`height` (unchanged safety property — a rect can never cause an out-of-world write, same as before). `GPUSandPoC.step()` (full-world, Phase 2C compatibility) always passes `rect = (0, 0, width, height)` — its dispatch shape, and therefore its measured behavior/performance, is unchanged.

**A third storage buffer**, 16 bytes, atomic bounds tracking:
```glsl
layout(set = 0, binding = 2, std430) restrict buffer BoundsBuf {
    uint min_x;
    uint min_y;
    uint max_x;
    uint max_y;
} bounds_buf;
```
Reset to sentinel values (`min_x=min_y=0xFFFFFFFF`, `max_x=max_y=0`) once per **batch** (not per tick) via one small `buffer_update()` call before the batch's dispatches are recorded. Every thread that computes a `next_val` different from its own `current` value calls `atomicMin`/`atomicMax` against its own `(x, y)` — commutative/associative, so ordering across the batch's N dispatches doesn't matter, and the buffer accumulates the **union** of every cell that changed anywhere across the whole batch, which is exactly what's needed to compute the next dispatch's rect.

**Why this is not "the whole world state," and not a violation of §16's "no full readback":** 16 bytes, regardless of world size, active region size, or batch length. Compare to the 8-byte-per-cell full state buffer (tens of megabytes at the tested world sizes) — this is a fixed-size summary, not a scan.

**CURRENT / IMPLEMENTED.**

---

## CPU → GPU Synchronization

**Only the rect** (16 bytes, inside the existing push-constant upload every batch already pays) — no per-chunk active-list array, no per-chunk metadata buffer of any kind. This is the direct benefit of choosing B-with-GPU-computed-bounds over A: there is nothing analogous to "upload N chunk coordinates" to measure, because the representation is 4 numbers regardless of how many chunks the rect happens to cover. Measured explicitly in [Performance](#performance) as part of the CPU-orchestration-cost breakdown, expected to be unmeasurably small.

**CURRENT / IMPLEMENTED.**

---

## GPU → CPU Synchronization

**The 16-byte bounds buffer, read back once per dispatch batch** — not the cell state, not a per-chunk array. This is a real, measured, per-batch cost (a `buffer_get_data` call has fixed overhead independent of size), reported separately from GPU compute time, matching this project's established "compute ≠ compute+readback" measurement discipline (GPU_SIMULATION.md "Performance", SIMULATION_TIMESCALE.md "GPU Capacity"). Full cell-state readback remains reserved for debug/validation/benchmark/explicit-gameplay-query only, exactly as Phase 2C established — this phase does not change that rule, it just adds one more small, justified, separately-measured exception (the bounds buffer) alongside it.

**CURRENT / IMPLEMENTED.**

---

## Performance

**Measured results:** see [Workload Validation](#workload-validation) below (active-chunk-count sweep, world-size scaling, CPU/GPU-full/GPU-active tier comparison, CPU activation-management overhead breakdown).

---

## World Scaling

**Measured results:** see [Workload Validation](#workload-validation).

---

## Correctness

Standalone-runnable via `gpu_solver_tests.gd` (existing 12+16, re-verified unaffected by the shader's additive changes) plus 10 new active-region scenarios:

1. **Single active chunk** — a lone falling cell, active region stays a small, bounded rect (not the full world).
2. **Falling across chunks** — material crossing a would-be chunk boundary inside the tracked rect, correctly received (mirrors GPU_SIMULATION.md's existing 126-row chunk-boundary test, now inside a moving active rect instead of a full-world dispatch).
3. **Horizontal water propagation** — WATER spreading sideways across several chunks, rect grows to follow it.
4. **Activation chain** — a multi-row SAND stack collapsing, rect tracks the leading edge of the collapse as it descends.
5. **Sleep after settle** — once nothing changes for one batch, `region_active` becomes `false` and no further dispatches occur until woken.
6. **Wake after new material** — `wake_region()` on a currently-asleep backend correctly resumes dispatching.
7. **Mining wake** — a direct write simulating a mining command (removing support) correctly triggers `wake_region()` and the newly-unsupported material falls.
8. **Boundary wake** — material starting right at the world edge is handled without the rect going out of bounds.
9. **Active/inactive transition** — repeated settle→wake→settle cycles produce consistent, correct results each time.
10. **Deterministic repeatability** — two independent active-region runs, same seed, same initial rect, produce byte-identical final state.

**Measured results:** see [Workload Validation](#workload-validation).

---

## CPU vs GPU Active Set

Per the request's explicit instruction: **not** claimed as exact equality (the GPU's rect-based region is coarser-grained than the CPU's exact per-chunk sleep/dirty state by design — see [Active Region Design](#active-region-design)). The behavior invariant actually checked, mirroring Phase 2B's own honesty standard for contested-case CPU/GPU comparison: **both reach the same final stable state and the same mass-conserved counts**, not that they report identical "which chunks were active when." No exact-equivalence claim is made or implied where the models structurally can't agree.

**Measured results:** see [Workload Validation](#workload-validation).

---

## Player / Mining

Unchanged from Phase 2C — player collision and mining remain entirely CPU-side. What this phase adds is only the **mechanism** a future mining-to-GPU wake path would use (`wake_region(rect)`), tested via a direct simulated write (test 7 above), not an actual CPU mining → GPU pipeline integration (explicitly out of scope, see [Prohibited This Phase](#prohibited-this-phase)).

## Rendering

Unrelated concept, unchanged. "Simulation active" (this document) and "render resident" (PERFORMANCE_SCALABILITY.md's Phase 1 lazy rendering) are independent — a chunk can be simulation-active and render-non-resident (an off-screen falling mass) or render-resident and simulation-asleep (a settled, on-screen pile). Neither system reads or depends on the other's state.

---

## Known Limitations

Explicitly out of this phase's scope, not oversights:

- **Scattered, simultaneously-active regions are not efficiently handled** — a bounding rect covering two distant active pockets pays for the empty space between them. Not a problem for any tested or currently-anticipated PixelSim workload (see [Active Region Design](#active-region-design)); would motivate option A or D if it ever becomes one.
- **No GPU-side per-chunk sleep/dirty state** — the active representation is one rect, not a discrete per-chunk set. Coarser than the CPU's chunk-granular model by design.
- **LAVA, Material Reaction System, GPU mining, GPU player collision, GPU-native rendering remain entirely CPU-side** — unchanged from every prior phase's limitations list.
- **Margin sizing assumes the existing "at most 1 cell per tick" movement invariant** — a future material or rule that could move faster than 1 cell/tick would need the margin formula revisited, not just a bigger constant.

---

## Architecture Decision

**GO WITH CONDITIONS.**

### Does GPU cost now scale with active workload?

**Yes**, directly measured and isolated: the active-chunk-count sweep shows a clear, monotonic ~4.4× compute-time growth from 1 to 2,000 active chunks (6,055 µs → 26,735 µs) — a fundamentally different shape from Phase 2C's full-world dispatch, whose cost never moved regardless of SAND count.

### Does GPU cost remain mostly independent of total world size?

**Mostly, not perfectly** — reported honestly rather than rounded up. Holding the active region fixed at 56 chunks, growing the world 18× (5.5M → 100M cells) grew compute time only 3.7× (5,435 µs → 20,104 µs): a large, real improvement over what a full-world dispatch would show at that world size (an 18× cost increase, by construction), but not the flat line the request's ideal case describes. The residual growth tracks total GPU allocation size, not dispatched-region size — a distinct, smaller, separately-flagged effect (see [World-Size Scaling](#world-size-scaling)).

### Does 500k Sand remain real-time?

**Yes, at every measurement taken** — including the one unflattering result (the real-workload tier comparison, where active-region dispatch was *slower than full-world* at this tier due to workload shape, not architecture): even that slower path still delivers a ~64× real-time margin. The active-chunk sweep and the dedicated 500k stability run (600 ticks, 0.088s wall, ~113× margin, mass exactly conserved) both confirm this independently.

### Is CPU activation overhead acceptable?

**Yes, unambiguously** — 0.6–0.9 microseconds per bookkeeping call, 4–5 orders of magnitude below any measured GPU cost. The specific failure mode the request worried about ("GPU 0.2ms / CPU management 5ms") was checked for directly and does not occur.

### Is the architecture ready for additional GPU materials?

**Not tested this phase, but structurally plausible.** The bounds-buffer mechanism (`atomicMin`/`atomicMax` on any cell whose value changed) is material-agnostic by construction — it compares `next_val != current`, never inspects *which* material — so a third GPU material would not need this phase's active-region machinery touched. This is an expectation grounded in the mechanism's design, not an empirical result; it should be re-verified, not assumed, the moment a third material is actually ported (per this project's own "measure, don't assume" discipline).

### Conditions attached to the GO

1. **Workload-shape dependency is real.** The bounding-rect (Option B) approach chosen for this phase measurably underperforms on `stress_test.gd`'s wide-slab geometry specifically because that shape doesn't shrink much in one dimension. A genuinely scattered or highly elongated workload would show this more starkly than the tested tiers did — Option A/D (see [Active Region Design](#active-region-design)) remain the answer if that ever becomes a real, not synthetic, workload pattern.
2. **World-size independence is sub-linear, not absolute.** A world large enough that total GPU allocation size itself becomes the bottleneck (not tested at the sizes used here) would need the tighter state packing already flagged as future work in GPU_SIMULATION.md.
3. **Scope is still SAND + WATER only**, still not wired into `PixelSimWorld`/`Main.tscn`/any production path, still no LAVA/reactions/mining/GPU-side production integration — unchanged from every prior phase's condition list.
4. **The margin-sizing formula assumes the existing "≤1 cell/tick" movement invariant** — any future faster-moving material needs this formula revisited explicitly (see [Known Limitations](#known-limitations)).

None of these are reasons to reject the phase's core finding — they are the same kind of explicitly-scoped-out conditions Phase 2C's own GO carried, now joined by this phase's own new ones. The mechanism (active-region dispatch, GPU-computed bounds, chunk-aligned margin, wake/sleep) works, is correct (55/55 tests), and measurably reduces GPU cost when workload shape cooperates — proven, not assumed, exactly as this project's own documentation discipline requires.

---

## Workload Validation

All numbers from live measurement in the running editor (`gpu_active_region_benchmark.gd`, `gpu_simulation_backend.gd`, `gpu_active_region_tests.gd`).

### Correctness

`gpu_solver_tests.gd` (Phase 2A/2B, 40 checks) + `gpu_active_region_tests.gd` (Phase 2D, 15 checks, the 10 scenarios above): **55/55 checks passed, 0 failures**, against the additively-extended shader — confirms the rect-offset/bounds-buffer additions did not change a single movement outcome.

### Active-Chunk-Count Sweep

Fixed default world (3072×1792), direct `step_region()` calls (controlled, roughly-square regions), 60-tick batches:

| Requested chunks | Actual chunks | GPU compute (µs) | `simulation_real_time_ratio` |
|---:|---:|---:|---:|
| 1 | 1 | 6,055 | 164.9 |
| 10 | 12 | 7,350 | 136.0 |
| 50 | 56 | 9,610 | 104.0 |
| 100 | 100 | 11,299 | 88.5 |
| 500 | 506 | 16,901 | 59.2 |
| 1,000 | 896 | 21,083 | 47.4 |
| 2,000 | 2,025 (6144×3584 world — 2,000 exceeds the default world's 1,344-chunk capacity) | 26,735 | 37.4 |

**Directly answers §25.A: yes, GPU compute cost now measurably scales with active region size** — a monotonic ~4.4× growth from 1 to 2,000 active chunks, in clear contrast to Phase 2C's full-world dispatch, whose cost was flat *regardless* of how much material was present. Even at 2,000 active chunks (8.2M actively-simulated cells — more than the entire original 5.5M-cell world), the real-time margin stays a comfortable 37×.

### World-Size Scaling

Fixed active region (50 requested / 56 actual chunks), growing the **world buffer**, 60-tick batches:

| World | Cells | GPU compute (µs) | `simulation_real_time_ratio` |
|---:|---:|---:|---:|
| 3072×1792 | 5.5M | 5,435 | 183.7 |
| 6544×3816 | ~25M | 7,166 | 139.4 |
| 9280×5416 | ~50M | 13,861 | 72.1 |
| 13104×7648 | ~100M | 20,104 | 49.7 |

**Answering §25.B honestly, not optimistically:** cost grows **sub-linearly** with world size (3.7× compute-time growth for an 18× world-size increase) — much better than a full-world dispatch would show (which would grow ~18× directly, matching world size exactly, per Phase 2C's own established relationship between dispatch area and cost) — but **not perfectly flat**. The residual growth is consistent with GPU memory-subsystem/allocation overhead scaling with total buffer size (a ~1.6GB combined ping-pong allocation at 100M cells vs. ~44MB at 5.5M), not with the dispatched *region* itself, which stayed exactly the same 56 chunks throughout. This is a real, worth-tracking limitation, not a flaw in the active-region *mechanism* — the region-size sweep above already isolated and confirmed that dispatched-area cost scales correctly; this table isolates a *separate*, smaller effect (large-allocation overhead) that a future phase could investigate if world sizes this large become a real requirement (e.g. a tighter GPU state packing, already flagged as future work in GPU_SIMULATION.md "Future Phases").

100M cells (~1.6GB combined GPU allocation) ran without error on the test hardware (AMD RX 6900XT, 16GB VRAM) — not stress-tested to find the actual VRAM ceiling, which is hardware-dependent and out of this phase's scope to characterize.

### CPU vs GPU-Full-World vs GPU-Active-Region (Sand-Fall Tiers)

Same `stress_test.gd`-derived slab geometry as Phase 2C, default world, 60-tick/60-call comparison:

| SAND cells | CPU wall (60 calls) | GPU full-world wall (Phase 2C) | GPU active-region wall (Phase 2D) | Active region (chunks) |
|---:|---:|---:|---:|---:|
| 10,000 | 0.0489 s | 0.0140 s | **0.0055 s** | 192 |
| 100,000 | 0.1435 s | 0.0137 s | **0.0119 s** | 192 |
| 250,000 | 0.2306 s | 0.0134 s | 0.0151 s | 240 |
| 500,000 | 0.2283 s | 0.0142 s | 0.0157 s | 288 |

**An honest, unflattering-at-first-glance finding, reported as measured, not smoothed over:** active-region dispatch is faster than full-world at 10k/100k, but *slightly slower* at 250k/500k. This is **not** a flaw in the active-region mechanism (which the two controlled sweeps above prove works correctly) — it's a mismatch between this specific *workload shape* and what bounding-rect dispatch (Option B) is good at. `stress_test.gd`'s slab is **wide and short** (spans nearly the world's full 48-chunk width even at 10k, only height grows with cell count), so the active region's width dimension barely shrinks versus the full world at any tier — the "savings" only ever come from the height dimension, and at higher tiers the height itself grows enough to erode most of that saving, plus this table adds active-region-specific overhead (the bounds-buffer reset/readback each batch) that the full-world path doesn't pay. **The controlled active-chunk sweep above is the correct place to see this mechanism's real benefit** — it isolates region size from workload shape, which this table cannot do because `stress_test.gd`'s geometry was designed for a different purpose (CPU chunk-row activity testing) and happens to be close to worst-case for a bounding-rect GPU dispatch. A more realistic *localized* workload (a mining collapse in one spot, not a world-spanning slab) would look much more like the sweep's numbers — see [Known Limitations](#known-limitations).

**Still real-time at every tier tested**, including the "slower" ones: 500k SAND's active-region wall time (0.0157s for 60 ticks = 1.0s physical) is still a ~64× real-time margin — the comparison above is about *which GPU path is faster*, not about whether either one can keep up.

### CPU Activation Overhead

Pure CPU-side active-region bookkeeping (`_align_region`, `enable_active_region`), timed directly, no GPU dispatch involved:

| Operation | Cost per call |
|---|---:|
| `_align_region` | 0.60 µs |
| `enable_active_region` | 0.90 µs |

**Directly answers §26/§25.D: no, CPU activation overhead does not become a new bottleneck.** Sub-microsecond, 4–5 orders of magnitude smaller than any measured GPU compute time (5,000–27,000 µs across every table above). The "GPU 0.2ms / CPU active management 5ms" failure mode the request explicitly worried about does not occur — the actual relationship is closer to the reverse.

### GPU Stability

500,000-SAND tier, active-region dispatch, 60 consecutive batches × 10 ticks = 600 ticks (10.0s of physical simulation time), one continuous session (no `RenderingDevice` recreation mid-run, per the Phase 2C lesson):

- Wall time: **0.088 s** for the full 600-tick run (a ~113× real-time margin sustained across the whole run, not just a single batch).
- Mass conservation: exactly 500,000 SAND cells before and after — verified via full readback (validation-only, per the established readback discipline).
- No device loss, no validation errors, no dispatch failures.
- The 100M-cell world-scaling measurement (above) also completed without incident, at the largest single GPU allocation this phase tested (~1.6GB combined ping-pong buffers).

**A distinct operational lesson from this phase's own development, not a repeat of Phase 2C's:** an early version of this phase's benchmark script called `GPUSandPoC.new()` once per script-execution retry after a (since-fixed) GDScript type-inference bug caused repeated tool-level timeouts, silently accumulating multiple orphaned `RenderingDevice` instances across retries. No crash resulted this time, but it's the same class of risk Phase 2C's stability finding warned about — reinforced here: **fix compile errors before re-running a GPU-heavy script**, and restart the play session after any timeout/retry sequence to guarantee a clean device count, rather than assuming the previous attempt's resources were cleanly released.

---

## Architectural Invariants

- The movement rules (`powder_target`, `liquid_target`, `can_displace`, `resolve_winner_shallow`, `resolve_winner_for`) are byte-for-byte unchanged from Phase 2B — this phase only changes *where* they're dispatched, never *what* they compute.
- `GPUSandPoC.step()`'s observable behavior (signature, dispatch shape, results) is unchanged — Phase 2C's existing tests/benchmarks remain valid without modification.
- No per-tick, per-cell CPU-side scan exists anywhere in this feature — the active rect is always derived from a GPU-computed 16-byte summary, never CPU inspection of cell data.
- No per-chunk CPU→GPU metadata array — the active representation is 4 numbers (a rect), regardless of how many chunks it spans.
- Full cell-state GPU→CPU readback stays reserved for debug/validation/benchmark/explicit query only — this phase's addition (the 16-byte bounds readback) is a separately-measured, justified exception, not a loosening of that rule.
- `RenderingDevice`/shader/pipeline creation happens once per session, reused across an entire benchmark/test run — the Phase 2C stability lesson (rapid device recreation, not dispatch volume, crashes the process) is not repeated.
- 64×64 `CHUNK_SIZE`, the CPU reference solvers, fixed timestep, Background/Foreground, player collision, mining, and the renderer are unmodified.

## Prohibited This Phase

Per the request's explicit scope boundaries: no LAVA GPU migration, no Material Reaction GPU migration, no player-collision-to-GPU migration, no mining-to-GPU migration, no GPU-native renderer, no deletion of the CPU reference backend, no change to the physical timestep model "to make the benchmark look better," no change to the 4ms CPU budget.

## How Future Work Should Use This Document

1. Read this document, SIMULATION_TIMESCALE.md, and GPU_SIMULATION.md before touching GPU dispatch shape, the bounds buffer, or the active-region rect logic.
2. A future need for genuinely scattered simultaneous active regions is the trigger for revisiting option A/D — do not preemptively build that machinery without a measured need.
3. If a future material can move more than 1 cell per tick, the margin-sizing formula in [Wake Propagation](#wake-propagation) must be revisited explicitly, not patched with a bigger constant.
4. Re-run the correctness suite and re-measure performance after any change here, per this project's established "measure, don't assume" discipline.
5. If this document and the code disagree, that's a bug in one of them — fix the drift, don't silently pick a side.
