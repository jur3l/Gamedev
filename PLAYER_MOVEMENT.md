# Player Movement

Technical reference for the player movement/collision system in `scripts/player.gd`. Written against the actual code, not an idealized design. See [PROJECT_ARCHITECTURE.md](PROJECT_ARCHITECTURE.md) for how the player fits into the wider project (it is explicitly **not** part of the simulation core or the `World`/`Chunk`/`Cell` grid), and [PLAYER_COLLISION.md](PLAYER_COLLISION.md) for the configurable mining-drop collision toggle layered on top of the collision query documented here.

---

## Current Movement Architecture

The player (`Player`, a `CharacterBody2D`) does **not** use Godot's physics/collision system against the terrain. There are no `PhysicsBody2D`/`CollisionShape2D`/`Area2D` terrain colliders anywhere — the terrain is `PixelSimWorld`/`World` grid data, not physics bodies (see PROJECT_ARCHITECTURE.md §13/§14). `CharacterBody2D` is used purely as a convenient Node2D-derived class with a `position`; its built-in `move_and_slide()`/collision system is never called.

Instead, `player.gd` implements its own small kinematic controller entirely in `_physics_process`/`_move_and_collide`:
1. Gravity is integrated manually into `velocity_v.y` (a plain `Vector2`, not Godot's physics velocity).
2. Horizontal input (`move_left`/`move_right` actions) sets `velocity_v.x` directly (instant, no acceleration curve).
3. `_move_and_collide(delta)` resolves both axes by **stepping position 1 pixel at a time** and checking each candidate position against the terrain grid via `_rect_blocked()`, stopping at the last unblocked position - this is what prevents tunneling through thin walls at any speed.

`position` is the player's **center** (not top-left) - every place this file converts to a bounding box does `position ± PLAYER_SIZE * 0.5`.

---

## Collision

`_rect_blocked(top_left: Vector2) -> bool` is the single collision primitive everything in this file is built on: given a candidate top-left corner, it converts the `PLAYER_SIZE` bounding box to a cell-coordinate range (`floor(pixel / simulation_cell_size)`) and asks `PixelSimWorld.get_cell()` whether any covered cell is blocking, via `_is_blocking()`. This document's own feature (step-up) only ever calls `_rect_blocked` — it has no opinion on what counts as "blocking" beyond that.

**Note:** `_is_blocking()`'s definition of "blocking" was originally just `!= AIR && != WATER`, unconditionally. [PLAYER_COLLISION.md](PLAYER_COLLISION.md) (a later, separate feature) extended it with a configurable exception for mining-drop materials (`SAND`/`GRAVEL`) — see that document for the current, authoritative version of `_is_blocking()` and the `mined_drop_collision` toggle. The snippet below is simplified/historical, kept only to illustrate the general shape (query the grid, treat `AIR`/`WATER` as passable) that both this document's step-up system and PLAYER_COLLISION.md's toggle build on:

```gdscript
# Simplified - see PLAYER_COLLISION.md for the actual current version.
func _is_blocking(cell_x, cell_y) -> bool:
    var mat = sim_world.get_cell(cell_x, cell_y)
    return mat != MATERIAL_AIR and mat != MATERIAL_WATER
```

Everything that isn't `AIR` or `WATER` blocks the player (SAND, DIRT, STONE, ores, WOOD, METAL, GRAVEL - see PROJECT_ARCHITECTURE.md §8 for the full material table). This is a **live** query against the actual simulation grid - there is no separate/cached collision representation, so mining/building/falling sand are reflected in player collision on the very next `_rect_blocked()` call, with no synchronization step needed.

Horizontal and vertical motion are resolved as two independent, sequential 1px-stepped loops (see `_move_and_collide`). This existing structure is what the step-up system hooks into - it does not introduce a new collision path.

---

## Step-Up System

**CURRENT / IMPLEMENTED.** When a 1px horizontal sub-step is blocked, `_try_step_up()` is tried before giving up on that sub-step:

```
horizontal sub-step blocked at (target_x, current_y)
    |
for h = 1 .. player_step_height_cells (smallest first):
    lift = (0, -h * simulation_cell_size)
    |
    is (current_x, current_y + lift) blocked?  -> try next h (no headroom to lift here)
    |
    is (target_x,  current_y + lift) blocked?  -> try next h (still blocked/no room at target)
    |
    neither blocked -> SNAP position to (target_x, current_y + lift), continue the
                        horizontal loop (don't break) - remaining sub-steps this
                        frame keep evaluating from the new, raised position
    |
no h in [1, player_step_height_cells] works -> real obstacle: velocity_v.x = 0, stop
```

Two checks per candidate height, both against the **full `PLAYER_SIZE` bounding box** (not a single point/pixel):
1. **Headroom at the current x**: lifting the player straight up by `h` cells from where they currently stand must not itself be blocked (guards against a low ceiling directly overhead).
2. **Clearance at the target x**: the full player box at the target x, raised by `h` cells, must be entirely clear.

Check 2 alone already answers both "is there room above the ledge for the whole player" and "does the player end up inside solid terrain" - a full-box `_rect_blocked` call inherently covers both, since it scans every cell the box overlaps, not just the player's feet.

**Why this is checked per 1px sub-step, not once per frame:** the existing horizontal loop already advances in ≤1px increments specifically to avoid tunneling. Reusing that same loop for step-up means a bumpy/staircase surface (each individual rise ≤ `player_step_height_cells`) is climbed smoothly, one small snap per sub-step that needs it, while a single wall taller than the limit is re-evaluated against the **same** height cap at every sub-step and never accumulates past it - see [Edge Cases](#edge-cases).

**Why the smallest working height is used:** the loop tries `h = 1, 2, ..., player_step_height_cells` in order and returns on the first success, so the player is lifted exactly as much as the ledge requires, never more.

**Not step-up's job:** getting the player back down after a step, keeping them on the ground once stepped up, or resolving the vertical axis at all - that is entirely the existing, unmodified vertical collision loop and gravity integration. Step-up only ever adjusts position at the moment a horizontal sub-step would otherwise have been blocked.

---

## Step Height

`player_step_height_cells` (default **2**) is expressed in **simulation cells**, not world/screen pixels - see [Coordinate Units](#coordinate-units) for why. The effective pixel height used at runtime is always computed fresh as `player_step_height_cells * sim_world.get_simulation_cell_size()`, never cached, so changing `simulation_cell_size` at the `PixelSimWorld` node keeps "N cells" meaning the same physical ledge height in the world, automatically, with no change needed here.

`player_step_height_cells = 0` disables auto step-up entirely (the loop in `_try_step_up` doesn't execute, function returns `null` immediately) - a valid, supported configuration, not a special-cased "off" flag.

---

## Configuration

`player_step_height_cells` is an `@export var` on `Player` (`scripts/player.gd`), alongside the existing `sim_world_path` export - this is the established pattern in this codebase for a per-node, designer-tunable value (compare `PixelSimWorld.simulation_cell_size`/`simulation_budget_ms`/`world_seed`, all `@export var` on their respective node). No new configuration system was introduced; this is the same mechanism already used elsewhere in the project.

The other movement constants (`GRAVITY`, `MOVE_SPEED`, `JUMP_VELOCITY`, `MAX_FALL_SPEED`, `PLAYER_SIZE`) remain plain `const` values, unchanged by this feature - they were out of scope for this request and are not part of the step-up system.

To change it: set `player_step_height_cells` on the `Player` node in `scenes/Main.tscn` (Inspector, or a `player.player_step_height_cells = N` script call at runtime - it's read fresh every time `_try_step_up` runs, so it can even be changed live without restarting).

---

## Coordinate Units

**ARCHITECTURAL RULE.** `player_step_height_cells` is defined in simulation-cell units, and this must not silently change to world-pixel units.

Reasoning: `simulation_cell_size` (on `PixelSimWorld`) is itself configurable and is a pure rendering/scale factor that the simulation core never reads (PROJECT_ARCHITECTURE.md §10). If step height were stored in world pixels, its *meaning* in terms of actual terrain cells would silently change whenever `simulation_cell_size` changed - e.g. an 8px step height means "2 cells" at `simulation_cell_size=4` but "4 cells" at `simulation_cell_size=2`, quietly turning a small-ledge-assist into something that climbs much taller terrain features. Storing the value in cells and converting to pixels at the point of use (`h * sim_world.get_simulation_cell_size()`) keeps "a small ledge, a couple of terrain cells tall" true regardless of the current rendering scale - the least error-prone choice given the existing architecture.

Everywhere else in `player.gd`, positions/velocities/`PLAYER_SIZE` are plain **world pixels** (Godot's native 2D coordinate space) - this is unchanged. Only `player_step_height_cells` itself is cell-denominated; it is converted to pixels immediately inside `_try_step_up` and never stored or compared in pixels elsewhere.

---

## Edge Cases

- **Low ceiling directly overhead:** blocked by the headroom check (`position + lift`) even if the target x at that height would otherwise be clear - the player cannot be lifted through solid terrain directly above their current position.
- **A wall taller than `player_step_height_cells`:** every height `1..player_step_height_cells` fails the target-clearance check, `_try_step_up` returns `null`, and the existing fallback (`velocity_v.x = 0`, stop) applies exactly as it did before this feature existed.
- **Staircase of small rises:** each 1px horizontal sub-step independently re-runs `_try_step_up` against the same configured limit. A sequence of individually-climbable rises is climbed smoothly, one small snap per sub-step; a single obstacle taller than the limit is not bypassed by however many sub-steps a frame happens to contain, because the height cap is enforced identically on every sub-step, not accumulated across them.
- **Flat ground:** the flat horizontal check never fails on flat, unobstructed terrain, so `_try_step_up` is never invoked there at all - there is no code path by which step-up can cause oscillation/jitter on flat ground, by construction.
- **Water:** `WATER` is excluded from `_is_blocking()` (the player already walks/swims through it, PROJECT_ARCHITECTURE.md §8-adjacent behavior, unchanged) unconditionally, so it never blocks a horizontal sub-step and never triggers step-up either - this is unaffected by PLAYER_COLLISION.md's later `mined_drop_collision` toggle, which only concerns mining-drop materials, not `WATER`.
- **Mid-mining/building terrain changes:** since `_rect_blocked` always reads the live grid, a ledge that was climbable a moment ago but got mined away (or built up) mid-frame is picked up correctly on the very next call - there is no stale collision cache to invalidate.

---

## Performance

**PERFORMANCE REQUIREMENT.** Step detection must stay a small, local query - it must not scan the surrounding terrain region every frame.

`_try_step_up` only runs when a horizontal sub-step is actually blocked (not every frame, not every sub-step unconditionally), and even then it performs at most `2 * player_step_height_cells` calls to `_rect_blocked` (two checks per candidate height, default 2 → at most 4 calls), each of which scans only the handful of cells the `PLAYER_SIZE` box covers (a small, fixed-size AABB, independent of world size or how far the player has walked). This is the same cost class as the pre-existing per-pixel collision checks already run every physics frame for ordinary movement - no new region scanning, no new per-frame cost when nothing is blocking movement, and no dependency on or change to the simulation core's `World::step()`/chunk/sleeping system (PROJECT_ARCHITECTURE.md §4/§6, [SIMULATION_ACTIVATION.md](SIMULATION_ACTIVATION.md)).

---

## Architectural Invariants

- Player movement and the terrain Cellular Automata simulation remain separate systems: the player only ever *reads* the grid (`get_cell`), it never calls `set_cell`/`mine_area`/etc. as a side effect of moving or stepping up.
- Step-up never mutates `World`/`Chunk`/`Cell` state - it only changes `Player.position`, a value entirely local to the `Player` node.
- No new physics body, collision shape, or Godot Physics involvement was introduced for this feature - it extends the existing hand-rolled `_rect_blocked`-based collision, per PROJECT_ARCHITECTURE.md §13/§14.
- `_is_blocking` (`get_cell`-based) is the single source of truth step-up relies on for "is this cell solid" - there is no separate/parallel notion of "steppable terrain." Its exact definition of "blocking" is no longer fixed at `!= AIR && != WATER` alone (PLAYER_COLLISION.md later added a configurable exception for mining-drop materials) - step-up does not care what the current definition is, only that `_rect_blocked`/`_is_blocking` remain the sole authority on it.

### DO NOT CHANGE WITHOUT AN EXPLICIT ARCHITECTURAL DECISION

**WHAT:** Player movement and terrain simulation stay separate systems (player reads the grid; it never writes to it).
**WHY:** Keeps the simulation core's Godot-agnostic boundary intact (PROJECT_ARCHITECTURE.md §11) and avoids the player's own movement code becoming a second, ad-hoc way to mutate world state outside `set_cell`/`swap_cells` (which would also silently bypass [SIMULATION_ACTIVATION.md](SIMULATION_ACTIVATION.md)'s activation guarantees for any cell it touched).
**WHEN CAN IT CHANGE:** If a future feature genuinely needs the player to affect the grid directly (distinct from mining/building, which already do this correctly through `PixelSimWorld`), that should go through the existing `set_cell`/`mine_area`/`place_cell` API, not a new write path invented inside `player.gd`.

**WHAT:** Step-up must never write to or otherwise change simulation state (`World`/`Chunk`/`Cell`).
**WHY:** It is purely a player-collision convenience; conflating it with terrain mutation would blur the player/simulation boundary above and has no gameplay justification.
**WHEN CAN IT CHANGE:** It shouldn't. If a future feature wants "stepping flattens the ledge" or similar terrain-editing behavior, that is a distinct feature built on the mining/building API, not a modification of step-up.

**WHAT:** Step-up must not use a separate `PhysicsBody2D`/`CollisionShape2D`/Godot Physics query.
**WHY:** Consistent with the project-wide rule that the only terrain collision source is the live `PixelSimWorld` grid via `_rect_blocked`/`get_cell` (PROJECT_ARCHITECTURE.md §13/§14) - a second collision representation would risk drifting out of sync with the actual simulation state.
**WHEN CAN IT CHANGE:** Only alongside a broader, explicitly-decided change to how player-vs-terrain collision works in general, not for step-up specifically.

**WHAT:** `player_step_height_cells` stays configurable (an `@export var`, not a hardcoded constant folded into the algorithm).
**WHY:** Explicit project requirement - the value must be adjustable (1/2/3/4/...) without editing the step-up algorithm itself.
**WHEN CAN IT CHANGE:** The storage mechanism could move (e.g. into a future shared player-config resource) if one is ever introduced project-wide, but it must remain externally configurable in whatever form replaces it.

**WHAT:** `player_step_height_cells` stays denominated in simulation cells, converted to pixels only at the point of use.
**WHY:** See [Coordinate Units](#coordinate-units) - keeps its meaning stable across changes to `simulation_cell_size`.
**WHEN CAN IT CHANGE:** Only if the project moves away from a configurable `simulation_cell_size` entirely, which would be a much larger architectural change on its own (PROJECT_ARCHITECTURE.md §14).

- Foreground collision (`_rect_blocked`/`_is_blocking`/`get_cell`) remains the sole source of truth for what blocks the player. Step-up must not introduce a second notion of "solid."

---

## Testing Requirements

`player.gd` is Godot-dependent GDScript (extends `CharacterBody2D`, reads live scene-tree/`PixelSimWorld` state) and is therefore **not** covered by the standalone, engine-agnostic `tests/test_core.cpp` suite (PROJECT_ARCHITECTURE.md §11 - that boundary is intentional and this feature does not cross it). Verification for this feature was done live in the running editor (via the `godot-mcp-pro` tooling already used elsewhere in this project's development), covering:

1. No obstacle → unobstructed horizontal movement, `_try_step_up` never invoked.
2. A 1-cell ledge → auto step-up at the default `player_step_height_cells = 2`.
3. A 2-cell ledge (exactly at the default limit) → auto step-up.
4. A 3-cell ledge, default limit 2 → blocked, no step-up.
5. Same 3-cell ledge, `player_step_height_cells` set to 3 → now climbable.
6. A 2-cell ledge, `player_step_height_cells` set to 1 → no longer climbable.
7. Both `move_left` and `move_right` produce symmetric step-up behavior.
8. A low ceiling directly above a small ledge prevents stepping into it (headroom check).
9. A wall taller than the configured limit is never bypassed.
10. A staircase of small rises is climbable without a single tall wall (approached over many sub-steps in one frame) ever being treated as passable.
11. Flat ground produces no jitter/oscillation.
12. Player collision remains correct (no clipping into solid terrain) immediately after a step-up.

---

## Files Changed

- `scripts/player.gd` - `player_step_height_cells` export, `_try_step_up()`, and the one-line hook into the existing horizontal collision loop in `_move_and_collide()`.

No other file was modified for this feature - the simulation core, chunk/activation system, mining/building, and rendering are all untouched.
