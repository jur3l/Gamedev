# Simulation Timescale — Fixed Timestep, Accumulator, GPU Integration PoC

Architectural contract for PixelSim's **Phase 2C**: a Real-Time Timestep Proof of Concept that decouples physical simulation time from CPU compute-workload, integrated with the existing GPU Sand/Water PoC ([GPU_SIMULATION.md](GPU_SIMULATION.md)). This document is written with its design sections locked in **before** implementation (per this project's own convention — see PROJECT_ARCHITECTURE.md §19), then updated with measured results once built. Read [SIMULATION_TIMESCALE_INVESTIGATION.md](SIMULATION_TIMESCALE_INVESTIGATION.md) first — that document is the *problem statement* this one *solves*; nothing here repeats its analysis, only its conclusions.

**Status:** CURRENT / IMPLEMENTED. Design, implementation, correctness validation, benchmarking, and stability testing are all complete — see [Workload Validation](#workload-validation) and [Architecture Decision](#architecture-decision) for the measured results and final GO-WITH-CONDITIONS decision.

**Naming note.** [GPU_SIMULATION.md](GPU_SIMULATION.md)'s own roadmap already used "Phase 2C" for a different thing — a formal, automated CPU/GPU validation harness (the Sand-12/Water-16 test suites existed only as one-off scripted runs, never committed). This Phase 2C **fulfills that requirement as a side effect** (see [Validation](#validation)) while adding the timestep/accumulator/GPU-integration work that's this document's actual subject — one phase, two names reconciled, not a silent renumbering. See GPU_SIMULATION.md's own updated "Future Phases" for the resolution.

---

## Current CPU Model

Summarized from SIMULATION_TIMESCALE_INVESTIGATION.md (read that document for the full derivation and measurements):

- `PixelSimWorld::step_simulation(double delta)` receives `delta` and never uses it. `main.gd` calls it once per `_process`, unconditionally.
- `World::step(simulation_budget_ms)` is a **CPU wall-clock cutoff**, not a physics-rate control — it bounds how much real time one call may spend scanning rows, nothing more.
- The only unit of "physical time" that exists anywhere is the **pass** (one full bottom-to-top sweep), and pass rate (passes/real-second) is a pure side effect of how many frames a pass happens to take.
- **Measured, not theoretical**: the same 100 passes take 0.72s at 10k SAND vs. 4.22s at 500k SAND — a 5.85× real-time slowdown for identical physical progress, because a busier scene keeps more chunk-rows active, pushing `sim_ms` up toward the 4ms budget and fragmenting one pass across more frames.

## Problem

Compute-work budget and physical-time rate are the same variable today, when conceptually they should be independent. `simulation_budget_ms` protects frame time; nothing protects (or even defines) a target physical tick rate. This document's job is to introduce that missing concept — a fixed timestep + accumulator — and pair it with the GPU PoC (whose compute-only cost is close to flat across the tested scale, unlike the CPU's per-row serial cost) to test whether physical time can be kept workload-independent in practice, not just in principle.

---

## Fixed Timestep

**ARCHITECTURAL RULE.** One **physical simulation tick** = one fixed slice of simulated time, `fixed_dt`, independent of render frame rate.

```
PHYSICAL_TICKS_PER_SECOND = 60   # chosen baseline — see rationale below
fixed_dt = 1.0 / PHYSICAL_TICKS_PER_SECOND  # ~16.667 ms of simulated time per tick
```

**Why 60.** This is a deliberate, arbitrary-but-reasonable choice, not derived from anything else in the codebase: it matches the common render-frame-rate target this project already observes (PERFORMANCE_SCALABILITY.md's own FPS ceiling discussion), so that a simulation keeping perfect real-time cadence (`real_time_ratio == 1.0`) naturally produces "one tick per frame" at a 60fps render loop — an easy sanity check. Nothing about the accumulator design requires 60 specifically; it is a single named constant, changeable later without changing the mechanism.

**What one tick *is*, physically.** One GPU compute dispatch (`GPUSandPoC.step(1, seed, tick_index)`) is the direct GPU analog of one CPU pass: every currently-movable cell gets exactly one opportunity to move, resolved in parallel (pull model) rather than serially row-by-row, but the *physical meaning* — "gravity/flow got one uniform update across the whole grid" — is the same unit SIMULATION_TIMESCALE_INVESTIGATION.md already identified as the correct one to reason about. This is why `fixed_dt` is defined in terms of ticks, not frames or CPU-ms: a tick's *physical* cost is fixed by definition; only its *wall-clock* cost varies with hardware/workload, which is exactly the thing being measured, not assumed.

**CURRENT / IMPLEMENTED.**

---

## Accumulator

**ARCHITECTURAL RULE.** Render frame rate and physical simulation tick rate are decoupled via a standard fixed-timestep accumulator, with an explicit cap to prevent spiral-of-death:

```
accumulator += real_delta
ticks_this_frame = 0
while accumulator >= fixed_dt and ticks_this_frame < max_ticks_per_frame:
    run_simulation_tick()          # one GPU dispatch, batched with any others this frame
    accumulator -= fixed_dt
    ticks_this_frame += 1
    simulation_time += fixed_dt
# whatever remains in accumulator >= fixed_dt after the cap is backlog (see below)
```

`max_ticks_per_frame` (default **10**, configurable) is the spiral-of-death guard required by the request: a frame is never allowed to try to "catch up" an unbounded amount of simulation in one call, no matter how far behind the accumulator has fallen. This bounds worst-case per-frame GPU dispatch count, at the cost of allowing backlog to grow explicitly (never silently) when the true required rate exceeds what `max_ticks_per_frame` ticks can deliver in real time.

**Batching, not N round-trips.** `GPUSandPoC.step(steps, seed, start_step)` already records `steps` dispatches with barriers between them and issues exactly **one** `submit()`/`sync()` for the whole batch (see `gpu_sand_poc.gd`, unmodified). The accumulator calls this once per frame with `steps = ticks_this_frame`, never once per tick — reusing this existing batching property rather than reimplementing it.

**CURRENT / IMPLEMENTED.**

---

## GPU Integration

**ARCHITECTURAL RULE.** No new GPU simulation infrastructure. The accumulator/clock/backlog logic is a new, thin orchestration layer — `GPUSimulationBackend` (`project/scripts/gpu_simulation_backend.gd`) — that *composes* an unmodified `GPUSandPoC` instance; it does not touch `gpu_sand_poc.gd` or `gpu_cellular_solver.glsl` at all.

```
GPUSimulationBackend (new, thin orchestration)
  ├─ owns: GPUSandPoC (existing, unmodified — ping-pong buffers, dispatch, readback)
  ├─ owns: simulation_time, accumulator, fixed_dt, max_ticks_per_frame, tick_counter
  ├─ owns: backlog / ticks_executed / ticks_requested / max_backlog_seen counters
  └─ owns: compute_usec / readback_usec / orchestration_usec accumulation (§ No Hidden CPU Bottleneck)
```

`advance(real_delta: float) -> Dictionary` is the single entry point, analogous to `PixelSimWorld::step_simulation(delta)` but for the GPU path — the direct fix for the CPU model's core defect ("delta is received and never used"): here `delta` is exactly what drives the accumulator.

**No readback every tick.** Per the request's explicit instruction, `GPUSimulationBackend` never calls `GPUSandPoC.read_back()` as part of `advance()` — the simulation state stays GPU-resident across ticks by design (the ping-pong buffers already do this; nothing needs to leave the GPU for the simulation to keep progressing). `read_back()` is called only when something outside the simulation loop needs the data (a benchmark's correctness check, or in a hypothetical production path, the renderer) — and its cost is measured completely separately from compute cost (`last_readback_usec`, already exposed by `GPUSandPoC`, is never folded into `last_compute_usec`).

**CURRENT / IMPLEMENTED.**

---

## Real-Time Ratio

**Definition — two clocks, kept explicitly separate, per the request's §10 requirement:**

