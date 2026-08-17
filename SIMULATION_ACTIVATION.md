# Simulation Activation Architecture

Architectural contract for PixelSim's Simulation Wake / Activation system. This is not a description of an idealized design — it documents the actual mechanism in `addons/pixelsim/src/core/world.{h,cpp}` and `chunk.h`, written against the real bug it fixes. Read [PROJECT_ARCHITECTURE.md](PROJECT_ARCHITECTURE.md) first for the surrounding chunk/cell/sleeping model this document assumes.

**Status:** CURRENT / IMPLEMENTED (this document was written before the implementation, then updated to match it once built — see the note at the end of each section).

---

## Purpose

The chunk sleeping system (`Chunk::sleeping`, `dirty_this_pass`, `World::step()` skipping sleeping chunks — see PROJECT_ARCHITECTURE.md §6/§7) is what makes simulation cost track *activity* instead of *world size*. It is also, by construction, capable of producing a physically wrong result: a chunk that is asleep is **not simulated at all**, including cells inside it that would legitimately need to move if a change happened somewhere else. Before this feature, the only thing that woke a chunk was `Chunk::mark_touched()`, called exclusively for the chunk containing a cell that was *directly written to*. A change never woke any *other* chunk, even one containing material that is now physically unsupported as a direct result of that change.

This produced a real, reproducible bug: mining removes support directly below a column of SAND; if that SAND happens to sit in a different (already-sleeping) chunk than the mined cell — which happens whenever the affected material is within a few rows of a chunk's top edge — that chunk's `sleeping` flag is never cleared, `World::step()` skips its rows forever, and the SAND floats indefinitely.

The purpose of this system is to close that gap with a **general, demand-driven activation mechanism** — not a mining-specific patch — while preserving the sleeping system's performance property: stable regions of the world must cost effectively nothing per frame, and only the region actually physically affected by a change should ever wake up.

---

## Current Architecture (as of this document)

Recap of the mechanics this feature builds on (see PROJECT_ARCHITECTURE.md §4/§6/§7 for full detail):

