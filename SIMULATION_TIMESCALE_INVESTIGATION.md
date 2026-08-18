# Simulation Timescale Investigation

Follow-up to the stress-test wall-clock timing investigation (10k SAND ~6s vs 500k SAND ~26s to settle). That investigation found the wall-clock disparity fully explained by a mechanical fact: `simulation_budget_ms` fragments one logical gravity pass across more real engine frames as the active region grows. This document asks the follow-up question that finding raised but didn't answer: **is that mechanical fact also a gameplay problem** — does it mean gravity itself runs at a workload-dependent speed?

**Status:** Investigation only. No physics, budget, solver, activation, or GPU backend code was changed while producing this document. `git status` in `pixelsim/` is clean.

---

## Current Behavior

Confirmed by direct code reading, not assumption:

- `main.gd:31`: `sim_world.step_simulation(delta)` — called exactly once per `_process`, unconditionally. No accumulator, no catch-up, no "run N steps this frame" logic anywhere in the game layer.
- `sim_world_node.cpp:126` (`PixelSimWorld::step_simulation`): the `delta` parameter is **received and never used**. The function body is `last_stats_ = world_->step(simulation_budget_ms_); ...` — `delta` does not appear again. Godot's actual per-frame `delta` (which would vary with real frame time) has **zero effect** on how much simulation progress happens.
- `world.cpp:172` (`World::step`): scans grid rows bottom-to-top, skipping sleeping chunks in O(1), doing real per-cell work only for awake chunk rows. If elapsed CPU time inside this call reaches `simulation_budget_ms` (4.0 ms, set once in `main.gd:15`) before reaching row 0, it saves `resume_y_` and returns immediately — the pass is incomplete, `pass_completed = false`. The **next** `step_simulation()` call (i.e. the next engine frame) resumes from `resume_y_`. Only when a call reaches row 0 does `pass_completed = true` and `finish_pass()` run (chunk sleep/wake bookkeeping, `current_pass_id_++`).
- Critically: reaching row 0 with budget to spare does **not** trigger a second pass in the same call. `step()` returns immediately after `finish_pass()`. One `step_simulation()` call produces **at most one completed pass**, however much budget is left over.

## Physical Time Model

There is no explicit unit of "physical time" anywhere in this codebase — no `dt`, no simulated clock, no tick counter exposed to gameplay. The only thing that plays that role is the **pass**: one full bottom-to-top sweep, during which every currently-movable cell gets exactly one opportunity to move. This is the correct unit to reason about "how much gravity has happened," independent of how many real frames it took to get there.

**Passes vs. frames are two different clocks that the current architecture conflates:**