- **`physical_simulation_time`** — `ticks_executed × fixed_dt`. How much simulated world-time has elapsed. Independent of how it was produced.
- **`intended_wall_time`** — for a benchmark run emulating N frames at a target render rate F, `N / F` seconds. This is "how much real time a player would have experienced" at that render cadence — *not* how long the benchmark script itself took to execute (see below).
- **`script_wall_time`** — the actual, measured (`Time.get_ticks_usec()`) real time the benchmark script took to run. Dominated by GPU compute + optional readback + CPU orchestration overhead. This is **not** frame-rate-limited (there's no real vsync/render loop in an automated benchmark), so it answers a different question than `intended_wall_time`: not "did it keep the accumulator's backlog at zero" but "does the hardware have the raw throughput to sustain the target tick rate at all."

Two derived ratios, answering two different questions:

```
simulation_real_time_ratio (design-level)
    = physical_simulation_time / intended_wall_time
    → did the accumulator, under its max_ticks_per_frame cap, keep pace with
      the target render cadence it was fed?

simulation_real_time_ratio (hardware-capacity)
    = physical_simulation_time_covered / script_wall_time
    → measured by running enough ticks to cover a fixed amount of physical
      time (e.g. 1.0s = 60 ticks) back-to-back with no artificial frame
      pacing, and timing how long that actually took on the GPU. This is
      the number that answers the request's §2/§13 core question ("can the
      GPU keep real-time cadence") independent of any particular render FPS.
```

Both are reported; the hardware-capacity ratio is the primary metric for the [GPU Capacity](#gpu-capacity) results, and the design-level ratio is the primary metric for the [Accumulator](#accumulator)/[Backlog](#backlog)/[FPS Independence](#fps-independence) validation.

`1.00` = real-time. `< 1.00` = falling behind (hardware capacity, or an under-provisioned `max_ticks_per_frame`). `> 1.00` = simulation running ahead of the target rate (possible and fine — it just means the accumulator/backlog stays at zero and there was headroom to spare).

**Measured results:** see [GPU Capacity](#gpu-capacity) and [Workload Validation](#workload-validation) below.

---

## Backlog

**ARCHITECTURAL RULE.** Falling behind must be explicit and measured, never silently absorbed (per the request's §12 — "ne rejtsük el").

- **`backlog_ticks`** (current) — `floor(accumulator / fixed_dt)` remaining *after* a frame's capped execution loop stops (either because the accumulator dropped below `fixed_dt`, or because `max_ticks_per_frame` was hit first). Zero means fully caught up.
- **`max_backlog_ticks_seen`** — the largest `backlog_ticks` observed at any point during a run.
- **`avg_backlog_ticks`** — mean of `backlog_ticks` sampled every frame over a run.
- **`ticks_executed`** — cumulative count of ticks actually run.
- **`ticks_requested`** — `ticks_executed + backlog_ticks` (final) — the total number of ticks that have ever entered the queue, executed or not.

A backlog that stays at 0 throughout a run means `max_ticks_per_frame` was never the binding constraint — the GPU comfortably kept pace with whatever frame cadence was fed in. A nonzero, growing backlog means the target tick rate exceeded what the capped per-frame execution could deliver — the honest, bounded version of what today's CPU path does silently and unboundedly.

**Measured results:** see [Workload Validation](#workload-validation).

---

## GPU Capacity

The request's core question (§2/§13): *given the same physical timestep model, can the GPU keep real-time cadence at 10k/100k/500k SAND, without CPU budget slowing physical time down?*

Measured via the hardware-capacity `simulation_real_time_ratio` defined above: for each tier, run exactly `PHYSICAL_TICKS_PER_SECOND` ticks (= 1.0s of physical simulation time) as one batched dispatch, time it for real, compute the ratio. No artificial pacing, no frame simulation — this isolates raw GPU throughput from the accumulator/backlog mechanism entirely.

**Measured results:** see [Workload Validation](#workload-validation) and [Architecture Decision](#architecture-decision).

---

## FPS Independence

**Test design.** Run the *same* deterministic tick sequence (same seed, same initial state, same `PHYSICAL_TICKS_PER_SECOND=60` target) to `physical_simulation_time >= 1.0s`, three times, each time feeding the accumulator synthetic frame deltas matching a different render cadence: 30fps (`delta=1/30`), 60fps (`delta=1/60`), 120fps (`delta=1/120`). Because the accumulator always executes ticks in fixed `fixed_dt` increments regardless of how many frames it took to accumulate enough time, and because each tick's GPU dispatch is seeded by its own monotonically-increasing `tick_index` (not by frame count), **the exact same sequence of ticks should run in all three cases** whenever `max_ticks_per_frame` is never the binding constraint (i.e. backlog stays 0) — this is the thing being verified, not assumed.

**Pass condition:** after reaching `physical_simulation_time == 1.0s` in all three runs, `read_back()` the GPU state and confirm the three resulting grids are identical.

**Measured results:** see [Workload Validation](#workload-validation).

---

## Validation

Before any timestep/benchmark work is trusted, the existing GPU solver correctness must be reconfirmed against the *unmodified* shader/wrapper — and, since neither test suite was ever committed (GPU_SIMULATION.md's Phase 2A/2B tests were one-off scripted runs), this phase persists them as real, re-runnable files for the first time:

- `project/scripts/gpu_solver_tests.gd` — the 12 Phase 2A (SAND) + 16 Phase 2B (WATER) correctness scenarios, as a checked-in, re-runnable script (previously existed only as ad-hoc script calls during development — see GPU_SIMULATION.md "Results"). This is what fulfills GPU_SIMULATION.md's own originally-recommended "Phase 2C — formal, automated CPU/GPU validation harness."

**Measured results:** see [Workload Validation](#workload-validation).

---

## GPU Stability

Per the request's explicit concern (a Vulkan `device lost` event was observed once during Phase 2B, during one large script issuing many back-to-back GPU dispatches in a single call — see GPU_SIMULATION.md "Known Limitations"): run long-duration tick sequences (hundreds of consecutive ticks) at 10k/100k/500k, **each tier in its own isolated script invocation** (the lesson already learned from the Phase 2B incident — smaller, isolated calls had no further incidents), watching for device loss, validation errors, dispatch failures, or GPU memory growth across the run.

**Measured results:** see [Workload Validation](#workload-validation).

---

## Architecture Decision

### Can GPU simulation maintain real-time physical cadence?

| Tier | `simulation_real_time_ratio` |
|---|---|
| 10k | **71.4** |
| 100k | **72.9** |
| 500k | **70.4** |

**Yes — at all three tiers, by a 70×+ margin, essentially flat across a 50× range of SAND cell counts.** This is a substantially stronger result than the request's own "very good" hypothetical (`500k → 0.98`). The margin is large enough that the accumulator's `max_ticks_per_frame` safety cap was never observed to bind at any tested workload — see [Backlog / Accumulator Validation](#backlog--accumulator-validation).

**The honest caveat, stated per §13's own instruction not to report a comfortable number without its limit:** this margin is a property of *world size* (3072×1792 cells, fixed for every tier), not of SAND/WATER cell count, because the current PoC has no GPU-side activation/sleeping equivalent — every dispatch always evaluates the entire buffer (a known, already-documented Phase 2A/2B limitation, now connected empirically to the real-time-ratio question for the first time in this phase). The tested tiers did not stress this axis; a world large enough that full-buffer evaluation itself becomes the bottleneck (not tested here) would show a different, lower ratio, and that is the real capacity question a future phase would need to answer, not "how much SAND."

### Is GPU-first architecture justified?

**GO WITH CONDITIONS.**

**GO**, for the narrow question this phase was scoped to answer: the accumulator/fixed-timestep/GPU-integration *mechanism* works, is correct (backlog/FPS-independence validated), and the GPU PoC comfortably sustains real-time cadence at every stress-test tier this project already uses, with dramatic headroom to spare. The core architectural goal — physical simulation time decoupled from CPU compute workload — is demonstrated working, end to end, for SAND + WATER.

**WITH CONDITIONS**, because this remains exactly what §7/§8 of the request called for — an integration PoC, not a production migration — and the following are genuinely unresolved, not merely unfinished:
1. **Scope.** Only SAND + WATER are GPU-simulated. LAVA, the Material Reaction System, mining, activation/sleeping, Background/Foreground, and player collision are all still CPU-only — a production migration needs a plan for the *entire* ruleset, per SIMULATION_TIMESCALE_INVESTIGATION.md's own risk list, not just an extension of this PoC's two materials.
2. **World-size scaling is untested.** The measured 70×+ margin is buffer-size-bound, not activity-bound (see caveat above) — a GPU-side activation/sleeping equivalent (GPU_SIMULATION.md's own "Phase 2E," still not started) would need to exist before this margin could be assumed at a much larger world size than the one tested here.
3. **No production wiring exists.** `GPUSimulationBackend`/`GPUSandPoC` are not reachable from `PixelSimWorld`, `Main.tscn`, or any gameplay code. Deciding how gameplay reads (`get_cell`, mining, building — all currently synchronous CPU calls) would access a potentially GPU-resident world is unresolved and explicitly out of this phase's scope.
4. **Operational risk is real, not hypothetical.** This phase reproduced a process-crashing GPU stability issue live (see [GPU Stability](#gpu-stability)) — bounded and fixed within this PoC's own code, but a concrete reminder that GPU-resident production code needs the same discipline (bounded device lifecycle, no per-call device churn) applied everywhere it appears, not just here.

None of the above are reasons not to proceed eventually — they are exactly the deliberately-scoped-out items SIMULATION_TIMESCALE_INVESTIGATION.md already flagged as belonging to "a substantially larger migration... its own deliberately-scoped milestone." This phase's job was to test the timestep/accumulator/GPU-integration *mechanism* in isolation before committing to that larger milestone, and it passed.

---

## Workload Validation

All numbers below are from live measurement in the running editor (`project/scripts/gpu_solver_tests.gd`, `gpu_timestep_benchmark.gd`, `gpu_simulation_backend.gd`), world size fixed at 3072×1792 cells (the `PixelSimWorld` default 48×28 chunks) for both CPU and GPU paths, so the two are directly comparable — same world, same slab geometry (`GPUTimestepBenchmark.build_slab()`, a direct port of `stress_test.gd`'s own spawn shape), same seed.

### Validation (correctness)

`gpu_solver_tests.gd`'s persisted 12 SAND + 16 WATER scenarios (28 test functions, 40 individual assertions): **40/40 checks passed, 0 failures.** This re-confirms GPU_SIMULATION.md's Phase 2A/2B results against the still-unmodified shader/wrapper, and is now a re-runnable file instead of a one-off script.

### GPU Capacity

Per tier: `GPUSimulationBackend.run_ticks_unpaced(60)` (= 1.0s of physical simulation time, `PHYSICAL_TICKS_PER_SECOND = 60`), timed for real, no readback included in the timing (matches the "GPU compute ≠ GPU + readback" principle — readback only happens afterward, for the mass-conservation sanity check, never inside the timed region):

| SAND cells | Wall time for 1.0s physical | GPU compute (µs) | **`simulation_real_time_ratio`** |
|---:|---:|---:|---:|
| 10,000 | 0.0140 s | 13,995 | **71.4** |
| 50,000 | 0.0131 s | 13,073 | **76.4** |
| 100,000 | 0.0137 s | 13,696 | **72.9** |
| 250,000 | 0.0134 s | 13,385 | **74.6** |
| 500,000 | 0.0142 s | 14,179 | **70.4** |

**Answering the request's core §2/§13 question directly: yes, the GPU sustains real-time physical cadence at every tested tier (10k–500k), with a 70–76× margin, essentially flat regardless of SAND count.** This is not "the GPU happens to be fast enough" so much as a direct, expected consequence of a known, already-documented limitation (GPU_SIMULATION.md "Limitations": no GPU-side activation/sleeping — every dispatch evaluates the *entire* buffer, always). Because dispatch cost here is dominated by **buffer size** (3072×1792 = 5,505,024 cells, fixed for every tier), not by how much of it is SAND, the ratio barely moves across a 50× range of SAND cell counts. This is a genuinely different scaling story from the CPU's chunk-sleeping-driven, activity-scaled cost — see CPU comparison below — and it is the direct, measured answer to why option E (GPU) was identified in SIMULATION_TIMESCALE_INVESTIGATION.md as the only lever that raises the throughput *ceiling* rather than just accounting for a shortfall honestly.

**Compute vs. wall time (No Hidden CPU Bottleneck, §25):** `compute_usec` accounts for 99.7–99.9% of measured wall time at every tier (e.g. 10k: 13,995 µs compute of 14,012 µs wall) — CPU-side orchestration overhead for issuing the batched dispatch is on the order of tens of microseconds, not a meaningful cost next to the GPU work itself.

### CPU vs GPU Comparison

Same tiers, same world/geometry, `PixelSimWorld`/`World::step()` (unmodified), timing 60 `step_simulation(1/60)` calls (the direct CPU analog of "60 GPU ticks" — both are 60 units of their respective per-frame simulation primitive):

| SAND cells | CPU wall time (60 calls) | CPU avg `sim_ms` | GPU wall time (60 ticks) |
|---:|---:|---:|---:|
| 10,000 | 0.0489 s | 0.813 ms | 0.0140 s |
| 50,000 | 0.1573 s | 2.617 ms | 0.0131 s |
| 100,000 | 0.1435 s | 2.387 ms | 0.0137 s |
| 250,000 | 0.2306 s | 3.837 ms | 0.0134 s |
| 500,000 | 0.2283 s | 3.798 ms | 0.0142 s |

**CPU wall time grows 4.7× from 10k to 500k (0.049s → 0.228s), tracking `sim_ms` growth exactly as SIMULATION_TIMESCALE_INVESTIGATION.md's own measurements predicted. GPU wall time stays flat (0.013–0.014s throughout) — a ~3.5× GPU advantage at 10k widening to ~16× at 500k**, purely because CPU cost scales with active cell/chunk count while GPU cost here is buffer-size-bound. This is the empirical confirmation, at the exact tiers the request asked for, of the gap SIMULATION_TIMESCALE_INVESTIGATION.md identified only from the older Phase 2A/2B per-chunk tables.

### Backlog / Accumulator Validation

10k and 500k tiers, driven through `GPUSimulationBackend.advance()` with synthetic per-frame deltas at 30/60/120fps until 1.0s of physical time accumulated (`max_ticks_per_frame = 10`):

| SAND cells | FPS | Frames used | Ticks executed | `max_backlog_ticks_seen` | `avg_backlog_ticks` | design-level real-time ratio |
|---:|---:|---:|---:|---:|---:|---:|
| 10,000 | 30 | 31 | 62 | 0 | 0.000 | 1.0000 |
| 10,000 | 60 | 60 | 60 | 0 | 0.000 | 1.0000 |
| 10,000 | 120 | 120 | 60 | 0 | 0.000 | 1.0000 |
| 500,000 | 30 | 31 | 62 | 0 | 0.000 | 1.0000 |
| 500,000 | 60 | 60 | 60 | 0 | 0.000 | 1.0000 |
| 500,000 | 120 | 120 | 60 | 0 | 0.000 | 1.0000 |

**Backlog never leaves zero, at any tested FPS or tier.** `max_ticks_per_frame = 10` is never the binding constraint here — the GPU's raw throughput margin (70×+, above) is so far beyond what any of these render cadences require that the accumulator's safety cap never engages. This validates the *mechanism* is correct (ticks execute in exact `fixed_dt` increments, the design-level ratio computes to exactly 1.0 in every case) without needing to actually stress it into a backlog state — the [GPU Capacity](#gpu-capacity) numbers already establish that today's SAND/WATER-only PoC has enormous headroom before backlog would ever become observable at these tiers.

*(31 frames / 62 ticks at 30fps, not 30/60, is expected and correct: `1.0/30.0` isn't exactly representable in floating point, so the accumulator's `simulation_time` crosses the 1.0s stop-condition one frame late — see FPS Independence below for why this is a test-boundary artifact, not a determinism defect.)*

### GPU Capacity vs. §13's Example

The request's §13 gave `500k → 0.98` as a "very good" hypothetical and `500k → 0.35` as a "document the limit" hypothetical. **Measured: `500k → 70.4`.** The PoC is nowhere near its real-time ceiling at any tested tier — the actual constraint this document can identify is *not* "how much SAND/WATER," it's the fixed per-dispatch cost of evaluating the whole world buffer regardless of activity (see GPU Capacity above) — a different axis than the one §13 anticipated stressing, worth naming explicitly rather than reporting a misleadingly comfortable number without the caveat.

### FPS Independence

100k tier, three runs (30/60/120fps), `GPUTimestepBenchmark.measure_fps_independence()`:

- **Stopping by wall-time crossing (`simulation_time < 1.0`)**: 60fps and 120fps reached exactly 60 ticks and produced **byte-identical** final GPU states. 30fps reached 62 ticks (not 60) due to the same floating-point boundary drift noted above, and its final state differs from the other two **because it simulated 2 extra ticks of real physical progress**, not because of any per-tick nondeterminism.
- **Stopping by exact tick count (60 ticks, all three FPS)**: re-run directly comparing state after exactly 60 ticks regardless of FPS — **all three FPS byte-identical.**

**Conclusion: the tick sequence itself is fully deterministic and FPS-independent** — same seed, same monotonic `tick_counter`, same result, regardless of render cadence. The wall-time-crossing discrepancy at 30fps is an artifact of comparing "state after crossing an arbitrary 1.0-second threshold" (sensitive to which side of the threshold a frame's floating-point accumulator contribution lands on) rather than "state after N ticks" (not sensitive to this at all) — a test-methodology detail worth documenting precisely, not a flaw in the accumulator or the GPU solver.

### GPU Stability

500 consecutive ticks per tier (one batched dispatch each), each tier in its own isolated script invocation, mass-conservation checked after:

| SAND cells | Wall time (500 ticks) | Final SAND count | Errors |
|---:|---:|---:|---:|
| 10,000 | 0.108 s | 10,000 (conserved) | none |
| 100,000 | 0.113 s | 100,000 (conserved) | none |
| 500,000 | 0.128 s | 500,000 (conserved) | none |

No device loss, no validation errors, no dispatch failures, across 1,500 total consecutive ticks spanning three isolated runs.

**A real, distinct stability finding from earlier in this phase, not from the tiers above:** the first version of `gpu_solver_tests.gd` gave every one of its 28 tests its own fresh `GPUSandPoC` (its own `RenderingDevice` + shader compile), all created back-to-back in one script invocation — this **reliably crashed the running Godot process** (`--- Debugging process stopped ---` in the editor log) partway through, after roughly 27 rapid device/shader creations. This refines Phase 2B's original "device lost" note (GPU_SIMULATION.md, which attributed it to "many dispatches back-to-back in one call"): **Phase 2C's reproduction points specifically at rapid repeated `RenderingDevice` creation and shader compilation, not dispatch/tick volume** — the fix (share one backend across a whole test/benchmark run, `_reset_grid()`/`reset_grid()` to re-point it at a fresh grid instead of recreating the device) made both the 28-test correctness suite and the 1,500-tick stability run above complete without incident. **Recommendation for any future GPU test/benchmark code: create a `RenderingDevice` once per script session, never once per test case.**

*(Minor, unrelated tooling note: mid-session, Godot's editor cached a stale "Parse Error" against `gpu_timestep_benchmark.gd` from an early, since-fixed syntax mistake, and kept reporting it via `get_editor_errors`/the global `class_name` symbol even after the file was corrected and `reload_project` was called. Explicitly `load()`-ing the script and calling `.reload()` confirmed it was actually valid (error code 0); switching call sites from the bare global class name to `load(...).new()` worked around the stale cache. Not a code defect, worth knowing if a future session hits the same symptom.)*

---

---

## CPU Fixed Timestep (Production)

**Status: CURRENT / IMPLEMENTED.** A later, separately-scoped fix (stress-test FPS-independence investigation) — **not** the "future production wiring of this [GPU] PoC" flagged as out-of-scope below (see [How Future Work Should Use This Document](#how-future-work-should-use-this-document) point 3). This section applies the *same fixed-timestep-accumulator pattern* documented above to the **CPU reference path** instead of the GPU PoC — the GPU backend's own production-wiring status is completely unchanged by this work (still not wired into `Main.tscn`/`main.gd`/any gameplay path).

### RENDER FPS ≠ PHYSICS SPEED

**ARCHITECTURAL INVARIANT**, now enforced on the actual gameplay path, not just the GPU PoC: physical simulation speed must never depend on render frame rate. Concretely: `main.gd`'s `_process(delta)` used to call `sim_world.step_simulation(delta)` **once per render frame, unconditionally** — and since `step_simulation()` → `World::step()` is itself a real-wall-clock-time-budgeted call (`simulation_budget_ms`, bounded by `std::chrono::steady_clock`, not simulated time), calling it more often (higher render FPS) meant strictly more real CPU scanning time — and therefore more physical progress — happened per real second. This was the exact bug [Current CPU Model](#current-cpu-model) above already diagnosed for the GPU PoC's own motivation, but it had never been fixed on the CPU path itself, since Phase 2C's accumulator was deliberately scoped to the GPU PoC only (see [Architectural Invariants](#architectural-invariants) below). It was reconfirmed directly and empirically during the stress-test benchmark work: the 10k tier's time-to-settle dropped from 3.10s at ~240 FPS (V-Sync capped) to 1.39s uncapped (~337 FPS avg) with **zero simulation code changed** — proof render FPS, not physics, was setting the pace (see PERFORMANCE_SCALABILITY.md "Stress Test Benchmark Mode").

### The fix — `CPUSimulationBackend`

`project/scripts/cpu_simulation_backend.gd` — a new, standalone `RefCounted` class, structurally identical to `GPUSimulationBackend`'s own accumulator loop (same shape as the pseudocode in [Accumulator](#accumulator) above), but gating calls to the **unmodified, existing** `PixelSimWorld.step_simulation()` instead of `GPUSandPoC.step()`. Zero C++ files touched — `World::step()`/`PixelSimWorld` are byte-for-byte unchanged; the fix lives entirely in a new GDScript orchestration layer, exactly the same non-invasive pattern Phase 2C already established for the GPU side.

```
accumulator += real_delta
ticks_this_frame = 0
while accumulator >= fixed_dt and ticks_this_frame < max_ticks_per_frame:
    sim_world.step_simulation(fixed_dt)   # unmodified PixelSimWorld call
    accumulator -= fixed_dt
    ticks_this_frame += 1
    tick_count += 1
    simulation_time += fixed_dt
backlog_ticks = floor(accumulator / fixed_dt)
```

**Fixed timestep used: `fixed_dt = 1/60 s`** — reused directly from `GPUSimulationBackend.DEFAULT_FIXED_DT` (this document's own [Fixed Timestep](#fixed-timestep) section above), not reinvented. **`max_ticks_per_frame = 10`** — same backlog-cap convention as the GPU backend.

`main.gd`'s `_ready()` now constructs `cpu_backend = CPUSimulationBackend.new(sim_world)`, and `_process(delta)` calls `cpu_backend.advance(delta)` instead of `sim_world.step_simulation(delta)` directly. `stress_test.gd` reads `main.cpu_backend`'s own counters (`tick_count`, `simulation_time`, `passes_completed`, `backlog_ticks`) rather than resampling `sim_world.get_stats()` every render frame for edge-triggered events — necessary because, post-fix, `step_simulation()` no longer fires every frame (only when the accumulator has a full `fixed_dt` available), so a naive per-frame `stats.get("pass_completed")` read would double-count a still-`true` flag on frames where no new tick actually ran.

### Interaction with `simulation_budget_ms`

**Unchanged, and still doing exactly what it always did — bounding real CPU time per `step_simulation()` call, nothing more.** The two settings compose, not conflict:
- The accumulator decides **how often** `step_simulation()` is called — now capped at ~60 calls/sec regardless of render FPS (previously: once per frame, i.e. render-FPS calls/sec).
- `simulation_budget_ms` (4.0 ms, unchanged) still decides **how much a single call may do** before yielding — `World::step()`'s resumable row-scan/budget/`resume_y_` behavior is completely untouched.

Worst-case CPU time spent on simulation is now bounded at **~60 × 4 ms = 240 ms of real time per real second**, regardless of render FPS — previously this scaled linearly with render FPS with no ceiling (500 FPS could reach ~2000 ms/s of budgeted scanning, i.e. simulation could consume essentially the entire frame budget). This is the concrete mechanism behind the fix, not just its intent.

### Determinism

PROJECT_ARCHITECTURE.md §7 already documented, as a design expectation, that `simulation_budget_ms` "changes how many rows get processed per `step()` call, but not the order or outcome of any given row" — i.e. slicing the same cumulative work across more-or-fewer, larger-or-smaller calls shouldn't change what the simulation computes, only how many real-time call boundaries it's spread across. That document flagged this as **not formally tested**. It now has been — see [FPS Independence](#fps-independence-cpu) below.

### FPS Independence (CPU) {#fps-independence-cpu}

`project/scripts/cpu_fps_independence_test.gd` — a standalone validation harness (mirrors `gpu_timestep_benchmark.gd`'s own `measure_fps_independence()`, applied to the CPU path). Builds an identical small world + seed + SAND scenario, drives it through `CPUSimulationBackend` at four **controlled, synthetic** render cadences (constant `delta = 1/cadence` per call — deliberately never tied to this machine's actual display refresh rate, per the request's explicit instruction), and compares tick count and full-grid physical state at matching physical simulation time (1.0s and 2.0s checkpoints).

**Measured result:**

| Render FPS (synthetic) | Physics ticks/sec | Physical state @ 1s | Physical state @ 2s |
|---:|---:|---|---|
| 60 | 60 | IDENTICAL to base | IDENTICAL to base |
| 120 | 60 | IDENTICAL to base | IDENTICAL to base |
| 240 | 60 | IDENTICAL to base | IDENTICAL to base |
| 500 | 60 | IDENTICAL to base | IDENTICAL to base |

All four cadences produced **exactly 60 ticks/sec** and **byte-exact identical full-grid state** at both checkpoints (`PackedInt32Array ==` over every cell, all 4 cadences vs. the 60 FPS baseline) — a stronger result than the conservative fallback the request explicitly allowed for ("if exact equality isn't guaranteed by the architecture, measure physical invariants instead"). SAND mass was also confirmed conserved identically across all four runs. This directly confirms PROJECT_ARCHITECTURE.md §7's determinism claim for this specific scenario: the CPU reference path's outcome depends only on cumulative tick count, never on how those ticks were distributed across render frames.

**Live-gameplay confirmation** (not just the isolated harness above): running the actual `Main` scene and sampling `main.cpu_backend.tick_count`/`simulation_time` across a controlled real-time interval showed the tick rate tracking genuine elapsed wall-clock time at exactly ~60 ticks/sec with `backlog_ticks == 0` throughout, including through mining and SAND-drop interactions — see PERFORMANCE_SCALABILITY.md's stress-test results for the full 10k–500k re-measurement under this architecture.

### What changed for existing stress-test numbers

Every "Time to settle" number recorded before this fix (all of PERFORMANCE_SCALABILITY.md's stress-test tables prior to this section) was measured under the render-FPS-coupled bug — meaning uncapping V-Sync/FPS in the immediately preceding milestone made the *benchmark* more accurate at exposing the render/frame ceiling, but also made the underlying *physics* run measurably faster in wall-clock terms than its true, correctly-paced rate (since more real FPS meant more `step_simulation()` calls meant more real progress per second). Post-fix, wall-clock "Time to settle" and physical "simulation time" converge to the same number (`backlog_ticks` stayed at 0 for every tier in the re-measurement — the accumulator never needed to catch up), and both are now properly decoupled from however fast this machine can render. See PERFORMANCE_SCALABILITY.md "Stress Test — Fixed-Timestep Physics" for the re-measured table.

---

## Stress-Test Instrumentation Trustworthiness (Frame-Time / Stutter / Per-Tick Timing)

**Status: CURRENT / IMPLEMENTED. Instrumentation only — no new 10k-500k benchmark numbers were produced by this section; see the closing note below.**

### The report that triggered this section

The fixed-timestep fix above (previous section) reported avg FPS of ~2100 at the 10k tier down to ~1127 at the 500k tier — read superficially, an excellent result. Manually playing the 500k tier, however, visibly and repeatedly stutters. **A benchmark number that contradicts direct human observation cannot be trusted as-is** — this section exists to find out *why* the two disagreed, not to argue the FPS number was "basically fine."

### Root cause: two separate measurement gaps, not a physics bug

Neither gap is in `CPUSimulationBackend`'s accumulator itself (that mechanism's own correctness - fixed `fixed_dt`, `backlog_ticks == 0` throughout, byte-exact FPS-independence - is unaffected and re-confirmed below). Both are in what the *stress-test harness* sampled and reported:

1. **`Engine.get_frames_per_second()` is itself a smoothed, rolling-average counter** (Godot's own internal ~1-second smoothing window). `stress_test.gd`'s old code sampled this already-smoothed value once per render frame and then averaged *those samples* - smoothing an average of an average. A handful of genuine multi-frame stalls can sit inside that internal smoothing window without ever moving the reported number much, while still being fully visible to a human as a stutter. This is a measurement-methodology gap, not a claim that the counter itself is "wrong" for what it's designed to do (a rough on-screen FPS readout).
2. **`sim_ms` was resampled every render frame from `PixelSimWorld.get_stats()`**, a value that only changes when `step_simulation()` actually runs. Once render FPS decouples from the ~60 tick/s physics rate (exactly what the previous section's fix achieves), most render frames execute **zero** simulation ticks - on those frames, the old per-frame sample just reread the previous tick's stale cached `sim_ms`, which stopped being a meaningful per-frame (or per-tick) cost signal the moment the two rates diverged this far apart (1000+ FPS vs. 60 ticks/sec).

### The fix

**Per-tick wall-clock timing, not per-frame stats resampling.** `CPUSimulationBackend.advance()` now times each `step_simulation()` call directly with `Time.get_ticks_usec()`, immediately around the call - a sample always corresponds to a tick that actually ran. `last_advance_tick_usec`/`last_advance_ticks` (this frame's own tick timing) are always maintained, at negligible cost (a couple of `Time.get_ticks_usec()` calls per tick, no array growth); the full per-tick history needed for percentiles (`tick_duration_samples`) is gated behind `record_tick_samples` (default `false` - zero cost/growth in ordinary, non-benchmark gameplay), which `stress_test.gd` turns on only for the duration of a measured tier and off again once the tier's report is generated.

**Frame time derived from raw `delta`, not the smoothed engine counter.** `stress_test.gd` no longer calls `Engine.get_frames_per_second()` at all during measurement. Each frame's own `delta` is the source of truth for both frame-time-in-ms and an instantaneous `fps = 1.0 / delta` sample. The report's primary render-performance signal is now the **frame-time distribution** (average, median, p95, p99, max) plus explicit **stutter-frame counts** - frames slower than 16.67ms / 33.33ms / 50ms (60/30/20fps-equivalent thresholds) - not a single average. Average FPS/frame-time are still reported (useful, familiar numbers), but are explicitly documented as secondary to the distribution, per the same principle PERFORMANCE_SCALABILITY.md's "Stress Test Benchmark Mode" section already established for V-Sync-capped averages hiding a real ceiling - a smoothed or averaged number can hide exactly the thing a stutter *is*.

**Frame-vs-simulation split.** Because `last_advance_tick_usec` is available to any caller running after `Main._process()` in the same frame (`stress_test.gd`'s `_process()` does, since `StressTest` is a child of `Main`), the report can show "how much of an average frame's cost was simulation" (`avg frame-sim-time`) vs. everything else (`avg frame remainder`) - letting a stutter be attributed to "simulation-bound" or "something else" (rendering, engine/editor overhead) instead of guessed at.

**Zero simulation/gameplay/timestep code changed.** This is purely a measurement/reporting layer added on top of the unmodified accumulator from the previous section - `fixed_dt`, `max_ticks_per_frame`, gravity, the SAND solver, `simulation_budget_ms`, and `World::step()` are all byte-for-byte identical to before this section.

### Regression check

`CPUFPSIndependenceTest.run()` (`project/scripts/cpu_fps_independence_test.gd`) was re-run live, after the above instrumentation was added, exactly as in [FPS Independence (CPU)](#fps-independence-cpu) above: still **byte-exact identical grid state** across 60/120/240/500 synthetic render cadences, still exactly 60 ticks/sec at every cadence, SAND mass still conserved identically across all four runs. This confirms the new per-tick timing calls add no observable side effect to the accumulator they instrument. This is a correctness/determinism check, not a stress-tier benchmark - no 10k-500k tier was run to produce this confirmation.

### What this section does not answer yet

**Why the specific reported ~1127 avg FPS at 500k coexisted with visible stutter** - the actual frame-time distribution, stutter-frame counts, and simulation-tick timing for the 10k-500k tiers, measured with this new instrumentation. That requires running the harness, which per the request that scoped this section is a **human-run, human-observed** pass (Shift+1..5, one fresh scene per tier - see PERFORMANCE_SCALABILITY.md "How to Run the Stress Test Manually"), not something generated automatically here. This document and PERFORMANCE_SCALABILITY.md will be updated with the real measured numbers once that pass is reported back - until then, no 10k-500k table exists for this instrumentation, by design, not by oversight.

---

## GPU Production Wiring

**Status: WIRING/CORRECTNESS IMPLEMENTED AND VERIFIED — PERFORMANCE REGRESSION IDENTIFIED, ROOT-CAUSED, NOT YET FIXED.** Do not read this as a GO on production performance — see [Regression Investigation](#regression-investigation--root-cause-analysis) below for the full findings before drawing any performance conclusion from this section. The GPU PoC is now reachable from `Main.tscn`/`main.gd`, superseding this document's earlier "not wired into any production path" framing for the SAND+WATER movement question specifically — see [Prohibited This Phase](#prohibited-this-phase) above (Phase 2C's own scope boundary) for what this milestone deliberately did *not* extend to.

**What "wired in" means here, precisely:** `GPUSimulationBackend`/`GPUSandPoC` now compute where every SAND and WATER cell moves each physics tick, for the real, live game world. Everything else — the Material Reaction System, GRAVEL/LAVA movement, mining, building, player collision, and rendering — stays 100% CPU/`PixelSimWorld`, byte-for-byte unmodified in behavior. `PixelSimWorld` (CPU `World`) remains the single, authoritative source of truth every downstream system reads; GPU only decides *who moves* SAND/WATER, writing its result back through the same `set_cell()` path movement already used.

**New class: `GPUProductionBridge`** (`project/scripts/gpu_production_bridge.gd`) — the orchestration layer. Full per-frame contract, the ordering rule, and the CPU↔GPU material-id translation table are documented in its own class doc comment; not repeated here. `main.gd` calls `gpu_bridge.advance(delta)` **before** `cpu_backend.advance(delta)` every frame — this ordering is load-bearing (CPU's reaction pass must see this frame's fresh GPU-computed positions, never a stale one) and is called out explicitly in both files' doc comments.

**New CPU (C++) API, all additive** (`core/world.h/.cpp`, `sim_world_node.h/.cpp`):
- `World::set_movement_externally_owned(MaterialType, bool)` / `is_movement_externally_owned(...)` — a per-material gate at the single existing movement-dispatch site (`world.cpp`'s `if (!reacted) { solve_powder/solve_liquid }` → `if (!reacted && !externally_owned_movement_[mat])`). Defaults `false` for every material — zero behavior change unless a caller opts a material in. Reactions are **not** gated — only the movement dispatch — confirmed by a dedicated test (see Verification below).
- `World::get_materials_rect`/`set_materials_rect` — bulk raw-material-id rect I/O, exposed to GDScript as `PixelSimWorld.get_materials_rect`/`set_materials_rect` (`PackedByteArray`, one byte/cell — distinct from `get_chunk_pixels*`'s RGBA8 rendering bytes). The write path reuses `set_cell()` for every cell that actually differs from its current value, so it inherits all existing wake/dirty/render/neighbor-activation bookkeeping for free, and a true no-op write costs one comparison per cell, no wake/dirty churn.

**GPU-side additions, zero shader changes:**
- `gpu_sand_poc.gd`: `MAT_DIRT`/`MAT_IRON_ORE`/`MAT_COPPER_ORE`/`MAT_WOOD`/`MAT_METAL`/`MAT_GRAVEL`/`MAT_MUD`/`MAT_LAVA` (ids 6-13) — the remaining CPU materials, given GPU ids purely so SAND/WATER see correct obstacles. Confirmed via direct code read of `gpu_cellular_solver.glsl`'s `is_movable()`/`can_displace()`: any material id not specifically special-cased there is automatically treated as an immovable, non-displaceable obstacle — the shader itself needed no changes.
- `gpu_sand_poc.gd`: `write_rect`/`read_rect` — partial buffer I/O into the *existing* (not newly-allocated) buffer, for a sub-rectangle. One `RenderingDevice.buffer_update`/`buffer_get_data` call per row (each row is one contiguous span in the flat row-major buffer).
- `gpu_simulation_backend.gd`: `advance_active_region(real_delta)` — same fixed-timestep accumulator shape as the existing `advance()`, but drives `run_ticks_active_region()` (Phase 2D, bounded-region dispatch) instead of `gpu.step()` (full-world). Reuses the same accumulator/backlog fields, purely additive.

**Deliberately NOT enabled: GPU-owned reactions.** The GPU reaction rule table is never configured by this bridge (stays at its default identity/no-op table) — if it were, a GPU-synced LAVA cell next to a GPU-computed WATER cell could have its WATER+LAVA→STONE reaction independently computed by *both* GPU (which dispatches a compute thread over every cell in the region, not just SAND/WATER, and already runs a reaction check on each) and CPU (whose `try_react()` is unconditional, never gated). Leaving the table at identity avoids this dual-computation hazard entirely — the Material Reaction System stays exactly where it already was validated: 100% CPU.

**Also deliberately not extended to GPU:** GRAVEL/LAVA movement — would need real shader edits (`is_powder`/`is_liquid`/`density_of` additions for those two materials) and a wider regression surface; not needed to prove the SAND+WATER integration works, so not attempted in this milestone.

### Verification

- Standalone C++ suite (`tests/test_core.cpp`): **16,734/16,734 checks passed** (16,700 prior + 34 new, all green) — new tests cover `get_materials_rect`/`set_materials_rect` round-tripping, a no-op write causing zero wake/dirty churn, the movement gate suppressing `solve_powder`/`solve_liquid` for a gated material, and — the one that actually matters most — the gate **not** suppressing reactions for that same material (a live WATER+LAVA→STONE check with WATER's movement gated on).
- GPU correctness suite (`gpu_solver_tests.gd`): **40/40 checks passed**, unaffected (zero shader changes this milestone).
- `CPUFPSIndependenceTest`: still byte-exact identical across 60/120/240/500 synthetic render cadences — this bridge doesn't touch that code path at all (a different `World` instance, gate never enabled there).
- **Live, in-editor functional checks against the real `Main.tscn` scene** (not a synthetic test world): mining a real DIRT patch dropped 31 SAND cells (drop_ratio 0.5 of 62 removed, exact), which then genuinely fell under GPU control (settled 6 rows below the mine point) with mass conserved exactly; a second simultaneous mining action (59 removed → 29 dropped) settled correctly alongside the first, total SAND conserved exactly (60/60); a WATER+DIRT→MUD reaction fired correctly through the unmodified CPU reaction system using GPU-synced WATER positions (12/12 WATER cells converted); the GPU active region correctly woke on mining and went back to sleep once both piles settled (`region_active: false`, `backlog: 0` throughout, `cpu_active_chunks: 0` at rest); rendering showed both settled piles with no stale/duplicate pixels.
- **Not evaluated by this milestone: performance.** This work is about correctness/wiring, not speed — no stress-test/benchmark numbers were generated or claimed here, consistent with this document's own [Stress-Test Instrumentation Trustworthiness](#stress-test-instrumentation-trustworthiness-frame-time--stutter--per-tick-timing) precedent (avg-FPS-only claims are exactly what that section warned against trusting). Whether this changes real gameplay performance — and whether the active-region re-upload/download cost (already flagged as workload-shape-sensitive in GPU_ACTIVE_REGION.md) matters in practice — was flagged as an open question. **It has since been answered — see below.**

---

## Regression Investigation — Root Cause Analysis

**Trigger:** after the wiring above shipped, manual gameplay testing reported the whole game's performance got measurably worse, *and* SAND still didn't visibly fall faster than before. This section is instrumentation + measurement + analysis only — **no gravity, fixed timestep, solver, or `simulation_budget_ms` changes were made while investigating this**, per explicit instruction. Nothing below has been fixed yet.

### Primary question: why did overall performance get worse?

**Not the compute shader.** Measured GPU compute+sync cost (`GPUSandPoC.last_compute_usec`, i.e. `submit()`+`sync()` wall time) averaged **~1.5-1.9 ms per dispatch** — consistent with Phase 2C's own 70×+ real-time-margin finding above. GPU compute is roughly 3-4% of the actual per-dispatch cost. The other ~96% is the CPU-side orchestration surrounding it.

**The dominant cost is `GPUSandPoC.read_rect()`'s per-row `RenderingDevice.buffer_get_data()` loop.** `write_rect()`/`read_rect()` do one RD API call *per row* of the dispatched rectangle (each row is one contiguous span in the flat row-major GPU buffer — see their own doc comments in `gpu_sand_poc.gd`). For the active regions actually observed in live gameplay (see below, ~320-384 cells per side, i.e. 320-384 rows), that's 320-384 individual `buffer_get_data()` calls **every single dispatched frame**. Measured: **~35-38 ms** average, ~81% of total per-dispatch cost, vs. `write_rect()`'s much cheaper ~0.2 ms for the same row count (~0.6 µs/row) — `buffer_update()` can apparently just queue into the command stream, while `buffer_get_data()` appears to force some form of per-call synchronization/flush on this local `RenderingDevice`. This was not assumed - it's the single largest number in every sample taken.

**Compounding cause: the active region is far larger than the actual activity.** `GPUProductionBridge.wake_region()` → `GPUSimulationBackend.wake_region()`/`_align_region()`/`_margin_chunks_for()` sizes the safety margin off `GPUSimulationBackend.DEFAULT_MAX_TICKS_PER_FRAME` (10) **unconditionally**, regardless of how small the triggering event actually is: `margin_chunks_for(10) = ceil(10/64)+1 = 2` chunks of padding on every side, chunk-aligned (64-cell chunks) — so even a tiny, localized mining action (radius 8-18 cells) produces a minimum active region on the order of **320×320 to 384×320 cells (~102,000-123,000 cells)**, live-measured, for a drop of only 53-193 actual SAND cells. That's the exact "active chunks are few but the whole buffer moves" pattern this investigation was asked to check for (see [GPU Buffer / Active Region](#active-region-and-buffer-io-live-measurements) below) - confirmed. This inflates steps 1/2's already-expensive per-row I/O by roughly 12-25× more rows than the actual affected area would need.

**Total measured cost per dispatched frame: ~47-54 ms** (`GPUProductionBridge.get_stage_metrics()`'s `avg_advance_total_usec`, stable across repeated live measurements) — **2.8-3.2× a full 60fps frame budget (16.67 ms), in ONE synchronous, main-thread-blocking call**, since `gpu_bridge.advance()` runs directly inside `main.gd`'s `_process()`, before rendering. This is not a subtle regression; it is a direct, measured, per-mining-event stall.

**Crucially — this is exactly the "average hides the spike" trap the CPU stress-test instrumentation work already warned about, now proven to apply here too:** across a whole live session (21,040 total `advance()` calls, only 14 of them dispatched), the *session-wide* average cost was a reassuring-looking **~39-62 µs/frame** (`avg_advance_usec_all_frames`) — because the other 21,026 idle frames cost ~6-12 µs each. Only sampling the 14 dispatched frames specifically reveals the real ~47-54 ms spikes. An FPS counter or a naive average would completely hide this.

### Production path trace (what's CPU vs. GPU, blocking vs. not)

```
main.gd._process(delta)
  gpu_bridge.advance(delta)                     [CPU, GDScript, main thread]
    if will_tick and region active:
      sim_world.get_materials_rect(region)       CPU, C++ (loop, cheap)
      translate CPU ids -> GPU ids               CPU, GDScript loop over region_cells  <- ~3.3-3.6ms
      backend.gpu.write_rect(region, ...)         GPU, N=region_h buffer_update() calls  <- ~0.2ms (cheap)
    backend.advance_active_region(delta)
      run_ticks_active_region(ticks)
        gpu.step_region(...)                      GPU: dispatch + submit() + sync()      <- ~1.5-1.9ms (BLOCKS until GPU done)
        gpu.read_bounds()                         GPU: one 16-byte buffer_get_data() (cheap, not the region readback)
    if dispatched:
      backend.gpu.read_rect(region)               GPU, N=region_h buffer_get_data() calls <- ~35-38ms (DOMINANT COST, BLOCKS per call)
      translate GPU ids -> CPU ids                 CPU, GDScript loop over region_cells   <- ~3.0-3.4ms
      sim_world.set_materials_rect(region, ...)     CPU, C++ (per-cell get_material+set_cell) <- ~0.5ms
  cpu_backend.advance(delta)                      [CPU, unaffected by any of the above - reactions/GRAVEL/LAVA/etc.]
rendering (chunk_renderer.gd)                     [CPU, unaffected - unchanged from before this milestone]
```

Every stage marked "BLOCKS" runs synchronously on the main thread before the frame can proceed to rendering — there is no async/deferred readback anywhere in this pipeline. No duplicate dispatch exists (`step_region()` is called exactly once per tick-batch, handling every material in the region in one pass — confirmed by code trace, not just assumed). No buffer/pipeline/shader (re)allocation happens in this hot path — `setup_grid()`/shader compile run exactly once, in `GPUProductionBridge._init()`, confirmed by code trace.

### Active region and buffer I/O (live measurements)

| Event | DIRT removed | SAND dropped | Active region | Region cells | Dispatched frames to settle |
|---|---:|---:|---|---:|---:|
| Mining #1 (radius 8) | 106 | 53 | 384×320 | 122,880 | 5 |
| Mining #2 (radius 16) | 387 | ~193 | 320×320 | 102,400 | 14 |

For comparison, the CPU chunk-sleep model (unaffected, still active for every other material) would only mark the 1-2 actual 64×64 chunks touched by a mining action of this size as active — on the order of 4,096-8,192 cells, not 100,000+. The GPU active region here is roughly **12-25× larger than the area actually doing anything**, entirely a byproduct of the fixed `margin_chunks_for(DEFAULT_MAX_TICKS_PER_FRAME)` sizing, not of the SAND/WATER activity itself.

### CPU double-work: checked, not just assumed

New instrumentation (`StepStats::movement_gated_skips`, exposed via `PixelSimWorld.get_stats()["movement_gated_skips"]`) counts cells where `World::step()` reached the movement-dispatch site for a SAND/WATER cell and skipped it because `externally_owned_movement_` is set — proof the CPU-side gate is structurally engaged, not just present in code. A dedicated C++ test (`test_movement_gated_skips_counts_only_gated_movable_cells`) confirms the counter fires exactly once per gated movable cell touched, `cells_moved` stays 0 for those cells, and reactions remain unaffected. Live `get_stats()` sampling during settled/idle windows correctly showed `movement_gated_skips: 0` (nothing to skip when nothing's active) — consistent, not contradictory; the counter is proven correct at the unit level and structurally guaranteed live (the gate is a hard `if` branch — a gated material's movement dispatch code path cannot execute at all, not "usually doesn't"). **CPU double-work is ruled out as a contributing cause.**

### The two problems, kept separate as instructed

1. **"Overall game performance got worse."** Root-caused above: the ~47-54 ms per-dispatch stall from `read_rect()`'s per-row readback, amplified by an oversized active region. This is a **performance/architecture problem**, not a physics problem.
2. **"SAND still doesn't fall as fast as expected."** Measured separately: mining event #2 (~193 SAND cells) took 14 dispatched ticks to fully settle — at `fixed_dt = 1/60s`, that's **~0.23s of physical simulation time**, which is fast and unremarkable; physics ticks-to-settle is **not** abnormal, so this is **not** a physics-timescale/solver problem (gravity, `fixed_dt`, and the solvers were not touched or suspected further, per instruction). What *is* abnormal: **wall-clock** time to settle those same 14 ticks was 14 × ~47-54ms ≈ **0.66-0.76 seconds of real time** — roughly 3× the physical simulation time — because each tick's *real-world* duration is inflated by the I/O overhead above, even though the simulated `fixed_dt` per tick is unchanged. **The "slow-falling SAND" perception and the "worse overall performance" finding are the same root cause, not two separate problems** — every tick is real-time-expensive, so both physical settling *feels* slow (stretched across visible stutters) and every other frame in the game gets stalled behind it.

### Root cause ranking

| Priority | Finding | Evidence |
|---|---|---|
| **P0** | `GPUSandPoC.read_rect()`'s per-row `buffer_get_data()` loop is the dominant cost (~35-38ms/dispatch, ~81% of total) — one blocking RD call per region row instead of one bulk call for the whole rect | Directly measured, stable across repeated samples |
| **P0** | The entire `gpu_bridge.advance()` pipeline is synchronous/main-thread-blocking, called directly from `_process()` before rendering — ~47-54ms per dispatched frame, 2.8-3.2× a 60fps frame budget, in one call | Directly measured; code trace confirms no async/deferred path exists |
| **P1** | `wake_region()`'s margin sizing (`margin_chunks_for(DEFAULT_MAX_TICKS_PER_FRAME=10)`) inflates the minimum active region to ~320-384 cells/side regardless of the triggering event's actual size - multiplies P0's already-expensive per-row cost by ~12-25× more rows than the actual activity needs | Live-measured region sizes (102,400-122,880 cells) vs. estimated actual-activity size (a few thousand cells) |
| **P1** | GDScript-level CPU↔GPU material-id translation (`_translate_cpu_to_gpu`/`_translate_gpu_to_cpu`) costs ~3.0-3.6ms each way, proportional to the (inflated) region size | Directly measured |
| **P2** | `PixelSimWorld::set_materials_rect()`'s C++ writeback touches every cell of the (inflated) region to check for changes, even though only actually-changed cells get `set_cell()`'d | Directly measured (~0.5ms) - small on its own, but also inherits the P1 region-size inflation |
| **P3** | GPU compute itself (`step_region()`'s dispatch+sync) — genuinely fast, ~1.5-1.9ms, ~3-4% of total cost. Not a meaningful contributor. | Directly measured; consistent with Phase 2C's own 70×+ real-time-margin benchmark |

**Ruled out, not just assumed:** CPU double-moving GPU-owned materials (see above); duplicate/repeated dispatch per tick; runtime buffer/pipeline/shader (re)allocation in the hot path; the fixed-timestep/tick-rate itself (physics ticks-to-settle measured normal).

### New instrumentation added by this investigation

- `GPUProductionBridge`: per-stage timing (`last_upload_translate_usec`, `last_upload_write_usec`, `last_dispatch_usec`, `last_download_read_usec`, `last_download_translate_usec`, `last_cpu_writeback_usec`, `last_advance_total_usec`, plus cumulative/average variants and `get_stage_metrics()`) - zero behavior change, timing calls bracketing the existing pipeline only.
- `World`/`PixelSimWorld`: `StepStats::movement_gated_skips`, exposed via `get_stats()["movement_gated_skips"]`.

### What this investigation did NOT do

No fix was applied. Gravity, fixed timestep, the SAND/WATER solvers, `simulation_budget_ms`, and the Material Reaction System rules are all byte-for-byte unchanged. The obvious next steps this analysis points toward (a bulk rect read/write RD API instead of per-row calls; sizing `wake_region()`'s margin off the actual triggering event instead of a fixed worst-case constant) are **not implemented here** - they're implied by the P0/P1 findings above, not decided or attempted. The final 10k-500k manual gameplay validation remains the user's own, to be run after reviewing these findings.

---

## Architectural Invariants

- `fixed_dt`/`PHYSICAL_TICKS_PER_SECOND`/accumulator logic for the **GPU** PoC lives entirely in `GPUSimulationBackend` — it never touches `gpu_sand_poc.gd`, `gpu_cellular_solver.glsl`, `World`, `PixelSimWorld`, or any CPU solver. (The analogous **CPU** accumulator, `CPUSimulationBackend` - see [CPU Fixed Timestep (Production)](#cpu-fixed-timestep-production) - is a separate class with the same pattern, added in a later milestone; the two are independent, non-overlapping wrappers around their respective backends.)
- `GPUSimulationBackend` is still not wired into `Main.tscn`/`main.gd`/any production path — same experimental status as `GPUSandPoC` itself (PROJECT_ARCHITECTURE.md's "GPU PoC is EXPERIMENTAL, CPU stays PRODUCTION/REFERENCE" framing is unchanged by this phase). `CPUSimulationBackend` **is** wired into production (`main.gd`) - it wraps the CPU reference solver, not the GPU PoC, so this does not contradict the "GPU stays experimental" invariant.
- `max_ticks_per_frame` is a hard cap, never bypassed — backlog is the honest overflow valve, not a larger cap.
- No readback inside the accumulator's per-frame tick-execution path — readback is a separate, separately-measured, on-demand operation.
- Scope stays SAND + WATER only, matching what the GPU shader already implements — no LAVA, no Material Reaction System, no GPU activation/sleeping, no GPU-native rendering (see [Prohibited This Phase](#prohibited-this-phase)).

## Prohibited This Phase

Per the request's explicit scope boundaries — none of the following are touched by Phase 2C:
- CPU reference solvers, SAND/WATER CPU behavior, the 64×64 chunk architecture, Background/Foreground, player collision, mining, activation, sleeping, the Material Reaction System — all unmodified.
- No LAVA GPU migration, no Material Reaction GPU migration, no GPU activation/sleeping migration, no GPU-native renderer.
- No deletion of the CPU backend; no change to CPU solver behavior; no raising of `simulation_budget_ms` to flatter a benchmark number.

## How Future Work Should Use This Document

1. Read this document, GPU_SIMULATION.md, PERFORMANCE_SCALABILITY.md, and SIMULATION_TIMESCALE_INVESTIGATION.md before touching the GPU PoC, the accumulator, or `simulation_budget_ms`.
2. `GPUSimulationBackend` is the only sanctioned place for timestep/accumulator/backlog logic — do not duplicate this pattern elsewhere.
3. **Production wiring of this PoC into `PixelSimWorld`/`Main.tscn` is now done — but only for SAND+WATER movement**, via `GPUProductionBridge` (see [GPU Production Wiring](#gpu-production-wiring) above). Extending it further (GRAVEL/LAVA movement, GPU-owned reactions, or anything beyond the SAND+WATER-movement scope that section documents) is still its own, separately-scoped follow-up — not an implied next step of having done this much.
4. If a future measurement contradicts a number here, update the number and say what changed — the same policy PERFORMANCE_SCALABILITY.md and GPU_SIMULATION.md already follow.
5. `CPUSimulationBackend.record_tick_samples`/`tick_duration_samples` (see [Stress-Test Instrumentation Trustworthiness](#stress-test-instrumentation-trustworthiness-frame-time--stutter--per-tick-timing)) is the only sanctioned place for per-tick wall-clock timing on the CPU path — do not add a second, competing timing mechanism; extend `stress_test.gd`'s consumption of it instead.
6. Never trust a single averaged FPS/frame-time number as proof of smooth gameplay, on either the CPU or GPU path — always check the frame-time distribution (median/p95/p99/max) and stutter-frame counts alongside it, per the same reasoning that motivated this section.
7. `World::set_movement_externally_owned`/`GPUProductionBridge` is the only sanctioned place for a "which system currently moves this material" gate — do not add a second, competing ownership mechanism if some future material also needs to be externally driven.
