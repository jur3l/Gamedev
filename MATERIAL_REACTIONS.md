# Material Reaction System

Architectural contract for PixelSim's Material Interaction / Reaction system. This document is written **before** the implementation exists (per project convention — see [PROJECT_ARCHITECTURE.md](PROJECT_ARCHITECTURE.md) §19), then updated to match the real code once built. Read PROJECT_ARCHITECTURE.md first for the surrounding Cell/Chunk/Material/step() model this document assumes, and [SIMULATION_ACTIVATION.md](SIMULATION_ACTIVATION.md) + [TERRAIN_LAYERS.md](TERRAIN_LAYERS.md) — both are reused, unmodified, by this feature.

**Status:** CURRENT / IMPLEMENTED (each section is marked once the described behavior matches the shipped code).

---

## Purpose

Every material interaction in PixelSim today is really just movement — POWDER falls, LIQUID falls-then-spreads, STATIC never moves. Nothing ever *changes what a material is* as a result of touching another material. This feature adds that: a general, data-driven **Reaction System** where two adjacent materials can transform into two (possibly different) materials, according to a declarative table — not a hardcoded `if (a == WATER && b == LAVA)` chain anywhere in solver or `World::step()` code.

The goal is the *mechanism*, not any specific reaction. A single demonstration reaction is implemented to prove the architecture end-to-end (see [Current Reactions](#current-reactions)), but the system must support adding a second, fifth, or twentieth reaction later by adding one row to a table — never by touching `World::step()`, the solvers, or any per-pair branching code.

---

## Current Material Architecture (recap)

What this feature builds on, unchanged (see PROJECT_ARCHITECTURE.md §4/§5/§7/§8 for full detail):

- `Cell` — 2-byte POD: `material` (`uint8_t`), `flags` (`uint8_t`, 1 bit used by `FLAG_UPDATED_THIS_STEP`, 7 unused).
- `MaterialType` — append-only `uint8_t` enum (`AIR, SAND, DIRT, STONE, IRON_ORE, COPPER_ORE, WATER, WOOD, METAL, GRAVEL, MUD`). `MUD` is the one addition this feature makes — see [Current Reactions](#current-reactions).
- `MaterialDef` / `MATERIAL_TABLE` — static, per-*type* (not per-cell) data table in `core/material.h/.cpp`, looked up by `get_material_def()`.
- `World::step()` — resumable, budgeted, bottom-to-top row scan. For each awake chunk's row, for each cell not already `is_updated()` this pass, if the material's `MovementBehavior` is `NONE`/`STATIC` the cell is skipped entirely; otherwise `solve_powder`/`solve_liquid` is dispatched.
- Chunk sleeping/wake/activation (`Chunk::sleeping`, `dirty_this_pass`, `Chunk::wake()`, `World::activate_affected_neighbors()`) — see SIMULATION_ACTIVATION.md.
- Background layer (`Chunk::background`, `BackgroundType`) — a completely separate, smaller, non-simulated array; never touched by any solver.

---

## Reaction Model

**ARCHITECTURAL RULE.** Reaction metadata is static, per-*type* data — a table indexed by *material pair*, analogous to how `MaterialDef` is a table indexed by material. It is never per-`Cell` state. `Cell` is not modified to add a field; it gains exactly one more bit of its already-unused `flags` byte (see [Infinite-Loop / Same-Pass Protection](#infinite-loop--same-pass-protection)), which does not change `sizeof(Cell)`.

A reaction is defined once, symmetrically, as:

```cpp
struct ReactionDefinition {
    MaterialType reactant_a;
    MaterialType reactant_b;
    MaterialType result_a;   // what the cell holding reactant_a becomes
    MaterialType result_b;   // what the cell holding reactant_b becomes
    float probability;       // 1.0 = guaranteed, 0.5 = 50% per attempt, ...
};
```

`result_a`/`result_b` alone fully describe "consumed" vs. "transformed" vs. "unaffected" — there is no separate boolean:
- `result_a == AIR` → the reactant_a cell is destroyed/consumed.
- `result_a == <some other material>` → the reactant_a cell is transformed into that material.
- `result_a == reactant_a` → that side is unaffected by this reaction (legal, if unusual — a wasted-but-harmless table entry).

This is deliberately simpler than a separate `consumed_a`/`consumed_b` flag pair: everything a solver needs to know ("what does this cell become") is already in `result_a`/`result_b`, and there is no way for a `consumed` flag to disagree with a `result` field because there is only one field to read.

**CURRENT / IMPLEMENTED.**

---

## Reaction Definitions

Lives in a new, small, Godot-agnostic module, mirroring `core/background.h/.cpp`'s pattern (a tiny, separate data table next to the bigger `MaterialDef` table):

- `core/reaction.h` — `ReactionDefinition` struct, `find_reaction()` declaration.
- `core/reaction.cpp` — `constexpr ReactionDefinition REACTION_TABLE[]` + `find_reaction()`.

```cpp
constexpr ReactionDefinition REACTION_TABLE[] = {
    // reactant_a  reactant_b  result_a  result_b      probability
    { MaterialType::WATER, MaterialType::DIRT, MaterialType::AIR, MaterialType::MUD, 1.0f },
};
```

Adding a new reaction is exactly one more row. Nothing outside `reaction.cpp` needs to change.

**CURRENT / IMPLEMENTED.**

---

## Reaction Matching

**ARCHITECTURAL RULE.** A+B and B+A are the *same* reaction, defined once. There is exactly one lookup function, checked both orderings:

```cpp
// Returns true iff some reaction pairs mat1 with mat2 (in either order).
// out_result1 / out_result2 are filled with what mat1 / mat2 respectively
// become - i.e. always mapped back to the CALLER's argument order, never
// the table's internal a/b order.
bool find_reaction(MaterialType mat1, MaterialType mat2,
                    MaterialType &out_result1, MaterialType &out_result2,
                    float &out_probability);
```

For each table row: if `(reactant_a, reactant_b) == (mat1, mat2)`, results map straight across; if `(reactant_a, reactant_b) == (mat2, mat1)` (the swapped order), results map *crossed* (`out_result1 = result_b`, `out_result2 = result_a`) — so the caller never has to know or care which side of the table definition its two cells happened to land on.

The table is linear-scanned (a handful of rows expected for the foreseeable future — this mirrors `MATERIAL_TABLE`'s own lookup style, not a premature hash map). AIR is never a `reactant_a`/`reactant_b` in any row by construction of how reactions are authored (nothing "reacts with empty space"), so an AIR neighbor simply never matches — no special-case code needed for that either.

**CURRENT / IMPLEMENTED.**

---

## Reaction Execution

Lives in a new module, mirroring `solvers/solvers.h/.cpp`'s pattern (behavior, not data):

- `solvers/reaction_solver.h` — `try_react()`, `roll_reaction_probability()` declarations.
- `solvers/reaction_solver.cpp` — implementation.

```cpp
bool try_react(World &world, int x, int y);
```

For a cell at `(x, y)`:
1. If `(x, y)` already reacted this pass (see [Infinite-Loop Protection](#infinite-loop--same-pass-protection)), return `false` immediately.
2. Check its 4 orthogonal neighbors (up, down, left, right — **not** diagonals) in a fixed order.
3. For the first neighbor that (a) is in bounds, (b) has not itself already reacted this pass, and (c) has a material for which `find_reaction()` returns a match: roll probability (see below); if it passes, execute the reaction via `World::set_cell()` on both cells, mark both cells reacted, and return `true`.
4. If no neighbor matches (or the probability roll fails for all that do), return `false`.

**Probability** is checked with a small, pure, directly-testable helper that reuses the existing xorshift32 stream — never a new RNG:

```cpp
bool roll_reaction_probability(uint32_t rand_value, float probability);
```

`probability >= 1.0` short-circuits to `true` **without drawing from the RNG at all** — a guaranteed reaction should not perturb the shared random stream that `solve_powder`/`solve_liquid` also depend on for tie-breaking. Only a genuinely probabilistic reaction (`probability < 1.0`, none exist in the table yet — see [Current Reactions](#current-reactions)) calls `world.rand_u32()`.

**Consumption is not hardcoded anywhere in this function.** `try_react()` never inspects *which* materials are involved — it only ever calls `find_reaction()` and applies whatever `result_a`/`result_b` it returns via `set_cell()`. Adding a reaction never touches this file.

**CURRENT / IMPLEMENTED.**

---

## Simulation Integration

**ARCHITECTURAL RULE.** No new simulation lifecycle. Reaction detection is a small addition to the existing per-cell branch inside `World::step()`'s row scan — the same branch that already dispatches `solve_powder`/`solve_liquid` — not a separate scan, pass, or phase.

```cpp
// World::step(), per-cell, after the existing is_updated()/behavior==NONE|STATIC skip:
bool reacted = try_react(*this, world_x, y);
if (!reacted) {
    if (def.behavior == MovementBehavior::POWDER) moved = solve_powder(*this, world_x, y);
    else if (def.behavior == MovementBehavior::LIQUID) moved = solve_liquid(*this, world_x, y);
}
```

**Reaction and movement are mutually exclusive for a given cell within a given pass** — a cell either reacts, or attempts to move, never both in the same visit. This is a deliberate simplification, not a limitation forced by the code: trying to do both in one visit would mean deciding what "moving a cell whose material just changed out from under it" even means, for no real benefit — the cell that reacted (or the neighbor it reacted with) simply gets its normal turn at movement on the *next* pass, exactly like a cell whose material changed via mining or `place_cell` already does today. Every pass runs at simulation-step speed (potentially many times per second, budget permitting), so this costs at most one pass of latency, not any real responsiveness.

**Scope decision (documented, not accidental):** reaction detection is only invoked for cells with `MovementBehavior::POWDER` or `LIQUID` — the same cells the existing loop already visits for movement dispatch. `STATIC`/`NONE` cells never get their own reaction-detection turn; they only ever participate **passively**, as the neighbor a POWDER/LIQUID cell's check reads via `get_material()`. This is why `WATER + DIRT` (LIQUID + STATIC) works with zero extra scanning: WATER is already being visited every active pass; DIRT is read, not visited. A hypothetical future `STATIC + STATIC` reaction is **out of scope** for the current mechanism (see [Future Extensions](#future-extensions)) — it is not needed by [Current Reactions](#current-reactions) and would require deciding a new detection trigger (most likely: check on activation/wake rather than every pass), which is an explicit future architectural decision, not something to speculatively build now.

**"Just arrived via movement" compatibility:** a cell that moved into contact with a reaction partner this pass gets its *next* reaction-check on its very next visit (the following pass, since `is_updated()` prevents any further processing of it this pass) — there is no special "check again immediately after moving" path, and none is needed; see the mutual-exclusion note above.

**CURRENT / IMPLEMENTED.**

---

## Chunk / Wake Integration

**ARCHITECTURAL RULE.** No new chunk-to-chunk reaction system, and no new wake mechanism. `try_react()` reads neighbors via `World::get_material(nx, ny)` and writes results via `World::set_cell(x, y, ...)`/`World::set_cell(nx, ny, ...)` — the exact same coordinate-agnostic primitives every other piece of `World` (including the solvers) already uses. There is no code path anywhere in reaction execution that checks "am I crossing a chunk boundary" — chunk resolution happens inside `set_cell`/`get_material` themselves, identically for same-chunk and cross-chunk neighbors.

Because reaction execution goes through `set_cell()`, and **not** some new write path, it automatically inherits, for free, exactly the behavior [SIMULATION_ACTIVATION.md](SIMULATION_ACTIVATION.md) already guarantees for *any* world change:
- `mark_touched()` on the reacted cell's own chunk (wakes it, sets `dirty_this_pass`/`render_dirty`, grows the touched-rect).
- `activate_affected_neighbors()` on both reacted cells — waking the fixed 5-cell gravity neighborhood around each, exactly as a mined or built cell would.

This is also why a reaction between two cells in different chunks (one on each side of a chunk boundary) needs no special handling: `set_cell(x, y, ...)` and `set_cell(nx, ny, ...)` each independently resolve and wake *their own* chunk, and both go through the same activation call every other write does.

**Sleeping compatibility:** since reaction detection only runs for POWDER/LIQUID cells in **already-awake** chunks (the same population `World::step()` was already visiting for movement), a reaction can only ever be *detected* in a chunk that's already simulating. A chunk that goes fully to sleep (no movement, no reaction, for a full pass) stays asleep exactly as before — reactions do not add any new reason for a chunk to be scanned that wasn't already there. Placing two reactive materials next to each other (via `set_cell`, e.g. mining or building) wakes their chunk(s) the normal way, giving the reaction system its first chance to fire before anything can go back to sleep.

**CURRENT / IMPLEMENTED.**

---

## Background Exclusion

**ARCHITECTURAL RULE.** The Background layer is never a reactant, product, or reaction participant, and never triggers activation from a reaction. This isn't special-cased anywhere in reaction code — it's structural: `try_react()` and `find_reaction()` only ever see `MaterialType` values (via `World::get_material`/`set_cell`), and `BackgroundType` is a completely distinct type (see TERRAIN_LAYERS.md) that reaction code never references, imports, or has a way to read. There is no `BackgroundType` anywhere in `core/reaction.h/.cpp` or `solvers/reaction_solver.h/.cpp`.

**CURRENT / IMPLEMENTED.**

---

## Infinite-Loop / Same-Pass Protection

**ARCHITECTURAL RULE.** A cell may participate in **at most one** reaction per simulation pass, whether as the cell whose turn triggered the check or as the neighbor it reacted with. This is enforced with one new bit in `Cell::flags` (still a 2-byte `Cell` — this uses an already-unused bit, not a new field):

```cpp
static constexpr uint8_t FLAG_REACTED_THIS_STEP = 1 << 1;
bool is_reacted() const;
void mark_reacted();
void clear_reacted(); // called from Chunk::begin_pass(), alongside clear_updated()
```

`try_react()` checks this flag on **both** cells before matching (its own, at the very top; the candidate neighbor's, before accepting it as a match) and sets it on **both** cells the moment a reaction executes. Consequences:
- A cell cannot react twice in one pass, even if the scan later revisits a *different* cell that happens to have it as a neighbor.
- Two different anchor cells cannot both react with the same shared neighbor in one pass (e.g. `WATER-DIRT-WATER`: only one `WATER` reacts with the middle `DIRT`; the second `WATER`'s check on that neighbor is rejected because `DIRT`'s position — now `MUD` — is already flagged reacted).
- A newly-created reaction product is *not* blocked from normal **movement** by this flag — only from reacting again — and if the scan hasn't passed its row yet this pass, it gets a completely normal movement turn (POWDER/LIQUID dispatch), since the reacted-flag only gates `try_react()`, not `solve_powder`/`solve_liquid`. (Today's only product, `MUD`, is STATIC and never attempts movement at all - this note describes the general mechanism for a future POWDER/LIQUID product.)

Combined with `World::step()`'s existing scan order (each grid position visited **at most once** per pass by the main loop, regardless of how many times its material changed via reactions before that visit), this makes same-pass chain reactions **impossible by construction**, not just unlikely: the total reaction work in a pass is bounded by (number of POWDER/LIQUID cells visited) × (1, since each such visit executes at most one reaction and then never checks again), which is already bounded by the pass's normal per-cell workload. There is no recursion, no while-loop retry, and no separate "resolve the chain" step anywhere in this code.

**Reaction chains across passes** (a reaction's product becoming a reactant in a *later* pass) are fully supported and require no special code: a reaction product is a completely ordinary `Cell` value the moment it's written — the next pass that visits it treats it exactly like any other material, including being eligible for its own `try_react()` call (with the reacted-flag freshly cleared by that pass's `begin_pass()`).

**CURRENT / IMPLEMENTED.**

---

## Performance

**PERFORMANCE REQUIREMENT.** No full-world scan, ever, for reaction detection.

- Reaction checks only happen for cells the main `World::step()` loop was **already going to visit** for movement dispatch (POWDER/LIQUID, in an awake chunk, not yet `is_updated()` this pass) — reaction detection adds **zero** additional cells to the per-pass workload.
- Per visited cell, reaction detection adds a small, fixed amount of extra work: up to 4 neighbor lookups (`get_material` + `find_reaction` against a short table), independent of world size, chunk count, or how many reactions are defined for *other* material pairs elsewhere in the world.
- Sleeping chunks are skipped exactly as before — reaction code never runs for them, and never wakes them speculatively. (Compare with `activate_affected_neighbors`, which *does* legitimately wake neighbors as a result of an executed reaction — that's the same activation cost any other world change already pays, not something new to this feature.)
- `REACTION_TABLE`'s lookup cost scales with the number of *defined reactions* (a handful today), not with world size — this is the one place this feature's cost could grow if many reactions are added later; it remains a deliberate, documented, revisit-if-it-ever-matters tradeoff (see [Future Extensions](#future-extensions)), consistent with `MATERIAL_TABLE`'s own linear-scan lookups elsewhere in this codebase.

**CURRENT / IMPLEMENTED** — see [Testing Requirements](#testing-requirements) for the benchmark that validates this against the existing stress-test harness.

**Measured results** (live in the running editor, default 48×28-chunk / 1,344-chunk world, `simulation_budget_ms = 4.0`; methodology mirrors `stress_test.gd`'s sampling approach — `fill_rect`/`spawn_material_rect` placement, then repeated `step_simulation()` calls sampling `sim_ms`/`active_chunks`/`reaction_checks`/`reactions_executed`):

| Scenario | avg sim ms | max sim ms | max active chunks (of 1,344) | reaction checks | reactions executed |
|---|---|---|---|---|---|
| (a) No reaction-capable materials present | 0.094 | 0.110 | 0 | 0 | 0 |
| (b) Few reactions (60 scattered WATER/DIRT pairs across ~50 different chunks) | 0.160 | 0.418 | 49 | 49 | 49 |
| (c) Many simultaneous reactions (900 WATER cells over a 300×20 DIRT bed, 6 chunks wide) | 0.162 | 0.169 | 6 | 6,276 (10 steps) | 307 (10 steps; 300 fired on the very first step) |

All three stay within noise of the ~0.09ms no-op baseline for this world size, and `active_chunks` tracks the size of the *reactive region* (49 and 6 chunks respectively), never the world's 1,344 total — confirming reaction detection cost scales with active-cell count, not world size, exactly as required above.

---

## Determinism

**ARCHITECTURAL RULE.** No new RNG. `roll_reaction_probability()` is fed by `World::rand_u32()` — the exact same xorshift32 stream `solve_powder`/`solve_liquid` already draw from for tie-breaking. A fixed world seed plus a fixed sequence of `step()` calls therefore still reproduces a fixed simulation history, including reaction outcomes.

Two consequences worth stating explicitly:
- Adding this feature **changes** the sequence of values later solver calls draw from `rand_u32()` (a probabilistic reaction, when one exists, now consumes draws that didn't used to happen) — this means simulation outcomes for a given seed differ from before this feature existed, which is expected and fine (any new draw-consuming behavior does this) — it does **not** mean outcomes become non-reproducible *for the current code version*.
- The current, only defined reaction (`WATER + DIRT`) has `probability == 1.0`, which is special-cased to skip the RNG draw entirely (see [Reaction Execution](#reaction-execution)) — so today's demonstration reaction doesn't perturb the RNG stream at all. The mechanism is still fully implemented and unit-tested in isolation (see [Testing Requirements](#testing-requirements)) so a future `probability < 1.0` reaction is a one-line table addition, not new code.

**CURRENT / IMPLEMENTED.**

---

## Current Reactions

**Decision:** the request's own suggested example, `WATER + LAVA → STONE`, is **not implementable today** — `LAVA` does not exist in `MaterialType`. The request itself flags this as only a suggestion ("if it fits the current material set") and explicitly warns against introducing a pile of new materials just to demonstrate the system.

**First choice, tried and rejected: `WATER + STONE → AIR + GRAVEL`.** This looked attractive on paper (zero new materials, reuses `STONE`'s existing mining-drop `GRAVEL`, exercises the LIQUID+STATIC asymmetric case) — but implementing and running it against the existing test suite surfaced a real architectural problem: **`STONE` is the codebase's de facto "generic inert floor/wall" material**, used as such in the overwhelming majority of existing tests (`test_water_falls_then_spreads`, every `test_activation_*`/`test_background_*` test, `terrain_gen.cpp`'s entire base layer under the dirt, ...). Making `STONE` reactive with `WATER` broke that assumption outright — `test_water_falls_then_spreads` (a **pre-existing**, unrelated test) started failing, because the water sitting on its `STONE` floor now erodes the floor instead of resting on it. Worse, the same effect in real generated terrain (`terrain_gen.cpp` places `STONE` as the base layer under `DIRT` everywhere) would mean any body of water ever reaching bedrock perpetually eats through the world's foundation — a large, unbounded, spreading consequence for what was supposed to be one small demonstration reaction. This was caught by actually running the test suite, not by inspection alone — a concrete instance of why [Performance](#performance)'s "measure, don't assume" spirit applies to correctness decisions too, not just performance ones.

**Chosen demonstration reaction: `WATER + DIRT → AIR + MUD`** (water soaking into dirt) — the request's *other* suggested example, needing exactly one new, minimal, STATIC material (`MUD`):

```cpp
{ MaterialType::WATER, MaterialType::DIRT, MaterialType::AIR, MaterialType::MUD, 1.0f }
```

Why this one:
- **Doesn't break the `STONE`-as-inert-floor assumption.** `DIRT` is comparatively rare as a "wall/floor" filler in the existing test suite (it shows up mostly in mining-specific tests, never adjacent to `WATER`), so making it reactive doesn't retroactively invalidate anything already built. `STONE` remains fully inert and safe to use as filler everywhere, including in this feature's own tests.
- **Bounded in real terrain, too.** In `terrain_gen.cpp`, `DIRT` is only the thin surface layer above the `STONE` base — water reacting with it affects a shallow, self-limiting layer (surface dirt near a body of water), not the world's foundation.
- **`MUD` is `MovementBehavior::STATIC`** (`core/material.cpp`, mirroring `DIRT`) — deliberately so: a STATIC product can never attempt movement, which sidesteps an entire class of scan-order-dependent "did the product get a same-pass movement turn or not" subtlety that a POWDER product (like `GRAVEL` would have been) introduces. This made the reaction's own tests significantly simpler and more robust to write correctly.
- **Exercises the full mechanism.** `DIRT` is `MovementBehavior::STATIC` (passive-neighbor path) while `WATER` is `LIQUID` (active-anchor path) — this is exactly the asymmetric case [Simulation Integration](#simulation-integration) is built around, not the easy same-behavior case.
- **Given explicitly by the request itself** as a plausible example ("Például később: ... WATER + DIRT → MUD"), so adding this one material is squarely within what the request anticipated, not a speculative addition.

**`MUD`'s data row** (`core/material.cpp`): STATIC, solid, `can_be_mined = true` with `mined_drop = AIR` (mines away cleanly, no further conversion), `is_mining_drop = false`. That last field is worth spelling out: `is_mining_drop` means "exists only as a **mining**-drop product" (see PLAYER_COLLISION.md) — `MUD` exists only as a **reaction**-drop product, a related but distinct origin that the field was never meant to cover. This is a deliberate, correct non-match, not a gap — see [Architectural Invariants](#architectural-invariants).

**CURRENT / IMPLEMENTED.**

---

## Architectural Invariants

Things that must remain true about this system:

- Reaction metadata (`ReactionDefinition`) is static, per-*material-pair* data (`core/reaction.cpp`), never per-`Cell` state. `Cell` stays 2 bytes.
- Exactly one table entry defines a reaction for both `A+B` and `B+A` orderings — never two entries for the same pair.
- No hardcoded material-pair branching (`if (a == WATER && b == DIRT)`) anywhere in `World::step()`, the solvers, or reaction execution code — every decision goes through `find_reaction()` against the table.
- Reaction detection only runs for cells `World::step()` was already visiting for movement dispatch (POWDER/LIQUID, awake chunk, not yet updated this pass) — never an additional scan.
- Reaction execution writes exclusively through `World::set_cell()` — never direct `Chunk`/`Cell` mutation — so it automatically and correctly inherits activation/wake behavior with no reaction-specific wake code.
- The Background layer is structurally unreachable from reaction code (different type, never referenced).
- A cell reacts at most once per pass (`FLAG_REACTED_THIS_STEP`), making same-pass chain/infinite-loop scenarios impossible by construction, not just unlikely.
- Probability, when used, is sourced exclusively from `World::rand_u32()` — no second RNG.
- `is_mining_drop` keeps its existing, narrower meaning ("exists only as a **mining**-drop product") and is never redefined or stretched to also mean "any non-terrain-gen origin" — a reaction product like `MUD` is legitimately `is_mining_drop = false` even though terrain generation never places it either (see [Current Reactions](#current-reactions)).

---

## DO NOT CHANGE WITHOUT AN EXPLICIT ARCHITECTURAL DECISION

- **Do not make `ReactionDefinition` or any reaction table per-`Cell` state.** It must stay a static, type-indexed table. `Cell` must stay 2 bytes.
- **Do not hardcode any material pair as an `if`/`switch` anywhere outside `core/reaction.cpp`'s table.** New reactions are table rows, not new branches.
- **Do not add a second reaction-detection scan/phase.** Detection must continue to piggyback on the existing `World::step()` per-cell loop for POWDER/LIQUID cells — never a dedicated full-grid or full-chunk reaction pass.
- **Do not let a reaction bypass `set_cell()`/`swap_cells()`.** Any new reaction-effect code must write through those primitives to keep activation/wake correct for free.
- **Do not add a reaction-specific wake/activation mechanism.** SIMULATION_ACTIVATION.md's existing mechanism, triggered automatically by `set_cell()`, is the only wake path this feature may use.
- **Do not let reactions read or write `BackgroundType`/`Chunk::background` in any way.** Background stays fully unreachable from this feature.
- **Do not remove or weaken the `FLAG_REACTED_THIS_STEP` same-pass guard** without an explicit decision — it's what makes same-pass infinite loops structurally impossible, not merely unlikely.
- **Do not introduce a second RNG** for reaction probability. `World::rand_u32()` only.
- **Do not process `STATIC`/`NONE`-behavior cells as reaction anchors** (i.e. do not give them their own `try_react()` visit) without an explicit decision — this is a deliberate performance/scope boundary (see [Simulation Integration](#simulation-integration)), not an oversight. If a future reaction genuinely needs two `STATIC` reactants, that needs a new, explicitly-designed detection trigger (most likely keyed off activation/wake, not "visit every static cell every pass") — this document must be updated as part of that decision, not worked around silently.
- **Do not implement multi-step recursive chain resolution within one pass.** Chains must continue to resolve one hop per pass via the normal simulation cycle, exactly as [Infinite-Loop / Same-Pass Protection](#infinite-loop--same-pass-protection) describes.

---

## Future Extensions

**FUTURE / OPTIONAL — none of this is decided architecture:**
- More reaction rows (`FIRE + WOOD → ...`, `WATER + LAVA → STONE` once/if `LAVA` and any needed new `MovementBehavior` exist, etc.) — pure data additions to `REACTION_TABLE` once the materials they need exist.
- Reactions with genuinely probabilistic outcomes (`probability < 1.0`) — the mechanism (`roll_reaction_probability`) is implemented and unit-tested today; no reaction currently uses a non-1.0 value.
- `STATIC`+`STATIC` reaction detection (see the corresponding DO NOT CHANGE entry above) — would need a new, deliberately-designed trigger, most likely tied to activation/wake rather than per-pass scanning of static cells.
- A hash-map or indexed lookup for `REACTION_TABLE` if the number of defined reactions ever grows large enough for the linear scan to matter (not needed at today's table size).
- Additional reaction effects beyond a two-cell material swap (spawning a third cell, e.g. steam/smoke) — out of scope; the current model is strictly "two adjacent cells transform into two cells at the same two positions."

---

## Testing Requirements

Standalone tests (`tests/test_core.cpp`, no Godot dependency) required for this feature:

1. **A+B adjacency:** `WATER` directly left of `DIRT` → reaction fires, `WATER` cell becomes `AIR`, `DIRT` cell becomes `MUD`.
2. **B+A adjacency:** `DIRT` directly left of `WATER` (swapped order) → same result, proving table-order independence. Additionally proven directly at the `find_reaction()` level (both argument orders), which is the definitive check since `DIRT` can never itself be an anchor (STATIC).
3. **Non-adjacent, no reaction:** `WATER` and `DIRT` two cells apart (not touching, `WATER` fully boxed by inert `STONE`) → neither cell changes.
4. **No matching definition:** `SAND` next to `IRON_ORE` (no table entry) → neither cell changes, no crash.
5. **Correct cell mutation:** after a fired reaction, exact material values at both coordinates match `result_a`/`result_b` (not swapped, not left stale).
6. **Product is a real, simulated cell:** place `SAND` directly above the `WATER` cell before the reaction fires; after the reaction turns that `WATER` cell to `AIR`, run further steps and confirm the `SAND` falls into the newly-`AIR` position — proving the product isn't a dead/special placeholder.
7. **Chunk boundary:** `WATER`/`DIRT` pair straddling a chunk boundary (one cell in each chunk) reacts correctly, and both chunks individually wake/mark dirty.
8. **Sleeping/wake compatibility:** a `WATER`/`DIRT` pair placed into a previously-asleep, far-from-anything region wakes its chunk(s) via the normal `set_cell` path, the reaction fires, and the chunk returns to sleep afterward once stable (no permanent activation).
9. **Background exclusion:** background values set near/under a reacting `WATER`/`DIRT` pair are completely unchanged after the reaction executes.
10. **Mining regression:** existing mining/drop-ratio behavior (`DIRT`→`SAND`, `STONE`→`GRAVEL` at their configured ratios) is unaffected by the presence of reaction code.
11. **No full-world scan:** in a large, mostly-stable world (STONE fill, safely inert to this reaction) with one small `WATER`/`DIRT` region, `active_chunks` after stepping stays bounded to the affected area, not the whole world.
12. **Determinism:** two `World` instances constructed with the same seed, given the same sequence of placements and `step()` calls, produce identical resulting grids.
13. **Same-pass loop protection:** `WATER` between two `DIRT` cells (`DIRT-WATER-DIRT`) reacts with at most one side in a single pass (the other `DIRT` is unaffected that pass); symmetrically, `DIRT` between two `WATER` cells (boxed in inert `STONE` so the un-reacted `WATER` can't drift away) reacts with at most one `WATER`.
14. **Probability mechanism (unit-level):** `roll_reaction_probability(rand_value, probability)` tested directly against fixed `rand_value`/`probability` pairs (always-true at `probability >= 1.0` without needing a real RNG draw, always-false at `probability <= 0.0`, correct boundary behavior in between) — proving the mechanism is sound and ready for a future non-1.0 table entry without requiring one to exist yet.

**PERFORMANCE REQUIREMENT.** After implementation, the existing stress-test harness (`stress_test.gd` / `run_stress_test`) must be re-run comparing: (a) the baseline with zero reaction-capable materials present, (b) a scenario with a small number of `WATER`/`DIRT` reactions actively occurring, (c) a scenario with many simultaneous reactions occurring — recording `sim_ms`, max `sim_ms`, `active_chunks`, `reaction_checks`, and `reactions_executed` for each, to confirm reaction detection cost tracks active-cell count, not world size, and does not regress the pre-existing baseline.

---

## How Future Work Should Use This Document

1. Read this document before adding a new reaction, before touching `World::step()`'s per-cell branch, or before touching `Cell::flags`.
2. A new reaction is a new row in `core/reaction.cpp`'s `REACTION_TABLE` — nothing else should need to change for a same-shape reaction (two existing materials, two existing result materials).
3. A new reaction that needs a **new material** follows the existing append-only `MaterialType`/`MATERIAL_TABLE` extension pattern (PROJECT_ARCHITECTURE.md §8) — add the material first, then the reaction row.
4. Preserve the [Architectural Invariants](#architectural-invariants) and everything in [DO NOT CHANGE WITHOUT AN EXPLICIT ARCHITECTURAL DECISION](#do-not-change-without-an-explicit-architectural-decision).
5. Re-run both the standalone test suite and the stress-test harness after any change here (see [Testing Requirements](#testing-requirements)) before considering the change complete.
6. If this document and the code ever disagree, that's a bug in one of them — fix the drift, don't silently pick one.
