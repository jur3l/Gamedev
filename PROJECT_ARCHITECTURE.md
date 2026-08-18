# PixelSim — Project Architecture

Source of truth for the technical architecture of this project. Written against the actual codebase as of this document's last update — not an aspirational design doc. Where the code and an original spec disagree, this document describes the code.

**Companion documents**, each the source of truth for one feature layered on top of this one — read the relevant one before touching that area, and treat a conflict between this document and a companion as a bug to fix, not something to silently pick a side on:
- [SIMULATION_ACTIVATION.md](SIMULATION_ACTIVATION.md) — the cross-chunk wake/activation system referenced in §6/§7 below.
- [TERRAIN_LAYERS.md](TERRAIN_LAYERS.md) — the Background/Foreground terrain layer referenced in §4/§5/§10 below.
- [PLAYER_MOVEMENT.md](PLAYER_MOVEMENT.md) — the player's movement/step-up system (§13's "custom, non-physics-engine movement code").
- [PLAYER_COLLISION.md](PLAYER_COLLISION.md) — the configurable mining-drop collision toggle, an extension of PLAYER_MOVEMENT.md's collision query.
- [MATERIAL_REACTIONS.md](MATERIAL_REACTIONS.md) — the data-driven Material Reaction System (§4/§7/§8 below).
- [MATERIALS.md](MATERIALS.md) — the material *content* built on top of the above mechanisms: the DIRT/SAND/STONE/GRAVEL/WATER/LAVA ecosystem, density/displacement, and the WATER+LAVA reaction (§8 below).
- [PERFORMANCE_SCALABILITY.md](PERFORMANCE_SCALABILITY.md) — the performance/scalability audit, the touched-rect partial chunk rendering optimization, and Phase 1 visibility-based lazy chunk rendering (§10/§12 below).
- [GPU_SIMULATION.md](GPU_SIMULATION.md) — **EXPERIMENTAL.** The Phase 2A GPU simulation feasibility PoC (a standalone SAND solver) and the renderer migration (§2 below) it required. The CPU simulation described throughout this document remains PRODUCTION/REFERENCE, completely unmodified by it.

---

## 1. Project Overview

PixelSim is a **technical prototype**, not a finished game. It exists to prove out one thing: that a Noita/Powder-Game-style, cell-based 2D material simulation can run inside Godot 4 at meaningful scale (hundreds of thousands of active cells) while staying fast, deterministic-ish, and architecturally separate from Godot's own Physics engine.

Concretely, the prototype demonstrates:

- A world made of discrete material cells (AIR, SAND, DIRT, STONE, ores, WATER, WOOD, METAL, GRAVEL, MUD, LAVA) simulated as a grid-based Cellular Automata (CA), not as physics bodies.
- Falling/settling powders (SAND, GRAVEL) and spreading liquids (WATER, LAVA), plus density-based physical displacement between them (e.g. SAND/GRAVEL sinking through WATER) — see [MATERIALS.md](MATERIALS.md).
- A player that can move, jump, mine terrain, place blocks, and auto-climb small ledges (PLAYER_MOVEMENT.md), all of which read/write the same simulation grid.
- Mining that can convert one material into another (DIRT → SAND, STONE → GRAVEL) as a real, physically-simulated cell drop, not a visual effect — including a configurable, batch-quantity conversion ratio (e.g. only half of what's mined drops) rather than a flat 1:1 conversion (see [§9](#9-mining-system)).
- A cross-chunk activation/wake system so a change in one chunk correctly wakes physically-affected, currently-sleeping material sitting in a *different* chunk (e.g. a mined-out support column revealing unsupported SAND above it) — see [SIMULATION_ACTIVATION.md](SIMULATION_ACTIVATION.md).
- A static Background terrain layer, separate from the simulated Foreground, revealed wherever the foreground is `AIR` (e.g. mined-out space reads as "inside solid rock" instead of empty void) — see [TERRAIN_LAYERS.md](TERRAIN_LAYERS.md).
- Configurable player-side toggles for how mining-drop materials are treated: an auto-step-up height limit and a mining-drop collision on/off switch — see [PLAYER_MOVEMENT.md](PLAYER_MOVEMENT.md) / [PLAYER_COLLISION.md](PLAYER_COLLISION.md).
- A data-driven Material Reaction System, where two adjacent materials can transform into two (possibly different) materials per a declarative table rather than hardcoded per-pair logic — demonstrated today by `WATER + DIRT → AIR + MUD` and `WATER + LAVA → AIR + STONE` — see [MATERIAL_REACTIONS.md](MATERIAL_REACTIONS.md).
- Chunk-based GPU rendering and chunk-based simulation scheduling (sleep/dirty), so cost scales with *activity*, not world size.
- A configurable simulation performance budget so the simulation never blocks a frame indefinitely.

**What PixelSim is not (yet):** a shipped game, a multiplayer system, a save/load system, an infinite/streaming world, a multithreaded simulation, or a GPU-resident simulation. See [§16 Current Limitations](#16-current-limitations) and [§17 Future Directions](#17-future-directions).

The technical center of gravity is the **simulation core**, implemented as a Godot 4 GDExtension written in C++ that has zero dependency on Godot itself (see [§11](#11-c--godot-boundary)). Godot (GDScript) is only the shell around it: player movement, camera, input, chunk rendering, particles, and the debug/stress-test UI.

---

## 2. Tech Stack

| Component | Actual value in this project | Notes |
|---|---|---|
| Engine | **Godot 4.7.1** (stable, official build `a13da4feb`) | Executable used for all builds/testing: `D:\Claude\Gamedev\Godot\Godot_v4.7.1-stable_win64.exe` |
| `project.godot` `config/features` | `"4.7"` | Auto-maintained by the editor |
| Native extension mechanism | **GDExtension** (not a Godot module, not GDNative) | `addons/pixelsim/pixelsim.gdextension` |
| Native bindings | **godot-cpp**, branch `4.4` (commit `b0e3b1e`), vendored as a plain clone (not a git submodule) at `addons/pixelsim/godot-cpp/` | See important caveat below |
| GDExtension API surface | Built against a **custom-dumped** `extension_api.json` + `gdextension_interface.h`, generated directly from the actual Godot 4.7.1 executable (`--dump-extension-api` / `--dump-gdextension-interface`), stored in `addons/pixelsim/api_dump/` | This, not godot-cpp's bundled default API JSON, is what the extension is compiled against — see [§2.1](#21-version-coupling-that-must-not-be-casually-changed) |
| `pixelsim.gdextension` `compatibility_minimum` | `"4.2"` | Declared minimum; actually built/tested only against 4.7.1 |
| Simulation core language | **C++17** | `addons/pixelsim/src/core`, `solvers`, `gen` — zero Godot headers |
| Godot-facing wrapper | **C++17**, godot-cpp | `addons/pixelsim/src/sim_world_node.{h,cpp}`, `register_types.{h,cpp}` |
| Gameplay layer | **GDScript** | `scripts/*.gd` |
| Build system | **SCons 4.11.0** (installed via `pip install --user scons`) | `addons/pixelsim/SConstruct` wraps `godot-cpp/SConstruct` |
| Compiler | **MSVC** from Visual Studio 2022 Build Tools **17.14.37**, `cl.exe` **19.44.35228**, toolset `14.44.35207` | Invoked via `vcvars64.bat`; no MinGW/clang toolchain has been set up or tested |
| Built targets | `platform=windows target=template_debug` **only** | `template_release` has never been built — see [§16](#16-current-limitations) |
| Renderer | `forward_plus` (Vulkan) | Set explicitly in `project.godot`. Migrated from `gl_compatibility` (OpenGL) — see [PERFORMANCE_SCALABILITY.md "Renderer Migration"](PERFORMANCE_SCALABILITY.md#renderer-migration--compatibility--forward). `gl_compatibility` does not implement Godot 4.7.1's `RenderingDevice`/compute-shader API at all (`get_rendering_device()`/`create_local_rendering_device()` both returned `null`, live-verified); Forward+ was adopted, with explicit user approval, to unblock GPU simulation feasibility work ([GPU_SIMULATION.md](GPU_SIMULATION.md)), validated with zero measured regression in simulation or rendering cost, and is now the project's ongoing development renderer, not a temporary experiment |
| Rendering primitives used | `Sprite2D` + `ImageTexture`, one pair **per chunk** | See [§10](#10-rendering-architecture) |
| Standalone core tests | Plain **C++ console executable** (`tests/test_core.cpp`), compiled directly with `cl.exe` against the core `.cpp` files — **no godot-cpp, no Godot, no GDExtension involved** | Proves the "engine-agnostic core" claim is real, not aspirational |
| Dev-only tooling | `addons/godot_mcp/` — a third-party Godot-editor MCP bridge plugin used during development for automated in-editor testing (screenshots, script execution, input simulation) | **Not part of PixelSim's architecture.** It is a development tool only; do not treat it as a game system. |

### 2.1 Version coupling that must not be casually changed

- **godot-cpp branch vs. Godot version.** The vendored godot-cpp is branch `4.4`, but the actual engine is `4.7.1`. This works *only* because the extension is built with `custom_api_file` pointing at an API JSON dumped from the real 4.7.1 binary, not godot-cpp's own bundled (older) API JSON. If godot-cpp is ever re-cloned, upgraded, or the `custom_api_file=` argument is dropped from the SCons invocation, the API surface godot-cpp generates bindings for will silently drift from the actual running engine.
- **Patched `binding_generator.py`.** The vendored copy of `godot-cpp/binding_generator.py` has been **locally patched** (this is a modification to third-party vendored code, not upstream godot-cpp behavior): `generate_global_constants()` now wraps each generated `const int64_t NAME = ...;` in `#ifndef NAME / ... / #endif`. This exists because the custom-dumped API's global-constants list includes names (`UINT8_MAX`, `INT8_MIN`, `INT64_MAX`, …) that collide with MSVC's `<cstdint>`/`<ratio>`/`<chrono>` macros; without the guard, MSVC either corrupts the declaration via macro substitution or (if the earlier `#undef`-based fix is used instead) breaks unrelated standard-library headers that still expect the macro. **If godot-cpp is re-cloned from upstream, this patch is lost and the Windows/MSVC build will fail again** with `C2059`/`C2065` errors in `global_constants.hpp`. Re-apply the patch (see the comment left in `binding_generator.py` at the patched site) before rebuilding.
- **MSVC toolchain presence is not guaranteed by the OS.** This environment did not ship with a C++ compiler; VS2022 Build Tools were installed specifically for this project. A fresh machine will need the same toolchain (or an equivalent one) before `SConstruct` can run.

---

## 3. High-Level Architecture

```
pixelsim/                                (repo root)
└── project/                             Godot project root (open this in the editor)
    ├── project.godot
    ├── scenes/Main.tscn                 auto-loading test scene
    ├── scripts/*.gd                     GDScript gameplay layer
    │    ├── main.gd                     scene orchestrator, resource counters
    │    ├── player.gd                   movement + custom grid collision
    │    ├── mining_building.gd          mining tool (shape/size), building
    │    ├── chunk_renderer.gd           chunk-based GPU rendering
    │    ├── debug_overlay.gd            HUD, chunk-debug view, material inspector
    │    ├── stress_test.gd              built-in 10k–500k SAND stress harness
    │    └── particles.gd                cosmetic GPUParticles2D only
    │
    └── addons/pixelsim/                 the GDExtension (native simulation core)
        ├── src/
        │    ├── core/                   Godot-agnostic simulation core
        │    │    ├── sim_config.h       CHUNK_SIZE, world/cell-size defaults
        │    │    ├── cell.h             Cell (2-byte POD)
        │    │    ├── chunk.h            Chunk (fixed 64×64 Cell array + state + background array)
        │    │    ├── material.h/.cpp    MaterialType, MaterialDef table
        │    │    ├── background.h/.cpp  BackgroundType, BackgroundDef table (TERRAIN_LAYERS.md)
        │    │    ├── reaction.h/.cpp    ReactionDefinition, REACTION_TABLE, find_reaction() (MATERIAL_REACTIONS.md)
        │    │    └── world.h/.cpp       World: chunk grid, step(), mining, activation, background API
        │    ├── solvers/solvers.{h,cpp}          solve_powder, solve_liquid
        │    ├── solvers/reaction_solver.{h,cpp}  try_react, roll_reaction_probability (MATERIAL_REACTIONS.md)
        │    ├── gen/terrain_gen.{h,cpp} seeded test-terrain generator
        │    ├── sim_world_node.{h,cpp}  Godot Node wrapper (PixelSimWorld)
        │    └── register_types.{h,cpp}  GDExtension entry point
        ├── godot-cpp/                   vendored bindings (branch 4.4, patched)
        ├── api_dump/                    extension_api.json dumped from Godot 4.7.1
        ├── bin/                         compiled libpixelsim.windows.*.dll
        ├── tests/test_core.cpp          standalone (non-Godot) core tests
        ├── SConstruct
        └── pixelsim.gdextension
```

### Layer responsibilities

```
Game (Godot 4.7.1, gl_compatibility)
 │
 ├── GDScript layer (scripts/*.gd)
 │    ├── Player            — its own kinematics; NOT simulated as cells
 │    ├── Rendering (chunk_renderer.gd) — turns simulation cell data into Sprite2D/ImageTexture
 │    ├── Mining/Building (mining_building.gd) — user input → PixelSimWorld API calls
 │    └── Debug/UI (debug_overlay.gd, stress_test.gd) — introspection, not simulation
 │
 └── PixelSim GDExtension (addons/pixelsim, C++)
      ├── sim_world_node.cpp   — the ONLY bridge between GDScript and the core
      └── Simulation Core (core/, solvers/, gen/ — no Godot headers anywhere)
           ├── World      — owns the whole chunk grid, stepping, mining, activation, terrain gen entry point
           ├── Chunk      — 64×64 Cell block + sleep/dirty/render-dirty state + static Background array
           ├── Cell       — 2-byte POD: material id + flags
           ├── Material   — data table of per-material properties (density, behavior, mining rules, color)
           ├── Background — data table of per-cell static "revealed when foreground is AIR" set-dressing (TERRAIN_LAYERS.md)
           ├── Reaction   — data table of material-pair transformations, e.g. WATER+DIRT→AIR+MUD (MATERIAL_REACTIONS.md)
           └── Solvers    — solve_powder / solve_liquid / try_react (the actual CA rules; Background is never read by these)
```

- **Why this split:** the simulation core has no idea it's running inside Godot. It is a plain data structure plus plain functions operating on that data structure. Godot only ever sees it through the thin `PixelSimWorld` Node, which translates GDScript calls into core API calls and core results into `Dictionary`/`PackedByteArray`/`Vector2i` Variants. This is what makes the core's standalone C++ test suite possible (see [§2](#2-tech-stack)) and is treated as the most important architectural boundary in the project (see [§11](#11-c--godot-boundary)).
- **Why GDScript owns rendering, not C++:** the core never creates a single Godot Object. Rendering is chunk-granular Sprite2D/ImageTexture management living entirely in `chunk_renderer.gd`, fed by raw pixel bytes the core hands over on request.

---

## 4. Simulation Core

### World

`pixelsim::World` (`core/world.h/.cpp`) owns a **fixed-size**, pre-allocated grid of `Chunk`s (`std::vector<Chunk>`, size `chunks_x × chunks_y`, set once at construction and never resized). Default size, as configured on the `PixelSimWorld` node in `Main.tscn`, is **48×28 chunks = 1,344 chunks = 5,505,024 cells**. There is no streaming, no infinite world, and no chunk creation/destruction at runtime — mining and building only ever *write into* already-existing chunks.

Global cell coordinates are plain integers `(x, y)`. Chunk coordinates are `x / CHUNK_SIZE, y / CHUNK_SIZE` (integer division); local-in-chunk coordinates are `x % CHUNK_SIZE, y % CHUNK_SIZE`. Every public read/write on `World` (`get_material`, `set_cell`, `swap_cells`, `mine_area`, …) does this translation internally, so callers (solvers, the mining code, GDScript via the wrapper) only ever think in global coordinates.

Reads outside world bounds return `AIR` (`in_bounds()` gates it); writes outside bounds are simply rejected (`false`). This means the world edge behaves like an implicit infinite void above/around it and a hard floor/wall at its bounds — there is no wraparound and no auto-expansion.

### Chunk

A `Chunk` (`core/chunk.h`) is a fixed `CHUNK_SIZE × CHUNK_SIZE` (64×64 = 4096) block of `Cell`s, stored as an **inline `std::array<Cell, 4096>` member**, not a pointer to a separately-allocated buffer. Because `World` stores `Chunk`s directly in a `std::vector<Chunk>`, every chunk's 4096 cells sit contiguously inside one giant heap block for the whole world — there is no per-chunk allocation and no pointer-chasing between chunks.

Each `Chunk` also carries pure bookkeeping state used by the scheduler (not gameplay data):
- `sleeping` — if true, the chunk is skipped entirely during stepping.
- `dirty_this_pass` — did anything in this chunk change during the current pass.
- `last_begin_pass_id` — which pass id this chunk last had its per-pass state reset for (see [§7](#7-simulation-lifecycle)).
- `render_dirty` — independent of `sleeping`; tracks whether the *renderer* still needs to re-pull this chunk's pixels, even if the simulation itself has since gone quiet.
- `touched_min/max_x/y` — a bounding rect of cells touched this pass. **Currently tracked but not consumed anywhere** — the renderer always re-serializes the whole chunk (see [§10](#10-rendering-architecture), [§12](#12-performance-architecture)). This is a half-built optimization hook, not a working feature; do not assume it is wired in.
- `background` — a second, parallel `std::array<uint8_t, 4096>` (one `BackgroundType` byte per cell), added by the Background/Foreground layering feature (see [TERRAIN_LAYERS.md](TERRAIN_LAYERS.md)). Deliberately **not** part of `Cell` (which stays 2 bytes, unchanged) and deliberately **not** part of the simulation lifecycle above: writing it (`Chunk::set_background`) only flips `render_dirty`, never `sleeping`/`dirty_this_pass`, and it is never read by `World::step()` or any solver.

### Cell

`pixelsim::Cell` (`core/cell.h`) is:

```cpp
struct Cell {
    uint8_t material;
    uint8_t flags;
};
```

`static_assert(sizeof(Cell) == 2, ...)` enforces this at compile time. It is **not** a Godot `Object`, has no vtable, no reference counting, and no identity beyond its position in a `Chunk`'s array. `flags` currently holds two bits (6 still unused): `FLAG_UPDATED_THIS_STEP`, used to prevent a cell from being moved twice within the same simulation pass (see below), and `FLAG_REACTED_THIS_STEP`, the equivalent guard for the Material Reaction System (see [MATERIAL_REACTIONS.md](MATERIAL_REACTIONS.md) "Infinite-Loop / Same-Pass Protection") — both bits are cleared per-chunk at the start of every pass (`Chunk::begin_pass()`).

### Material

See [§8](#8-material-system) for the full material table. The key point for the simulation core: every solver dispatches purely on `MaterialDef::behavior` (`NONE`/`STATIC`/`POWDER`/`LIQUID`), never on a specific `MaterialType`. Adding a new falling/flowing material means adding a table row, not touching solver code (unless it genuinely needs a new *kind* of rule, which would be a new `MovementBehavior` case).

### Cellular Automata / movement / gravity

There is no separate "gravity system" — falling *is* the CA rule for `POWDER`/`LIQUID` materials, implemented in `solvers/solvers.cpp`:

- **`solve_powder`** (SAND, GRAVEL): try straight down; if blocked, try one diagonal-down direction then the other, with the *first-tried* direction randomized per call via `World::rand_u32()` so a flat, symmetric pile doesn't consistently favor one side.
- **`solve_liquid`** (WATER): try straight down; then diagonal-down (same random tie-break); then, if still blocked, spread sideways one cell toward whichever side is open.

"Movement" is always `World::swap_cells(x1,y1,x2,y2)` — a data swap between two `Cell`s, never object movement, never a new allocation. A cell can move at most **one step per pass** (one row down, or one cell sideways) — multi-row falls happen over multiple passes, not within a single one.

`can_displace(mover, target)`: `AIR` is always displaceable; a non-liquid mover can also displace into a liquid it's denser than (e.g. SAND sinking through WATER). Nothing else is displaceable — solids block everything, including denser powders.

### Sleeping / dirty / touched / active state

See [§6](#6-chunk-system) and [§7](#7-simulation-lifecycle) — these are chunk-system concepts, documented there in full.

### Material reactions

A cell can also *transform* rather than move: `try_react()` (`solvers/reaction_solver.cpp`) checks a POWDER/LIQUID cell's 4 orthogonal neighbors against a small, data-driven `REACTION_TABLE` (`core/reaction.cpp`) and, on a match, rewrites both cells via `set_cell()`. This is checked before movement dispatch in `World::step()`'s per-cell loop (mutually exclusive with movement for that cell this pass) — see [MATERIAL_REACTIONS.md](MATERIAL_REACTIONS.md) for the full model, matching mechanism, and why reaction detection is scoped to POWDER/LIQUID anchors only.

### Chunk boundary handling

There is no special-case code for chunk boundaries. Every solver call goes through `World::get_material`/`can_displace`/`swap_cells`, which resolve *any* global coordinate — including one that lands in a different chunk than the cell being processed — to the correct `(chunk, local)` pair. Writing into a neighboring chunk (even a currently-sleeping one) calls that chunk's `mark_touched()`, which wakes it. This is covered by `test_chunk_boundary_movement` and `test_mining_drop_chunk_boundary` in the standalone test suite.

### Randomization / direction-bias handling

Two independent mechanisms:
1. **Scan direction** alternates every full pass (`current_pass_id_ & 1`), flipping both the chunk-column iteration order and the in-row cell iteration order between left-to-right and right-to-left.
2. **Diagonal tie-break** inside `solve_powder`/`solve_liquid` is randomized per call via a single shared xorshift32 generator (`World::rand_u32()`, seeded from the world's construction seed).

Both draw from the same `World`-owned RNG stream, so a fixed `world_seed` reproduces a fixed sequence of tie-break decisions — the simulation is **deterministic given a fixed seed and a fixed sequence of external inputs** (mining/building/step calls), though this has not been formally tested for reproducibility across different `simulation_budget_ms` values (budget changes how many rows get processed per `step()` call, but not the order or outcome of any given row).

### Simulation budget

`World::step(double simulation_budget_ms)` processes rows from the bottom (`height_cells()-1`) to the top (`0`). Elapsed time is checked once **per row** (not per cell — the world/chunk-column loop for a row always finishes before the check), via `std::chrono::steady_clock`. If the budget is exceeded, the row cursor (`resume_y_`) is saved and the call returns a partial `StepStats` (`pass_completed = false`); the *next* call to `step()` resumes from that row. A pass is only considered complete, and only then does chunk sleep/wake bookkeeping finalize (`finish_pass()`), once the scan reaches row 0 in some call. This guarantees a single `step()` call — and therefore a single Godot frame calling it once via `step_simulation()` — never blocks indefinitely regardless of how much of the world is active.

`simulation_budget_ms` is a `PixelSimWorld` export property (default `4.0`, set to `4.0` again explicitly in `main.gd`), not a core-side constant — `sim_config.h` only supplies a `DEFAULT_SIMULATION_BUDGET_MS` fallback.

---

## 5. Data Model

| Type | Size / layout | Ownership | Lifetime | Why |
|---|---|---|---|---|
| `Cell` | 2 bytes, POD (`uint8_t material; uint8_t flags;`) | Owned inline by its `Chunk` | Same as the `Chunk` | Kept deliberately tiny so a full chunk (4096 cells) is only 8 KB, and a world of thousands of chunks stays a small, contiguous, cache-friendly block instead of scattering heap allocations. `static_assert`-enforced. |
| `Chunk` | `std::array<Cell, 4096>` (8 KB) + `std::array<uint8_t, 4096>` background (4 KB) + a handful of scalar/bool state fields | Owned inline by `World`'s `std::vector<Chunk>` | Same as the `World` (never individually destroyed/recreated) | Inline arrays (not pointers) means `std::vector<Chunk>` places every chunk's cell *and* background data back-to-back — one contiguous heap block for the entire world, no per-chunk allocation, no pointer chasing between chunks. The background array costs exactly 1 byte/cell, chosen over growing `Cell` itself — see [TERRAIN_LAYERS.md](TERRAIN_LAYERS.md) "Data Model". |
| `World` | `std::vector<Chunk>` (`chunks_x × chunks_y`, fixed at construction), plus a small amount of scalar scheduling state (`rng_state_`, `current_pass_id_`, `resume_y_`, per-material `mining_remainder_[]` for drop-ratio rounding) | Owned by `PixelSimWorld` via `std::unique_ptr<World>` | Created in `PixelSimWorld::init_world()`; replaced wholesale (old one destructed) if `init_world()` is called again — there is no incremental resize/rebuild path | Grid size is known and bounded up front (this is a prototype, not an infinite-world design), so full preallocation is simpler and more cache-friendly than a chunk hash map, at the cost of not supporting worlds larger than what's preallocated. |
| `MaterialDef` | Plain struct: name, behavior enum, density, several bools, hardness, RGBA color, `can_be_mined`, `mined_drop`, `drop_ratio`, `is_mining_drop` | `static constexpr` array (`MATERIAL_TABLE`), file-scope in `material.cpp` | Program lifetime, no allocation at all | Data-driven material properties so solvers and mining logic never hardcode a specific `MaterialType`. |
| `BackgroundDef` | Plain struct: name, RGBA color — deliberately much smaller than `MaterialDef` (no simulation/mining fields) | `static constexpr` array (`BACKGROUND_TABLE`), file-scope in `background.cpp` | Program lifetime, no allocation at all | Mirrors `MaterialDef`'s pattern for the same reason, but kept a distinct, smaller type so it's a compile error to hand a background value to a solver or mining check — see [TERRAIN_LAYERS.md](TERRAIN_LAYERS.md). |
| `MineResult` | `int counts[MATERIAL_COUNT]` + `int total_removed` | Returned by value from `World::mine_area` | Transient (stack/return value) | Simple fixed-size aggregation, no dynamic allocation for a mining call. |
| `StepStats` | A handful of counters/flags | Returned by value from `World::step` | Transient | Same reasoning. |

Performance-relevant decisions worth calling out explicitly (all currently true of the code, not aspirational):
- **POD `Cell`, no Godot `Object` per cell, ever.**
- **Contiguous chunk storage** (`std::vector<Chunk>` of inline arrays), not a map or per-chunk `new`.
- **Fixed-size world, preallocated once** — no runtime chunk allocation/deallocation.
- **No pointer chasing** between chunks or cells during simulation — everything is index math into flat arrays.

---

## 6. Chunk System

- **Chunk size:** `CHUNK_SIZE = 64` (`sim_config.h`), i.e. 64×64 = 4096 cells per chunk. This is a compile-time constant, not runtime-configurable.
- **World → chunk indexing:** `chunk_index = cy * chunks_x + cx`, where `cx = x / CHUNK_SIZE`, `cy = y / CHUNK_SIZE` (integer division on global cell coordinates). `World::chunk_at(cx, cy)` does this lookup; bounds are checked separately via `chunk_in_bounds`.
- **Memory layout:** see [§5](#5-data-model) — one contiguous `std::vector<Chunk>`, each `Chunk` holding its 4096 cells inline.
- **Boundary handling:** no special-casing; see [§4](#4-simulation-core).
- **Sleeping:** a chunk with `sleeping == true` is skipped in `World::step()`'s inner loop with a single `if` check per row per chunk-column — an entire 64-cell-wide row segment is skipped in O(1) when its chunk is asleep. A chunk starts `sleeping = true` at construction.
- **Dirty (`dirty_this_pass`):** set to `true` by `Chunk::mark_touched()`, which any write (`set_cell`, either side of `swap_cells`) triggers. At the end of a full pass, `end_pass()` sets `sleeping = !dirty_this_pass` — a chunk with zero activity during the pass that just finished goes to sleep; one with any activity (a real cell move, or an external write like mining/building) stays awake for at least one more pass.
- **Simulation activation:** any `World::set_cell`/`swap_cells` call — whether from a solver, `mine_area`, `place_cell`, `fill_rect`, or terrain generation — calls `mark_touched()` on the affected chunk(s), which unconditionally sets `sleeping = false`. A sleeping chunk touched by mining or a neighboring chunk's cell moving into it wakes up immediately, without waiting for the next pass to "notice." **In addition**, every `set_cell`/`swap_cells` call also runs `World::activate_affected_neighbors()` (see [SIMULATION_ACTIVATION.md](SIMULATION_ACTIVATION.md)), which wakes — via the lighter-weight `Chunk::wake()`, not `mark_touched()` — the small, fixed set of *neighboring* chunks whose cells might now behave differently (the row above and the immediate same-row sides, derived from what the solvers actually read). This is what makes a cross-chunk collapse (e.g. mining support out from under a column of SAND that sits in a different, sleeping chunk) wake correctly instead of leaving that chunk permanently asleep.
- **Render-dirty state:** tracked separately from `sleeping`/`dirty_this_pass` via `Chunk::render_dirty`, because a chunk can finish a pass and go to sleep while the *renderer* still hasn't picked up its final frame's worth of changes. `PixelSimWorld::get_and_clear_dirty_render_chunks()` is a **consuming read** — calling it clears `render_dirty` (and resets the touched-rect) for every chunk it returns, so it must be called (and its result acted on) exactly once per frame by the renderer, not queried speculatively.

**How neighboring chunks communicate:** two mechanisms, both routed through `World` (never chunk-to-chunk directly — from a solver's point of view there is no concept of "chunk" at all, only global cell coordinates). First, a solver moving a cell across a chunk boundary just calls `swap_cells` with global coordinates, and `World` routes each side of that swap to whichever chunk it actually belongs to, waking it via the normal `mark_touched()` path. Second, and independently of whether a boundary was actually crossed, every write also runs `activate_affected_neighbors()` (previous bullet) — see [SIMULATION_ACTIVATION.md](SIMULATION_ACTIVATION.md) for the full design (why this exists, the exact neighbor set, and the performance guarantees around it, e.g. that it never wakes more than a small fixed number of chunks per write).

---

## 7. Simulation Lifecycle

Actual call sequence, as implemented (not the idealized version):

```
Godot _ready() (main.gd)
  → PixelSimWorld._ready() already ran (children ready before parent),
    which called init_world() once if not yet created
  → main.gd calls sim_world.init_world() again unconditionally
      (replaces the just-created empty World with a fresh one — see note below)
  → main.gd calls sim_world.generate_test_terrain()
      (many World::set_cell calls — see §11 gen/terrain_gen.cpp)

Every Godot frame, main.gd._process(delta):
  → sim_world.step_simulation(delta)
      → World::step(simulation_budget_ms)
          for each row (bottom → top):
            for each chunk-column (scan direction alternates per pass):
              if chunk.sleeping: skip whole row-segment
              ensure_chunk_begun(chunk)   // lazy per-pass flag reset
              for each cell in the row segment:
                if cell already updated this pass: skip
                if material behavior is NONE/STATIC: skip
                try_react() against the cell's 4 orthogonal neighbors
                  (MATERIAL_REACTIONS.md) - if it fires, this cell's turn is
                  done (no movement attempt this pass); otherwise:
                dispatch to solve_powder / solve_liquid
                  → World::can_displace / World::swap_cells
                    → Chunk::mark_touched (wakes + dirties both chunks)
                    → World::activate_affected_neighbors (wakes, on suspicion only,
                       the small fixed neighborhood above/beside each written cell -
                       see SIMULATION_ACTIVATION.md; this is what lets a change in
                       one chunk wake unsupported material sitting in another)
            check elapsed time; if over budget, save resume_y_ and return early
          if the full pass completed: finish_pass()
            → for every chunk touched this pass: end_pass()
                (sleeping = !dirty_this_pass)
            → current_pass_id_++, resume_y_ = -1 (ready for a fresh pass)

Independently, every frame, chunk_renderer.gd._process(delta):
  → sim_world.get_and_clear_dirty_render_chunks()
      (consumes render_dirty + touched-rect for every chunk it returns)
  → for each returned chunk: sim_world.get_chunk_pixels(cx, cy)
      (always the FULL chunk — see §10)
  → Image.set_data(...) + ImageTexture.update(...) on that chunk's sprite

Mining/building (mining_building.gd, on input):
  → sim_world.mine_area(x, y, size, shape) or sim_world.place_cell(x, y, material)
      → directly calls World::mine_area / World::place_cell
        (these do NOT go through step() — they take effect immediately,
         synchronously, outside the row-by-row pass loop)
```

Two things worth being explicit about because they diverge from a "clean" textbook lifecycle:
1. **`init_world()` runs twice at startup** (once from `PixelSimWorld._ready()`, once explicitly from `main.gd._ready()`), and the second call silently discards the first `World` instance. This is harmless (the first one is never used for anything) but is real, observable behavior, not a design choice with a stated rationale.
2. **Mining and building are not part of the row-by-row simulation pass.** They mutate the grid directly and immediately, and rely entirely on `mark_touched()`'s wake/dirty side effects to make sure the *next* `step()` call picks up any resulting activity (e.g. an unsupported column of sand now needing to fall). There is no "pending mutation queue" — the effect is visible to `get_cell`/`get_material` the instant the mining/building call returns.

---

## 8. Material System

`MaterialType` (`core/material.h`) is a `uint8_t`-backed enum, **append-only by convention** (a comment in the header states this explicitly, because `Cell::material` stores the raw value and any future save format would depend on the ordering):

```
AIR, SAND, DIRT, STONE, IRON_ORE, COPPER_ORE, WATER, WOOD, METAL, GRAVEL, MUD, LAVA
```

`MovementBehavior` is a separate, small enum (`NONE`, `STATIC`, `POWDER`, `LIQUID`) that every solver dispatches on — see [§4](#4-simulation-core).

`MaterialDef` (one `static constexpr` row per material, in `material.cpp`) currently carries:

| Field | Used by | Status |
|---|---|---|
| `name` | `get_material_name()` (Godot-exposed, drives the in-game material inspector) | Implemented |
| `behavior` | Solver dispatch in `World::step` | Implemented |
| `density` | `material_can_displace` (denser powder sinks through less-dense liquid) | Implemented |
| `is_solid` / `is_liquid` / `is_powder` / `is_static` | Descriptive flags | `is_liquid` is used by `material_can_displace`; the others are not currently read anywhere in solver/mining logic (kept for clarity/future use, not dead in the sense of being wrong, just not yet load-bearing) |
| `is_flammable_stub` | — | **Reserved, unused.** Explicitly named `_stub` for future FIRE-type materials. |
| `hardness` | — | **Reserved, unused.** Intended for future per-material mining speed. |
| `color_r/g/b/a` | `get_chunk_pixels()` (rendering) | Implemented |
| `can_be_mined` | `World::mine_area` | Implemented |
| `mined_drop` | `World::mine_area` | Implemented |
| `drop_ratio` | `World::compute_drop_count` (via `mine_area`) | Implemented — fraction of a mined *quantity* (not per-cell) that becomes `mined_drop` cells; see [§9](#9-mining-system) |
| `is_mining_drop` | `PixelSimWorld::is_mining_drop_material()` (consumed by `player.gd`'s collision query) | Implemented — see [PLAYER_COLLISION.md](PLAYER_COLLISION.md). The simulation core itself never reads this field; it exists purely for the player-collision classification described there. |

### Current material table (from `material.cpp`)

| Material | Behavior | Density | `can_be_mined` | `mined_drop` | `drop_ratio` | `is_mining_drop` |
|---|---|---|---|---|---|---|
| AIR | NONE | 0.0 | false | AIR | 1.0 | false |
| SAND | POWDER | 1.6 | **false** | AIR | 1.0 | **true** |
| DIRT | STATIC | 1.5 | true | **SAND** | **0.5** | false |
| STONE | STATIC | 2.6 | true | **GRAVEL** | **0.5** | false |
| IRON_ORE | STATIC | 3.0 | true | AIR | 1.0 | false |
| COPPER_ORE | STATIC | 2.9 | true | AIR | 1.0 | false |
| WATER | LIQUID | 1.0 | true | AIR | 1.0 | false |
| WOOD | STATIC | 0.9 | true | AIR | 1.0 | false |
| METAL | STATIC | 7.8 | true | AIR | 1.0 | false |
| GRAVEL | POWDER | 1.9 | **false** | AIR | 1.0 | **true** |
| MUD | STATIC | 1.6 | true | AIR | 1.0 | false |
| LAVA | LIQUID | **3.2** | true | AIR | 1.0 | false |

MUD exists only as a product of the Material Reaction System (`WATER + DIRT → AIR + MUD`, see [MATERIAL_REACTIONS.md](MATERIAL_REACTIONS.md)), never placed by terrain generation. It is deliberately `is_mining_drop = false`: that field means "exists only as a **mining**-drop product," a narrower, unrelated concept from "exists only as a **reaction**-drop product" — see MATERIAL_REACTIONS.md for why this is a correct non-match, not a gap.

LAVA is the second `LIQUID` material (see [MATERIALS.md](MATERIALS.md) for the full material-ecosystem writeup) and reuses `solve_liquid()` verbatim — no `solve_lava()` was written. It is distinguished from WATER purely by data: a density (3.2) deliberately higher than every other material in the table (including STONE), so nothing here ever sinks through it, and by being the second reactant in the `WATER + LAVA → AIR + STONE` reaction (MATERIAL_REACTIONS.md). WATER and LAVA never physically displace each other (`material_can_displace` never lets one liquid displace another, regardless of density) — their only interaction is the reaction system.

`can_be_mined` and `mined_drop` are deliberately independent fields — a material can be minable with no drop (`mined_drop == AIR`, i.e. "just clear it"), and the table format allows a drop mapping to exist without that alone implying minability (mining code always checks `can_be_mined` first; nothing infers minability from whether `mined_drop` is set). This is why SAND and GRAVEL — themselves the *product* of mining DIRT/STONE — are not re-minable: it's what prevents an infinite DIRT → SAND → (mine again) → SAND loop.

Ore (`IRON_ORE`/`COPPER_ORE`) is minable but has no drop mapping (`mined_drop = AIR`) — the ore is instead tracked through `MineResult.counts[]` (the *original* material mined, independent of what if anything it converts into) and turned into a GDScript-side resource counter by `mining_building.gd`. This is why ore mining and DIRT/STONE mining can share the same `World::mine_area` code path even though only the latter produces a physical drop cell.

`drop_ratio` is applied to a mined *batch's* quantity, never per individual cell — see [§9](#9-mining-system) for the exact algorithm (`World::compute_drop_count`). `is_mining_drop` is unrelated to mining mechanics entirely; it exists only so `player.gd` can classify SAND/GRAVEL as "collision-configurable" without adding per-cell state — see [PLAYER_COLLISION.md](PLAYER_COLLISION.md).

Future materials the table format already supports without further core changes: anything expressible as a name + behavior + density + color + `can_be_mined`/`mined_drop`/`drop_ratio`/`is_mining_drop` set — e.g. `COPPER_ORE → COPPER_ORE_CHUNK`, `ICE → ICE_CHUNK`. LAVA is a real, shipped example of exactly this: a second `LIQUID` material added as pure data (see above), no core changes required. Anything needing a genuinely new *movement rule* (FIRE spreading, GAS rising, temperature/pressure) would need a new `MovementBehavior` case and solver, not just a table row — that is future/unimplemented work (see [§17](#17-future-directions)).

---

## 9. Mining System

Entry point: `World::mine_area(center_x, center_y, size, MiningShape shape)` (`core/world.h/.cpp`). `World::mine_circle(x, y, radius)` still exists as a thin backward-compatible wrapper (`mine_area(..., MiningShape::CIRCLE)`).

**Cell selection:** for every `(dx, dy)` in `[-size, size]²`:
- `CIRCLE`: keep only cells with `dx² + dy² ≤ size²`.
- `SQUARE`: keep everything in the bounding box (`size` is a *half-side-length*, so `size=8` mines a 17×17 box) — no extra containment check beyond the loop bounds.

Both shapes and the size are fully runtime-configurable and exposed to GDScript (`PixelSimWorld.SHAPE_CIRCLE`/`SHAPE_SQUARE`, `mine_area(x, y, size, shape)`). `mining_building.gd` keeps the current tool shape/size as plain instance variables (`mining_shape`, `mining_size`, clamped `1..24`), adjustable at runtime via dedicated input actions (`mining_size_increase`/`decrease`, `toggle_mining_shape`) and drawn as a live outline at the cursor.

**How it modifies the World, in two passes:**
1. **Selection pass**, per candidate cell in the footprint: out-of-bounds and `AIR` cells are skipped; then `MaterialDef.can_be_mined` is checked. **If false, the cell/chunk/result are left completely untouched** — no clear, no drop, no dirty flag, no wake (this is the mechanism that makes mining a non-op against already-mined SAND/GRAVEL). Everything that passes is bucketed by material into a per-material coordinate list; nothing is written to the grid yet.
2. **Conversion pass**, once per material present in the selection (not once per cell): the *original* material's total mined count is tallied into `MineResult.counts[material]`/`total_removed`, then `World::compute_drop_count(remainder, mined_count, def.drop_ratio)` decides how many of that batch become drops — `floor(remainder + mined_count * drop_ratio)`, with the leftover fraction carried in a per-material `remainder` that persists for the `World`'s lifetime (so, e.g., mining 3 DIRT then 4 DIRT in two separate calls at `drop_ratio = 0.5` still yields the same total (3) as mining all 7 in one call — the ratio is never rounded per individual cell). The first `drop_count` cells (in scan order) get **one `World::set_cell(x, y, def.mined_drop)` call** each; the rest get `set_cell(x, y, AIR)`. `mined_drop` defaults to `AIR` for materials with no conversion mapping, so "just remove it" and "convert it" are the same code path, not two branches — and at `drop_ratio = 1.0` this collapses back to the original 1:1-per-cell behavior.

**How it activates surrounding simulation:** entirely through `set_cell()`'s existing `mark_touched()` side effect (see [§6](#6-chunk-system)) — there is no mining-specific activation logic. Placing a drop cell wakes its chunk immediately (observable the instant `mine_area` returns, without needing a `step()` call first), and if that drop is a `POWDER` material with open space beneath it, the very next `World::step()` call picks it up and starts moving it, exactly like any other sand cell.

**The drop is a real simulation cell, full stop** — not a particle, not a visual effect, not a side-channel object. It is written into the same `Chunk`/`Cell` storage as everything else in the world, and is picked up by the exact same `solve_powder`/`solve_liquid` code that handles naturally-generated terrain sand and water. This was verified end-to-end (both via the standalone C++ tests and live in the running editor) to fall, settle, and correctly cross chunk boundaries.

**`can_be_mined` vs. `mined_drop` — why kept separate:** see [§8](#8-material-system). The mining code never infers one from the other; a material could in principle have a `mined_drop` set and still be non-minable (the drop mapping would simply never be consulted), which is intentionally allowed by the data model even though no current material uses that combination.

**Current mining-drop mappings:** DIRT→SAND, STONE→GRAVEL (see the table in [§8](#8-material-system) for the complete picture including ore).

---

## 10. Rendering Architecture

Rendering is **chunk-granular**, never per-cell, and lives entirely on the GDScript side (`chunk_renderer.gd`) — the C++ core has no rendering code beyond one data-export function.

**C++ side — `PixelSimWorld::get_chunk_pixels(cx, cy)`:** allocates a `PackedByteArray` of `CHUNK_CELL_COUNT * 4` bytes (64×64×4 = 16,384 bytes) and, for every one of the chunk's 4096 cells, decides a color and writes it into the corresponding 4-byte slot: if the foreground cell is `AIR`, it looks up that cell's `Chunk::background` value's `BackgroundDef` color (`BackgroundType::NONE` renders fully transparent); otherwise it uses the foreground cell's `MaterialDef` color exactly as before the Background/Foreground feature. This is the **only** place that compositing decision is made (shared with `get_chunk_pixels_rect()` below via one `composite_pixel()` helper, so the rule is defined exactly once) — see [TERRAIN_LAYERS.md](TERRAIN_LAYERS.md) "Rendering" for why a second sprite/texture layer was deliberately avoided in favor of this single-buffer compositing approach. Still used as the **fallback** full-chunk path — see "Touched-rect partial update" below for when a partial path is used instead.

**Touched-rect partial update (PERFORMANCE_SCALABILITY.md, implemented):** a performance audit measured that re-serializing the *entire* 4096-cell chunk on every dirty frame — regardless of whether 1 cell or all 4096 had changed — was the dominant render-pipeline cost (see "Known rendering bottleneck" below, now historical). `Chunk::touched_min/max_x/y` (see [§5](#5-data-model)) already tracked exactly the region that changed; it was simply never read by anything. Three additions close that gap:
- `World::consume_render_dirty_rect(cx, cy)` (`core/world.h/.cpp`) — a consuming read alongside the pre-existing `consume_render_dirty()` (kept, unchanged), returning the touched-rect bounds *before* clearing them. Returns `has_rect = false` whenever there's no valid rect to report (in particular, a Background-only write, since `set_background()` deliberately never touches the touched-rect — TERRAIN_LAYERS.md) — callers must fall back to a full-chunk read in that case.
- `PixelSimWorld::get_chunk_pixels_rect(cx, cy, x, y, w, h)` — the same compositing rule as `get_chunk_pixels()`, restricted to a sub-rectangle.
- `PixelSimWorld::get_and_clear_dirty_render_chunks()` — same single full-chunk-list scan as before (no new scan added — verified to have exactly one caller before its return shape changed), now returning a `Dictionary` per dirty chunk (`coord`, `full`, and when not full: `x`/`y`/`w`/`h`) instead of a bare `Vector2i`, since the touched-rect must be read in the same pass that clears it.

**GDScript side — `chunk_renderer.gd`:**
- Each sprite is positioned at `(chunk_x, chunk_y) * CHUNK_SIZE * simulation_cell_size` in world space, scaled by `(simulation_cell_size, simulation_cell_size)`, and set to `CanvasItem.TEXTURE_FILTER_NEAREST` — i.e. one simulation cell becomes one texel, upscaled with hard pixel edges, never interpolated.
- Every `_process(delta)`, calls `get_and_clear_dirty_render_chunks()` (a **consuming** read — see [§6](#6-chunk-system)) and, for each chunk it returns *that currently has a render resource* (see "Visibility-based lazy chunk rendering" below — offscreen chunks are silently skipped here, their dirty state still drained at zero texture cost): if the touched rect covers ≥50% of the chunk's cells or no valid rect was reported, falls back to the original full-chunk `get_chunk_pixels()` + `Image.set_data()` path (**kept, unchanged, still the necessary fallback** for background-only and bulk/terrain-gen writes); otherwise fetches only the touched sub-rect via `get_chunk_pixels_rect()` and patches it into the persistent `Image` via `Image.blit_rect()`. Either way, `ImageTexture.update()` is still called on the full `Image` — Godot 4.7.1's public API (`Image`/`ImageTexture`/`RenderingServer`, verified against this project's own `extension_api.json` dump) has no partial/regional GPU texture upload method, so the GPU-upload stage's cost is an unavoidable fixed cost per dirty chunk regardless of touched-rect size; only the CPU-side pixel-gen/marshal/patch steps shrink. See PERFORMANCE_SCALABILITY.md for the full investigation and measured before/after numbers.

**Visibility-based lazy chunk rendering (PERFORMANCE_SCALABILITY.md "Phase 1", implemented):** the touched-rect work above reduced the *per-frame cost* of updating a dirty chunk; this is a separate optimization reducing the *total resident render-resource footprint*. Two concepts, kept deliberately distinct:
- **Simulation chunk state** (`World`'s `Chunk` objects, C++) — **always exists**, for the entire world, completely independent of rendering. Unaffected by anything below; an offscreen chunk simulates, sleeps, wakes, and crosses chunk boundaries exactly as if it were resident.
- **Render resource** (a chunk's `Sprite2D`+`Image`+`ImageTexture`) — exists **only while "resident"**: within the camera's current visible chunk region plus a configurable preload margin (`@export var preload_margin_chunks: int = 2`). `chunk_renderer.gd`'s `sprites` dictionary now holds entries **only** for resident chunks — this is the single source of truth for "does this chunk have a render resource right now."
- **The single, central visibility calculation** lives in `chunk_renderer.gd`'s `_compute_resident_rect()`: reads the active camera via `get_viewport().get_camera_2d()` (the same idiom already used by `mining_building.gd`/`debug_overlay.gd` — no new camera system was introduced), converts the camera's zoom-adjusted viewport into a world-space rect, then into chunk coordinates, expands by the margin, and clamps to world bounds. No second visibility calculation exists anywhere else.
- **Lifecycle**, recomputed every `_process()` frame but only acted on when the resident rect actually changes (a cheap `Rect2i` equality check gates all the work below):
  - **CREATE** — a chunk enters the resident rect: allocate its `Sprite2D`/`Image`/`ImageTexture`, then immediately do a full `get_chunk_pixels()` rebuild (never assumed blank/correct).
  - **KEEP** — stays resident: untouched by residency logic; the ordinary dirty-chunk loop (partial/full, above) keeps its texture current.
  - **RELEASE** — leaves the resident rect: `sprite.queue_free()` (Godot's own deferred deletion — the actual node removal and GPU texture release happen on the next idle/frame boundary, not synchronously) and the `sprites` entry is dropped; `Image`/`ImageTexture` are `RefCounted` and free themselves (and their GPU texture) once that was their last reference.
  - **RECREATE** — identical to CREATE. A chunk's simulation state may have changed arbitrarily while non-resident (its dirty state was being drained with no texture upload the whole time — see above), so a full rebuild is always correct here, never redundant.
- Dirty-chunk processing runs **before** the residency update within the same `_process()` call — this ordering means a chunk that becomes newly resident this frame never gets a wasted redundant partial update stacked on top of its fresh full rebuild.
- **Measured** (PERFORMANCE_SCALABILITY.md "Phase 1"): resident chunk count and GPU texture memory stayed **completely flat (63 chunks, ~17.2 MB) across an 18.3× world-size increase (5.5M → 100M cells)** — camera-bound, not world-size-bound, exactly the intended property. At the current world size, lazy vs. eager-style (all-chunks-resident) measured **21.4× less GPU texture memory** (0.98 MB vs. 21.00 MB). At 100M cells the gap widens to roughly 384× (extrapolated from this milestone's own measured per-chunk rate).

**`simulation_cell_size`** (default `4`, a `PixelSimWorld` export property) is a pure rendering/scale value. The simulation core never reads it — it only ever appears in `sim_world_node.{h,cpp}` accessors and in GDScript's own coordinate math (world-pixel ↔ cell-coordinate conversion in `player.gd`, `mining_building.gd`, `debug_overlay.gd`).

**C++ → GDScript → Godot pipeline, end to end:**
```
World (Cell grid, C++)
  → PixelSimWorld::get_chunk_pixels() / get_chunk_pixels_rect()  [C++, RGBA8 PackedByteArray - full chunk or touched sub-rect]
  → chunk_renderer.gd                   [GDScript: Image.set_data (full) or Image.blit_rect (partial) + ImageTexture.update]
  → Sprite2D (nearest-neighbor, scaled by simulation_cell_size)
  → GPU / screen
```

### Known rendering bottleneck (historical baseline — measured pre-optimization)

During stress testing (see [§12](#12-performance-architecture)), the CA simulation math itself never exceeded roughly 4 ms even with 500k+ active SAND cells, but observed FPS varied widely (30–140 fps) and correlated with the **number of active/render-dirty chunks per frame**, not with total cell count. This is because every active chunk paid a full 4096-cell `PackedByteArray` rebuild plus an `Image.set_data`/`ImageTexture.update` GPU upload **every single frame it's dirty**, regardless of whether 1 cell or 4000 cells inside it actually changed. This was the verified primary rendering bottleneck (measured at ~8.75 µs/dirty-chunk, ~66% of it the C++ pixel-gen/marshalling step alone) — not the Cellular Automata logic.

**Addressed:** see "Touched-rect partial update" above and [PERFORMANCE_SCALABILITY.md](PERFORMANCE_SCALABILITY.md) for the full measurement, implementation, and before/after numbers (~41% total render-cost reduction for the realistic small-scattered-change workload at this world's current worst case). This paragraph is kept as the historical baseline the fix was measured against, per this document's policy of not deleting superseded benchmarks.

---

## 11. C++ / Godot Boundary

This is the boundary the project treats as load-bearing (see [§13](#13-architectural-invariants)).

**Strictly Godot-agnostic (no Godot headers may be included here):**
- `core/sim_config.h`, `core/cell.h`, `core/chunk.h`, `core/material.h/.cpp`, `core/world.h/.cpp`
- `solvers/solvers.h/.cpp`
- `gen/terrain_gen.h/.cpp`

Verified by the fact that `tests/test_core.cpp` compiles and links these files directly with plain `cl.exe`, with **no** `godot_cpp` include path and **no** link against `libgodot-cpp` or `libpixelsim` at all.

**Godot-dependent (the only two files that may `#include <godot_cpp/...>`):**
- `src/sim_world_node.h/.cpp` — the `PixelSimWorld : public Node` wrapper. This is the *only* class GDScript ever talks to.
- `src/register_types.h/.cpp` — the GDExtension entry point (`pixelsim_library_init`), registers `PixelSimWorld` with `ClassDB` at `MODULE_INITIALIZATION_LEVEL_SCENE`.

**What `PixelSimWorld` exposes to GDScript** (see `sim_world_node.h` for the authoritative list): configuration properties (`world_width_chunks`, `world_height_chunks`, `simulation_cell_size`, `simulation_budget_ms`, `world_seed`); lifecycle (`init_world`, `generate_test_terrain`); `step_simulation(delta) -> Dictionary`; grid access (`get_cell`, `set_cell`, `place_cell`, `get_material_name`, `is_mining_drop_material` — PLAYER_COLLISION.md); mining (`mine_circle`, `mine_area(x, y, size, shape)`); `fill_rect`/`spawn_material_rect`; background layer (`get_background`, `set_background`, `get_background_name` — TERRAIN_LAYERS.md); rendering support (`get_chunk_size`, `get_world_size_cells/chunks`, `get_chunk_pixels`, `get_chunk_pixels_rect` — PERFORMANCE_SCALABILITY.md, `get_and_clear_dirty_render_chunks`, `get_active_chunk_coords`, `get_sleeping_chunk_coords`); `get_stats`; and the `MaterialId`/`ToolShape`/`BackgroundId` enum constants (`MATERIAL_*`, `SHAPE_*`, `BACKGROUND_*`).

**Ownership/lifetime model:** `PixelSimWorld` owns exactly one `std::unique_ptr<pixelsim::World>`. There is no shared ownership, no reference counting of the `World` or any of its internals, and no Variant ever holds a raw pointer into simulation memory — every value crossing the boundary (`Dictionary`, `PackedByteArray`, `Vector2i`, `String`, `int`) is a copy. GDScript never receives a handle to a `Chunk` or `Cell` directly.

**What must not be blurred:** the core must never be given a reason to `#include` a Godot header, construct a Godot `Object`, or depend on the scene tree; conversely, `sim_world_node.cpp` should stay a thin translation layer (Variant marshalling in, plain-C++ calls out) rather than accumulating simulation logic of its own. If a feature needs new simulation behavior, it belongs in `core/`/`solvers/`/`gen/`, with `sim_world_node.cpp` only adding the corresponding binding.

---

## 12. Performance Architecture

### CURRENT DESIGN

- **Chunking** — the unit of both simulation scheduling and rendering scheduling, fixed at 64×64 cells.
- **Sleeping** — whole chunks are skipped (O(1) per row-segment) when inactive; see [§6](#6-chunk-system).
- **Dirty state** (simulation-side `dirty_this_pass`, render-side `render_dirty`) — decoupled from each other on purpose, so the renderer and the scheduler each only do work when *they* have something to do.
- **Simulation budget** — `step()` is resumable across frames and never blocks indefinitely; see [§4](#4-simulation-core).
- **Preallocation** — the entire chunk grid is allocated once at `World` construction; no runtime chunk allocation.
- **Contiguous memory** — `std::vector<Chunk>` of inline `std::array<Cell,4096>`; see [§5](#5-data-model).
- **Single-threaded simulation** — `World::step()` runs entirely on the calling (main/game) thread. There is no threading anywhere in the C++ core or the GDScript layer.
- **Rendering strategy** — see [§10](#10-rendering-architecture); chunk-granular Sprite2D/ImageTexture, touched-rect partial texture update when the changed region is small, full-chunk re-upload as the fallback (background-only writes, or a touched region covering ≥50% of the chunk) — see [PERFORMANCE_SCALABILITY.md](PERFORMANCE_SCALABILITY.md).

### Performance & Scalability Audit (PERFORMANCE_SCALABILITY.md)

A dedicated audit measured simulation scaling, rendering scaling, dirty-chunk scaling, and memory scaling separately (never blended into one FPS number), up to a 100M-cell/24,600-chunk world (20× the current default), and identified the render pipeline's C++ pixel-gen/marshalling step as the dominant, addressable bottleneck — see [PERFORMANCE_SCALABILITY.md](PERFORMANCE_SCALABILITY.md) for the full methodology, every measured number, the touched-rect optimization this audit motivated (§10 above), and the answer to "what runs out first at 10×/20× world size" (short version: per-frame rendering CPU cost during high-activity moments, up to ~20–30× scale; GPU texture memory beyond that, due to eager visibility-independent chunk sprite/texture creation — a separate, not-yet-addressed finding).

### Stress test results (measured)

The stress-test harness (`stress_test.gd`) only spawns SAND — see [MATERIALS.md "Performance"](MATERIALS.md#performance) for an equivalent-methodology comparison (standalone `World` API, not the GDScript harness) of the pre-existing SAND-only baseline against the new WATER/LAVA-inclusive ecosystem, confirming active-chunk count still tracks the reactive/liquid region's size, not the world total, and that adding a WATER pool to a 250k-SAND scenario costs roughly the same order of magnitude as SAND alone (~+5.6% avg sim time). See [PERFORMANCE_SCALABILITY.md "Baseline"](PERFORMANCE_SCALABILITY.md#baseline) for a further, separately-dated re-run of this same harness, and its "Rendering Scaling" section for the dedicated render-pipeline stage timing this harness itself does not capture.

Using the built-in harness (`Shift+1..5` in `stress_test.gd`), default world (48×28 chunks, 5,505,024 total cells), `simulation_budget_ms = 4.0`:

| SAND cells spawned | avg FPS | min FPS | avg sim ms | max sim ms | active chunks (of 1344) |
|---|---|---|---|---|---|
| 10,000 | 31.8 | 31.0 | 0.54 | 0.99 | 53 |
| 50,000 | 36.2 | 31.0 | 0.97 | 1.95 | 101 |
| 100,000 | 30.6 | 30.0 | 1.52 | 2.12 | 53 |
| 250,000 | 139.0 | 127.0 | 2.20 | 4.07 | 8 |
| 500,000 | 97.3 | 67.0 | 2.95 | 4.06 | 161 |

**Caveats on this data:** these five runs were executed **cumulatively in one session, without resetting the world between tiers** — later tiers include leftover settled sand from earlier ones, and the 250k/500k tiers' unusually high FPS is explained by those spawns landing as wide, mostly-self-supporting slabs that settled (and went back to sleep) quickly, leaving few active chunks — not by the simulation being faster at higher cell counts. The one consistent, reliable signal across all five runs: **simulation time (`sim_ms`) stayed under ~4 ms throughout**, while FPS tracked active-chunk count (i.e. rendering cost), not cell count. This directly supports the bottleneck analysis in [§10](#10-rendering-architecture).

**This table predates the cross-chunk activation system** ([SIMULATION_ACTIVATION.md](SIMULATION_ACTIVATION.md)); a later re-run at the same tiers showed a modest (roughly 30–40%) `sim_ms` increase at comparable cell counts — expected, given `activate_affected_neighbors()` adds a small fixed amount of work to every `set_cell`/`swap_cells` call — while still staying under the ~4 ms budget throughout, and `active_chunks` still correctly returned to 0 after each tier settled. See SIMULATION_ACTIVATION.md's own Performance Requirements section for that comparison; this table is kept here as the original pre-activation baseline, not updated in place, so the "what changed" story stays visible.

### KNOWN FUTURE OPTIMIZATIONS (not implemented, not decided architecture)

These are directions identified as plausible next steps, **not** commitments or in-progress work:
- ~~Upload only each chunk's touched sub-rect to its texture~~ — **implemented**, see [§10](#10-rendering-architecture) and [PERFORMANCE_SCALABILITY.md](PERFORMANCE_SCALABILITY.md). The GPU-upload call itself (`ImageTexture.update()`) still re-uploads the whole chunk texture every dirty frame regardless of touched-rect size — confirmed, via this project's own Godot 4.7.1 API dump, that no partial/regional texture-upload method exists in the public API — so this remains a real, if now smaller, per-dirty-chunk fixed cost.
- ~~Visibility-based (camera-culled) lazy chunk sprite/texture creation~~ — **implemented** (Phase 1), see [§10](#10-rendering-architecture) and [PERFORMANCE_SCALABILITY.md "Phase 1"](PERFORMANCE_SCALABILITY.md#phase-1--lazy-rendering-visibility-based-chunk-residency). Measured flat GPU texture memory (~17.2 MB, 63 resident chunks) across a tested 18.3× world-size increase.
- Move chunk-pixel generation and/or upload to the GPU (compute shader / `RenderingDevice`) instead of round-tripping a `PackedByteArray` through Variant marshalling every frame.
- Multi-threaded chunk stepping — the sleep/dirty chunk-granular design is a plausible foundation for this, but no threading exists today.
- SIMD in the solver inner loops.
- Streaming/lazy chunk allocation for worlds larger than what fits in one preallocated block.
- Reduce `World::step()`'s idle-world cost from O(total chunks) toward O(active chunks) — the row-scan currently re-checks every chunk's `sleeping` flag once per row (64× per chunk per pass) rather than once per chunk; measured as a real, linear-with-world-size cost (still small through 100M cells) in [PERFORMANCE_SCALABILITY.md "Simulation Scaling"](PERFORMANCE_SCALABILITY.md#simulation-scaling). Touches the core scan structure, so treated as a deliberate future architectural decision, not a rendering-milestone tweak.

---

## 13. Architectural Invariants

Things that hold true throughout the current codebase and should not change without a deliberate decision (see [§14](#14-do-not-change-without-an-explicit-architectural-decision) for the subset of these with the highest blast radius):

- The simulation core (`core/`, `solvers/`, `gen/`) does not `#include` any Godot header, directly or transitively.
- `Cell` is a 2-byte POD, not a Godot `Object`, and has no per-cell identity beyond its array position.
- The world is grid/chunk-based; there is no continuous-space representation of material.
- Material simulation contains zero `PhysicsBody2D`/`CollisionShape2D`/`Area2D`/`RigidBody2D` — movement is `swap_cells()`, not physics.
- The chunk is the unit of both simulation scheduling (sleep/dirty) and render scheduling (render-dirty).
- The renderer never creates a Node/Sprite per cell — only per chunk.
- A mining drop is a real `World` cell (via `set_cell`), never a particle, visual-only effect, or side-channel object.
- Gravity/falling/flowing is implemented as CA solver rules (`solve_powder`/`solve_liquid`) operating inside `World::step()`, not as a separate physics or gravity subsystem.
- `PixelSimWorld` is the sole point of contact between GDScript and the core; nothing else in GDScript reaches into `pixelsim::` types directly (there is no way for it to, since they aren't exposed).
- Material behavior (movement rule, mining rule, color, density) is data (`MaterialDef` table rows), not per-material `if`/`else` chains in solver or mining code.
- `can_be_mined` and `mined_drop` are independent properties; neither is inferred from the other.
- The player does not exist as simulation cells and is not part of the `World` grid; it is a separate Godot node with its own (currently fully custom, non-physics-engine) movement code that *reads* the grid for collision.
- Activation propagation (waking a neighboring chunk on suspicion) is O(1)/fixed-size per world change and is never a full-world or unconditional-large-radius wake — see [SIMULATION_ACTIVATION.md](SIMULATION_ACTIVATION.md) for the complete, binding invariant list.
- The Background layer is static and never participates in the CA simulation, is never written by simulation code, and a write to it never wakes a chunk — see [TERRAIN_LAYERS.md](TERRAIN_LAYERS.md) for the complete, binding invariant list.
- Material reactions are table-driven (`ReactionDefinition`/`REACTION_TABLE`), never per-pair `if`/`switch` logic; a reaction is defined once and matches both `A+B` and `B+A`; reaction execution writes exclusively through `set_cell()` (so it inherits activation/wake for free, with no reaction-specific wake path); the Background layer is structurally unreachable from reaction code — see [MATERIAL_REACTIONS.md](MATERIAL_REACTIONS.md) for the complete, binding invariant list.
- `Cell` growth is avoided even for features that conceptually add "per-cell" data (the Background layer, mining-drop collision classification) by pushing that data to `Chunk`-level or `MaterialDef`-level (per-type) storage instead — see [§14](#14-do-not-change-without-an-explicit-architectural-decision).

---

## 14. DO NOT CHANGE WITHOUT AN EXPLICIT ARCHITECTURAL DECISION

**WHAT:** The engine is Godot 4, and the simulation core integrates via GDExtension (not a compiled-in Godot module, not GDNative, not a separate process/IPC boundary).
**WHY:** GDExtension is what makes the core buildable/testable independent of a full Godot engine build, while still shipping as a normal Godot plugin/addon. This is the foundation the rest of the architecture ([§11](#11-c--godot-boundary)) is built on.
**WHEN CAN IT CHANGE:** Only if the project's target platform or distribution model changes in a way GDExtension can't serve (e.g. a need to modify Godot's own engine source). This would invalidate large parts of §2, §3, and §11.

**WHAT:** The simulation core (`core/`, `solvers/`, `gen/`) must never `#include` a Godot header.
**WHY:** This is what keeps the core testable standalone (see the `tests/` suite) and keeps the C++/Godot boundary ([§11](#11-c--godot-boundary)) meaningful rather than nominal.
**WHEN CAN IT CHANGE:** If a future decision deliberately abandons the "engine-agnostic core" goal — at which point this document's framing of the project (§1) would also need to change.

**WHAT:** `Cell` stays a small POD (currently 2 bytes) — no Godot `Object`, no per-cell heap allocation, no per-cell Node/Sprite/PhysicsBody.
**WHY:** This is the single most load-bearing performance decision in the project — see [§5](#5-data-model) and [§12](#12-performance-architecture). It is also an explicit, repeated requirement from the original project brief.
**WHEN CAN IT CHANGE:** If a specific material genuinely needs per-cell state that can't fit in a couple of bytes, extend `Cell` deliberately (and re-measure memory/perf impact) rather than reaching for a parallel per-cell object system.

**WHAT:** `CHUNK_SIZE = 64` and the chunk-based sleep/dirty scheduling model.
**WHY:** This is the mechanism that makes simulation cost scale with activity rather than world size ([§12](#12-performance-architecture)), and changing the chunk size has correctness implications throughout `World`'s coordinate math, not just a performance tuning knob.
**WHEN CAN IT CHANGE:** If profiling on a concrete workload shows a different chunk size is measurably better — this is a tuning parameter in principle, but touching it means re-validating the full test suite and re-running the stress harness, not a casual edit.

**WHAT:** Material behavior is table-driven (`MaterialDef` + `MovementBehavior`), not per-material conditional logic in solvers or mining code.
**WHY:** This is what lets new materials (and the mining-drop system) be added by extending a table, and is explicitly required by the project's development rules ([§18](#18-development-rules)).
**WHEN CAN IT CHANGE:** If a genuinely new category of behavior is needed that the current `MovementBehavior` enum can't express (e.g. temperature/pressure-driven materials), add a new case/solver — don't special-case a `MaterialType` inside an existing solver.

**WHAT:** Rendering is chunk-granular (one Sprite2D/ImageTexture per chunk), never per-cell.
**WHY:** A per-cell Node/Sprite approach was explicitly ruled out by the original project brief and would not scale to hundreds of thousands of cells; see [§10](#10-rendering-architecture).
**WHEN CAN IT CHANGE:** If rendering moves to a GPU-buffer/compute approach (see [§17](#17-future-directions)), which would still keep the "not per-cell Godot objects" property, just via a different mechanism.

**WHAT:** The vendored `godot-cpp` (branch `4.4`) plus the locally-patched `binding_generator.py` plus the custom-dumped `extension_api.json` from the actual Godot 4.7.1 binary, used together via `custom_api_file`.
**WHY:** This specific combination is what makes the Windows/MSVC build succeed at all against Godot 4.7.1 today; see [§2.1](#21-version-coupling-that-must-not-be-casually-changed).
**WHEN CAN IT CHANGE:** If godot-cpp is upgraded to a version with native 4.7.x support and without the MSVC macro-collision issue, this combination can be simplified — but that must be a deliberate re-validation (rebuild, rerun both test suites, re-verify in the editor), not a silent `git pull` inside `godot-cpp/`.

**See also** — each companion document has its own, more detailed "DO NOT CHANGE WITHOUT AN EXPLICIT ARCHITECTURAL DECISION" section for the feature it covers, not duplicated here: [SIMULATION_ACTIVATION.md](SIMULATION_ACTIVATION.md#do-not-change-without-an-explicit-architectural-decision) (activation neighborhood, no full-world wake), [TERRAIN_LAYERS.md](TERRAIN_LAYERS.md#do-not-change-without-an-explicit-architectural-decision) (Background stays static/non-simulated, `Cell` stays unchanged), [PLAYER_COLLISION.md](PLAYER_COLLISION.md#do-not-change-without-an-explicit-architectural-decision) (mining-drop collision classification is per-type, never per-cell), [MATERIAL_REACTIONS.md](MATERIAL_REACTIONS.md#do-not-change-without-an-explicit-architectural-decision) (reactions stay table-driven, no reaction-specific wake path, no second reaction-detection scan).

---

## 15. Decision Log

| Decision | Choice | Reason |
|---|---|---|
| Simulation architecture | Custom Cellular Automata over a fixed chunked grid | Explicit project requirement: Godot Physics must not represent material cells |
| Engine | Godot 4 (4.7.1 in practice) | RATIONALE UNKNOWN — inferred from current implementation; not derivable from code alone |
| Native integration | GDExtension (not a Godot module) | Keeps the simulation core buildable/testable independently of the Godot engine source itself |
| Simulation core language | C++17, zero Godot dependency | Explicit project requirement (performance-critical core in C++, engine-agnostic where possible) |
| Cell representation | 2-byte POD (`material`, `flags`) | Explicit project requirement: no per-cell Godot Object/Node/PhysicsBody; cache-friendly at scale |
| Chunk size | 64×64 cells | RATIONALE UNKNOWN beyond "starting baseline" — matches the value used throughout without a recorded quantitative justification in-code |
| World sizing | Fixed, fully preallocated at construction (no streaming) | Simpler and more cache-friendly than a chunk hash map for a bounded-scope technical prototype; explicitly a scope limitation, not a permanent design |
| Chunk scheduling | Sleep + dirty flags, chunk-granular | Standard falling-sand-sim technique to make simulation cost track activity, not world size |
| Movement mechanism | `swap_cells()` (data swap) | Explicit project requirement: material movement must be data movement, not object movement |
| Randomization | Shared xorshift32 RNG on `World`, plus alternating scan direction per pass | Avoids consistent directional bias in tie-breaking while staying deterministic for a fixed seed |
| Mining tool shape/size | `MiningShape` enum (`CIRCLE`/`SQUARE`) + runtime-configurable `size`, unified through `mine_area()` | User-requested configurability; generalized from an original fixed-radius-circle implementation |
| Mining-drop model | `MaterialDef.can_be_mined` + `MaterialDef.mined_drop`, drop placed via the same `set_cell()` path as everything else | Explicit requirement that drops be real simulation cells and that minability/drop-mapping stay independent, data-driven properties |
| Rendering unit | One `Sprite2D`/`ImageTexture` per chunk, RGBA8, nearest-neighbor filtering | Explicit project requirement: no per-cell rendering objects; chunk-based GPU-friendly rendering |
| Player collision | Fully custom stepped AABB-vs-grid collision in GDScript; no Godot Physics colliders exist for terrain | The CA grid has no physics representation to collide against; Godot's own gravity/physics integration for the player was not actually used even though `CharacterBody2D` was chosen as the node base |
| Threading | Single-threaded | RATIONALE UNKNOWN — no multithreading has been implemented or attempted; treated as a starting point, not a conclusion |
| Build toolchain | MSVC (VS2022 Build Tools) + SCons | Godot/GDExtension's standard supported toolchain on Windows; no alternative (MinGW/Clang) was evaluated |
| Cross-chunk activation | `World::activate_affected_neighbors()`, a fixed 5-cell neighborhood (row above + same-row sides) derived from the solvers' own read patterns, hooked into `set_cell`/`swap_cells` themselves rather than into mining specifically | Fixes a real bug (mined-out support leaving unsupported material in a different, still-sleeping chunk floating forever) without reintroducing full-world or unconditional-large-radius wakes; see [SIMULATION_ACTIVATION.md](SIMULATION_ACTIVATION.md) |
| Background layer storage | A second, parallel `std::array<uint8_t, 4096>` on `Chunk` (not a field added to `Cell`, not a separate rendering layer/second sprite-per-chunk) | Explicit requirement to avoid growing the performance-critical `Cell`; compositing into the same single per-chunk pixel buffer avoids doubling GPU texture/sprite count for a layer that's visible only where foreground is already transparent — see [TERRAIN_LAYERS.md](TERRAIN_LAYERS.md) |
| Mining-drop conversion ratio | `MaterialDef.drop_ratio` applied to a mined *batch's* quantity via `World::compute_drop_count` (floor + persistent per-material remainder), not rounded per individual mined cell | Explicit requirement that repeated small mining actions total the same drop count as one big one, and that fractional ratios (e.g. 0.5) behave deterministically |
| Player step-up | Custom, GDScript-only lift-and-retry inside the existing per-pixel horizontal collision loop; height configured in simulation cells (`player_step_height_cells`), converted to pixels only at point of use | Keeps the feature's meaning stable under a reconfigured `simulation_cell_size`, and reuses (rather than duplicates) the existing `_rect_blocked` collision primitive — see [PLAYER_MOVEMENT.md](PLAYER_MOVEMENT.md) |
| Mining-drop collision classification | `MaterialDef.is_mining_drop`, a per-material-type flag (not per-cell), consumed only by `player.gd`'s collision query, never by the simulation core | SAND/GRAVEL are, in the current game content, exclusively mining-drop products (never placed by generation/building), so type-level classification is exact today; see [PLAYER_COLLISION.md](PLAYER_COLLISION.md) for what would have to change if that stops being true |
| Material Reaction System | `ReactionDefinition`/`REACTION_TABLE` (data) + `try_react()` (`solvers/reaction_solver.cpp`), piggybacked on `World::step()`'s existing per-cell loop for POWDER/LIQUID cells; one new `Cell::flags` bit (`FLAG_REACTED_THIS_STEP`) bounds a cell to at most one reaction per pass | Reuses the existing pass/scan/activation machinery instead of a new lifecycle; first demo reaction is `WATER + DIRT → AIR + MUD` (not the originally-suggested `WATER + LAVA → STONE`, since `LAVA` doesn't exist; an earlier `WATER + STONE` draft was rejected after it broke `STONE`'s pervasive role as the codebase's inert floor/wall material) — see [MATERIAL_REACTIONS.md](MATERIAL_REACTIONS.md) |
| Material ecosystem (LAVA) | LAVA added as a second `MovementBehavior::LIQUID` material row (density 3.2, deliberately higher than everything else including STONE), reusing `solve_liquid()` verbatim; paired with one new `REACTION_TABLE` row, `WATER + LAVA → AIR + STONE` | Fulfills the reaction system's originally-deferred demo reaction now that LAVA exists, without any new solver/lifecycle/collision code; LAVA's density was chosen so no POWDER material sinks through it (a deliberate gameplay property, not real-world physics) — see [MATERIALS.md](MATERIALS.md) |
| Touched-rect partial chunk rendering | `World::consume_render_dirty_rect()` (new, alongside the kept `consume_render_dirty()`) + `PixelSimWorld::get_chunk_pixels_rect()` + `chunk_renderer.gd`'s partial (`Image.blit_rect`) / full (`Image.set_data`) split, threshold ≥50% touched area falls back to full | A performance audit ([PERFORMANCE_SCALABILITY.md](PERFORMANCE_SCALABILITY.md)) measured the C++ pixel-gen/marshalling step as the dominant render-pipeline cost, constant regardless of touched-rect size under the old always-full-chunk code; `ImageTexture.update()` has no partial-upload equivalent in Godot 4.7.1's public API (confirmed against this project's own `extension_api.json`), so only the CPU-side steps could be, and were, made partial — measured ~41% total render-cost reduction for the realistic small-scattered-change workload |
| Visibility-based lazy chunk rendering (Phase 1) | `chunk_renderer.gd`'s `sprites` dict now holds render resources only for "resident" chunks (camera viewport + configurable `preload_margin_chunks`), computed by one central `_compute_resident_rect()`; CREATE/RECREATE always does a full `get_chunk_pixels()` rebuild, RELEASE frees via `queue_free()` (deferred) + dropping the dict entry (`Image`/`ImageTexture` are `RefCounted` and self-release); simulation `Chunk` state is completely untouched by any of this | The prior audit's own memory analysis found GPU texture memory (~16–21 KB/chunk, measured twice independently) was the largest per-chunk cost and was paid for the *entire world* regardless of camera visibility; measured flat resident-chunk-count/GPU-memory across an 18.3× world-size increase (5.5M→100M cells) after this change, vs. a ~384×-larger cost the old eager design would have paid at 100M cells — see [PERFORMANCE_SCALABILITY.md "Phase 1"](PERFORMANCE_SCALABILITY.md#phase-1--lazy-rendering-visibility-based-chunk-residency) |
| Renderer: `gl_compatibility` → `forward_plus` | One-line `project.godot` change (`renderer/rendering_method`); `renderer/rendering_method.mobile` left untouched | `gl_compatibility` does not implement `RenderingDevice`/compute shaders at all (live-verified: both `get_rendering_device()` and `create_local_rendering_device()` returned `null`), blocking the requested GPU simulation feasibility work entirely; switched with explicit user approval after confirming zero measured regression in simulation cost, per-chunk render cost, or any correctness test — see [PERFORMANCE_SCALABILITY.md "Renderer Migration"](PERFORMANCE_SCALABILITY.md#renderer-migration--compatibility--forward) |
| GPU simulation feasibility PoC (Phase 2A, EXPERIMENTAL) | Standalone `GPUSandPoC` (`RefCounted`, GDScript) driving a ping-pong compute-shader SAND solver via a local `RenderingDevice`; "pull"-model conflict resolution (each cell independently derives its own next value from the previous buffer, no write races); not wired into `PixelSimWorld` or any production path | Answers "is GPU-resident cellular simulation worth pursuing" with measurements: correct (exact match in the no-contention case, mass-conservation + final-state equivalence in the contested case), deterministic, and 34–44× faster than CPU (compute-only) at 100–1,000 active-chunk-equivalent workloads — GO decision, see [GPU_SIMULATION.md](GPU_SIMULATION.md) |
| GPU Water solver (Phase 2B, EXPERIMENTAL) | Same infrastructure as Phase 2A, extended, not duplicated — the shader was renamed `gpu_sand_solver.glsl` → `shaders/gpu_cellular_solver.glsl` and given a `LIQUID`/WATER behavior path alongside SAND's `POWDER` path, sharing one `can_displace()` mirroring `material_can_displace()`'s exact density/liquid rules; `GPUSandPoC` itself was not renamed (its API was already material-agnostic) | A displacement-duplication bug (a cell being displaced could simultaneously "escape" to a third position, cloning itself) was found by a failing water-conservation test and fixed with a bounded, non-recursive two-tier resolution (`resolve_winner_shallow` + a displacement-aware `resolve_winner_for`) — still pull-model, still zero atomics/write races; all 16 Water tests + all 12 Phase 2A SAND tests pass; performance nearly identical in shape to Phase 2A's SAND numbers — GO decision, see [GPU_SIMULATION.md "Phase 2B"](GPU_SIMULATION.md#phase-2b--gpu-water) |

---

## 16. Current Limitations

These are observed, real limitations of the current state — documenting them is **not** a request or a plan to fix them.

- **Single-threaded simulation.** `World::step()` runs entirely on the main thread; no work is parallelized across chunks or cores.
- **Rendering CPU cost, not the CA math, remains the dominant per-frame cost at scale** — see [§10](#10-rendering-architecture)/[§12](#12-performance-architecture)/[PERFORMANCE_SCALABILITY.md](PERFORMANCE_SCALABILITY.md). The touched-rect optimization reduced it (~41% for the realistic small-change workload) but did not eliminate it — the GPU-upload call (`ImageTexture.update()`) still re-uploads the whole chunk texture on every dirty frame regardless of touched-rect size, since Godot 4.7.1's public API has no partial-upload equivalent.
- ~~GPU texture memory scales eagerly with world size, independent of camera visibility~~ — **addressed.** `chunk_renderer.gd` now holds a render resource only for "resident" chunks (camera viewport + configurable preload margin), not the entire world — see [§10](#10-rendering-architecture) and PERFORMANCE_SCALABILITY.md "Phase 1". Measured flat at ~17.2 MB / 63 resident chunks across a tested 5.5M-to-100M-cell world-size range (18.3×), versus a measured ~384× larger cost the old eager design would have paid at 100M cells.
- **Idle (fully sleeping) simulation cost scales linearly with total world chunk count**, not O(1) — `World::step()`'s row-scan checks every chunk's sleep state once per row rather than once per chunk. Measured small in absolute terms through 100M cells (PERFORMANCE_SCALABILITY.md), but a real, documented, unaddressed scaling cost, not the "effectively free" behavior SIMULATION_ACTIVATION.md's framing aspires to in the strict sense.
- **Fixed, fully preallocated world.** No streaming, no chunk creation/eviction at runtime, no support for a world larger than what's allocated at `World` construction (default 48×28 chunks / 5,505,024 cells). PERFORMANCE_SCALABILITY.md measured this scales cleanly (linearly, in both memory and one-time construction cost) up through a tested 100M-cell/24,600-chunk world via the standalone `World` API — the *preallocation model itself* isn't what breaks first at that scale; see that document for what does.
- **Only the `template_debug` export target has ever been built.** `template_release` has not been built or tested; packaging/exporting this project as a release build has not been validated.
- **No save/load system** for world state at all.
- **`init_world()` runs twice at scene startup** (see [§7](#7-simulation-lifecycle)) — harmless today, but a real inefficiency/oddity, not an intentional pattern to replicate elsewhere.
- **Stress test methodology caveat:** the recorded 10k–500k results ([§12](#12-performance-architecture)) were run cumulatively without resetting the world between tiers, and the spawn shape (a wide, mostly-full-width slab) means higher tiers aren't a clean apples-to-apples scaling comparison — useful as a stability/ballpark signal, not as a rigorous scaling curve.
- **Determinism is plausible but not formally verified** across different `simulation_budget_ms` values or across engine/platform versions — only reasoned about from the code structure ([§4](#4-simulation-core)).
- **Only Windows/MSVC has actually been built and tested.** The `.gdextension` file declares Linux and macOS library paths, but neither has been built or verified.
- **Reaction detection only covers POWDER/LIQUID anchors.** A reaction between two `STATIC` materials would never be detected by the current mechanism (it piggybacks on cells `World::step()` already visits for movement) — see [MATERIAL_REACTIONS.md](MATERIAL_REACTIONS.md) "Simulation Integration". Not needed by the one reaction implemented today; a deliberate scope boundary, not an oversight.

---

## 17. Future Directions

**FUTURE / OPTIONAL — none of this is decided architecture, and none of it should be treated as implied scope for an unrelated task.**

- GPU-resident chunk buffers / compute-shader-driven rendering, to remove the per-frame `PackedByteArray` marshalling entirely and the fixed per-dirty-chunk `ImageTexture.update()` GPU-upload cost the touched-rect optimization ([§10](#10-rendering-architecture), [PERFORMANCE_SCALABILITY.md](PERFORMANCE_SCALABILITY.md)) could not remove (no partial-upload API exists in Godot 4.7.1).
- ~~Using the already-tracked `Chunk` touched-rect to do partial (sub-chunk) texture uploads~~ — **implemented**, see [§10](#10-rendering-architecture).
- ~~Visibility-based (camera-culled) lazy chunk sprite/texture creation~~ — **implemented**, see [§10](#10-rendering-architecture) and [PERFORMANCE_SCALABILITY.md "Phase 1"](PERFORMANCE_SCALABILITY.md#phase-1--lazy-rendering-visibility-based-chunk-residency).
- **GPU-resident cellular simulation** (experimental backend alongside the existing CPU reference/production backend) — the natural next step after Phase 1's lazy rendering, per PERFORMANCE_SCALABILITY.md's own roadmap. Not started; would need its own architecture document (`GPU_SIMULATION.md`) before any implementation begins.
- Multi-threaded chunk stepping, using the existing chunk-granular sleep/dirty model as the unit of parallel work.
- SIMD-optimized solver inner loops.
- Streaming/lazy chunk allocation for worlds larger than a single preallocated block (a real hash-map-or-similar chunk store instead of a flat preallocated array).
- Additional materials requiring new `MovementBehavior` kinds: FIRE, OIL, GAS, ACID, SMOKE, STEAM, temperature/pressure simulation. (LAVA no longer belongs on this list — it shipped as a second `LIQUID` material requiring no new `MovementBehavior`; see [§8](#8-material-system) / [MATERIALS.md](MATERIALS.md).)
- Building/automation-layer systems (conveyors, machines, storage, power) explicitly deferred by the original project brief.
- A `template_release` export build and cross-platform (Linux/macOS) verification.

---

## 18. Development Rules

- Prefer extending the existing architecture (chunk/cell/material/solver model) over introducing a parallel system for a similar purpose.
- Do not introduce a Godot dependency into `core/`, `solvers/`, or `gen/` for any reason — if something *needs* Godot, it belongs in `sim_world_node.cpp` or GDScript.
- Do not add per-material `if (material == X)` branches to solver or mining code — extend `MaterialDef`/`MATERIAL_TABLE` instead, per the "Solvers dispatch on `behavior`, never hardcode a specific `MaterialType`" convention already in the code.
- Do not replace or "optimize" a currently-working simulation system (chunk stepping, sleep/dirty, a solver) as an unstated side effect of an unrelated feature request — if a change to shared code is genuinely required, call it out explicitly rather than folding it in silently.
- Do not perform architectural refactors bundled into a feature change; keep them as separate, explicit work.
- Keep simulation (`core/`) and rendering (`chunk_renderer.gd` + `get_chunk_pixels`) concerns separate — the core should keep producing plain data (materials, pixels), not gain Godot-rendering-shaped API surface.
- Preserve current performance characteristics (chunking, sleep/dirty, budgeted stepping, contiguous storage) unless there is a measured (not assumed) reason to change them — see the stress-test caveats in [§12](#12-performance-architecture)/[§16](#16-current-limitations) before drawing conclusions from the existing numbers.
- When adding a new mining-drop mapping or a new minable material, edit `MATERIAL_TABLE` in `material.cpp` only — do not touch `World::mine_area`'s selection/dispatch logic unless the *mechanism* itself (not just the data) needs to change.
- New core behavior should get a corresponding standalone test in `tests/test_core.cpp` (it has no Godot dependency and is cheap to build/run — see [§2](#2-tech-stack)), not only in-editor manual verification.

---

## 19. How Future Agents Should Use This Document

1. Read this document before making any architectural change to PixelSim.
2. Preserve all items in [§13 Architectural Invariants](#13-architectural-invariants).
3. Do not modify anything listed in [§14 DO NOT CHANGE WITHOUT AN EXPLICIT ARCHITECTURAL DECISION](#14-do-not-change-without-an-explicit-architectural-decision) unless the user explicitly approves that specific change.
4. Prefer incremental changes within the existing architecture (see [§18](#18-development-rules)) over introducing a new parallel system.
5. If a requested feature conflicts with an invariant, say so and explain the conflict *before* changing the architecture to accommodate it — don't silently work around an invariant.
6. Do not fold unrelated refactors into a feature change, even a small one.
7. If a genuinely major architectural change becomes necessary and is approved, document the reason and add a row to [§15 Decision Log](#15-decision-log) — don't let this document silently drift out of sync with the code.
8. If something about the current implementation is unclear or not fully derivable from the code, say so explicitly (as this document does, e.g. "RATIONALE UNKNOWN") rather than inventing a rationale.
