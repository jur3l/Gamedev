# Player Collision

Technical reference for player-vs-terrain collision, and specifically for the configurable mining-drop collision toggle added in this feature. See [PLAYER_MOVEMENT.md](PLAYER_MOVEMENT.md) for the surrounding movement/step-up system this document assumes and does not repeat, [TERRAIN_LAYERS.md](TERRAIN_LAYERS.md) for the Background/Foreground model, and [PROJECT_ARCHITECTURE.md](PROJECT_ARCHITECTURE.md) for the material table this feature extends.

---

## Current Player Collision Architecture

Unchanged by this feature, restated from PLAYER_MOVEMENT.md for context: the player (`Player`, a `CharacterBody2D`) does not use Godot Physics against the terrain. `_rect_blocked()`/`_is_blocking()` in `player.gd` are the sole collision primitives, querying the live simulation grid via `PixelSimWorld.get_cell()` every time. There is still no per-cell Node, no `PhysicsBody2D`/`CollisionShape2D` for terrain, and no second/cached collision representation - this feature only changes what `_is_blocking()` decides for one category of foreground material, nothing about how the query itself works.

---

## Foreground Collision

Unchanged in the general case. For any foreground material that is **not** a mining-drop material (see below), `_is_blocking()` behaves exactly as before this feature: anything other than `AIR`/`WATER` blocks the player, unconditionally. `STONE`, `DIRT`, ore, `WOOD`, `METAL` - normal terrain and player-built blocks - all still collide exactly as they did prior to this feature, regardless of `mined_drop_collision`'s value.

---

## Background Collision

Unchanged, and not touched by this feature at all: `_rect_blocked`/`_is_blocking` only ever call `PixelSimWorld.get_cell()` (foreground). There has never been a code path in `player.gd` that reads `get_background()`. The Background layer was non-collidable before this feature and remains so - this is an existing property of the collision code, not something this feature needed to add or guard.

---

## Mining Drop Collision

