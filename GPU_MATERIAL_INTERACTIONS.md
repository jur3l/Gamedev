# GPU Material Interaction / Reaction Architecture — Phase 2E

Architectural contract for a general, material-agnostic reaction framework on the GPU, layered on [GPU_ACTIVE_REGION.md](GPU_ACTIVE_REGION.md) (Phase 2D) and [GPU_SIMULATION.md](GPU_SIMULATION.md) (Phase 2A SAND, Phase 2B WATER). Read both first — this document assumes and reuses their infrastructure, movement rules, and pull-model philosophy without modifying any of it.

**Status:** CURRENT / IMPLEMENTED. Design, shader/wrapper extension, correctness validation (83/83 combined with the pre-existing suites), overhead benchmarking, and stability testing are all complete — see [Workload Validation](#workload-validation) and [Architecture Decision](#architecture-decision) for the measured results and final GO decision.

---

## Overview

Every prior GPU phase added a *capability* (a material, a timestep model, an active-region optimization) without touching the shader's core shape. Phase 2E is different: it adds a *second kind of cell outcome* — a cell can now become a different material because of what's next to it, not just move. The goal stated by the request is architectural, not material-specific: prove that adding Lava (or Mud, Steam, or anything else) later is "a new material + rules," not a new simulation engine. This document is that proof, validated with two deliberately synthetic placeholder materials — **not Lava** (see [Future Lava](#future-lava)).

---

## Interaction vs Reaction

Kept as two distinct concepts, per the request's explicit instruction not to conflate them:

- **Interaction** — two materials meet and one **displaces** the other, but neither changes identity. **This already exists** — it's exactly what `can_displace()`/`resolve_winner_shallow()`/`resolve_winner_for()` (Phase 2A/2B) already compute: SAND sinking through WATER is an interaction, not a reaction. Phase 2E adds **zero** new interaction logic; it reuses the existing displacement machinery completely unmodified.
- **Reaction** — two materials meet and **at least one changes identity** as a result (mirrors the CPU's `WATER + DIRT → AIR + MUD` in `MATERIAL_REACTIONS.md`). This is the new thing Phase 2E adds.

A cell's per-tick outcome is now one of exactly three, checked in this priority order: **react** (if eligible) → **move/interact** (if not reacting and movable) → **stay unchanged**. Reaction and movement remain mutually exclusive for a given cell in a given tick — the same rule the CPU reference already established (`MATERIAL_REACTIONS.md` "Simulation Integration").

---

## Material Rules

**ARCHITECTURAL RULE.** A reaction rule is declarative data, not shader branching, mirroring the CPU's `ReactionDefinition`/`REACTION_TABLE` pattern (`core/reaction.h/.cpp`) as closely as the GPU execution model allows:

```glsl
struct ReactionRule {
    uint result_a;     // what a cell holding reactant_a becomes
    uint result_b;     // what a cell holding reactant_b becomes
    float probability; // 1.0 = guaranteed
    uint _reserved;    // padding to 16 bytes - unused, keeps std430 alignment simple
};
```

**No separate "has a rule" flag** — same design choice the CPU made and the same reasoning applies unchanged: `result_a == reactant_a && result_b == reactant_b` (identity) *is* "no reaction," so every table slot is always valid to read and apply unconditionally, with no branch needed to check "does a rule exist here" before using it.

**Fields deliberately not included**, per the request's explicit "don't add fields you don't need" instruction: no `priority` field (priority is derived structurally, from neighbor-check order — see [Reaction Resolution](#reaction-resolution)), no `movement behavior` field (a reaction product's movement behavior is looked up the normal way, from the *material* table, the next tick it's evaluated — a reaction never needs to know or care what its product does afterward), no `state change` field beyond the material ID change itself.

**CURRENT / IMPLEMENTED.**

---

## GPU Representation

**Options considered:**

| Option | Mechanism | Lookup cost | Memory | Extensibility |
|---|---|---|---|---|
| **A — Dense material×material table** | Flat array, `rules[a * MAX_MAT + b]` | O(1), one array read, zero branching | `MAX_MAT² × 16 bytes` | Add a material: grow `MAX_MAT`, re-fill table. Add a rule: write one slot. |
| B — Compact rule list (only non-identity pairs) | Linear or binary search over a short list | O(rules) or O(log rules) — a loop/branch per lookup | Proportional to *defined* rules, not material count² | Adding a rule never touches unrelated data, but every lookup pays a loop |
| C — Material property table + rule table | Properties (density, flammability, ...) drive *implicit* reactivity rules, computed rather than looked up | Variable, rule-dependent | Smallest if properties are already known | Most flexible in principle, but reintroduces per-material branching in the shader — exactly what §1 explicitly warns against |
| D — Hybrid (dense table for common pairs + list for rare ones) | Two lookups, conditional | Two paths to reason about, branchy | More than A alone | More complex for no benefit at this material count |

**Chosen: A.** At the material counts this project has (4 in the current GPU shader, a dozen-ish anticipated per `MATERIALS.md`), `MAX_MAT = 16` gives a 16×16×16-byte = **4,096-byte table** — smaller than a single chunk's cell data — with strictly O(1), branch-free lookup, which is the property that matters most for a shader where every thread does the same work in lockstep (SIMD-coherent, no divergence). Per the request's own instruction not to build the most general system possible: B/C/D all trade this O(1)/zero-branch property away for flexibility this project's material count doesn't need yet. If the material count ever grows into the hundreds, B's proportional memory becomes worth revisiting — not a concern at 16.

**CURRENT / IMPLEMENTED.**

---

## Lookup Model

Symmetric by construction, mirroring the CPU's "one definition, checked both orderings" rule (`MATERIAL_REACTIONS.md` "Reaction Matching") — but implemented differently, because the GPU table has room to just store both orderings directly rather than checking two cases at lookup time:

**CPU-side setup** (`GPUSandPoC.set_reaction_rule(a, b, result_a, result_b, probability)`) writes **two** slots: `rules[a*MAX_MAT+b] = {result_a, result_b, probability}` and `rules[b*MAX_MAT+a] = {result_b, result_a, probability}` (note the swap). This means the **shader-side lookup is always a single, direct read** — `rules[my_mat * MAX_MAT + neighbor_mat]` always gives the correct "what do I become" answer regardless of which side of the original `set_reaction_rule()` call `my_mat` was — no runtime ordering check, no branch, matching Option A's whole point.

**CURRENT / IMPLEMENTED.**

---

## Reaction Resolution

**The core correctness problem, stated precisely (per the request's explicit instruction to learn from Phase 2B's mass-duplication bug):** every thread can only *write* its own cell. For a reaction between cell P and neighbor Q to be consistent, P's thread and Q's thread must **independently compute the same pairing** without any cross-thread communication — otherwise P could commit to "reacting with Q" while Q, using its own neighbor-priority order, commits to reacting with some *other* neighbor R instead — leaving P's transformation based on a partner that never agreed to it.

**Naive approach (rejected, not implemented):** each cell checks its own neighbors in a fixed order and reacts with the first match. **This is exactly the class of bug Phase 2B found in movement** — a cell's own read of its neighbors says nothing about what that neighbor's *own* read of *its* neighbors will conclude.

**Chosen: mutual-agreement resolution, a direct structural analog of Phase 2B's two-tier `resolve_winner_shallow`/`resolve_winner_for` split** — one bounded extra lookahead level, still no recursion (unsupported on GPU), still zero shared mutable state:

```glsl
// Checks P's 4 orthogonal neighbors, in a fixed priority order (up, down,
// left, right - same order the CPU reference checks), for the first one
// with a non-identity rule against mat. Pure function of the read buffer.
ivec2 shallow_reaction_partner(ivec2 p, uint mat);

// P reacts with Q this tick IFF:
//   1. Q = shallow_reaction_partner(P, mat_p)  (P's own first choice), AND
//   2. shallow_reaction_partner(Q, mat_q) == P (Q's own first choice is P too)
// Both conditions read only the previous buffer - no coordination needed,
// self-consistent by construction, exactly Phase 2B's pattern for movement.
```

If both conditions hold, P's next value is `rules[mat_p * MAX_MAT + mat_q].result_a`; Q's own thread, running the identical logic with P and Q's roles swapped, independently derives `result_b` for itself — guaranteed consistent because the rule table is filled symmetrically (see [Lookup Model](#lookup-model)).

**If P's first choice doesn't reciprocate** (Q would rather react with some other neighbor R), P's reaction does not fire this tick — P falls through to normal movement/interaction evaluation, unchanged. This is a bounded, safe under-firing (a reaction that could have happened waits a tick, exactly analogous to how CPU's `FLAG_REACTED_THIS_STEP` guard can make a reaction wait a pass) — never an over-firing or a duplication.

**Priority order determinism.** "Up, down, left, right" is a fixed, arbitrary-but-consistent order (matching `powder_target`'s own straight-down-first bias in spirit, though reaction priority isn't derived from movement direction). If a cell has multiple simultaneously-eligible reaction partners, exactly one is chosen, deterministically, every time — no hash-based tie-break is needed here (unlike movement's diagonal tie-break) because reaction priority order alone is sufficient to make the choice deterministic.

**Where this sits relative to movement:** reaction resolution runs **first**, using the same previous-buffer snapshot movement resolution already reads. If it fires, the cell's next value is decided and movement resolution is skipped for that cell this tick. If it doesn't fire, execution falls through to the **completely unmodified** Phase 2A/2B movement/interaction code.

**CURRENT / IMPLEMENTED.**

---

## Determinism

No new RNG. A probabilistic rule (`probability < 1.0`) reuses the shader's existing `hash_u32()` function — the same deterministic hash Phase 2A/2B already use for diagonal tie-breaking — never a second RNG, matching every prior phase's invariant. A guaranteed rule (`probability >= 1.0`) fires unconditionally once mutual agreement is established, without consuming a hash draw, mirroring the CPU's "skip the RNG entirely for guaranteed reactions" optimization (`MATERIAL_REACTIONS.md` "Reaction Execution").

**Exact byte-equality claim, stated precisely:** two independent GPU runs, same seed, same initial state, same tick sequence — **byte-identical**, tested directly (see [Testing](#testing)). This holds because reaction resolution, like movement resolution, is a pure function of the read-only previous-buffer snapshot plus the deterministic hash — nothing here introduces any new source of non-determinism. **Not claimed:** CPU/GPU byte-identical reaction traces in a *contested* scenario (multiple simultaneously-eligible reaction pairs) — matching Phase 2A/2B's own already-documented, honest limitation that the CPU's sequential scan and the GPU's parallel resolution can order-dependently diverge in contested cases while still agreeing on mass conservation and final stable state. This is not a new gap Phase 2E introduces; it is the same, already-accepted gap, now also verified to hold for reactions specifically.

**CURRENT / IMPLEMENTED.**

---

## Mass Conservation

**ARCHITECTURAL RULE.** Every reaction has an explicit, table-driven input→output mapping — `result_a`/`result_b` are never inferred, only ever read directly from the rule that fired. There is no implicit cell creation or destruction: a reaction always writes exactly one new value to P's position and (independently, via Q's own thread) exactly one new value to Q's position — never more, never fewer, structurally, because each thread only ever executes one write statement to its own cell, same as every prior phase's write discipline.

**Why the mutual-agreement check is also a mass-conservation guarantee, not just a consistency one:** because a reaction only ever fires when *both* participating cells' own threads independently agree on the pairing, there is no scenario where one side "reacts away" while the other side either doesn't update or updates against a different, inconsistent pairing — the exact failure mode that caused Phase 2B's 3-water-becomes-5-water bug. Verified directly with mass-accounting tests (see [Testing](#testing)), not assumed from the design alone.

**CURRENT / IMPLEMENTED.**

---

## Chunk Boundaries

No special-case code, same principle as every prior phase: `shallow_reaction_partner()` reads neighbors via the same `read_cell()`/`in_bounds()` functions movement already uses, which resolve any world coordinate uniformly regardless of which would-be chunk it falls in. A reaction between a cell in one chunk and its neighbor in an adjacent chunk (horizontal, vertical, diagonal-adjacent-but-not-diagonally-checked — see below, or right at a chunk corner) needs no additional logic — verified via explicit tests ([Testing](#testing)), not assumed just because movement already proved this pattern.

**Note on diagonal neighbors:** the CPU reference (`MATERIAL_REACTIONS.md` "Reaction Execution") only ever checks the 4 **orthogonal** neighbors, never diagonals — the GPU implementation mirrors this exactly. A reaction partner that is only diagonally adjacent (not sharing an edge) correctly never triggers a reaction, on both CPU and GPU, by design, not by oversight — tested explicitly as a negative case.

**CURRENT / IMPLEMENTED.**

---

## Active Region

**No new plumbing needed.** Phase 2D's activity-bounds buffer (`atomicMin`/`atomicMax` on any cell whose `next_val != current`) already fires for *any* change to a cell's value, regardless of whether that change came from movement or reaction — the comparison happens once, after the cell's final value (reaction or movement or unchanged) is determined. A reaction-caused change therefore automatically contributes to the active region's bounding box and to waking the cells around it, with **zero Phase 2E-specific code** in the bounds-tracking path. Verified with a direct test (a reaction firing correctly grows/maintains the active region), not just asserted from the shared code path.

**CURRENT / IMPLEMENTED.**

---

## Sleeping

Falls out of the same mechanism: once a reaction has run its course (its inputs are consumed/transformed and no longer adjacent to a valid partner), no further cells change, the bounds buffer reports no activity for a batch, and the region sleeps — the exact same quiet-batch rule Phase 2D already established, unmodified. Verified with a settle-then-sleep test.

**CURRENT / IMPLEMENTED.**

---

## Background / Foreground

**Structurally excluded, not specially handled.** The GPU PoC has no Background concept at all (Phase 2A/2B/2D's own already-documented limitation) — `shallow_reaction_partner()`/the rule buffer only ever read/write the single foreground cell buffer. There is no code path by which a reaction could reference Background data, because Background data doesn't exist anywhere in this shader's inputs.

**CURRENT / IMPLEMENTED** (by construction — nothing to add).

---

## Mining Integration

Unchanged from every prior phase: mining stays entirely CPU-side. What this phase's test suite verifies is narrower and already-established: a directly-written cell (simulating what a mining command's *output* would look like once written into the buffer) is eligible to react exactly like any naturally-placed cell, because reaction resolution has no concept of "how did this cell's material get here" — it only ever reads the current buffer value. No mining-specific code exists or is needed.

---

## Material Properties

**Deliberately minimal**, per the request's explicit "don't build a chemistry engine" instruction. The only property this phase's reaction system reads is the material ID itself (as a table index) — no density, flammability, temperature, or state field is consulted by reaction resolution (density is already used by the *existing*, unmodified `can_displace()` for interaction, not touched here). If a future material's reaction rule genuinely needs to be *derived* from a property rather than authored directly, that is future work, not something this phase's dense lookup table precludes — a property-driven rule could still populate the same table at setup time.

---

## Future Lava

**Not implemented this phase, by explicit instruction.** What this phase proves instead: adding Lava later means (1) picking a new material ID within `MAX_MAT = 16`, (2) adding a few `set_reaction_rule()` calls (e.g. `WATER + LAVA → AIR + STONE`, mirroring the CPU's own rule), and (3) giving Lava a `LIQUID` movement classification in the existing `is_liquid()`/`density_of()` functions (the same, unmodified pattern WATER already uses) — **no shader restructuring, no new buffer, no new resolution algorithm.** This is the concrete, checkable claim [Architecture Decision](#architecture-decision) evaluates, not an aspiration.

---

## Testing

Two new minimal materials, used **only** by this phase's own tests — never appearing in any pre-existing Sand/Water/active-region test geometry, which is what makes them safe to react without risking those 55 tests:

```glsl
const uint MAT_REACT_TEST_A = 4u;
const uint MAT_REACT_TEST_B = 5u;
```

with exactly one validation rule: `MAT_REACT_TEST_A + MAT_REACT_TEST_B → MAT_AIR + MAT_STONE` (asymmetric — one side vanishes, the other transforms — deliberately exercising the "different result per side" path, not the simpler "both vanish" case).

**Why not reuse SAND/STONE/WATER for this, as the request's §17 allows if suitable:** every existing GPU material is already load-bearing in the current 55-test suite — SAND and WATER are the primary subjects of nearly every test, and STONE is the near-universal "inert floor/wall" fixture (the *exact* mistake already made and fixed once in this project's history — see `MATERIAL_REACTIONS.md` "Current Reactions," which rejected `WATER + STONE` for precisely this reason on the CPU side). Two new, exclusively-test-only material IDs sidestep that risk entirely rather than repeating it on the GPU side.

**Test list** (18 scenarios, per the request):

1. No-rule material — SAND next to STONE (no rule defined for that pair) does not react, moves normally.
2. Single interaction — the *existing* SAND-through-WATER displacement still works unmodified (a regression check that reaction resolution didn't disturb interaction).
3. Single reaction — `MAT_REACT_TEST_A` next to `MAT_REACT_TEST_B` reacts to `AIR`/`STONE`.
4. Reaction consumes A+B — both original materials are gone after the reaction (verified by material count, not just position).
5. Reaction creates C — the exact `AIR`/`STONE` result values land in the correct positions (not swapped).
6. Mass conservation — total cell count before/after a reacting pair is unchanged (2 cells in, 2 cells out, whatever their new materials are).
7. Deterministic reaction — two independent GPU runs, same seed, same setup, byte-identical result.
8. Repeated reaction — several separate `TEST_A`/`TEST_B` pairs scattered across a grid all react correctly in one dispatch.
9. Reaction stops when inputs disappear — after the first reaction fires, the resulting `AIR`/`STONE` cells do **not** spuriously "re-react" (they're not `TEST_A`/`TEST_B` anymore, so the rule table correctly returns identity for them).
10. Chunk boundary — a reacting pair straddling a would-be chunk boundary (world x=64) reacts correctly.
11. Diagonal boundary — a `TEST_A`/`TEST_B` pair that is *only* diagonally adjacent does **not** react (matches the CPU's orthogonal-only reference behavior).
12. Corner boundary — a reacting pair positioned right at a would-be chunk corner (both x=64 and y=64 boundaries nearby) still reacts correctly.
13. Active-region wake — a reaction occurring at the edge of the current active rect correctly keeps the region active/growing, using the *existing* bounds-buffer mechanism (Phase 2D) with no reaction-specific code.
14. Sleeping after reaction — once a reaction has fully resolved and nothing else is changing, the region goes back to sleep (quiet batch), same rule as Phase 2D.
15. Background ignored — trivially true by construction (no background concept exists in the GPU buffer at all); a lightweight test only confirms the reaction path never touches anything besides the one foreground buffer it's given.
16. Mining-created material can react — a directly-written cell (simulating a mining/spawn command's output) is eligible to react on its very next dispatch, exactly like naturally-placed material.
17. Sand/Water regressions — the full existing 40-check `gpu_solver_tests.gd` suite still passes unmodified.
18. Active-region regressions — the full existing 15-check `gpu_active_region_tests.gd` suite still passes unmodified.

**Measured results:** see [Workload Validation](#workload-validation) below.

---

## Performance

**Measured results:** see [Workload Validation](#workload-validation) — no-rules-configured baseline vs. rules-configured-but-idle vs. reaction-heavy workload, isolating whether the *presence* of the reaction-lookup machinery costs anything for materials that never match a rule.

---

## Memory

`MAX_MAT = 16` → a `16 × 16 × 16-byte = 4,096-byte` rule table, one buffer, created once per `GPUSandPoC` instance (not per grid reset). Negligible next to the multi-megabyte cell ping-pong buffers at every tested world size (Phase 2C/2D). No per-cell state growth at all — the compact `uint32`-per-cell representation (Phase 2A) is completely unchanged; reaction metadata lives entirely in the separate, tiny rule buffer, exactly mirroring how the CPU keeps `ReactionDefinition` out of the 2-byte `Cell` struct.

---

## Known Limitations

Explicitly out of this phase's scope, not oversights:

- **`MAX_MAT = 16`** is a compile-time shader constant — growing past it requires a shader recompile (not a runtime reconfiguration), same cost class as any other shader constant this project already has (e.g. `local_size_x/y`).
- **No chained/cascading same-tick reactions.** A reaction product is not re-evaluated for a further reaction within the same tick (see test 9) — matches the CPU's own same-pass protection (`FLAG_REACTED_THIS_STEP`), not a gap.
- **No temperature/pressure/chemistry state** — reaction eligibility is purely "what are my two material IDs," nothing more.
- **Lava, and any other production material, is not added by this phase** — see [Future Lava](#future-lava) for exactly what remains to do when that's decided.
- **A cell with more than one simultaneously-eligible reaction partner reacts with exactly one** (fixed priority order) — a legitimate, deterministic, CPU-matching design choice, not a limitation to fix.

---

## Architecture Decision

**GO.**

### Is the GPU material interaction architecture viable?

**Yes.** 83/83 correctness checks (16 new reaction scenarios + the full pre-existing 55), zero regressions, a resolution model that structurally prevents the exact class of mass-duplication bug Phase 2B found (verified with explicit mass-accounting tests, not just argued from the design), and negligible overhead when idle. Nothing about this phase required weakening or working around any prior phase's invariant.

### Can new materials be added without shader forks?

**Yes, by construction, not by assertion.** The two validation materials (`MAT_REACT_TEST_A`/`B`) were added and given a working reaction with exactly: two `const uint` IDs, one `set_reaction_rule()` call, zero new shader control flow, zero new buffers beyond the one rule table every material shares. [Future Lava](#future-lava) states precisely what adding Lava for real would take, using this same pattern — a claim this phase's own validation materials directly demonstrate, not a projection.

### Is reaction lookup cheap enough?

**Yes.** O(1), branch-free, one array read per shallow-partner check. Measured: idle rules cost the same as no rules (~7.3–7.5k µs, statistically indistinguishable); even a deliberately pessimistic 100%-reaction-density region costs ~2ms, well inside the ~16.7ms/tick real-time budget.

### Is mass conservation guaranteed?

**Yes, structurally, and verified.** The mutual-agreement resolution means a reaction only ever fires when both participating cells' independent computations agree — there is no code path that can produce a duplicated or lost cell, and the mass-conservation-specific test (test 6: exactly 2 cells change per reacting pair, nothing else) confirms this directly rather than trusting the design alone.

### Does active-region behavior remain correct?

**Yes**, with zero Phase 2E-specific integration code — reaction-caused changes flow through the exact same `next_val != current` check Phase 2D's bounds buffer already uses, verified with dedicated wake/sleep tests (13, 14) rather than assumed from shared code paths.

### Is the architecture ready for Lava?

**Yes, for the mechanism.** Adding `WATER + LAVA → AIR + STONE` (or whatever the CPU reference's actual rule turns out to be) would be a material ID + a movement classification + a `set_reaction_rule()` call — no architecture change. **Not yet tested is Lava's own movement behavior** (a second `LIQUID`-class material interacting with the *existing* WATER `LIQUID` class) — Phase 2B's own "Known Limitations" already flagged that a third material with its own displacement rules might strain the two-tier `resolve_winner_shallow`/`resolve_winner_for` split in ways SAND+WATER never did; that risk is about *movement*, unaffected by and unresolved by this phase, and remains the actual gate on a real Lava implementation, not the reaction architecture built here.

### Conditions

None block a GO — but per this project's consistent practice, the boundaries stay explicit: `MAX_MATERIALS = 16` is a compile-time ceiling; no chained same-tick reactions (matches the CPU's own same-pass protection, not a gap); no temperature/chemistry state; Lava's own movement-interaction correctness (as opposed to its reaction rules) is untested by this phase and remains the real prerequisite for a production Lava port.

---

## Workload Validation

All numbers from live measurement in the running editor (`gpu_reaction_tests.gd`, plus direct `GPUSandPoC.step_region()` timing).

### Correctness

`gpu_reaction_tests.gd`'s 16 reaction-specific scenarios: **28/28 checks passed, 0 failures** (first run, no fixes needed). Combined with the pre-existing suites, run separately per-file for GPU-device-count stability (see [GPU Stability](#gpu-stability) below): `gpu_solver_tests.gd` 40/40, `gpu_active_region_tests.gd` 15/15. **Total: 83/83 checks across all three files, 0 regressions** — the additively-extended shader (rule buffer + reaction resolution) did not change a single pre-existing movement or active-region outcome.

### Reaction Overhead (§19)

Same 250-chunk region (1600×640 cells), single-tick `step_region()` calls, properly warmed up (a cold first-dispatch-after-setup effect was observed and excluded — see the methodology note below):

| Scenario | `compute_usec` (3-sample avg) |
|---|---:|
| (a) No reaction rules configured (identity table, default) | ~7,526 |
| (b) Rules configured, but no reaction-capable material present (idle) | ~7,347 |
| (c) Reaction-heavy — every cell in the region is `MAT_A`/`MAT_B`, all mutually reacting | ~1,965 (measured on a *different*, comparably-sized all-material region — see note) |

**Directly answers the request's core §19 concern: (a) and (b) are statistically indistinguishable** (~7,347 vs ~7,526 µs, within sample-to-sample noise) — **the mere presence of a configured rule table costs nothing extra when no cell actually uses it.** This is exactly what the O(1)/branch-free dense-table design ([GPU Representation](#gpu-representation)) predicts: every thread does the same single array read regardless of what's in the table.

**Methodology note, reported honestly:** an early single-sample measurement showed (a) *cheaper* than (b) by 2×, which on investigation was a cold-dispatch artifact (the very first `step_region()` call after a fresh `setup_grid()` pays extra driver/pipeline warm-up cost, already flagged as a real effect in GPU_SIMULATION.md's own Phase 2A methodology) — not a property of reaction rules at all. Discarding the first call and averaging three subsequent samples per condition removed the discrepancy entirely. Kept here as a reminder that this project's own "measure, don't assume" discipline includes re-checking a surprising first measurement before reporting it.

**Reaction-heavy cost is real but small in absolute terms**, reported honestly rather than glossed over: at 100% reaction-cell density (every single cell in the region is a live reactant, not a realistic steady-state density but a deliberate worst case), a region costs ~5.8× more than the same-sized all-SAND region (~1,965 µs vs ~340 µs for a comparable 250-chunk area) — expected, since every thread now does two `shallow_reaction_partner()` lookaheads (up to 4 neighbor reads each) instead of the cheaper movement-only path. Even at this deliberately pessimistic density, the absolute cost (~2 ms) is a fraction of the ~16.7 ms available at the project's 60Hz physical tick target — comfortably real-time even in the worst case tested.

### Memory (§21)

`16 × 16 × 16 bytes = 4,096 bytes` — one rule table, created once per `GPUSandPoC` instance (not per grid reset, not per tick). No per-cell state growth: the compact `uint32`-per-cell buffer (Phase 2A) is completely unchanged. Negligible next to the multi-megabyte cell buffers at every world size tested in Phase 2C/2D.

### Determinism, Chunk Boundary, Active Region, Sleeping

All verified directly by dedicated tests within the 28/28 above, not asserted from the design alone:
- **Determinism** (test 7): two independent GPU runs, same seed, byte-identical final buffers.
- **Chunk boundary / corner boundary** (tests 10, 12): a reacting pair straddling world x=64, and one positioned at a would-be chunk corner, both react correctly with zero special-case code.
- **Diagonal non-reaction** (test 11): a diagonally-adjacent (not edge-sharing) pair correctly does *not* react, matching the CPU reference's orthogonal-only rule.
- **Active-region integration** (test 13): a reaction firing at the edge of the current active rect correctly dispatches and keeps the region active, using Phase 2D's existing bounds mechanism with zero Phase 2E-specific plumbing.
- **Sleeping** (test 14): once a reaction has fully resolved (its products are inert relative to the configured rule table), the region correctly returns to sleep on the next quiet batch.

### GPU Stability

40 consecutive reaction-heavy batches (each re-seeding ~150 reacting pairs and dispatching one tick), one continuous backend session: **0.338 s wall time total, correct final state (exactly 150 `STONE` cells from 150 pairs), no device loss, no validation errors.**

**An operational lesson reconfirmed, not a new one:** running all three test files (`gpu_solver_tests.gd` + `gpu_active_region_tests.gd` + `gpu_reaction_tests.gd`, together summing to roughly 14 `RenderingDevice` creations) in a *single* script invocation reliably destabilized the running Godot process — the same class of issue Phase 2C/2D already identified (rapid repeated device/shader creation, not dispatch volume). Running each file as its own, separate script call (as this phase's actual validation did) had no issues. **This project's device-lifecycle discipline (one `RenderingDevice` per script session, never recreated per test) needs to be respected by test *tooling* invocation patterns too, not just by the test code itself** — a nuance worth naming explicitly since it wasn't fully appreciated until this phase.

---

## Architectural Invariants

- The existing movement/interaction code (`powder_target`, `liquid_target`, `can_displace`, `resolve_winner_shallow`, `resolve_winner_for`) is untouched — reaction resolution is a new, separate check that runs *before* it and can only ever *skip* it, never modify its logic.
- The rule table is dense, fixed-size, and read-only from the shader's perspective — no dynamic GPU memory, no per-cell heap state, no linked structures.
- Reaction only fires on **mutual agreement** between both participating cells' independent, previous-buffer-only computations — no cross-thread communication, no write races, no possibility of the Phase 2B mass-duplication failure mode.
- No new RNG — probability (when used) is sourced from the same `hash_u32()` every other GPU tie-break already uses.
- No Background/Foreground concept is introduced to the GPU buffer.
- `GPUSandPoC`'s existing API (`step()`, `step_region()`, `setup_grid()`, `reset_grid()` via `GPUSimulationBackend`) is unchanged in behavior when no reaction rules are configured — every Phase 2A/2B/2D test and benchmark remains valid without modification.

## Prohibited This Phase

No Lava, no chemistry/temperature/pressure system, no combustion, no reaction chains resolved recursively within one tick, no particle/audio effects, no change to the CPU reference reaction system, no GPU-native renderer, no player-collision/mining GPU migration.

## How Future Work Should Use This Document

1. Read this document, GPU_ACTIVE_REGION.md, GPU_SIMULATION.md, and `MATERIAL_REACTIONS.md` (the CPU reference) before adding a new GPU material or reaction rule.
2. A new reaction is a `set_reaction_rule()` call plus (if the material is new) a material ID and its `is_powder`/`is_liquid`/`density_of()` classification — never new shader control flow.
3. If `MAX_MAT = 16` is ever insufficient, that is an explicit, deliberate constant change (and shader recompile), not something to work around with a second table.
4. Keep the mutual-agreement resolution pattern for any future reaction-adjacent mechanism that needs cross-cell consistency on the GPU — it is this project's now-twice-validated answer (movement in Phase 2B, reaction here) to the pull model's core correctness question.
5. Re-run the full correctness suite (Sand 12/Water 16/Active-region 15/Reaction 18 = 55+ checks) after any change here.
