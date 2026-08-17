# Materials

Source of truth for PixelSim's material content — what each `MaterialType` row in `core/material.cpp`'s `MATERIAL_TABLE` actually does, and how the materials interact as one small ecosystem. This is a **content** document, not an architecture one: it does not redefine any mechanism. For the mechanisms themselves (the `MaterialDef` schema, solver dispatch, mining, activation, reactions), see [PROJECT_ARCHITECTURE.md](PROJECT_ARCHITECTURE.md) and its companions — [MATERIAL_REACTIONS.md](MATERIAL_REACTIONS.md) in particular, since most of what makes DIRT/SAND/STONE/GRAVEL/WATER/LAVA a genuine *ecosystem* rather than six unrelated table rows is that system.

**Status:** CURRENT — matches `core/material.cpp` / `core/reaction.cpp` as built. If this document and the code ever disagree, the code wins; treat the drift as a bug in this document.

---

## Scope: the core ecosystem

This document's focus is the six-material set the project deliberately kept small so the *interactions* between materials, not the count of materials, would be the demonstration:

```
DIRT, SAND, STONE, GRAVEL   (solid / powder side)
WATER, LAVA                 (liquid side)
```

Every one of these already existed in `MaterialType` except `LAVA`, which this feature adds — the only genuinely new material. `MUD` (a reaction product, not part of the core six) and the pre-existing IRON_ORE/COPPER_ORE/WOOD/METAL are documented in the [Current Material Table](#current-material-table) for completeness, since they share the same table and the same mechanisms, but they are not this ecosystem's focus.

No new `MovementBehavior`, no new per-cell state, and no new solver were added to build this — LAVA is `MovementBehavior::LIQUID` and runs through the exact same `solve_liquid()` WATER does (see [Liquid Materials](#liquid-materials)); the WATER+LAVA interaction is one more row in the existing reaction table (see [Reactions](#reactions)), not new solver code.

---

## Material Categories

Every material's simulated behavior is fully determined by its `MovementBehavior` (`core/material.h`), which every solver dispatches on — never a specific `MaterialType`:

| `MovementBehavior` | Meaning | Ecosystem members |
|---|---|---|
| `NONE` | Nothing to simulate | AIR |
| `STATIC` | Immovable; only removable via mining | DIRT, STONE (also: IRON_ORE, COPPER_ORE, WOOD, METAL, MUD) |
| `POWDER` | Falls straight down, then diagonally | SAND, GRAVEL |
| `LIQUID` | Falls straight down, then diagonally, then spreads sideways | WATER, LAVA |

Adding LAVA required zero new categories: it reuses `LIQUID` verbatim.

---

## Solid Materials

**DIRT** and **STONE** are the ecosystem's `STATIC` terrain. Neither moves, ever — the only way either changes is mining (or, for STONE, the WATER+LAVA reaction product — see [Reactions](#reactions)). They are the "walls/floor" that give SAND, GRAVEL, WATER, and LAVA something to rest on, pool in, or sink through.

STONE remains the codebase's inert-floor material by design: it is not itself a reactant with either WATER or LAVA (only the *combination* WATER+LAVA produces STONE — STONE never breaks down again once formed), so building a test scenario or a real terrain layer around a STONE floor/wall stays safe regardless of what liquid touches it.

---

## Powder Materials

**SAND** and **GRAVEL** are `POWDER`: each simulation pass, a powder cell tries straight down, then one randomized diagonal-down direction, then the other (`solve_powder`, `solvers.cpp`) — never sideways on its own row. They are also this ecosystem's **mining drops**: SAND only ever enters the world as a DIRT-mining drop, GRAVEL only as a STONE-mining drop (see [Mining](#mining)) — neither is placed by terrain generation, and neither is itself re-minable (`can_be_mined = false`), which is what prevents an infinite DIRT→SAND→(mine again)→SAND loop.

What this feature adds to their story is not new powder behavior but new *neighbors*: SAND and GRAVEL now have a LIQUID (WATER, and — via density alone, since LAVA never displaces or is displaced by a powder differently than WATER is — LAVA too) to physically interact with via density-based displacement (see [Density](#density)), not just STONE walls and each other.

---

## Liquid Materials

**WATER** and **LAVA** are both `MovementBehavior::LIQUID` and run through the identical `solve_liquid()` (`solvers/solvers.cpp`): straight down, then diagonal-down (randomized tie-break), then sideways one cell toward whichever side is open. There is no `solve_water()`/`solve_lava()` split, and none was added for this feature — see [PROJECT_ARCHITECTURE.md §4](PROJECT_ARCHITECTURE.md#4-simulation-core) "Cellular Automata / movement / gravity" for the shared mechanism, unchanged by LAVA's addition.

Everything that makes LAVA feel different from WATER in play comes from **data**, not code:
- **Density** (3.2 vs. 1.0) — see [Density](#density) for what this actually changes (nothing sinks through LAVA; LAVA never displaces or is displaced by any powder).
- **Reaction with each other** (`WATER + LAVA → AIR + STONE`) — see [Reactions](#reactions).
- **Color/alpha** — WATER renders as a translucent blue (`60,120,220,180`), LAVA as an opaque orange-red (`230,70,20,255`); see [Rendering](#rendering).

Two LIQUID materials never physically displace one another (`material_can_displace` requires the mover to be *non*-liquid to displace into a liquid target — see [Density](#density)), so WATER and LAVA sitting side by side do not swap positions or mix by simple contact. Their only interaction mechanism is the reaction system.

---

## Material Properties

Every material is one row in `MaterialDef` (`core/material.h`) — see [PROJECT_ARCHITECTURE.md §8](PROJECT_ARCHITECTURE.md#8-material-system) for the authoritative field-by-field description. No field was added or changed shape for this feature; LAVA and the WATER+LAVA reaction are expressed entirely with the *existing* schema (`behavior`, `density`, the mining triplet, color, `is_mining_drop`) plus the *existing* `ReactionDefinition` schema (`core/reaction.h`) for the reaction itself. This is exactly what [PROJECT_ARCHITECTURE.md §8](PROJECT_ARCHITECTURE.md#8-material-system) predicted future materials like this would need: "anything expressible as a name + behavior + density + color + `can_be_mined`/`mined_drop`/`drop_ratio`/`is_mining_drop` set."

---

## Density

`density` (a `float` on `MaterialDef`) drives exactly one mechanism, `material_can_displace()` (`core/material.cpp`):

```cpp
bool material_can_displace(MaterialType mover, MaterialType target) {
    if (target == AIR) return true;
    // A movable material can push into a lower-density liquid it can sink
    // through, but never into anything solid/static:
    if (target.is_liquid && !mover.is_liquid && mover.density > target.density)
        return true;
    return false;
}
```

Ecosystem densities, in order:

```
WATER (1.0) < SAND (1.6) < GRAVEL (1.9) < STONE (2.6) < LAVA (3.2)
```

This is **not** real-world lava density — it is a deliberately chosen gameplay/simulation property (see the comment on LAVA's row in `material.cpp`). The chosen value (higher than every other material, including STONE) was picked for a specific, testable consequence: **nothing in this ecosystem sinks through LAVA.** SAND/GRAVEL rest *on top of* LAVA exactly like they would on STONE, because `can_displace`'s `mover.density > target.density` check only ever matters when the *target* `is_liquid` — and no POWDER material here is denser than LAVA's 3.2. Contrast with WATER (1.0), which both SAND (1.6) and GRAVEL (1.9) sink through.

What density does and does not explain here:
- **SAND/GRAVEL vs. WATER:** SAND and GRAVEL both displace into WATER (denser powder into less-dense liquid) — this is a **physical interaction** (a `swap_cells()` in the solver), not a reaction. No `WATER`+`SAND` row exists in `REACTION_TABLE`, and none should — see [MATERIAL_REACTIONS.md](MATERIAL_REACTIONS.md) "Physical interaction" vs. "Chemical/Reaction interaction" for why these two kinds of interaction are deliberately not conflated.
- **SAND/GRAVEL vs. LAVA:** density alone (LAVA is the densest thing in the table) means neither SAND nor GRAVEL ever sinks into LAVA — they simply rest on it, the same "solid floor under a movable" shape as resting on STONE.
- **WATER vs. LAVA:** both `is_liquid`, so `material_can_displace` never returns true either direction between them (the `!mover_def.is_liquid` guard excludes liquid-into-liquid displacement categorically) — they never physically swap. Their only interaction is the reaction system (see [Reactions](#reactions)), which is unrelated to density and would fire even if their densities were reversed or equal.

---

## Mining

Mining is unchanged by this feature — see [PROJECT_ARCHITECTURE.md §9](PROJECT_ARCHITECTURE.md#9-mining-system) for the full two-pass mechanism (`World::mine_area`). What's relevant to this ecosystem:

- **DIRT** and **STONE** are the ecosystem's minable terrain (`can_be_mined = true`).
- **WATER** and **LAVA** are also `can_be_mined = true`, with `mined_drop = AIR` — "mining" a liquid just clears it (the same "just remove it" path AIR-dropping materials like IRON_ORE already use), matching the existing precedent rather than inventing a new "drain" concept.
- **SAND** and **GRAVEL** are `can_be_mined = false` — they are themselves mining *products*; see [Drops](#drops).

No mining code changed for this feature — LAVA's row simply participates in the exact same `MATERIAL_TABLE`-driven selection/conversion pass everything else does. `test_mining_regression_with_lava_present` in the standalone suite exists specifically to confirm `MATERIAL_COUNT` growing by one (for LAVA) doesn't silently break any `MATERIAL_COUNT`-sized array the mining code depends on (`MineResult::counts[]`, the per-material `mining_remainder_[]`).

---

## Drops

Two drop mappings exist in this ecosystem, both pre-existing and unmodified by this feature:

```
DIRT  --mining--> SAND    (drop_ratio 0.5)
STONE --mining--> GRAVEL  (drop_ratio 0.5)
```

The drop is a real, simulated `POWDER` cell the instant it's placed — not a particle or visual effect — and immediately falls/settles under the same `solve_powder` every other SAND/GRAVEL cell uses. See [PROJECT_ARCHITECTURE.md §9](PROJECT_ARCHITECTURE.md#9-mining-system) for `drop_ratio`'s exact batch-quantity rounding behavior.

One more "drop" exists in the wider sense of "material produced by an action other than terrain generation": the WATER+LAVA **reaction** also produces STONE. This is deliberately *not* classified as a mining drop (`is_mining_drop` stays `false` on both STONE and MUD) — `is_mining_drop` means "exists only as a **mining**-drop product" specifically, a narrower concept than "any non-terrain-gen origin." See [Reactions](#reactions) and [MATERIAL_REACTIONS.md](MATERIAL_REACTIONS.md) "Current Reactions" for why this is a correct non-match, not a gap. (STONE is additionally *not* exclusively a reaction product the way MUD is — STONE is also placed by ordinary terrain generation, which is itself a further reason it could never honestly carry `is_mining_drop`.)

---

## Reactions

Two reactions exist in `REACTION_TABLE` (`core/reaction.cpp`), both `probability = 1.0` (guaranteed):

```
WATER + DIRT → AIR + MUD     (water soaking into dirt - the system's original demo reaction)
WATER + LAVA → AIR + STONE   (lava cooling/solidifying on contact with water)
```

**WATER + LAVA → AIR + STONE** is this feature's reaction. It was the originally-suggested demonstration reaction back when [MATERIAL_REACTIONS.md](MATERIAL_REACTIONS.md) was first implemented, deferred at the time only because LAVA didn't exist yet (that document's "Current Reactions" section explains the earlier `WATER + STONE` draft that *was* tried and rejected, for reference). Now that LAVA exists, this is exactly the shape that reaction system was built to support without any code change: one new row.

- WATER is consumed (`AIR`) — matching real-world intuition (the water boils away / is consumed cooling the lava) and avoiding the need for a STEAM material, which is explicitly out of scope for this feature (see [Not Implemented](#not-implemented-this-feature)).
- LAVA becomes STONE — matching the mining system's own STONE→GRAVEL precedent for "this material's presence implies STONE nearby," and giving the reaction product an immediately-useful identity (an inert floor cell) rather than a dead-end material.
- Reaction detection, matching, same-pass protection, chunk-boundary behavior, sleep/wake integration, and Background exclusion are **all** inherited unmodified from the existing mechanism — see [MATERIAL_REACTIONS.md](MATERIAL_REACTIONS.md) for the complete model. Nothing about *how* reactions work changed; only the table grew by one row.
- Because both WATER and LAVA are `LIQUID` (unlike the WATER+DIRT case, where DIRT is a passive `STATIC` neighbor), this reaction exercises a genuinely different code path: **either** side can be the anchor whose `World::step()` visit triggers the check, not just the liquid one. `test_water_lava_reaction_same_pass_protection` (standalone suite) confirms the same-pass guard (`FLAG_REACTED_THIS_STEP`) still caps this at exactly one reaction per pass regardless of which side's turn comes first (which itself depends on scan direction, alternating per pass) — and that the *other*, un-reacted LIQUID is free to take its own ordinary movement turn later in that same pass (e.g. flowing into the cell the reaction just vacated), since reaction and movement are mutually exclusive **per cell**, not a freeze on the rest of the row.

`material_is_reaction_capable()` correctly reports WATER, DIRT, and LAVA as reaction-capable (they appear as a `reactant_a`/`reactant_b` somewhere in the table) and MUD/STONE as *not* reaction-capable (they're only ever a `result`, never a reactant) — this is derived from the table, not a separate flag, so it can never drift out of sync with what actually reacts.

---

## Rendering

No renderer change was needed for LAVA — `get_chunk_pixels()` (C++) already looks up whatever `MaterialDef.color_r/g/b/a` a cell's material has, generically, for every material; LAVA's row simply supplies its own color like every other material does. See [PROJECT_ARCHITECTURE.md §10](PROJECT_ARCHITECTURE.md#10-rendering-architecture) for the full chunk-granular rendering pipeline, unchanged by this feature.

LAVA renders fully opaque (`alpha = 255`) and WATER stays translucent (`alpha = 180`, letting the Background layer's rock color show through it faintly) — a deliberate, purely visual distinction consistent with each material's real-world reading, using the color field's existing 4-channel range rather than any new rendering concept.

---

## Collision

Player collision is unchanged by this feature — see [PLAYER_COLLISION.md](PLAYER_COLLISION.md) / [PLAYER_MOVEMENT.md](PLAYER_MOVEMENT.md). LAVA and WATER both have `is_mining_drop = false` (correctly — neither is a mining-drop product), so the mining-drop collision toggle simply never applies to them, exactly as it never applied to WATER before this feature. No new collision category, no per-material collision special-casing was added: LAVA is, from the player collision system's point of view, an ordinary solid-for-collision-purposes foreground cell like STONE or WATER already are (the actual pass/block decision is unchanged and out of this feature's scope).

---

## Simulation Behavior

Summary of what's new vs. reused, for the whole ecosystem:

| Mechanism | New for this feature? | Notes |
|---|---|---|
| `MovementBehavior::LIQUID` dispatch | No | LAVA reuses it verbatim |
| `solve_liquid()` | No | Shared by WATER and LAVA, zero LAVA-specific branches |
| Density / displacement (`material_can_displace`) | No (mechanism); yes (LAVA's density value) | See [Density](#density) |
| Chunk sleep/wake/dirty | No | LAVA chunks sleep/wake exactly like any other material's — see `test_lava_sleep_wake` |
| Cross-chunk activation | No | `activate_affected_neighbors()` is material-agnostic |
| Chunk boundary handling | No | No special-case code exists anywhere for this; `test_lava_flows_sideways`-style and `test_water_lava_reaction_chunk_boundary` confirm it |
| Mining / drops | No | LAVA participates in the existing table-driven mine/drop pass unchanged |
| Reaction system | No (mechanism); yes (one new table row) | See [Reactions](#reactions) |
| Rendering | No | Generic per-material color lookup |
| Background layer | No | Structurally unreachable from LAVA/reactions, same as everything else |
| Player collision | No | LAVA is an ordinary solid-for-collision foreground cell |

**The point of this table is what it *doesn't* contain:** no row says "new solver," "new lifecycle," "new wake path," or "new collision category." Every mechanism this ecosystem relies on already existed; LAVA and the WATER+LAVA reaction are additions to the *data* those mechanisms already read (`MATERIAL_TABLE`, `REACTION_TABLE`), consistent with [PROJECT_ARCHITECTURE.md §18](PROJECT_ARCHITECTURE.md#18-development-rules)'s "prefer extending the existing architecture" rule.

---

## Performance

**Requirement (unchanged from [MATERIAL_REACTIONS.md](MATERIAL_REACTIONS.md)):** no full-world scan for reaction detection, and — new for this feature — no full-world simulation just because WATER/LAVA are present. Chunk sleep/wake stays the only thing that determines cost; `active_chunks` should track the *size of the active region*, never the world's total chunk count (1,344 in the default 48×28-chunk world).

**Measured** (standalone `World` API, same methodology as MATERIAL_REACTIONS.md's own table — `fill_rect`/`set_cell` placement, then repeated `world.step(1000.0)` calls run to full-pass completion, sampling `sim_ms`/`active_chunks`/`reaction_checks`/`reactions_executed`; default 1,344-chunk world):

| Scenario | avg sim ms | max sim ms | max active chunks | reaction checks | reactions executed | final active chunks |
|---|---:|---:|---:|---:|---:|---:|
| (a) Untouched world (nothing placed) | 0.146 | 0.260 | 0 | 0 | 0 | 0 |
| (b) Pre-existing set: 250k SAND falling (existing stress tier) | 14.83 | 16.75 | 144 | 10,000,000 | 0 | 144 |
| (c) New ecosystem: WATER+DIRT bed, 300× WATER+LAVA pairs, SAND/GRAVEL sinking through a WATER pool — everything else untouched | 0.48 | 0.85 | **52** | 221,692 | 625 | **11** |
| (d) New ecosystem at (b)'s scale: 250k SAND falling through a WATER pool | 15.66 | 24.91 | 144 | 16,013,760 | 0 | 96 |

What this confirms:
- **(a) vs. everything else:** an untouched world costs essentially nothing (0.146ms, 0 active chunks) — the sleeping baseline is intact.
- **(c) is the key result for this feature's own performance requirement:** despite three simultaneous WATER+LAVA/WATER+DIRT/density-displacement interactions running, `max_active_chunks` stayed at 52 of 1,344 (3.9% of the world) and settled to 11 within 60 passes — the active region tracked the *size of the reactive/liquid area*, not the world. This is the same shape of result MATERIAL_REACTIONS.md already established for WATER+DIRT alone (its scenario (c): 6 of 1,344 active chunks for 900 simultaneous reactions); this feature's own reactions and physical interactions preserve that property.
- **(b) vs. (d) is the fairest "old set vs. new set" comparison, at equal scale:** adding a WATER pool underneath 250,000 falling SAND cells (d) costs 15.66ms avg vs. 14.83ms for SAND alone (b) — a ~5.6% increase, not an order-of-magnitude regression — while `max_active_chunks` stayed identical (144) between the two. The liquid pool participating in density displacement with a quarter-million falling powder cells does not blow up simulation cost.
- **LAVA specifically never causes a full-world wake:** in scenario (c), the 300 WATER+LAVA pairs (600 LIQUID cells) contributed a small, bounded slice of the total 221,692 reaction checks and 625 executed reactions, consistent with [MATERIAL_REACTIONS.md](MATERIAL_REACTIONS.md)'s "Performance" requirement that reaction-detection cost scales with active-cell count, not world size or number of defined reactions.

These numbers use an unbounded `step()` budget (`1000.0` ms, always completes a full pass per call) to make the measurement itself deterministic and comparable — not the `simulation_budget_ms = 4.0` the game actually runs with. In the game, the same per-pass costs are simply spread across more `step_simulation()` calls (frames) rather than measured as one blocking call; the *relative* comparison between scenarios is what's meaningful here, matching how MATERIAL_REACTIONS.md's own table was produced.

---

## Not Implemented (this feature)

Explicitly out of scope, per the request that started this feature — none of the following exist, and none should be inferred from anything above:

- FIRE, SMOKE, STEAM, OIL, ACID, GAS materials.
- Temperature or pressure simulation.
- Combustion/flammability (`is_flammable_stub` remains reserved/unused).
- Viscosity, spread-rate, or any other new per-liquid tuning property — WATER and LAVA are distinguished entirely by `density` and by the reaction table, which was sufficient for every behavior this feature needed. A future liquid that genuinely can't be expressed that way would need a deliberate, documented property addition, not a speculative one now.
- MUD, STEAM, ASH, SMOKE, OIL, ACID as *placed/generated* content — MUD exists today only as the pre-existing WATER+DIRT reaction product; the rest don't exist in `MaterialType` at all yet.
- Terrain generation placing WATER or LAVA — `gen/terrain_gen.cpp` is unchanged; both liquids are currently introduced only via the player's build tool (`mining_building.gd`, keys `3`/`4`) or directly via `PixelSimWorld.place_cell`/`fill_rect` (e.g. from a test or a future terrain-gen pass), not automatically by generation.

---

## Current Material Table

Values sourced directly from `core/material.cpp`'s `MATERIAL_TABLE` (`MaterialDef` fields — see [PROJECT_ARCHITECTURE.md §8](PROJECT_ARCHITECTURE.md#8-material-system) for what each column means). "Movable" = `behavior` is `POWDER` or `LIQUID` (i.e. participates in `World::step()`'s movement dispatch at all). "Reaction-capable" = `material_is_reaction_capable()`, derived from `REACTION_TABLE`, not a separate flag.

| Material | Category | Density | Movable | Mineable | Drop | Drop ratio | Reaction-capable |
|---|---|---:|---|---|---|---:|---|
| AIR | — (NONE) | 0.0 | no | no | AIR | 1.0 | no |
| SAND | Powder | 1.6 | **yes** | no | AIR | 1.0 | no |
| DIRT | Solid (static) | 1.5 | no | **yes** | SAND | 0.5 | **yes** |
| STONE | Solid (static) | 2.6 | no | **yes** | GRAVEL | 0.5 | no |
| IRON_ORE | Solid (static) | 3.0 | no | yes | AIR | 1.0 | no |
| COPPER_ORE | Solid (static) | 2.9 | no | yes | AIR | 1.0 | no |
| WATER | Liquid | 1.0 | **yes** | yes | AIR | 1.0 | **yes** |
| WOOD | Solid (static) | 0.9 | no | yes | AIR | 1.0 | no |
| METAL | Solid (static) | 7.8 | no | yes | AIR | 1.0 | no |
| GRAVEL | Powder | 1.9 | **yes** | no | AIR | 1.0 | no |
| MUD | Solid (static) | 1.6 | no | yes | AIR | 1.0 | no |
| **LAVA** | **Liquid** | **3.2** | **yes** | **yes** | **AIR** | **1.0** | **yes** |

**Ecosystem members bolded in the "Movable"/"Mineable"/"Reaction-capable" sense that matters most for this feature:** SAND, GRAVEL, WATER, and **LAVA** move; DIRT, STONE, WATER, and **LAVA** are mineable; DIRT, WATER, and **LAVA** react.

---

## How Future Work Should Use This Document

1. Read this document (and [MATERIAL_REACTIONS.md](MATERIAL_REACTIONS.md)) before adding a new material or a new reaction — most new content needs a table row, not new code.
2. A new movable material that fits `POWDER`/`LIQUID` needs only a `MATERIAL_TABLE` row; a new reaction needs only a `REACTION_TABLE` row (plus the material row, if it's new). Neither should touch `World::step()`, the solvers, or reaction-detection code — see [PROJECT_ARCHITECTURE.md §18](PROJECT_ARCHITECTURE.md#18-development-rules).
3. If a new material genuinely needs a new *kind* of behavior (temperature, pressure, gas-rises-instead-of-falls, flammability), that's a new `MovementBehavior` and solver — an explicit, larger architectural decision, not something to shoehorn into `POWDER`/`LIQUID`. Say so explicitly rather than working around it.
4. Keep the [Current Material Table](#current-material-table) in sync with `material.cpp` — pull values from the code, never invent them.
5. If this document and the code ever disagree, that's a bug in one of them — fix the drift, don't silently pick one.