**CURRENT / IMPLEMENTED.** A configurable exception to [Foreground Collision](#foreground-collision), for exactly the materials that exist only as a mining-drop product in the current game content: `SAND` (dropped by mining `DIRT`) and `GRAVEL` (dropped by mining `STONE`) - see PROJECT_ARCHITECTURE.md §8's material table.

### How a mining-drop material is identified

**Not per-cell state.** A new field, `MaterialDef::is_mining_drop` (`core/material.h`/`material.cpp`), classifies this **per material type** - one bit per row in the existing `MATERIAL_TABLE` (10 materials total), exactly like `is_solid`/`is_liquid`/`can_be_mined` already do. `Cell` itself (PROJECT_ARCHITECTURE.md §5, TERRAIN_LAYERS.md §Data-Model) was **not** touched and remains a 2-byte POD - there is no new per-cell memory, for the same reason the Background layer avoided growing `Cell`: the grid can hold millions of cells, and this classification is a property of *what material a cell holds*, not of the individual cell.

```cpp
// material.cpp - MATERIAL_TABLE, relevant column added:
// SAND:   is_mining_drop = true
// GRAVEL: is_mining_drop = true
// everything else: is_mining_drop = false
```

Exposed to GDScript as `PixelSimWorld.is_mining_drop_material(material_id) -> bool`, a thin wrapper around `MaterialDef::is_mining_drop` (same pattern as the existing `get_material_name`).

### Why type-based classification is correct here

`SAND` and `GRAVEL` are **never** placed by terrain generation (`gen/terrain_gen.cpp` only ever writes `AIR`/`DIRT`/`STONE`/ore) and are never placed by building (`place_cell` is only ever called with `WOOD`/`METAL` from `mining_building.gd`). The *only* way a `SAND` or `GRAVEL` cell comes into existence in the current game is `World::mine_area`'s drop mechanism (or the stress-test harness explicitly spawning `SAND` for load-testing, which is the same material and reasonably behaves the same way for collision purposes). So today, "this cell's material is `SAND`/`GRAVEL`" and "this cell is a mining-drop product" are exactly the same fact, and a type-level table flag captures it exactly, with no ambiguity and no per-cell tracking needed.

**This stops being exact only if a future material is both naturally placed by generation/building AND is also some other material's `mined_drop` target** - at that point `is_mining_drop` would over-classify (a naturally-placed instance would still be treated as collision-configurable). That is a real, known limitation of the type-based approach - see [Architectural Invariants](#architectural-invariants) for what to do if that ever happens. It does not exist in the current game content.

### The `mined_drop_collision` config

```gdscript
@export var mined_drop_collision: bool = false
```

Note: this was implemented with a default of `true` (matching pre-existing collision behavior exactly, see [Files Changed](#files-changed)); the project has since been reconfigured to ship with `false` as the live default. Both are valid values of the same toggle — nothing about the mechanism differs based on which one is current. Always check `scripts/player.gd` for the value actually in effect rather than trusting a hardcoded number in this document.

Lives on `Player` (`scripts/player.gd`), immediately alongside `player_step_height_cells` - the same established pattern for a per-node, designer-tunable value (PLAYER_MOVEMENT.md "Configuration"). No new configuration system was introduced.

### Collision decision

```gdscript
func _is_blocking(cell_x, cell_y) -> bool:
    var mat = sim_world.get_cell(cell_x, cell_y)
    if mat == MATERIAL_AIR or mat == MATERIAL_WATER:
        return false
    if sim_world.is_mining_drop_material(mat):
        return mined_drop_collision
    return true   # normal foreground material - existing, unconditional rule
```

```
collision query for a foreground cell
    |
AIR or WATER?  -----------------------------------------> not blocking (unchanged)
    |
is_mining_drop_material(material)?
    |                                   \
   no                                    yes
    |                                     |
blocking (existing, unconditional    blocking = mined_drop_collision
rule - unchanged for STONE/DIRT/          (true -> blocks, false -> doesn't)
ore/WOOD/METAL)
```

`mined_drop_collision = true`: `SAND`/`GRAVEL` block the player exactly like any other solid foreground material (the pre-this-feature behavior).
`mined_drop_collision = false`: `SAND`/`GRAVEL` are skipped by `_is_blocking` (treated as non-blocking, the same branch `AIR`/`WATER` take) - the player passes through them - while the cell itself is completely unaffected: still real foreground data, still simulated, still rendered. **This is the current live default** - see the note in [The `mined_drop_collision` config](#the-mined_drop_collision-config).

---

## Coordinate / Query Behavior

No change from PLAYER_MOVEMENT.md: collision is still queried in simulation-cell coordinates (`floor(pixel / simulation_cell_size)`), against the live grid, for the player's full `PLAYER_SIZE` bounding box, via the same `_rect_blocked` used by both the flat horizontal/vertical collision loops and the step-up system. `mined_drop_collision` is read fresh on every `_is_blocking` call (no caching), so toggling it at runtime takes effect on the very next collision check - no state to invalidate.

---

## Performance Considerations

`is_mining_drop_material` is a single array-index-and-field-read in C++ (`get_material_def(material).is_mining_drop`), the same cost class as the already-existing `get_material_name` call. It is invoked once per candidate cell inside `_rect_blocked`'s existing per-cell scan - no new scan, no new query granularity, no per-frame cost when nothing changed. The classification table itself is the existing `static constexpr MATERIAL_TABLE` (10 rows) - this feature adds one `bool` per row, not a new data structure.

---

## Architectural Invariants

- Mining-drop collision classification lives on `MaterialDef` (per material type), never on `Cell` (per cell instance).
- `mined_drop_collision` only affects materials where `is_mining_drop == true` (`SAND`, `GRAVEL` today). Every other foreground material's collision is unconditional and unchanged.
- The Background layer remains non-collidable, unconditionally - `mined_drop_collision` has no effect on it and never will, since `player.gd` never queries `get_background()`.
- Toggling `mined_drop_collision` never changes simulation behavior: it is read only inside `player.gd`'s collision query, never by `World::step()`, the solvers, `swap_cells`, mining, or the drop-ratio system. A `SAND`/`GRAVEL` cell falls, stabilizes, wakes/sleeps its chunk, and renders identically regardless of this setting.

### DO NOT CHANGE WITHOUT AN EXPLICIT ARCHITECTURAL DECISION

**WHAT:** Mining-drop collision state is classified per material type (`MaterialDef.is_mining_drop`), not per cell.
**WHY:** Explicit project requirement - `Cell` is a 2-byte, performance-critical, multi-million-instance structure (PROJECT_ARCHITECTURE.md §5/§14), and today's game content makes "material is SAND/GRAVEL" exactly equivalent to "cell is a mining drop" (see [Why type-based classification is correct here](#why-type-based-classification-is-correct-here)).
**WHEN CAN IT CHANGE:** Only if a future material becomes both naturally-placed (by generation/building) *and* someone's `mined_drop` target - at that point type-based classification would over-broadly apply to naturally-placed instances too, and a real per-cell (or per-placement-source) distinction would need its own explicit design, not a quiet extension of this table flag.

**WHAT:** `mined_drop_collision` must never be read by the simulation core (`World`, `Chunk`, solvers, mining/drop code).
**WHY:** Keeps collision a purely player-side concern, exactly like the rest of `player.gd`'s collision code already is (PLAYER_MOVEMENT.md's own invariant) - the simulation must stay unaware that "collision" is even a concept.
**WHEN CAN IT CHANGE:** Not without revisiting the player/simulation separation invariant these documents all share.

**WHAT:** The Background layer stays non-collidable.
**WHY:** Explicit scope boundary - this feature is only about foreground mining-drop materials.
**WHEN CAN IT CHANGE:** Only via its own explicit decision (also noted as a `TERRAIN_LAYERS.md` future extension), not as a side effect of this one.

**WHAT:** No new physics body/collision shape system, no per-cell collider, no per-cell `Cell` state - the existing `_rect_blocked`/`get_cell` query remains the only terrain collision mechanism.
**WHY:** Consistent, repeated project-wide rule (PROJECT_ARCHITECTURE.md §13/§14, PLAYER_MOVEMENT.md's own DO-NOT-CHANGE section).
**WHEN CAN IT CHANGE:** Only alongside a much broader, explicitly-decided change to how terrain collision works in general.

---

## Testing

`MaterialDef.is_mining_drop` is pure data and is covered by the standalone, engine-agnostic `tests/test_core.cpp` suite (confirms `SAND`/`GRAVEL` are classified `true` and every other material is `false`). The actual `player.gd` collision behavior is Godot-dependent GDScript and was verified live in the running editor (same approach as PLAYER_MOVEMENT.md), covering:

1. `mined_drop_collision = true` - a `GRAVEL` wall blocks the player.
2. `mined_drop_collision = false` - the same `GRAVEL` wall does not block the player.
3. `GRAVEL` remains a real simulation cell in both cases (`get_cell` unaffected by the collision setting).
4. `GRAVEL` still falls under gravity in both cases (collision setting has no bearing on simulation).
5. Normal `STONE` terrain collision is unchanged regardless of `mined_drop_collision`.
6. The Background layer remains non-collidable.
7. Toggling the config does not alter solver behavior (regression guard alongside 3/4).
8. The player still cannot pass through normal solid foreground terrain.

---

## Files Changed

- `addons/pixelsim/src/core/material.h`/`.cpp` - `MaterialDef.is_mining_drop` field and table values.
- `addons/pixelsim/src/sim_world_node.h`/`.cpp` - `PixelSimWorld.is_mining_drop_material()`.
- `scripts/player.gd` - `mined_drop_collision` export and the updated `_is_blocking()` branch.

No other file was modified for this feature - the Background/Foreground architecture, the Cellular Automata simulation, the Sand/Water/gravity solvers, the mining drop-ratio system, and the chunk sleeping/activation system are all untouched.