- `Chunk::sleeping` — if true, `World::step()` skips the chunk's entire row-segment for every row, every pass, in O(1).
- `Chunk::mark_touched(local_x, local_y)` — called by `World::set_cell`/`swap_cells` for the chunk(s) actually written to. Clears `sleeping`, sets `dirty_this_pass` and `render_dirty`, and grows the touched-rect.
- `World::step()` scans rows bottom-to-top; for each row, for each chunk-column, if the chunk is not sleeping, **every** cell in that chunk's portion of the row is evaluated that pass — not just cells that were individually "touched." This is why a stack of SAND fully contained in one already-awake chunk already cascades correctly today: waking the chunk once is enough for every row of it to be visited over successive passes.
- `Chunk::end_pass()` — `sleeping = !dirty_this_pass`. A chunk that had zero activity during a pass it was awake for goes back to sleep; one that had any activity (a real move, or an external write) stays awake for at least one more pass.
- Solvers (`solve_powder`, `solve_liquid`) only ever read a small, fixed set of neighbor cells relative to the cell being evaluated (see [Gravity Activation](#gravity-activation) below) — they never read anything outside that set.

**The gap this feature closes:** `mark_touched()` wakes exactly the chunk of the cell that was written. It does not wake any *other* chunk, even one containing a cell whose movement decision depends on the cell that was just written (e.g. the cell directly above it, for a POWDER material). When that dependent cell's chunk happens to be a different, sleeping chunk, it is never re-evaluated.

---

## World Changes

**ARCHITECTURAL RULE.** A **world change** is any write to the simulation grid's material data, through either of the two core write primitives:

- `World::set_cell(x, y, material)`
- `World::swap_cells(x1, y1, x2, y2)` (counts as a world change at **both** `(x1,y1)` and `(x2,y2)`)

This is deliberately source-agnostic. A world change is a world change whether it originates from:
- a solver (`solve_powder`/`solve_liquid` calling `swap_cells` as part of normal simulation),
- mining (`World::mine_area`, which itself just calls `set_cell` per affected cell),
- building (`World::place_cell`, which calls `set_cell`),
- terrain generation (`gen/terrain_gen.cpp`, which calls `set_cell` and `fill_rect`),
- the stress-test harness (`fill_rect`/`spawn_material_rect`),
- or any future feature (explosion, fluid injection, terrain deformation, material transformation, …) — **as long as it goes through `set_cell`/`swap_cells` and not some other path that writes `Cell` data directly.**

**CURRENT / IMPLEMENTED:** because activation is hooked into these two primitives themselves (see [Activation Rules](#activation-rules)), every world change — regardless of source, including the solvers' own movement — automatically gets correct activation propagation. No feature-specific code (mining, building, or otherwise) needs to know this system exists.

**Note (added after [TERRAIN_LAYERS.md](TERRAIN_LAYERS.md)'s Background/Foreground layer):** a write to the Background layer (`World::set_background`/`Chunk::set_background`) is explicitly **not** a world change by this definition — it goes through neither `set_cell` nor `swap_cells`, uses its own narrower write path, and therefore never triggers activation, exactly as TERRAIN_LAYERS.md's own invariants require ("Background writes must never wake a sleeping chunk"). This isn't a special case bolted onto this document's rule — the Background layer simply never touches the two primitives this section defines "world change" in terms of.

**ARCHITECTURAL RULE.** Anything that needs to modify `Cell` material data must go through `set_cell`/`swap_cells`. Writing directly to a `Chunk`'s cell array from outside `World` (bypassing these primitives) is what would silently reintroduce this bug for that code path, and must not be done.

---

## Activation Rules

**ARCHITECTURAL RULE — the core principle.** A world change at `(x, y)` must activate every cell whose *current* solver behavior reads `(x, y)`'s state to decide whether *it* can move. It must not activate anything beyond that.

This is implemented as `World::activate_affected_neighbors(x, y)`, called automatically at the end of both `set_cell` and `swap_cells` (both sides, for a swap). It does two things, and two things only:
1. Computes a small, fixed set of neighbor coordinates around `(x, y)` (see [Gravity Activation](#gravity-activation) — this set is derived from the solvers' actual read patterns, not an arbitrary radius).
2. For each neighbor coordinate that's in-bounds, resolves its chunk and calls `Chunk::wake()` on it.

`Chunk::wake()` is deliberately **not** the same thing as `mark_touched()`:

| | `mark_touched()` | `wake()` |
|---|---|---|
| Clears `sleeping` | yes | yes |
| Sets `dirty_this_pass` | yes | **no** |
| Sets `render_dirty` | yes | **no** |
| Grows touched-rect | yes | **no** |
| Meaning | "this exact cell's material changed" | "this chunk *might* have work to do; go find out" |

This distinction matters: activating a neighbor is a **suspicion**, not a fact. Nothing about the neighbor's actual cell data has changed. If the woken chunk gets scanned and nothing in it actually moves, `dirty_this_pass` stays false (because no solver call ever ends up calling `swap_cells` there), and `end_pass()` correctly puts it back to sleep — at the cost of exactly one pass of scanning, not indefinite activity. See [Sleep Conditions](#sleep-conditions).

**CURRENT / IMPLEMENTED.**

---

## Gravity Activation

**ARCHITECTURAL RULE.** The activated neighborhood for a change at `(x, y)` is derived by inverting the read-offsets every currently-implemented solver uses, **not** assumed to be uniform in all directions.

Concretely, from `solvers/solvers.cpp` as it exists today:
- `solve_powder(world, cx, cy)` reads `(cx, cy+1)`, `(cx-1, cy+1)`, `(cx+1, cy+1)` — i.e. only the row *below* itself.
- `solve_liquid(world, cx, cy)` reads the same three cells, **plus** `(cx-1, cy)` and `(cx+1, cy)` — its own row's immediate left/right (for sideways spread).

A solver at `(cx, cy)` reads `(x, y)` exactly when `(x, y) = (cx, cy) + offset` for one of those offsets. So the cells whose behavior could change as a result of `(x, y)` changing are found by inverting: `(cx, cy) = (x, y) - offset`. Taking the **union** across both currently-implemented behaviors gives a fixed, 5-coordinate neighborhood:

```
        (x-1,y-1) (x,y-1) (x+1,y-1)     <- row above (both solvers' "read below" dependency)
(x-1,y)  (x,y)  (x+1,y)                  <- same row, left/right (LIQUID's sideways-spread dependency)
```

i.e. `{(x,y-1), (x-1,y-1), (x+1,y-1), (x-1,y), (x+1,y)}`. This is exactly why, in the reported bug, SAND *directly above* a mined cell is the thing that needs activating — that's what falls into gravity's downward rule — while cells below, or two rows up, are correctly *not* activated by a single change (they don't fall through the changed cell and no current solver reads that far).

**PERFORMANCE REQUIREMENT.** This neighborhood is **fixed-size (5 coordinates) and O(1) per world change** — it does not scale with mining radius, world size, or chunk size. It is a small constant amount of extra work added to an operation (`set_cell`/`swap_cells`) that already does comparable bounds/chunk-resolution work.

**FUTURE / OPTIONAL — do not implement without deciding to.** If a future `MovementBehavior` (FIRE spreading, GAS rising, temperature/pressure) reads a different neighbor pattern (e.g. upward, or a wider radius), the neighborhood in `activate_affected_neighbors()` must be extended to also cover that pattern — this is the intended, and only sanctioned, extension point for new solvers. It should remain derived from what solvers actually read, not grown speculatively "to be safe." A todo marker referencing this section should accompany any new `MovementBehavior` addition.

**CURRENT / IMPLEMENTED.**

---

## Chunk Boundary Propagation

**ARCHITECTURAL RULE.** Activation must work identically whether the affected neighbor cell is in the same chunk as the change or a different one — there is no special-cased "boundary" code path, by construction.

`activate_affected_neighbors(x, y)` computes neighbor coordinates and resolves each one's chunk via the same `x / CHUNK_SIZE, y / CHUNK_SIZE` math every other `World` method uses (`get_material`, `set_cell`, `swap_cells`). It never checks whether a neighbor coordinate is inside the "current" chunk — it always resolves fresh. This means:
- If the neighbor is in the same chunk (the common case, away from any boundary), `Chunk::wake()` is called on an already-awake chunk — a no-op field write, negligible cost.
- If the neighbor is in a different chunk (near a chunk boundary), that chunk's `sleeping` flag is cleared, regardless of whether it was previously asleep for a long time or freshly asleep.

**How multi-chunk cascades propagate:** because activation is hooked into `swap_cells` itself (not just external writes like mining), every solver-driven move is *also* a world change that re-runs this same neighborhood check. When a SAND cell falls (vacating its old position), the cell above *that* old position gets activated too — which may itself cross into yet another chunk further up. This is how a multi-chunk-tall column of SAND fully collapses: each row's fall, as it happens, activates the row above it, one pass at a time, regardless of how many chunk boundaries that spans. There is no upfront "wake the whole column" step — the propagation **is** the cascade, one row of activation per row of actual movement.

**CURRENT / IMPLEMENTED.**

---

## Wake Lifecycle

```
SLEEPING
   |
world change at (x,y)  [set_cell / swap_cells, from ANY source]
   |
activate_affected_neighbors(x,y) wakes the chunks of a fixed 5-cell
neighborhood (mark_touched() also wakes (x,y)'s own chunk, with full
dirty/render semantics)
   |
next time World::step()'s scan reaches an awake chunk's rows: every cell
in that chunk is evaluated this pass, not just the ones "activated"
   |
IF something actually moves (a solve_* call triggers swap_cells):
     dirty_this_pass = true (via mark_touched on both sides of the swap)
     that swap is ALSO a world change -> activates its own neighborhood
     -> possible further chunks wake -> cascade continues
   |
IF nothing moves this pass in a given chunk:
     dirty_this_pass stays false for that chunk
   |
finish_pass() -> end_pass() per chunk touched this pass:
     sleeping = !dirty_this_pass
   |
STABLE (no more movement) -> chunks with no activity this pass go back
to SLEEPING
```

**ARCHITECTURAL RULE.** Waking a chunk must never by itself imply permanent or extended activation. The *only* thing that keeps a chunk awake past the current pass is `dirty_this_pass` being true, which only happens as a side effect of an actual `mark_touched()` call (a real write) during that pass — never from `Chunk::wake()` alone. A speculatively-woken chunk with nothing to do costs exactly one pass of scanning (bounded, not indefinite) before falling back asleep through the existing, unmodified `end_pass()` logic.

**CURRENT / IMPLEMENTED.**

---

## Sleep Conditions

Unchanged from the existing sleeping system (PROJECT_ARCHITECTURE.md §6) — this feature adds a new way for `sleeping` to become `false` (`Chunk::wake()`), but does not add any new way for it to *stay* false, and does not touch `end_pass()`/`dirty_this_pass` semantics at all. A chunk goes back to sleep exactly when it has had a full pass with `dirty_this_pass == false`, regardless of whether it woke up via `mark_touched()` (a direct write) or `wake()` (activation on suspicion).

**ARCHITECTURAL RULE.** The activation system must never prevent a chunk from re-entering `sleeping`. There is no "cooldown," no minimum-awake-duration, and no permanent-activation concept anywhere in this design.

**CURRENT / IMPLEMENTED.**

---

## Performance Requirements

These are **mandatory**, not aspirational:

1. **No full-world wake, ever, for any world change.** Activation cost per world change is bounded by a fixed, small constant (5 neighbor lookups), independent of world size or chunk count.
2. **No radius that scales with the size of the change.** A 500,000-cell mining operation does not activate a 500,000-cell-sized halo — it activates, per mined cell, the same fixed 5-neighbor set as a 1-cell mining operation. The *total* activation work scales with the number of cells actually written (which the caller already controls, e.g. mining footprint size), never with an artificially inflated "safety margin" region around it.
3. **A stable world must still cost effectively nothing.** With no world changes happening, no chunk is ever woken, and `World::step()`'s existing O(1)-per-sleeping-chunk-row-segment skip is completely unaffected by this feature.
4. **A speculative wake must be self-correcting.** A chunk woken by activation that turns out to have nothing to do returns to sleep after exactly one pass — see [Wake Lifecycle](#wake-lifecycle). There is no mechanism, anywhere, that keeps a chunk awake "just in case."
5. **Measure, don't assume.** Any change to the activation neighborhood or its call sites must be re-validated against the stress-test harness (`stress_test.gd`, `Shift+1..5`) and the standalone `tests/test_core.cpp` suite before being considered acceptable — see [Testing Requirements](#testing-requirements).

---

## Activation Invariants

Things that must remain true about this system:

- Activation never marks a cell's material as changed, dirty-for-rendering, or part of a touched-rect. Only an actual `set_cell`/`swap_cells` write does that (via `mark_touched`), for the cell(s) it actually writes.
- Activation cost per world change is O(1) (fixed 5-neighbor set), never proportional to mining radius, chunk size, or world size.
- Activation is derived from what the currently-implemented solvers actually read as neighbors — not a guessed or "safe" radius.
- Waking a chunk via activation is reversible within one pass if nothing turns out to move there; it never blocks or delays a chunk's return to sleep.
- Activation is triggered by the two core write primitives (`set_cell`, `swap_cells`) themselves, not by any specific feature (mining, building, …) calling into it directly. New world-changing features get correct activation for free by writing through those primitives — they should not implement their own wake logic.
- `Chunk` remains unaware of `World` or any other `Chunk` (see PROJECT_ARCHITECTURE.md §13) — `activate_affected_neighbors` lives in `World`, which is the only thing allowed to reason about cross-chunk coordinates. `Chunk::wake()` is a trivial, local, single-field method with no knowledge of *why* it was called.

---

## Forbidden Approaches

Explicitly ruled out, regardless of how convenient they'd be for a specific feature:

- **No full-world wake.** Never clear `sleeping` on every chunk in response to a world change.
- **No unconditional large-radius wake.** Never wake "everything within N chunks" of a change as a blanket safety measure. The activated set must be derived from actual solver read-patterns (currently: row above + same-row sides), not an arbitrary radius.
- **No permanent activation.** No flag, counter, or mechanism that keeps a chunk awake beyond what `dirty_this_pass`/`end_pass()` already decide.
- **No bypassing sleeping for convenience.** Do not disable or special-case the sleeping system to make a feature "just work" — fix activation instead.
- **No mining-specific activation hack.** Activation must not live inside `mine_area`/`mine_circle` or any other single feature's code. It lives in `set_cell`/`swap_cells`, where every feature gets it automatically.
- **No duplicate physics system.** This feature does not add a second way for material to move, a parallel gravity system, or any Godot Physics involvement (see PROJECT_ARCHITECTURE.md §13/§14) — it only affects *whether a chunk gets simulated*, never *how* a cell moves once simulated. `solve_powder`/`solve_liquid`/`swap_cells` are unmodified.

---

## Testing Requirements

Standalone tests (`tests/test_core.cpp`, no Godot dependency) required for this feature, matching the numbered scenarios from the originating request:

1. **Sleeping chunk, same chunk:** SAND resting on STONE, both asleep; remove the STONE; SAND wakes and falls. (Regression guard — already worked before this feature via the "whole awake chunk gets scanned" mechanism; confirms this feature didn't break it.)
2. **Chunk boundary:** SAND at the bottom row of one chunk, the supporting cell at the top row of the chunk below it, both chunks asleep; removing the support wakes the *other* chunk (verified immediately, without needing a `step()` call first) and the SAND subsequently falls across the boundary.
3. **Multi-chunk cascade:** a SAND column spanning several chunks vertically; removing support at the bottom lets the collapse propagate through all of them over successive passes, not just the chunk adjacent to the change.
4. **Stable world:** a settled world with no changes has (~zero) active chunks; running additional passes doesn't spuriously wake anything.
5. **Small change, bounded wake:** a single-cell mining operation against inert terrain (no overhang to fall) wakes only a small, fixed number of chunks (at most the mined cell's own chunk plus its immediate neighbors touched by the 5-cell pattern — never hundreds/thousands).
6. **Large collapse:** a large SAND mass collapsing keeps the active-chunk count bounded by the actual falling/settling frontier, not the whole world.
7. **Sleep after stabilization:** after a collapse fully settles, previously-active chunks return to `sleeping` again.

**PERFORMANCE REQUIREMENT.** In addition to the functional tests above, the existing stress-test harness (`stress_test.gd`, tiers 10k/50k/100k/250k/500k SAND cells) must be re-run after any change to this system and compared against the previously recorded baseline (see PROJECT_ARCHITECTURE.md §12) for simulation-ms and active-chunk regressions. A regression here is a defect in the activation neighborhood or its call sites, not something to fix by weakening or bypassing the sleeping system.

---

## Future Extensions

**FUTURE / OPTIONAL — none of this is decided architecture:**
- Narrowing the activated neighborhood per-material (e.g. skip the same-row sideways checks for a pure POWDER change, since only LIQUID needs them) — a possible micro-optimization if profiling ever shows the current fixed 5-cell superset matters at scale. Not needed today.
- Extending the neighborhood set for new `MovementBehavior` kinds (FIRE, GAS, temperature/pressure) as they're added — see [Gravity Activation](#gravity-activation).
- Using activation as the trigger mechanism for future world-changing features (explosion, fluid injection, terrain deformation, material transformation) — these get correct activation automatically as long as they write through `set_cell`/`swap_cells`, requiring no changes to this system.

---

## How Future Work Should Use This Document

1. Read this document before adding any feature that changes the world (mining-like, explosion-like, or otherwise) or before touching `World::step()`, `mark_touched()`, `Chunk::sleeping`/`dirty_this_pass`, or the solvers.
2. Preserve the [Activation Invariants](#activation-invariants) and everything in [Forbidden Approaches](#forbidden-approaches).
3. A new world-changing feature should call `set_cell`/`swap_cells` (directly or via existing helpers like `fill_rect`/`place_cell`/`mine_area`) and get correct activation automatically. Do not write a parallel wake mechanism for it.
4. If a new feature's physical behavior isn't covered by the current activation neighborhood (e.g. a new solver that reads cells in a direction/pattern not listed in [Gravity Activation](#gravity-activation)), extend `activate_affected_neighbors()` deliberately and update this document — do not work around it with a feature-local hack.
5. Any change to the activation neighborhood, or to what counts as a "world change," is an architectural decision — flag it explicitly rather than folding it into an unrelated feature.
6. Re-run both the standalone test suite and the stress-test harness after any change here (see [Testing Requirements](#testing-requirements)) before considering the change complete.
7. If this document and the code ever disagree, that's a bug in one of them — fix the drift, don't silently pick one.