| Clock | What advances it | Rate in the current implementation |
|---|---|---|
| **Physical/logical time** | One `pass_completed == true` event | Whatever `World::step()` produces — no target rate exists |
| **Wall-clock (real) time** | One engine frame (`_process` call) | ~144 Hz (display-refresh-capped, per PERFORMANCE_SCALABILITY.md's existing methodology note) |

Because `step_simulation` ignores `delta` and there is no accumulator, **the pass rate (passes per real second) is a pure side effect of how many frames each pass happens to take** — never a designed, controlled quantity. This is the fact this investigation set out to either confirm or rule out as a real gameplay concern.

## Compute Budget Model

`simulation_budget_ms` (`sim_config.h:19`, `DEFAULT_SIMULATION_BUDGET_MS = 4.0`) is documented and implemented purely as a **CPU wall-clock cutoff per `step()` call** — "don't spend more than 4ms of this frame scanning rows." Nothing in its implementation or the surrounding docs (`PROJECT_ARCHITECTURE.md`, `SIMULATION_ACTIVATION.md`) frames it as a physics-rate control.

But because nothing else governs pass rate, this CPU-time budget **is, in practice, the only thing that determines how fast gravity ticks in real time** whenever a pass's active region is large enough to exceed it. The budget was designed to answer "how much CPU time may this frame spend" and, as an unintended side effect with no code change required, it also answers "how many gravity ticks happen per second" — those are conflated into a single number today. This is the architectural root of the concern: **compute-work budget and physical-time rate are the same variable**, when conceptually they should be independent.

## 10k vs 500k Measurements

Two separate measurements were run, both via a standalone `PixelSimWorld` instance (same spawn geometry as `stress_test.gd`, seed 1337, `simulation_budget_ms = 4.0`, no rendering, no GPU) — isolating the simulation core from every other system.

**Measurement 1 — time to fully settle** (carried over from the prior investigation, included here for continuity):

| Tier | Frames to settle | Passes to settle | Frames/pass | Avg `sim_ms` | Est. wall time |
|---:|---:|---:|---:|---:|---:|
| 10,000 | 742 | 738 | 1.01 | 0.76 | 5.15 s |
| 50,000 | 754 | 750 | 1.01 | 2.25 | 5.24 s |
| 100,000 | 1,317 | 740 | 1.78 | 2.33 | 9.15 s |
| 250,000 | 1,938 | 701 | 2.76 | 3.55 | 13.46 s |
| 500,000 | 3,130 | 607 | 5.16 | 3.68 | 21.74 s |

**Measurement 2 — wall-clock time for a *fixed* number of passes (100), the direct test of §2/§9's question.** This removes the confound in Measurement 1 (different tiers need different total passes to fully settle, since taller blocks start closer to the ground). Holding physical time constant at exactly 100 passes for every tier isolates the pass-rate distortion cleanly:

| Tier | Frames for 100 passes | Wall time | Passes/sec | Avg `sim_ms` |
|---:|---:|---:|---:|---:|
| 10,000 | 104 | 0.722 s | **138.5** | 0.96 |
| 50,000 | 105 | 0.729 s | **137.1** | 2.69 |
| 100,000 | 204 | 1.417 s | **70.6** | 2.45 |
| 250,000 | 306 | 2.125 s | **47.1** | 3.80 |
| 500,000 | 608 | 4.222 s | **23.7** | 3.79 |

**This is explicit proof, not inference:** the exact same 100 passes — the exact same amount of "physical" gravity simulation, cell-for-cell — takes **0.72 s at 10k SAND and 4.22 s at 500k SAND: a 5.85× difference for identical physical progress.** Passes/sec ranges from 138.5 down to 23.7 across the tested tiers. Answering §2 directly: **no, the same physical time does not elapse in the same wall-clock time.** A sand grain governed by the exact same gravity rule falls roughly 6× slower in real seconds in a busy 500k-cell world than in a quiet 10k-cell world.

## Why Simulation Slows Down

Mechanically (confirmed by the `active_chunks` sampling from the prior investigation): a taller spawn block — the natural result of `stress_test.gd`'s fixed-width, height-scales-with-count spawn geometry — keeps more chunk-rows simultaneously active (10k: steady 48 active chunks = exactly 1 chunk-row; 500k: fluctuating 104–192 = 2–4 chunk-rows). More simultaneously active chunk-rows means more real per-cell work inside a single pass, which pushes `sim_ms` per call up toward the 4 ms ceiling (0.76 ms avg at 10k → 3.7–3.8 ms avg at 250k/500k, saturating near the budget). Once a pass's real cost exceeds the budget, it is split across multiple frames — and since nothing tracks "how many passes *should* have happened by now," the pass rate silently drops to whatever the CPU can sustain, with no compensating mechanism.

## Is This Intended Technically?

**Yes, in the narrow sense** the prior investigation established: the row-budget mechanism is doing exactly what it was written to do (bound per-frame CPU cost), and no bug (readback stall, sync bug, over-activation, harness defect) was found anywhere in the chain.

**No, in a broader sense worth naming explicitly:** the budget's design never considered "and what should happen to the simulated tick rate when this triggers" — because no simulated tick rate concept exists to protect. It isn't that someone decided physics should slow down under load; it's that nothing was ever built to prevent it. The current behavior is an *emergent* property of an absent design decision, not a deliberate one.

## Is This Desirable Gameplay Behavior?

This is the judgment call this document was asked to surface, not resolve unilaterally. The case against it, per your framing: a player watching a 500k-cell scene experiences gravity itself as ~6× slower than in a light scene, governed by an implementation detail (how many chunk-rows happen to be active) that has nothing to do with the fiction of "how fast does sand fall." That's a believability/consistency problem, not merely a performance number. It also means "how fast the world settles" is not really a property a designer or player can reason about — it depends on incidental scene composition, not on any tunable rule.

The case that current behavior is tolerable: no gameplay system today reads "elapsed simulated time" and depends on it being wall-clock-accurate (no timers, no synced animations, no fixed-rate resource generation tied to it, as far as documented in `PROJECT_ARCHITECTURE.md`) — so nothing is *functionally* broken, only *perceptually* inconsistent, and only in scenes heavy enough to matter (this repo's own baseline table shows 100k+ SAND is where `sim_ms` starts approaching the budget; ordinary gameplay mining/building footprints are almost certainly far below that).

I'm not resolving this trade-off — it's the one this document exists to hand back to you with hard numbers attached, per §10/§11 of the request.

## Possible Solutions

Evaluated only, per instruction — nothing below was implemented.

**A — Fixed simulation timestep + accumulator.** Decouple pass execution from frame cadence: track accumulated real time, and trigger a pass attempt once enough time has accumulated for a target tick rate (e.g. 60 passes/sec). *Necessary but not sufficient on its own:* it formalizes "how many ticks should have happened," but a single pass over a large active region can cost more CPU time (~18–20 ms observed for 500k, i.e. ~5 frames' worth of budget) than one tick period at any reasonable target rate. Without a throughput fix, this just relocates the same shortfall into an explicit backlog rather than removing it.

**B — Simulation backlog / catch-up.** Track "passes owed" against a target rate; spend up to the per-frame budget paying it down, carrying remainder forward. Makes the tradeoff *visible and measurable* (a debug stat like "simulation N% behind real-time") instead of silently absorbed as normal frame time — valuable for diagnosis and for deciding when a scene has exceeded design intent. Does **not** by itself increase throughput, so a genuinely overloaded scene still falls behind; the classic accumulator "spiral of death" also needs an explicit cap on max catch-up per frame.

**C — Multiple logical passes per frame while budget allows.** Already partially true today by omission rather than design: `step()` never attempts a second pass after completing one early, even with budget to spare (confirmed in Current Behavior above) — light tiers leave ~3 ms of unused budget every frame. This isn't a fix for the heavy-tier case (a pass there already exceeds the budget alone) but is a real, currently-unclaimed inefficiency: light scenes are frame-rate-limited at ~144 passes/sec rather than budget-limited, meaning there's headroom being left on the table that a target-rate design (A/D) would need to actively manage rather than assume away.

**D — Budget-aware simulation with separated simulation-time and compute-budget concepts.** This is the correct conceptual frame, and effectively formalizes A+B into a named architecture: a target simulated tick rate (independent variable) plus a bounded per-frame compute budget (unchanged, still 4 ms) plus explicit backlog accounting for when the two don't reconcile. It reframes rather than replaces A/B — the throughput ceiling problem below still applies.

**E — GPU: entire active region in one/few compute dispatches.** The already-built Phase 2A/2B PoC is the strongest lever on the actual bottleneck (per-pass compute cost scaling with active-region size), because GPU compute-only cost is close to **flat** across the tested range, unlike CPU's per-row serial cost:

| Chunks | Cells | CPU `sim_ms` (Phase 2A) | GPU compute only |
|---:|---:|---:|---:|
| 1 | 4,096 | 0.061 ms | 0.086 ms |
| 100 | 409,600 | 4.058 ms | 0.093 ms |
| 500 | 2,048,000 | 4.901 ms | 0.145 ms |
| 1,000 | 4,096,000 | 6.919 ms | 0.194 ms |

(Source: `GPU_SIMULATION.md` Phase 2A table; Phase 2B's WATER numbers are near-identical in shape.) At 1,000 chunks (4.1M cells — comparable in scale to what a heavily-loaded active region could reach), GPU compute-only cost is still under 0.2 ms — meaning a pass over an active region this large could plausibly complete in a small fraction of a single frame's budget, removing the fragmentation-across-frames problem at its source rather than managing around it. This is evaluation only — the existing GPU PoC has no reactions, mining, activation, sleeping, background/foreground layers, or LAVA ported, is not GPU-resident (readback cost scales with cell count, per the same table), and migrating the *production* simulation is explicitly out of scope for this round.

## Recommended Architecture

Not implemented — a direction for your decision, combining the pieces above: **D as the conceptual model (target tick rate + bounded compute budget + explicit backlog), built from A (accumulator) and B (backlog/catch-up tracking), with C absorbed as the natural "spend leftover budget on more passes, up to backlog" execution rule inside it.** This alone makes the tradeoff explicit and diagnosable, but does not remove the underlying throughput ceiling — at sufficiently large active regions, the target tick rate still won't be met by CPU alone, exactly as Measurement 2 shows. **E (GPU)** is the lever that actually raises the ceiling, based on the already-measured near-flat GPU compute cost — but it's a substantially larger migration (production simulation, not a PoC) that should be its own deliberately-scoped milestone, not a side effect of fixing pass-rate accounting.

In short: A+B+D can make the current slowdown *honest and bounded*; only E can make it *not happen* at the scales this repo's own stress tiers already reach.

## Risks

- **A/B/D (accumulator + backlog):** classic fixed-timestep "spiral of death" if uncapped — needs an explicit max-catch-up-per-frame limit, meaning a sufficiently overloaded scene will still visibly run gravity in slow motion, just now *intentionally and boundedly* instead of as an unadvertised side effect. Changes the meaning of `pass_completed`/frame cadence that `stress_test.gd` and any future caller currently assumes is 1:1-ish; anything relying on "roughly one pass per frame" needs re-auditing.
- **C:** using leftover budget for extra passes in light scenes changes their pass rate upward (potentially past display refresh rate) — fine physically, but changes what "1 second of stress test" currently measures; needs re-baselining against the existing PERFORMANCE_SCALABILITY.md numbers.
- **E (GPU):** the single largest risk surface. Requires re-validating CPU/GPU divergence (already documented as non-bit-identical in contested cascades, mass/behavior-equivalent only) for the *entire* production ruleset, not just SAND/WATER — reactions, mining, activation/sleeping, background/foreground layers, LAVA. Requires deciding how gameplay code (`get_cell`, mining, building, all currently synchronous CPU reads) accesses a potentially GPU-resident world. Carries the previously-observed Vulkan device-loss operational risk under heavy scripted GPU load. This is a major architectural commitment, not a tuning change.
- **Doing nothing:** the gameplay-consistency concern in "Is This Desirable Gameplay Behavior?" stays unresolved and will reproduce at whatever scale a scene next gets busy enough to trigger it — including potentially during normal play, not just synthetic stress tiers, once enough SAND/WATER is present at once (mining collapses, flooding, etc.).

## Next Step

This document is the deliverable for this round, per your explicit instruction — no physics, budget, solver, activation, or GPU code was touched. The open decision is yours: whether the gameplay-consistency question above is worth acting on now, and if so, which combination of A/B/D (bounded, honest slowdown) vs. E (production GPU migration, a large separate milestone) — or neither, if you judge the "load-dependent gravity rate" acceptable at PixelSim's actual expected in-game scene sizes rather than synthetic 250k–500k stress tiers. I have not started implementing any of the above and am stopping here.
