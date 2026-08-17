# Terrain Layers

Architectural source of truth for PixelSim's Background/Foreground terrain layering. Written against the actual implementation in `addons/pixelsim/src/core/{background,chunk,world}.{h,cpp}`, `gen/terrain_gen.cpp`, and `sim_world_node.cpp`. See [PROJECT_ARCHITECTURE.md](PROJECT_ARCHITECTURE.md) for the surrounding chunk/cell/material model this document assumes, and [SIMULATION_ACTIVATION.md](SIMULATION_ACTIVATION.md) for the wake/activation system the Background layer is explicitly excluded from.

---

## Overview

Every terrain position has two independent material values, not one:

```
CELL / POSITION
├── FOREGROUND  - the real, simulated, minable terrain (existing system, unchanged)
└── BACKGROUND  - a static, non-simulated visual layer revealed wherever the
                  foreground is AIR
```

This is a genuine second data layer stored per cell (in `Chunk`, see [Data Model](#data-model)) - not a rendering trick, not a global overlay, not a darkened copy of the foreground texture. The purpose is purely to make mined-out space read visually as "inside solid rock" instead of "the void," and to leave room for future biome-specific or material-specific backgrounds without having invented a rendering hack that would need to be replaced to get there.

---

## Foreground

Unchanged by this feature. The foreground is everything documented in PROJECT_ARCHITECTURE.md: `Cell`-based, participates in the Cellular Automata (`World::step()`, `solve_powder`/`solve_liquid`), minable via `World::mine_area` (including the drop-ratio/material-conversion system), and is the sole source of player collision (PLAYER_MOVEMENT.md - also unchanged by this feature). Nothing about how the foreground is stored, simulated, mined, or collided with was touched to add the Background layer.

---

## Background

The Background layer is, by design, **not** a peer of the foreground in capability - it is deliberately minimal:

- Static: written once (by terrain generation, or in principle by a future explicit "set background" call), never by simulation.
- Not simulated: no `MovementBehavior`, no gravity, no `can_displace`, no `swap_cells` involvement of any kind.
- Not minable: there is no `can_be_mined`/`mined_drop` concept for the background - mining only ever touches the foreground (see [Mining Integration](#mining-integration)).
- Not an activation source or target: writing a background value never calls `mark_touched()` or `activate_affected_neighbors()` - see [Simulation](#simulation).
- Currently exactly one non-empty value exists (`BackgroundType::DARK_ROCK`), plus `BackgroundType::NONE` (open sky / never assigned). The type is designed to grow (`DARK_DIRT`, `DARK_CAVE`, biome variants, ...) without any of the surrounding architecture changing - see [Future Extensions](#future-extensions).

`BackgroundType` and `BackgroundDef` (`core/background.h/.cpp`) deliberately mirror `MaterialType`/`MaterialDef`'s *pattern* (an append-only enum plus a `static constexpr` properties table) but are a **separate, smaller type** - a `BackgroundDef` carries only a `name` and an RGBA render color, none of `MaterialDef`'s simulation/mining fields. Keeping them distinct types (not, say, reusing `MaterialType` with a "these values are background-only" convention) makes it a compile error to accidentally hand a background value to a solver or `can_be_mined`/`mined_drop` check.

---

## Data Model

**ARCHITECTURAL RULE.** `Cell` did not grow. It is still the 2-byte POD documented in PROJECT_ARCHITECTURE.md (`static_assert(sizeof(Cell) == 2, ...)`, unchanged).

The background is stored as a second, parallel array **on `Chunk`**, not inside `Cell`:

```cpp
class Chunk {
    std::array<Cell, CHUNK_CELL_COUNT> cells{};           // existing, unchanged
    std::array<uint8_t, CHUNK_CELL_COUNT> background{};   // new - one BackgroundType byte per cell
};
```

This was chosen over growing `Cell` for the reason PROJECT_ARCHITECTURE.md already establishes as load-bearing: `Cell` is a performance-critical, per-cell, potentially-multi-million-instance structure, and the background needs none of what would justify enlarging it - no velocity, no flags, no sleeping/simulation state (all explicitly ruled out by the originating request). A parallel `Chunk`-level array:
- Costs exactly **1 byte per cell** (`CHUNK_CELL_COUNT` = 4096 bytes per chunk), not the 2+ bytes (plus alignment padding) a naive `Cell` field would likely cost.
- Keeps `cells` itself untouched - every existing foreground-only code path (`get_material`, `set_cell`, `swap_cells`, the solvers, mining, activation) needed **zero** changes to its own data access, because it never looks at `background` at all.
- Stays contiguous and cache-friendly the same way `cells` already is: `background` is an inline `std::array` member of `Chunk`, so a `std::vector<Chunk>` still places every chunk's data (foreground *and* background) in one contiguous heap block - no new per-chunk allocation, no pointer chasing (PROJECT_ARCHITECTURE.md §5).

For a default 48x28-chunk world (5,505,024 cells - PROJECT_ARCHITECTURE.md §6), this adds **~5.25 MB** flat (1 byte x total cells), independent of how much of the world is actually explored or mined. `sizeof(Chunk)` grows by exactly `CHUNK_CELL_COUNT` bytes, verified in `tests/test_core.cpp`.

---

## Chunk Integration

The background array lives directly on `Chunk` (not a separate `World`-level buffer, not a hash map) for the same reason the foreground `cells` array does: chunks are the existing unit of both storage and rendering granularity, and background data is addressed with the **exact same** local-coordinate math (`x % CHUNK_SIZE, y % CHUNK_SIZE`) as foreground data, via `Chunk::get_background`/`set_background`.

Crucially, the background does **not** follow the foreground's simulation lifecycle:

| | Foreground (`cells`) | Background (`background`) |
|---|---|---|
| Lifecycle | active / sleeping / dirty-this-pass (PROJECT_ARCHITECTURE.md §6/§7) | none - just sits there |
| Written via | `set_cell`/`swap_cells` -> `mark_touched()` | `Chunk::set_background` directly - no `mark_touched()` call |
| Wakes a chunk | yes | **no** |
| Participates in `World::step()` | yes | **no** - never read by `step()` or any solver |
| `render_dirty` | set by `mark_touched()` | set by `set_background()` directly (a narrower flag flip, see [Rendering](#rendering)) |

`World::set_background(x, y, BackgroundType)` (the public, coordinate-resolving entry point, mirroring `set_cell`'s bounds-checking and chunk/local-coordinate math) calls `Chunk::set_background` and nothing else - no `ensure_chunk_begun`, no `mark_touched`, no `activate_affected_neighbors`. This is the mechanism, not a side effect, that guarantees a background write can never wake a sleeping chunk - see [Simulation](#simulation).

---

## Rendering

Rendering order, as requested:

```
BACKGROUND
    v
FOREGROUND
    v
PLAYER / EFFECTS / UI
```

**Implementation note - this is a compositing decision, not a second rendering system.** PixelSim's existing rendering architecture (PROJECT_ARCHITECTURE.md §10) already produces exactly one RGBA8 pixel buffer per chunk (`PixelSimWorld::get_chunk_pixels`), consumed by exactly one `Sprite2D`/`ImageTexture` per chunk in `chunk_renderer.gd`. Introducing a second sprite/texture per chunk purely to draw the background underneath would double the sprite/texture count (2,688 instead of 1,344 for the default world) for a layer that is visible only where the foreground is already transparent - strictly worse for the exact rendering bottleneck PROJECT_ARCHITECTURE.md §10/§12 already documents (per-chunk texture upload cost), for no behavioral benefit, since the two layers never need independent per-pixel blending - it's a strict either/or per cell.

Instead, `get_chunk_pixels` (the single, existing place per-cell colors are decided for rendering) now picks the color per cell as:

```cpp
if (foreground_cell.material == AIR) {
    color = get_background_def(chunk.get_background(lx, ly)).color;  // BackgroundType::NONE is fully transparent
} else {
    color = get_material_def(foreground_cell.material).color;        // unchanged existing behavior
}
```

This is still a real two-layer data model (see [Data Model](#data-model)) - the compositing only happens at the moment pixel bytes are generated for upload, which was already happening for every render-dirty chunk regardless of this feature. `chunk_renderer.gd` needed **zero** changes - it still just uploads whatever `get_chunk_pixels` returns, exactly as before.

**Color centralization.** Per the originating request, background color must not be hardcoded at multiple points in the renderer: `BACKGROUND_TABLE` in `background.cpp` is the single place any background color is defined, exactly mirroring how `MATERIAL_TABLE` in `material.cpp` is already the single place foreground colors are defined. `get_chunk_pixels` looks the color up; it never contains a literal color value itself.

**Performance.** Because a background write only ever flips `render_dirty` (never `sleeping`/`dirty_this_pass`), and rendering already only re-serializes/re-uploads chunks that are render-dirty (PROJECT_ARCHITECTURE.md §10's `get_and_clear_dirty_render_chunks`), the Background layer causes a render update **exactly when**: (a) it is written for the first time (terrain generation), or (b) a foreground cell that was already `AIR` needed re-rendering for an unrelated reason anyway. It never causes a *recurring* per-frame render cost by itself - see [Performance](#performance).

---

## Mining Integration

**Mining code was not modified for this feature; this is a consequence of the data model, not special-cased logic.** `World::mine_area` (and everything it calls - `set_cell`) only ever reads/writes `Chunk::cells`. It has no awareness of `Chunk::background` at all, so:

1. The foreground material is removed (existing drop-ratio/`mined_drop` logic, PROJECT_ARCHITECTURE.md §8/§9 - unchanged).
2. The foreground cell becomes `AIR` (or the drop material, e.g. `SAND`/`GRAVEL` - still 100% foreground, still a real simulation cell, still picked up by the existing gravity solver - unchanged).
3. The background byte at that position is never touched by mining, at any point - it was set once during terrain generation and mining has no code path that can reach it.
4. On the next render, [Rendering](#rendering)'s compositing rule picks the background color for that now-`AIR` cell, making it visible.
5. If a drop occurred (e.g. `STONE` -> `GRAVEL`), the drop is foreground, and the background is still whatever it was before mining - a dropped `GRAVEL` cell sitting where `STONE` used to be simply has its own background value underneath it too (irrelevant while the foreground there is non-`AIR`, but preserved regardless).

---

## Simulation

**ARCHITECTURAL RULE - the core guarantee of this feature.** The Background layer is invisible to the simulation, by construction, not by a runtime check:

- `World::step()`, `solve_powder`, `solve_liquid`, and `material_can_displace` only ever read `Chunk::cells` (via `get_material`/`can_displace`). None of them has a code path that reads `Chunk::background` - there was nothing to "turn off," because nothing was ever wired up to look at it.
- `World::set_background` does not call `ensure_chunk_begun`, `mark_touched`, or `activate_affected_neighbors`. A background write cannot wake a sleeping chunk, cannot mark a chunk `dirty_this_pass`, and is never treated as a "world change" for [SIMULATION_ACTIVATION.md](SIMULATION_ACTIVATION.md)'s activation propagation - it is a completely different, narrower write path than `set_cell`/`swap_cells`.
- Consequently: the background never falls, never flows, never reacts to gravity, and never generates simulation work of any kind - because there is no code anywhere that could make it do any of those things.

---

## Performance

**PERFORMANCE REQUIREMENT.**

1. **Memory:** exactly `CHUNK_CELL_COUNT` (4096) additional bytes per chunk, verified by a `sizeof(Chunk)` test. No per-cell growth of `Cell` itself, no additional heap allocation beyond the existing `std::vector<Chunk>` (the array is an inline `Chunk` member).
2. **Simulation cost:** zero. `World::step()`'s cost model (PROJECT_ARCHITECTURE.md §12) is entirely unchanged - the background array is never touched by it.
3. **No new continuous render cost:** a background write flips only `render_dirty` (once, on write) - it never touches `sleeping`/`dirty_this_pass`, so it cannot cause a chunk to be repeatedly re-simulated or repeatedly re-rendered on its own. Verified in `tests/test_core.cpp`: after one `set_background` write is consumed via `consume_render_dirty`, running further simulation passes with no other activity produces no further `render_dirty` flips.
4. **No new per-frame renderer cost:** `chunk_renderer.gd` is unmodified - it still only re-uploads chunks `get_and_clear_dirty_render_chunks()` returns, exactly as before this feature.
5. **No per-cell Godot objects:** the background is plain per-cell data composited into the same chunk-granular `Sprite2D`/`ImageTexture` pipeline that already existed (PROJECT_ARCHITECTURE.md §10) - no new Node/Sprite of any kind was introduced, per cell or per chunk.

---

## Architectural Invariants

- The foreground is the simulation layer; the background is not, and never will be without a separate, explicit architectural decision (see [Future Extensions](#future-extensions)).
- `Cell` stays a 2-byte POD - the background lives on `Chunk`, never on `Cell`.
- Background data is written exactly twice in the current codebase: once by terrain generation (`gen/terrain_gen.cpp`), and (in test code only) directly via `World::set_background` - never by mining, never by a solver, never by `World::step()`.
- Mining removes foreground material only; it never clears, replaces, or otherwise touches the background at the mined position.
- Wherever the foreground is `AIR`, the renderer shows the background; wherever it is not, the renderer shows the foreground. This is the entire compositing rule, defined in exactly one place (`PixelSimWorld::get_chunk_pixels`).
- Background colors are defined in exactly one place (`BACKGROUND_TABLE` in `background.cpp`), never hardcoded elsewhere in rendering code.
- Player movement/collision (PLAYER_MOVEMENT.md) is unchanged by this feature - the player still only ever queries the foreground (`get_cell`) for collision. The Background layer has no collision meaning yet (see [Future Extensions](#future-extensions)).

### DO NOT CHANGE WITHOUT AN EXPLICIT ARCHITECTURAL DECISION

**WHAT:** The foreground remains the sole simulation layer; the Background layer does not participate in the Cellular Automata.
**WHY:** This is the core premise of the feature as requested, and is what keeps `World::step()`'s performance model (PROJECT_ARCHITECTURE.md §12) entirely unaffected by adding this layer.
**WHEN CAN IT CHANGE:** Only via a deliberate, separately-decided "interactive background" feature (explicitly deferred by the originating request) - not as an incidental side effect of some other change.

**WHAT:** The Background layer is static - nothing in simulation code writes it.
**WHY:** Same reasoning as above; a background that could be mutated by simulation would need its own activation/lifecycle story, which does not exist today.
**WHEN CAN IT CHANGE:** Only alongside the same explicit "interactive background" decision as above.

**WHAT:** Background writes must never wake a sleeping chunk (no `mark_touched`/`activate_affected_neighbors` call from `World::set_background`/`Chunk::set_background`).
**WHY:** Explicit, load-bearing performance requirement from the originating request - conflating background writes with simulation activation would silently reintroduce unnecessary chunk activity every time background is touched (e.g. during terrain generation, which touches nearly every chunk).
**WHEN CAN IT CHANGE:** Not without revisiting the "static, non-simulated" premise of the whole feature.

**WHAT:** Mining never modifies the background.
**WHY:** The originating request's core example (`STONE / STONE / STONE` -> mine the middle -> background shows through, background "changatlan marad") depends on this; drop materials (e.g. `GRAVEL`) also remain purely foreground.
**WHEN CAN IT CHANGE:** A future feature that explicitly wants mining to also affect background (e.g. "background erosion") would need its own decision and its own document update here.

**WHAT:** Wherever foreground is `AIR`, background is what renders; otherwise foreground renders. No other compositing rule.
**WHY:** This is the entire visual contract requested - simple, predictable, and cheap to compute per-cell during the existing chunk-pixel generation.
**WHEN CAN IT CHANGE:** If a future feature needs partial transparency/blending between layers, that is a materially different rendering model and needs its own decision - not a tweak to this rule.

**WHAT:** `Cell` does not grow to accommodate the background.
**WHY:** Explicit, repeated project-wide invariant (PROJECT_ARCHITECTURE.md §5/§14) - `Cell` is a performance-critical, per-cell, multi-million-instance structure.
**WHEN CAN IT CHANGE:** Only alongside the same broader "is `Cell` still the right shape" decision PROJECT_ARCHITECTURE.md already gates.

**WHAT:** Player collision is untouched by this feature - it still queries only the foreground.
**WHY:** Explicit scope boundary from the originating request; player-vs-mined-material collision is a separate, later feature.
**WHEN CAN IT CHANGE:** When that later feature is explicitly undertaken (see PLAYER_MOVEMENT.md) - not as a side effect of this one.

---

## Future Extensions

**FUTURE / OPTIONAL - none of this is decided architecture:**
- Additional `BackgroundType` values (`DARK_DIRT`, `DARK_CAVE`, biome-specific variants) - purely additive to `BACKGROUND_TABLE`, no surrounding architecture change needed.
- Terrain-generation-time variety (e.g. background type correlated with depth or biome, rather than the current single `DARK_ROCK` for all solid terrain).
- An explicit, separate "interactive background" feature, if ever decided: would need its own activation/simulation story and must not silently piggyback on the foreground's `World::step()`/activation system.
- ~~Player collision against mined-material state~~ — **done**: see [PLAYER_COLLISION.md](PLAYER_COLLISION.md)'s `mined_drop_collision` toggle (configurable per-material-type collision for mining-drop products like SAND/GRAVEL). Background collision specifically was **not** part of that feature and remains out of scope - the Background layer is still always non-collidable (see [Architectural Invariants](#architectural-invariants) above), unaffected by `mined_drop_collision`.
- Per-cell background textures/detail instead of flat colors, once foreground rendering itself moves beyond flat colors.

---

## Testing Requirements

`tests/test_core.cpp` (standalone, no Godot dependency - PROJECT_ARCHITECTURE.md §11) covers:

1. Foreground material is what `get_material` returns while foreground is non-`AIR` (regression guard).
2. Mining exposes the background: after mining, `get_material` is `AIR`/drop material and `get_background` is unchanged from what was set before mining.
3. Background survives repeated foreground changes (multiple mine/build cycles over the same cell never alter `get_background`).
4. Background is inert under gravity: SAND falling through/past a column with background set leaves every background byte in that column exactly as set.
5. Background is inert under Sand/Water simulation generally (a full stress-like pass over an area with background set and materials moving changes zero background bytes).
6. `World::set_background` never wakes a sleeping chunk (`chunk.sleeping` stays `true` immediately after the call).
7. Mining drop is still foreground material, and the background at that position is unaffected by the drop.
8. Mining drop still falls under gravity with background present nearby (end-to-end regression guard - this feature must not have disturbed the existing drop-then-fall behavior).
9. Background set across a chunk boundary is stored/retrieved correctly on each side, via the same local-coordinate math foreground already uses.
10. A background write causes exactly one `render_dirty` flip (consumed via `consume_render_dirty`); further simulation passes with no other activity produce no further flips.
11. `sizeof(Chunk)` grows by exactly `CHUNK_CELL_COUNT` bytes relative to a chunk without the background array (memory-footprint claim, proven rather than assumed).
