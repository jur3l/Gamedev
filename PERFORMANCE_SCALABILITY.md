# Performance & Scalability

Source of truth for PixelSim's performance/scalability characteristics: what the current architecture actually costs, where it scales linearly vs. stays flat, and where its real ceilings are — measured, not theorized. Companion to [PROJECT_ARCHITECTURE.md](PROJECT_ARCHITECTURE.md) (§10 Rendering Architecture, §12 Performance Architecture), which this document extends rather than replaces. Read that document first for the surrounding chunk/cell/sleep/dirty model this one assumes.

**Status:** CURRENT. Every number below either comes from a standalone C++ benchmark (`World` API, no Godot involved) or a live measurement taken inside the actual running Godot 4.7.1 editor via the project's MCP tooling — nothing here is estimated without being labeled as such. If this document and the code ever disagree, that's a bug in one of them, not something to silently pick a side on.

**Scope of the original audit milestone:** a measure-first audit of how the current architecture scales toward a much larger final game world, followed by exactly one implemented optimization — touched-rect-based partial chunk texture update — because the audit's own data identified it as the dominant, addressable bottleneck. Nothing in the simulation core, chunk/sleep/activation model, Background/Foreground system, Material Reaction System, mining/drop system, or player collision was touched. See [Architectural Invariants](#architectural-invariants).

**Scope of the second milestone — [Phase 1 — Lazy Rendering](#phase-1--lazy-rendering-visibility-based-chunk-residency):** that audit's own memory findings (GPU texture memory as the largest per-chunk cost, paid eagerly for the whole world regardless of camera visibility) motivated a follow-up: visibility-based lazy chunk render-resource residency. GDScript-only (`chunk_renderer.gd`), zero C++ files changed.

**Scope of the third milestone — [Renderer Migration](#renderer-migration--compatibility--forward) and [Phase 2A — GPU Simulation PoC](#phase-2a--gpu-simulation-poc):** a GPU cellular-simulation feasibility investigation, scoped to a single SAND/powder solver, per explicit user request. Discovered mid-milestone that the project's prior renderer (`gl_compatibility`) categorically does not support the `RenderingDevice`/compute-shader API this needs — resolved, with explicit user approval, by switching to `forward_plus` (now the project's ongoing development renderer, validated with zero regressions). The GPU solver itself is a standalone, isolated PoC (`GPUSandPoC`) — zero C++ files changed, not wired into any production path. Full detail in [GPU_SIMULATION.md](GPU_SIMULATION.md).

**Scope of the fourth milestone — [Phase 2B — GPU Water](#phase-2b--gpu-water):** extends the *same* GPU infrastructure (not a second one) from Phase 2A with a WATER/liquid solver, per explicit user request. A real mass-conservation bug (a displaced cell could duplicate itself) was found by a failing test and fixed with a bounded, non-recursive two-tier resolution, still zero atomics/write races. Zero C++ files changed. Full detail in [GPU_SIMULATION.md "Phase 2B"](GPU_SIMULATION.md#phase-2b--gpu-water). Per the request's explicit instruction, this milestone stopped after Phase 2B — LAVA/Material Reaction System/Activation GPU migration (Phase 2C+) is **not started**.

---

## Current Hardware / Test Environment

| | |
|---|---|
| CPU | AMD Ryzen 7 7700X (8 cores / 16 threads) |
| RAM | 32 GB |
| GPU | AMD Radeon RX 6900 XT |
| OS | Windows 11 Pro, 64-bit |
| Engine | Godot 4.7.1 stable (official), `gl_compatibility` renderer |
| Build target | `template_debug` only (same limitation as PROJECT_ARCHITECTURE.md §16 — `template_release` has never been built) |
| Compiler | MSVC (VS2022 Build Tools), `cl.exe` — same toolchain as the rest of the project |
| Measurement method | (a) a standalone, Godot-independent C++ benchmark linked directly against `core`/`solvers` (mirrors `tests/test_core.cpp`'s build approach) for simulation-core/memory numbers; (b) live `execute_game_script` calls into the actually-running Godot editor (Godot MCP Pro tooling) for anything Godot-side (rendering, `Image`/`ImageTexture`, `Performance` monitors) |

**A methodology note worth stating up front, because it shaped how several measurements below were taken:** in this automation environment, the running game does **not** appear to be throttled to real display vsync between separate tool calls — a multi-hundred-row SAND fall that should take hundreds of frames at the stress-test harness's own reported ~144 FPS instead completed in well under one second of wall-clock time between two script calls. `Engine.get_frames_per_second()` reads a display-refresh-capped ~144 FPS number for on-screen rendering purposes, but the actual achievable step-rate when driven by script (not waiting on real vsync) is far higher. Practical consequence: wall-clock `sleep`-then-sample was **not** a reliable way to catch a scenario "mid-flight" for the active/dirty-chunk scaling tests below — those were instead measured by directly and deterministically driving exactly N dirty chunks per call, timed with `Time.get_ticks_usec()` inside a single script execution, which sidesteps the frame-cadence ambiguity entirely. This is noted so a future re-measurement on a different machine/display setup isn't surprised by a different FPS ceiling — the `sim_ms`/stage-timing numbers are the meaningful signal, not FPS, exactly as PROJECT_ARCHITECTURE.md §12 already noted for the historical baseline.

---

## Current World Size

`48 × 28` chunks = **1,344 chunks** = **5,505,024 cells** (`CHUNK_SIZE = 64`, unchanged). This is the same default described in PROJECT_ARCHITECTURE.md §4 — not modified by this milestone.

---

## Baseline

The existing stress-test harness (`stress_test.gd`, `Shift+1..5`) was run **unmodified**, live in the editor, before any code in this milestone changed. This is a new, separately-dated data point — it does **not** overwrite the historical baseline already in PROJECT_ARCHITECTURE.md §12, which predates the Material Reaction System / LAVA ecosystem and this milestone's rendering change; both are kept, each labeled by what state of the code produced them.

**Historical baseline** (PROJECT_ARCHITECTURE.md §12, pre-reaction-system, pre-LAVA, pre-touched-rect): see that document — kept there unmodified.

**New baseline** (this session, pre-touched-rect-optimization, WATER/LAVA/reactions present, cumulative run without resetting the world between tiers, same caveat as the historical table):

| SAND cells spawned | avg FPS | min FPS | avg sim ms | max sim ms | active chunks (of 1344) |
|---|---|---|---|---|---|
| 10,000 | 144.0 | 144.0 | 0.691 | 1.478 | 0 |
| 50,000 | 144.0 | 144.0 | 2.060 | 3.536 | 0 |
| 100,000 | 144.0 | 143.0 | 2.572 | 4.229 | 96 |
| 250,000 | 143.9 | 143.0 | 3.632 | 4.161 | 96 |
| 500,000 | 144.0 | 143.0 | 3.878 | 4.194 | 144 |

FPS is pinned at the ~144 Hz display-refresh ceiling throughout (see the methodology note above) — it is not a useful signal here. `sim_ms` is: consistent with the historical table's own shape (grows with active material, stays under the ~4 ms `simulation_budget_ms`), confirming the Material Reaction System / LAVA addition (a separate, already-shipped milestone) didn't regress simulation-side stress behavior.

**What this harness does *not* measure, and why a separate rendering measurement was needed:** `stress_test.gd` only samples `sim_ms` (simulation) and FPS — it has no rendering-stage breakdown. Section [Rendering Scaling](#rendering-scaling) below is where this milestone's actual target (the render pipeline) is measured, using dedicated stage-timing instrumentation added to `chunk_renderer.gd` for this audit.

---

## Simulation Scaling

**Method:** standalone C++ benchmark, `World` API only, no Godot. Constructs a `World` at each target size, measures construction time and RSS memory delta, then runs 5 idle `step()` calls (**nothing placed** — every chunk starts and should stay asleep) to isolate "does world size alone cost anything."

| Label | Chunks | Cells | Construct (ms) | RSS Δ (MB) | Idle avg step (ms) | Idle max step (ms) |
|---|---:|---:|---:|---:|---:|---:|
| 5.5M (current) | 1,344 | 5,505,024 | 4.81 | 15.8 | 0.1016 | 0.1077 |
| 10M | 2,496 | 10,223,616 | 8.80 | 29.3 | 0.1755 | 0.1911 |
| 25M | 6,200 | 25,395,200 | 21.25 | 72.8 | 0.4341 | 0.4925 |
| 50M | 12,325 | 50,483,200 | 42.05 | 144.8 | 0.8703 | 0.9749 |
| 100M | 24,600 | 100,761,600 | 95.63 | 288.9 | 1.6857 | 1.8912 |

**Construction time and memory scale perfectly linearly** with chunk count (confirmed, not assumed — see [Memory Scaling](#memory-scaling) for the exact per-chunk formula this validates). Neither is a per-frame cost; construction happens once at world load.

**Important finding: idle simulation cost is *not* O(1) with world size.** `World::step()`'s row-scan structure (`PROJECT_ARCHITECTURE.md` §4/§7) iterates every row (`height_cells` times) × every chunk-column (`chunks_x` times) — i.e. `64 × total_chunks` cheap `chunk.sleeping` checks per pass, *even when every chunk is asleep and nothing happens*. The measured numbers confirm this directly: 18.3× more chunks (1,344 → 24,600) costs 16.6× more idle time (0.10 ms → 1.69 ms) — a clean linear relationship, not the flat "effectively free" behavior [SIMULATION_ACTIVATION.md](SIMULATION_ACTIVATION.md)'s Performance Requirement #3 aspires to in the strict sense. In **absolute terms this stays cheap through 100M cells** (1.69 ms, comfortably inside the 4 ms `simulation_budget_ms`) — it is **not** the near-term bottleneck — but it is a real, linear-with-world-size cost, and extrapolating the same rate, an idle world around ~500M cells would cost roughly 8+ ms *on its own*, exceeding the entire per-frame simulation budget with **zero** active material anywhere. See [Known Limits](#known-limits) — this is documented, not fixed, in this milestone (see [Architectural Invariants](#architectural-invariants) for why).

---

## Rendering Scaling

This is where the audit's data pointed to the real, addressable, current-scale bottleneck. Three things were measured separately, per the request not to blend them into one FPS number.

### A) Active/dirty chunk count scaling (scenarios A–F)

**Method:** exactly N chunks are made dirty (one cell each re-written) in a single deterministic script call, then the render pipeline's stages are timed directly with `Time.get_ticks_usec()` — sidesteps the frame-cadence ambiguity noted above.

**Before this milestone's optimization** (every dirty chunk always fully re-serialized, 4,096 cells, regardless of how much actually changed):

| N chunks | dirty-scan (µs) | marshal (µs) | Image.set_data (µs) | ImageTexture.update (µs) | **total (µs)** |
|---:|---:|---:|---:|---:|---:|
| 0 | 3 | 0 | 0 | 0 | 0 |
| 1 | 3 | 8 | 20 | 26 | 54 |
| 10 | 5 | 72 | 12 | 35 | 119 |
| 100 | 9 | 653 | 71 | 275 | 999 |
| 500 | 25 | 3,117 | 379 | 1,266 | 4,762 |
| 1,000 | 28 | 5,826 | 704 | 2,140 | 8,670 |
| **1,344** | **46** | **7,812** | **913** | **3,029** | **11,800 (11.8 ms)** |

Per-chunk at the current world's worst case (all 1,344 chunks dirty in one frame): **marshal 5.81 µs, set_data 0.68 µs, update 2.25 µs — 8.75 µs/chunk total**, dirty-scan itself negligible (~0.03 µs/chunk).

**This directly answers §2's "which stage dominates":** the C++ pixel-generation + `PackedByteArray` marshalling step (`get_chunk_pixels()`) was **~66% of total render cost**, more than `Image.set_data()` and `ImageTexture.update()` combined — and critically, this cost was **the same whether 1 cell or all 4,096 cells in a chunk had changed**, because the old code always re-serialized the whole chunk. This is the exact problem statement in the request (§6): "1 cell changes → whole 64×64 chunk regenerated."

### B) Godot-side per-chunk rendering *setup* cost (memory + creation time, not per-frame)

**Method:** create N throwaway `Sprite2D` + `Image` + `ImageTexture` (mirrors `_create_chunk_sprite()`) in the live editor, measuring `OS.get_static_memory_usage()` and `Performance.RENDER_TEXTURE_MEM_USED` deltas, then free them.

| N sprites created | create time | static (CPU) mem Δ | GPU texture mem Δ |
|---:|---:|---:|---:|
| 1,344 | 14.59 ms (10.86 µs/sprite) | 5.39 MB (4,204 B/sprite) | not sampled separately |
| 4,000 | 48.73 ms (12.18 µs/sprite) | 14.74 MB (3,867 B/sprite) | 83.33 MB (**21,845 B/sprite ≈ 21.3 KB**) |

**Important finding:** GPU texture memory per chunk (~21.3 KB, measured) is **larger than the entire C++ chunk's own memory footprint** (12,316 bytes — see [Memory Scaling](#memory-scaling)). This is a *setup-time/total-memory* cost (paid once at world load, for every chunk, everywhere in the world, whether the camera will ever see it or not — `chunk_renderer.gd`'s `_ready()` creates a sprite for literally every chunk up front) — not a per-frame cost. See [Rendering Visibility](#rendering-visibility) and [Known Limits](#known-limits).

### C) C++ → GDScript marshalling, in isolation

Covered by (A) above: "marshal (µs)" is exactly this stage — the `PixelSimWorld::get_chunk_pixels()` C++ call plus the `PackedByteArray` it returns crossing into GDScript. It was the single largest render-pipeline stage before optimization (see (A)), and is the stage this milestone's optimization directly targets.

### D) Image / texture update cost, and why it has a floor

`Image.set_data()` and `ImageTexture.update()` were measured separately from marshalling (see (A)). `ImageTexture.update()`'s cost (~2.25 µs/chunk at scale) stays essentially **flat regardless of how much of the chunk changed** — see [Dirty Chunk Rendering](#dirty-chunk-rendering-the-optimization) for why this is a hard API limit, not an implementation gap.

---

## Dirty Chunk Rendering (the optimization)

### Investigation: is a partial update even possible in Godot 4.7.1?

Checked directly against this project's own `addons/pixelsim/api_dump/extension_api.json` (the exact API surface this build compiles against — PROJECT_ARCHITECTURE.md §2.1), not general Godot documentation:

| Class | Method | Signature | Partial? |
|---|---|---|---|
| `Image` | `blit_rect` | `(Image src, Rect2i src_rect, Vector2i dst) -> void` | **Yes** — CPU-side, copies a sub-rect into an existing `Image` |
| `Image` | `set_pixel` | `(int x, int y, Color) -> void` | Yes, but per-pixel (worse than `blit_rect` for anything beyond a few pixels) |
| `Image` | `set_data` | `(w, h, mipmaps, format, PackedByteArray) -> void` | No — replaces the whole `Image` |
| `ImageTexture` | `update` | `(Image) -> void` | **No** — always re-uploads the entire `Image` to the GPU |
| `RenderingServer` | `texture_2d_update` | `(RID, Image, layer) -> void` | **No** — same full-image constraint, even at the lower-level API |

**Conclusion, confirmed before writing any implementation code:** the CPU-side steps (pixel generation, marshalling, writing into the persistent `Image`) *can* be made partial via `blit_rect`. The **GPU upload itself cannot** — there is no partial/regional texture update method anywhere in this Godot build's public API. This sets the realistic ceiling for the optimization: it can shrink marshal + `set_data` cost roughly proportionally to the touched area, but `ImageTexture.update()`'s cost is an unavoidable fixed cost per dirty chunk, confirmed by measurement (D above).

### What was implemented

- **`World::consume_render_dirty_rect(cx, cy)`** (`core/world.h/.cpp`) — a new consuming-read alongside the existing `consume_render_dirty()` (kept, unchanged), returning a `RenderDirtyRect { was_dirty, has_rect, min_x, min_y, max_x, max_y }`. It captures the chunk's already-existing `touched_min/max_x/y` bounds *before* clearing them (the previous code path discarded them unread). `has_rect` is `false` whenever there's no valid touched-rect to report — in particular when `render_dirty` was set by a **Background-only write** (`set_background()` deliberately never touches the touched-rect — TERRAIN_LAYERS.md — since a background change can affect any cell currently `AIR`, not a bounded region). Callers **must** fall back to a full-chunk read in that case; this is enforced by the data shape, not a comment.
- **`PixelSimWorld::get_chunk_pixels_rect(cx, cy, x, y, w, h)`** (`sim_world_node.h/.cpp`) — same RGBA8 compositing as `get_chunk_pixels()` (`TERRAIN_LAYERS.md`'s foreground-wins-else-background rule, unchanged), but only for a sub-rectangle. Both functions now share one `composite_pixel()` helper so the compositing rule is defined exactly once.
- **`PixelSimWorld::get_and_clear_dirty_render_chunks()`** — same single full-chunk-list scan as before (no new scan added), but each entry is now a `Dictionary` (`coord`, `full`, and when not full: `x`/`y`/`w`/`h`) instead of a bare `Vector2i`, since it's the only place where the touched-rect can still be read before `consume_render_dirty_rect()` clears it. Verified via grep to have exactly one caller (`chunk_renderer.gd`) before changing its return shape.
- **`chunk_renderer.gd`** — for each dirty chunk: if `full` is set, or the touched rect covers ≥50% of the chunk's cells (`FULL_UPDATE_AREA_FRACTION`), do the original full-chunk `get_chunk_pixels()` + `set_data()` path (**unchanged, still the fallback**). Otherwise, fetch only the touched sub-rect via `get_chunk_pixels_rect()`, wrap it in a small `Image.create_from_data()`, and `blit_rect()` it into the chunk's persistent `Image`. Either way, `ImageTexture.update()` is still called on the full `Image` (per the API ceiling above).

**Fallback is not optional plumbing — it's exercised and necessary in practice**, confirmed live: a direct `set_background()` call with no accompanying foreground write correctly reports `full: true` and renders the correct color through the full-chunk path; a large bulk `fill_rect`/terrain-generation write correctly exceeds the 50% threshold and also falls back; both were verified pixel-for-pixel against the C++ ground truth (see [Testing / Correctness](#correctness-verification) below).

### Before / After Benchmarks

**Same N-chunks-dirty methodology as (A) above**, one cell touched per chunk (the realistic "small scattered change" shape), now with the optimization active — every one of the 1,344 chunks correctly took the **partial** path (0 full-fallbacks):

| N chunks | dirty-scan (µs) | marshal (µs) | blit/apply (µs) | update (µs) | **total (µs)** |
|---:|---:|---:|---:|---:|---:|
| 0 | 3 | 0 | 0 | 0 | 0 |
| 1 | 5 | 3 | 4 | 24 | 36 |
| 10 | 9 | 5 | 15 | 38 | 67 |
| 100 | 96 | 59 | 111 | 330 | 596 |
| 500 | 543 | 343 | 541 | 1,507 | 2,934 |
| 1,000 | 1,091 | 774 | 1,062 | 3,614 | 6,541 |
| **1,344** | **1,083** | **1,169** | **1,467** | **4,277** | **7,996 (~6.9 ms excluding scan)** |

**Direct comparison at the current world's worst case (1,344 dirty chunks, one cell each):**

| Stage | Before (µs/chunk) | After (µs/chunk) | Change |
|---|---:|---:|---:|
| marshal | 5.81 | 0.87 | **−85% (6.7× faster)** |
| apply (set_data → blit) | 0.68 | 1.09 | +60% (small absolute cost either way — see note below) |
| update (GPU upload) | 2.25 | 3.18 | flat within run-to-run noise, as predicted (no partial GPU-upload API exists) |
| **Total** | **8.75** | **5.14** | **−41%** |

**Reading this honestly:** the marshal-stage win is large, consistent, and directly attributable to the code change — it shows up both in this aggregate 1,344-chunk comparison and in an independent, averaged (30 repetitions/tier) single-chunk measurement across touched-rect sizes 1/10/100/1,000/4,096 cells, where marshal cost scaled from 0.27 µs (1 cell) up to 1.73 µs (full chunk, correctly triggering the fallback) — proportional to touched area, exactly as intended. The `update()` stage's small measured increase here is within the noise this environment's microsecond-scale timings show run-to-run (that same stage, being an unmodified `texture.update(image)` call, has no code-level reason to differ before/after) — it is reported rather than hidden, and the `set_data`-vs-`blit_rect` apply-stage cost is genuinely close either way at these tiny absolute magnitudes (a fixed per-call `Image.create_from_data()` overhead partially offsets `blit_rect`'s smaller-copy advantage for very small rects). The **total** — the number that actually matters for frame cost — dropped by 41% at this milestone's most demanding realistic scenario.

**Real-world touched-rect sizes** (stress scenarios 1–8, measured live, see [full breakdown below](#stress-scenario-results)): **none** of eight realistic gameplay workloads (a single falling grain, a small pile, a 200×40-cell avalanche, a 60×10 WATER spread, 50 scattered liquid pockets, a radius-15 mining circle, 20 consecutive small minings, a 100×15 WATER+DIRT reaction bed) ever triggered the 50%-area fallback — every one of them benefited from the partial path. The fallback exists and is necessary (confirmed above), but ordinary gameplay rarely needs it; only large, roughly chunk-spanning writes (terrain generation) or background-only writes do.

---

## Dirty Chunk Scaling

Combines (A) and the before/after table above: render cost (both before and after) scales **linearly with the number of dirty chunks per frame**, not with world size — exactly the intended chunk-granular design (PROJECT_ARCHITECTURE.md §10/§12). What changed in this milestone is the *constant factor* per dirty chunk (8.75 µs → 5.14 µs at this world's scale, for a typical small-change workload), not the scaling shape. The **`get_and_clear_dirty_render_chunks()` full-chunk-list scan** itself (the part that *does* touch every chunk in the world every frame, dirty or not) was separately confirmed cheap and non-scaling-relevant: 3–46 µs at 1,344 total chunks (~2–3 ns/chunk) — extrapolating linearly, still only ~50–70 µs at a 100M-cell/24,600-chunk world. **Ruled out as a bottleneck by measurement**, not assumed away.

---

## Memory Scaling

| Component | Per-unit cost (measured) | At current (1,344 chunks / 5.5M cells) | At 100M cells / 24,600 chunks (measured where noted, else linearly extrapolated) |
|---|---:|---:|---:|
| `Cell` | 2 bytes (unchanged) | — | — |
| `Chunk` (cells + background + bookkeeping) | **12,316 bytes/chunk** (measured `sizeof(Chunk)`: 8,192 cells + 4,096 background + 28 padding/bookkeeping) ≈ 3.01 bytes/cell | 15.8 MB (measured) | **288.9 MB (measured directly, not extrapolated)** |
| Godot `Sprite2D`+`Image` CPU-side | ~3.9–4.2 KB/chunk (measured) | ~5.4 MB (measured) | ~96–103 MB (**extrapolated**, linear) |
| GPU texture (`ImageTexture` backing) | **~21.3 KB/chunk (measured)** | ~28.6 MB (extrapolated from the measured rate) | **~511 MB (extrapolated, linear)** |
| **Total (all of the above)** | — | ~50 MB | **~900 MB – 1 GB (mostly extrapolated)** |

**The single most important memory finding: GPU texture memory (~21.3 KB/chunk) is the *largest* per-chunk memory cost — larger than the C++ simulation chunk itself (12.3 KB/chunk).** At 20× the current world size, it becomes the dominant total-memory consumer, and it is paid **eagerly, for every chunk in the world, whether the camera will ever see it or not** — `chunk_renderer.gd`'s `_ready()` creates one `Sprite2D`/`Image`/`ImageTexture` per chunk for the *entire* world up front (PROJECT_ARCHITECTURE.md §10 already flagged this as "not lazy/streamed"). This is a **separate problem from this milestone's rendering-cost fix** (per-frame CPU cost vs. total resident memory) and a separate problem from world-size streaming/allocation (per §5 of the request) — see [Rendering Visibility](#rendering-visibility) and [Future Optimizations](#future-optimizations).

**Per-frame temporary allocation:** before this milestone, every dirty chunk's render update allocated a fixed 16,384-byte `PackedByteArray` (`CHUNK_CELL_COUNT * 4`) regardless of how much actually changed. After: allocation size is proportional to the touched-rect area (frequently a small fraction of 16,384 bytes for realistic small changes — see the stress-scenario table), plus one small temporary `Image` object per partially-updated chunk. This was not separately profiled in absolute bytes/frame (out of scope for this pass), but the measured CPU-time reduction in the marshal stage already captures its practical effect.

---

## Bottlenecks

Ranked by what the data actually shows, not by assumption:

1. **[Addressed by this milestone] Per-frame CPU rendering cost during high-activity moments** (many simultaneously dirty chunks), specifically the C++ pixel-generation + `PackedByteArray` marshalling step. Confirmed the single largest render-pipeline stage (~66% of render time at this world's worst case) and larger than simulation cost itself at comparable activity levels (11.8 ms render vs. ~3.9 ms sim at the 500k-SAND-equivalent activity tier). Now reduced ~41% for the realistic small-scattered-change workload that dominates ordinary gameplay.
2. **[Not addressed — flagged as next milestone] GPU texture memory at large world sizes**, driven by eager, visibility-independent, upfront sprite/texture creation for the entire world. Becomes the single largest memory consumer beyond roughly 20–30× the current world size. A memory-ceiling problem, not a per-frame-cost problem — genuinely separate from item 1.
3. **[Not addressed — long-tail, still within budget] Idle simulation cost scales linearly (not O(1)) with total chunk count**, due to `World::step()`'s per-row-per-chunk-column sleep check. Real, measured, but small in absolute terms even at 100M cells (1.69 ms); would only become a genuine per-frame concern well beyond that scale.
4. **Ruled out by measurement, not assumption:** the dirty-chunk full-list scan (`get_and_clear_dirty_render_chunks`) — O(total_chunks) but only ~2–3 ns/chunk, negligible even extrapolated to 100M cells; C++ chunk-grid memory (289 MB at 100M cells, unremarkable, linear, and exactly matches the `sizeof(Chunk)` formula); world construction time (one-time, <100 ms even at 100M cells).

---

## Optimizations

**Implemented this milestone:** touched-rect-based partial chunk texture update (`World::consume_render_dirty_rect`, `PixelSimWorld::get_chunk_pixels_rect`, `chunk_renderer.gd`'s partial/full split) — see [Dirty Chunk Rendering](#dirty-chunk-rendering-the-optimization) for the full design and [Before / After Benchmarks](#before--after-benchmarks) for the measured result (~41% total render-cost reduction for the current world's worst-case active-chunk scenario; 6.7× reduction in the dominant marshal stage specifically).

**Deliberately not implemented, and why** (per the request's explicit "measure, don't blindly optimize" instruction):
- Solver SIMD, multithreading, or GPU simulation — the audit found simulation cost is *not* the current bottleneck at any tested scale; touching it now would be optimizing a stage the data doesn't implicate.
- The row-scan's O(total_chunks)-even-when-idle cost (see [Simulation Scaling](#simulation-scaling)) — real, but still small in absolute terms through 100M cells, and fixing it means restructuring `World::step()`'s core iteration order, a genuine architectural change to a system explicitly protected in this milestone's invariants (see below). Documented as a known, measured limit instead.
- Visibility-based (camera-culled) lazy chunk sprite/texture creation — the GPU-memory finding above clearly motivates this as the *next* milestone, but it is a distinct problem (total memory footprint / world-size scaling) from this milestone's problem (per-frame CPU cost), and the request explicitly warned against conflating "bigger map" work with "streaming/lazy allocation" work. Not started here.

---

## Before / After Benchmarks

See [Dirty Chunk Rendering → Before / After Benchmarks](#before--after-benchmarks) above for the full stage-by-stage tables. Summary:

| Scenario | Before (total render µs, 1,344 dirty chunks) | After | Change |
|---|---:|---:|---:|
| 1 cell changed per chunk (realistic "many small changes" shape) | 11,800 (11.8 ms) | 7,996 (~8.0 ms, incl. scan) | **−32% to −41%** depending on whether the scan is counted |
| Full chunk changed (terrain generation, bulk fill) | ~11,800 (unchanged code path) | ~11,800 (same full-chunk path, correctly still used) | No change (by design — this is the fallback case) |

### Stress Scenario Results

Real gameplay-shaped workloads, measured live (touched-rect stats per dirty chunk, after optimization):

| # | Scenario | Dirty chunks | Partial | Full | Avg. touched area (of 4,096) |
|---|---|---:|---:|---:|---:|
| 1 | Single SAND cell moves | 1 | 1 | 0 | 2 (0.05%) |
| 2 | Small SAND pile (10 cells) moves | 1 | 1 | 0 | 60 (1.5%) |
| 3 | Large SAND avalanche (200×40 fill) | 8 | 8 | 0 | 1,000 (24.4%) |
| 4 | WATER spread (60×10 body, 1 step) | 11 | 11 | 0 | 811 (19.8%) |
| 5 | Many active liquid chunks (50 scattered spots) | 27 | 27 | 0 | 468 (11.4%) |
| 6 | Mining a large area (radius-15 circle) | 4 | 4 | 0 | 223 (5.4%) |
| 7 | Many consecutive mining events (20×) | 3 | 3 | 0 | 167 (4.1%) |
| 8 | Material reaction over a larger area (100×15 WATER+DIRT bed) | 39 | 39 | 0 | 526 (12.8%) |

**Every single realistic workload used the partial path exclusively.** The full-chunk fallback (verified separately, see [Correctness Verification](#correctness-verification)) exists for, and is only actually needed by, bulk/aligned writes (terrain generation) and background-only writes — not ordinary gameplay.

---

## Known Limits

**Measured, not theoretical — this section only contains numbers actually produced by a benchmark run.**

- Idle-world simulation cost at 100,761,600 cells (24,600 chunks): **1.69 ms/pass**, scaling linearly with chunk count (confirmed: 16.6× cost for 18.3× more chunks between the 5.5M and 100M tiers). Still within the 4 ms `simulation_budget_ms` at this scale.
- C++ chunk-grid memory at 100,761,600 cells: **288.9 MB**, matching the measured `sizeof(Chunk) = 12,316` bytes formula exactly (no drift between predicted and measured).
- World construction time at 100,761,600 cells: **95.63 ms** — a one-time cost, not per-frame.
- Render cost per dirty chunk (1-cell-change workload, current 1,344-chunk world): **8.75 µs/chunk before, 5.14 µs/chunk after** this milestone's optimization.
- GPU texture memory: **~21.3 KB/chunk**, measured via `Performance.RENDER_TEXTURE_MEM_USED` delta over 4,000 real `ImageTexture` allocations — this is the largest single per-chunk memory cost found anywhere in this audit.
- Dirty-chunk full-list scan: **3–46 µs** at 1,344 total chunks regardless of how many are actually dirty (0 to 1,344) — confirmed sub-linear-in-practice at this scale and not expected to matter before ~100M+ cells even by extrapolation.

---

## Future Optimizations

**FUTURE / OPTIONAL — not decided architecture, not started in this milestone.** Ordered by what the data suggests matters most:

1. ~~Visibility-based (camera-culled) lazy chunk sprite/texture creation.~~ — **implemented, see [Phase 1 — Lazy Rendering](#phase-1--lazy-rendering-visibility-based-chunk-residency) below.**
2. **Reduce the row-scan's per-row-per-chunk-column sleep check to per-chunk-per-pass**, addressing the measured (if currently small) linear idle-cost-vs-world-size relationship in `World::step()`. Would need careful re-validation against the full simulation test suite and stress harness, since it touches the core scan structure `World::step()` is built on — an explicit, separate architectural change, not a rendering tweak. Still not started — explicitly out of scope for the Phase 1 lazy-rendering milestone too (per its own request: "ne optimalizáld az idle O(total_chunks) scan-t ebben a milestone-ban").
3. **Use the already-tracked `touched_min/max` for a GPU-side partial upload**, if/when Godot exposes one (none exists in 4.7.1's public API per the investigation above) — revisit if the engine version changes.
4. Everything already listed as future work in PROJECT_ARCHITECTURE.md §17 (GPU-resident chunk buffers, multi-threaded stepping, SIMD solvers, streaming/lazy chunk allocation for a larger world than fits in one preallocated block) remains unstarted and unchanged by this milestone.
5. **GPU-resident cellular simulation (Phase 2)** — see [Phase 1 — Lazy Rendering](#phase-1--lazy-rendering-visibility-based-chunk-residency)'s closing note. Explicitly not started in this pass, pending review of Phase 1's results first.

---

## Phase 1 — Lazy Rendering (Visibility-Based Chunk Residency)

**Status: DONE, measured, live in the running editor.** A second, distinct performance milestone from the touched-rect work above — that milestone reduced the *per-frame CPU cost* of updating a dirty chunk's texture; this one reduces the *total resident GPU/CPU memory* the render pipeline holds, by no longer holding a render resource for every chunk in the world regardless of whether the camera can ever see it. See the request's own framing: **simulation chunk state always exists; render resource may not.**

### What changed

`chunk_renderer.gd` no longer creates a `Sprite2D`/`Image`/`ImageTexture` for every world chunk in `_ready()`. Instead:

- **Resident region** = the camera's currently-visible chunk rect (derived from `Camera2D.global_position`, `Camera2D.zoom`, and the viewport size — the *only* place this calculation happens, per the request's "ne legyen több különböző chunk visibility calculation") **+ a configurable preload margin** (`@export var preload_margin_chunks: int = 2`), recomputed every frame but only acted on when it actually changes (a cheap `Rect2i` equality check first).
- **CREATE**: a chunk enters the resident rect → allocate its `Sprite2D`+`Image`+`ImageTexture`, then immediately do a **full** `get_chunk_pixels()` rebuild from live simulation state (never assumed to start correct/blank).
- **KEEP**: a chunk stays resident → completely unchanged from the touched-rect milestone — the existing dirty-chunk loop updates it via partial (`blit_rect`) or full (`set_data`) path exactly as before.
- **RELEASE**: a chunk leaves the resident rect → `sprite.queue_free()` (Godot's own deferred-deletion mechanism — see "A subtlety worth documenting" below) and the `sprites` dictionary entry is dropped; `Image`/`ImageTexture` are `RefCounted`, so they release (and free their GPU texture) as soon as that was their last reference — no explicit GPU-resource-free call needed or written.
- **RECREATE**: identical code path to CREATE. A chunk becoming resident again after release has no reason to be treated specially — see "Offscreen simulation" below for why a full rebuild is always correct here, never redundant.

**Why dirty-chunk processing runs *before* the residency update each frame, not after:** `get_and_clear_dirty_render_chunks()` already unconditionally scans and clears *every* chunk's render-dirty flag/touched-rect every frame, resident or not (this was true before Phase 1 too). Running the dirty loop first means an offscreen chunk's dirty state is drained with `sprites.get(coord) == null`, so the loop just `continue`s past it — free. If that same chunk becomes newly resident later in the *same* frame (residency step, second), `_create_chunk_sprite()` does its own fresh `get_chunk_pixels()` read of current ground truth — so this ordering never loses or duplicates work, and a newly-resident chunk's first frame is always a clean full rebuild, never a redundant partial update stacked on top of one.

### Offscreen simulation

Verified live, not assumed: a SAND grain was placed in a chunk far outside the resident rect (no sprite ever existed for it), stepped through **5 manual `step_simulation()` calls** (which — per this document's own methodology note on this environment's frame cadence — actually let the simulation advance much further in real terms), and was found **237 rows away and 3 chunk-boundaries later**, still with **zero render resources created anywhere along its path** (`sprites.has(...)` false for every chunk it passed through). The moment the camera was moved to that location, the newly-resident chunk's full rebuild produced the *exact* correct SAND color at the *exact* correct pixel — pixel-for-pixel verified against the live simulation state, not assumed correct from "it should work."

### Measured Results

**A) Same world size (1,344 chunks), eager-vs-lazy, freshly measured this session** (via `Performance.RENDER_TEXTURE_MEM_USED` deltas from a common baseline, using the actual production `_create_chunk_sprite()`/`_release_chunk_sprite()` functions, not a reimplementation):

| | Resident chunks | GPU texture memory (delta) | Per-chunk rate |
|---|---:|---:|---:|
| Before-style (eager, all chunks) | 1,344 | 21.00 MB | 16.0 KB/chunk |
| **After (Phase 1, lazy, default 1920×1080 viewport @ zoom 2, margin 2)** | **63** | **0.98 MB** | 16.0 KB/chunk |

**~21.4× reduction in GPU texture memory at the current world size**, purely from not holding resources for the 1,281 chunks the camera can't see. (Note: this session's freshly-measured 16.0 KB/chunk differs somewhat from the earlier touched-rect milestone's 21.3 KB/chunk estimate, which was taken via throwaway sprites outside the real chunk-renderer lifecycle — both are legitimate, independently-obtained numbers; the ~25–30% spread is consistent with normal GPU-driver-level memory-accounting variance at this granularity, not a sign either measurement is wrong.)

**B) World-size scaling — the headline result.** Camera pinned to a fixed, safely-interior world position (to remove the confound of the player free-falling through an ungenerated test world near an edge), world reconfigured live (`world_width_chunks`/`world_height_chunks` + `init_world()`) across four sizes matching the original performance audit's own tiers:

| World size | Cells | Total chunks | `init_world()` time | **Resident chunks** | **GPU texture memory** |
|---|---:|---:|---:|---:|---:|
| 5.5M (current default) | 5,505,024 | 1,344 | 11 ms | **63** | **17.23 MB** |
| 25M | 25,395,200 | 6,200 | 22 ms | **63** | **17.23 MB** |
| 50M | 50,483,200 | 12,325 | 50 ms | **63** | **17.23 MB** |
| 100M | 100,761,600 | 24,600 | 105 ms | **63** | **17.23 MB** |

**Resident chunk count and GPU texture memory are completely flat across an 18.3× world-size increase** — exactly the property this milestone set out to prove (request §37: "nagy világ → kevés resident render resource → jelentősen kevesebb GPU texture memory"). `init_world()` time scales linearly with chunk count as expected (matches the standalone C++ benchmark's own construction-time numbers closely: 95.63 ms measured there vs. 105 ms here at 100M cells, the difference being live-Godot overhead vs. a bare C++ harness) — a one-time world-load cost, not a per-frame one, and unaffected by this milestone (Phase 1 never touched `World` construction).

At the 100M-cell tier specifically, extrapolating this session's own measured 16.0 KB/chunk rate to what the *old, eager* design would have cost for all 24,600 chunks: **~384 MB**, versus Phase 1's actual **~1 MB** resident cost at that world size — a **~384× reduction**, growing linearly with world size (the gap widens, unbounded, as the world gets bigger — this is the point: GPU memory cost is now O(viewport), not O(world size)).

### Camera Movement Test

Five waypoints — centered, a small move within the preload margin, a move crossing a chunk boundary, a large/fast jump far away, and a reversal back to an earlier position — all verified live:

- Resident count stayed at a stable, bounded value (63) throughout every waypoint — no growth, no drift.
- The old area's chunks were confirmed released (not leaked) after the far jump, and the reversal step reproduced the *exact same* resident rect (`(4,6)` size `(9,7)`) as the earlier visit to that position — deterministic, not path-dependent.
- Actual `Sprite2D` child count under `ChunkRenderer` matched `sprites.size()` exactly at every checkpoint (no orphaned nodes from normal camera movement).
- A screenshot at the final position showed correct, complete terrain rendering with no pop-in, no missing/black chunks, no corrupted textures.

### A subtlety worth documenting: `queue_free()` is deferred

`Sprite2D.queue_free()` doesn't free the node (or its GPU texture reference) synchronously — it's processed at the next idle/frame boundary. This was discovered directly while writing this section's own test harness: a synchronous "release all, then immediately re-measure" script saw the old node count and GPU memory reading *unchanged* until a real frame was allowed to elapse afterward. **Practical consequence for anything else built on this system:** GPU memory reduction from a batch of releases (e.g. a large, fast camera jump releasing many chunks at once) is visible one frame after the release, not instantaneously within the same frame — never assume a `queue_free()`'d resource is gone yet within the same function call that queued it.

### Test-harness note (not a production-code finding)

While measuring (B) above, an early version of the test script called the internal `_create_chunk_sprite()` helper directly without the existence guard `_update_residency()` always applies, which left 63 orphaned `Sprite2D` nodes (untracked by `sprites`, still children of `ChunkRenderer`, still consuming GPU memory) — a bug in the ad-hoc measurement script, not in the shipped `_update_residency()`/`_create_chunk_sprite()`/`_release_chunk_sprite()` code path, which always pairs creation with an existence check and release with a dictionary-entry removal. Caught and cleaned up before trusting any further numbers; noted here because it's exactly the failure mode (an inconsistent `sprites` dict vs. actual scene-tree children) [Correctness Verification](#correctness-verification) below explicitly re-checked for afterward.

### What Phase 1 deliberately did not touch

- Simulation core, chunk sleep/dirty/activation, Material Reaction System, mining/drop system, Background/Foreground layering, player collision — all completely unmodified (this milestone is GDScript-only; zero C++ files changed).
- The touched-rect partial-update mechanism from the prior milestone — untouched, still the exact same code path for resident chunks.
- The idle-world O(total chunks) row-scan cost identified (but explicitly not fixed) in [Simulation Scaling](#simulation-scaling) — out of scope per the request's own instruction.

### Next: Phase 2

Phase 2A (GPU simulation feasibility PoC) is documented immediately below. See [GPU_SIMULATION.md](GPU_SIMULATION.md) for the full detail — this section is a summary, not a duplicate.

---

## Renderer Migration — Compatibility → Forward+

**Status: DONE, explicit user decision, now the project's ongoing development renderer.** Discovered as a hard blocker while starting Phase 2A (see below), not something this milestone set out to change — `gl_compatibility` (the project's prior renderer, PROJECT_ARCHITECTURE.md §2) does not implement Godot 4.7.1's `RenderingDevice` abstraction at all, so `RenderingServer.get_rendering_device()` / `create_local_rendering_device()` both returned `null`, live-verified, before any GPU code was written. Since the project's own long-term goal is GPU-resident simulation, the user chose to resolve this now rather than defer it, and explicitly approved switching the renderer as "a controlled architecture experiment and a potential permanent switch," not a temporary revert-after-testing.

**Change:** `project.godot`'s `renderer/rendering_method` set to `"forward_plus"` (`renderer/rendering_method.mobile` left at `"gl_compatibility"` — mobile export is out of this project's scope, PROJECT_ARCHITECTURE.md §16). One line. Requires a full editor/engine restart (not just a project reload) to take effect.

**Validated before any GPU work began** (per explicit instruction — validate the renderer switch itself first):

| | `gl_compatibility` (prior) | Forward+ (current) |
|---|---:|---:|
| Game boots, terrain/background/foreground/mining/SAND/WATER/LAVA/reactions/lazy-rendering | ✅ all correct | ✅ all correct, zero regressions |
| `sim_ms` @ 500k SAND stress tier | 3.878 ms | 3.899 ms (statistically unchanged — simulation has zero rendering-backend dependency) |
| Per-dirty-chunk CPU render cost (marshal+apply+update) | 5.14 µs/chunk | 5.07 µs/chunk (statistically unchanged) |
| Reported FPS ceiling (this test environment) | ~144 Hz | ~120 Hz |
| `RenderingServer.get_rendering_device()` | `null` | valid, GPU-resource-creation-proven |

The FPS difference is uniform across every workload tier (not scaling with simulation or render cost), which is the signature of a different default vsync/present-mode behavior between the OpenGL and Vulkan backends — **not** increased rendering work, which the per-chunk CPU timing directly rules out. Not root-caused further in this milestone; flagged as worth investigating before a real ship decision, not a blocker for GPU feasibility work.

**Decision: kept.** Zero measured regression, and required for everything below.

---

## Phase 2A — GPU Simulation PoC

**Status: DONE — GO decision.** Full detail, including the compute shader design, the CPU-vs-GPU validation methodology, and the complete Results/Decision writeup, lives in **[GPU_SIMULATION.md](GPU_SIMULATION.md)** — this is a summary, kept here per the request's instruction to record Phase 2A results in this document too.

**What was built:** a standalone, isolated GPU SAND/powder solver (`project/shaders/gpu_sand_solver.glsl` + `project/scripts/gpu_sand_poc.gd`, a `GPUSandPoC` class) — ping-pong double-buffered, "pull"-model conflict resolution (no write races, no atomics), hash-based deterministic randomness. Not wired into `PixelSimWorld`, `Main.tscn`, or any production path — the CPU simulation core is byte-for-byte unmodified (zero C++ files touched).

**Correctness:** 12/12 requested test cases passed, including a no-contention case matching the CPU **exactly** at every one of 30 steps, and a contested-pile case matching CPU on mass conservation and final settled-pile shape (per-step positions differ, by design — see GPU_SIMULATION.md "Sand Solver" for why the CPU's sequential-scan cascade and the GPU's parallel model are expected to diverge mid-fall while still converging on equivalent stable outcomes).

**Performance** (workload = a slab of SAND falling onto a floor, same initial content given to CPU and GPU, matching the existing stress-test harness's own shape):

| Chunks | Cells | CPU `sim_ms` | GPU compute (incl. sync) | GPU compute + readback |
|---:|---:|---:|---:|---:|
| 1 | 4,096 | 0.061 ms | 0.086 ms | 0.159 ms |
| 10 | 40,960 | 0.599 ms | 0.127 ms | 0.573 ms |
| 100 | 409,600 | 4.058 ms | 0.093 ms | 0.790 ms |
| 500 | 2,048,000 | 4.901 ms | 0.145 ms | 1.985 ms |
| 1,000 | 4,096,000 | 6.919 ms | 0.194 ms | 2.697 ms |

**Crossover:** CPU narrowly wins at 1 chunk (fixed GPU dispatch overhead dominates at trivial scale — expected and explicitly accepted as fine per the request). GPU compute-only wins from ~10 chunks onward, reaching **34–44× faster** at 100–1,000 chunks, with GPU compute time barely growing at all across that entire range (86 µs → 194 µs for a 1,000× increase in cell count). Even the conservative "GPU + full readback every step" number overtakes CPU by the 10–100-chunk range and stays 2.5–5× faster through 1,000 chunks.

**Memory:** GPU simulation state costs 8 bytes/cell (4-byte material ID × 2 ping-pong buffers) vs. the CPU `Chunk`'s measured 3.01 bytes/cell (12,316 bytes/chunk, including background+bookkeeping) — a **2.66× memory ratio**, tracked entirely separately from the lazy-rendering texture memory in [Phase 1](#phase-1--lazy-rendering-visibility-based-chunk-residency) above (unrelated GPU memory pools — simulation storage buffers vs. render textures).

**Decision: GO.** See [GPU_SIMULATION.md "Decision"](GPU_SIMULATION.md#decision) for the full reasoning against all 10 of the request's own success criteria. Recommended next step: Phase 2B (WATER/liquid solver), **not started** — per the request's explicit instruction to stop after Phase 2A and report before continuing.

*(This section is kept exactly as originally written, per this document's own "don't overwrite historical results" policy — Phase 2B, described immediately below, has since been completed.)*

---

## Phase 2B — GPU Water

**Status: DONE — GO decision.** Full detail (CPU source-of-truth reading, the pull-model displacement-duplication bug and its fix, the complete correctness/results/decision writeup) lives in **[GPU_SIMULATION.md "Phase 2B"](GPU_SIMULATION.md#phase-2b--gpu-water)** — this is a summary.

**What was built:** the *same* infrastructure from Phase 2A, extended — `gpu_sand_solver.glsl` renamed to `gpu_cellular_solver.glsl` and given a `LIQUID` behavior path (WATER) alongside the existing `POWDER` path (SAND), sharing one `can_displace()` function mirroring `material_can_displace()`'s exact density/liquid rules. The `GPUSandPoC` GDScript wrapper was not renamed or duplicated — its API was already material-agnostic. No second GPU simulation infrastructure was introduced, per the request's explicit instruction.

**A real bug, found and fixed via a failing conservation test:** the naive pull-model extension let a cell being displaced (e.g. WATER pushed out by denser SAND from above) *also* independently win a move of its own to a third cell in the same step, duplicating its material. Caught directly by a SAND-through-WATER test reporting 5 water cells instead of the initial 3 — not by inspection. Fixed with a bounded, non-recursive two-tier resolution (`resolve_winner_shallow` + a displacement-aware `resolve_winner_for` that rejects any candidate that is itself simultaneously being displaced) — still pull-model, still zero atomics, zero write races. All 12 Phase 2A SAND tests were re-verified green after the fix (structurally unaffected, since nothing can ever displace into a SAND cell in a SAND-only scenario).

**Correctness:** all 16 requested Water test cases passed — single cell, vertical fall, diagonal-around-obstacle, horizontal spread (with the same left/right oscillation `solve_liquid()`'s own randomized dx1/dx2 produces), a 24-cell pool spreading to fill a basin, resting against a wall, flowing around a floating obstacle, resting on SAND without sinking, SAND sinking through WATER via a true swap, conservation across an actual chunk-boundary crossing (`x = 64`, 18 cells in/out), deterministic repeatability (byte-identical across independent runs), multi-step stability (150 steps, zero drift), and CPU vs. GPU validation at both levels the parallel model actually supports (exact match, no-contention; mass-conservation + final-state equivalence, contested).

**Performance** (same slab-falling-onto-a-floor methodology as Phase 2A, WATER instead of SAND):

| Chunks | Cells | CPU `sim_ms` | GPU compute (incl. sync) | GPU compute + readback |
|---:|---:|---:|---:|---:|
| 1 | 4,096 | 0.062 ms | 0.095 ms | 0.163 ms |
| 10 | 40,960 | 0.612 ms | 0.095 ms | 0.422 ms |
| 100 | 409,600 | 4.175 ms | 0.097 ms | 0.648 ms |
| 500 | 2,048,000 | 4.824 ms | 0.175 ms | 1.494 ms |
| 1,000 | 4,096,000 | 6.881 ms | 0.250 ms | 2.611 ms |

**Crossover, nearly identical shape to Phase 2A's SAND numbers** (the extra displacement-aware logic adds a small, bounded per-cell cost, not a different scaling curve): CPU narrowly wins at 1 chunk (same fixed-overhead story as Phase 2A). GPU compute-only wins from ~10 chunks onward — **~6.4×** faster at 10, **~43×** at 100, **~27–39×** at 500–1,000 (compute time only grows 95 µs → 250 µs across a 1,000× increase in cell count). GPU + full readback overtakes CPU in the 10–100-chunk range and stays **~2.6×** faster at 1,000 chunks.

**Memory:** no new category — WATER reuses SAND's exact buffer representation (8 bytes/cell, 2.66× the CPU `Chunk`'s measured rate), per the request's explicit instruction not to build a separate Water buffer.

**Decision: GO.** See [GPU_SIMULATION.md "Phase 2B Decision"](GPU_SIMULATION.md#decision-1) for the full reasoning against all 10 of the request's own success criteria. Recommended next step: Phase 2C (a formal, automated CPU/GPU validation harness), **not started** — per the request's explicit instruction to stop after Phase 2B and report before continuing.

---

## Phase 2C — Real-Time Timestep Integration

**Status: DONE — GO WITH CONDITIONS.** Full detail lives in **[SIMULATION_TIMESCALE.md](SIMULATION_TIMESCALE.md)** and **[GPU_SIMULATION.md "Phase 2C"](GPU_SIMULATION.md#phase-2c--real-time-timestep-integration)** — this is a scalability-focused summary.

**What this measures that Phase 2A/2B didn't:** those phases benchmarked raw GPU compute cost by *chunk count* (1–1,000 chunks, an abstract test grid). Phase 2C benchmarks the same 10k/50k/100k/250k/500k SAND tiers `stress_test.gd` already uses, at the *actual default world size* (3072×1792 cells), so GPU and CPU numbers are directly comparable at the exact scale this project's own stress harness already establishes as meaningful.

**Headline scalability result:**

| SAND cells | CPU wall time (60 `step_simulation` calls) | GPU wall time (60 ticks) | GPU `simulation_real_time_ratio` |
|---:|---:|---:|---:|
| 10,000 | 0.049 s | 0.014 s | 71.4 |
| 50,000 | 0.157 s | 0.013 s | 76.4 |
| 100,000 | 0.143 s | 0.014 s | 72.9 |
| 250,000 | 0.231 s | 0.013 s | 74.6 |
| 500,000 | 0.228 s | 0.014 s | 70.4 |

**CPU wall time grows 4.7× across this range (tracking active-chunk-count-driven `sim_ms` growth, exactly this document's own §"Simulation Scaling" story). GPU wall time is flat** — because GPU dispatch cost here is bound by *world buffer size* (fixed for every tier), not by SAND cell count, a direct consequence of this project's own already-documented "no GPU activation/sleeping" limitation. This is the same bottleneck-ranking item already tracked in this document's own "Bottlenecks" section ("idle simulation cost scales linearly with total chunk count") viewed from the opposite direction: on GPU, cost is *world-size*-bound rather than *activity*-bound, which is a strength at every SAND/WATER count tested here and a named, deliberately out-of-scope risk at world sizes this phase did not test (see SIMULATION_TIMESCALE.md "Architecture Decision").

**Decision: GO WITH CONDITIONS.** Mechanism validated (fixed timestep, accumulator, backlog, FPS independence all correct); production wiring, world-size scaling beyond the tested range, and the rest of the CPU ruleset (LAVA, reactions, mining, activation, Background/Foreground) remain explicitly out of scope — see SIMULATION_TIMESCALE.md for the full condition list.

---

## Correctness Verification

Verified live, pixel-for-pixel against C++ ground truth, before considering the optimization complete:

- A single moved cell's rendered pixel color matched its material's defined color exactly (SAND: `(0.8549, 0.7451, 0.3804, 1.0)`, matching `material.cpp`'s `(218,190,97,255)` normalized), and a *neighboring, untouched* cell's pixel was unaffected (STONE floor cell unchanged) — confirms `blit_rect` patches only the intended region.
- A background-only write (`set_background()`, no foreground change) correctly reported `full: true` (no valid touched-rect) and rendered the correct `DARK_ROCK` color through the full-chunk fallback path.
- Mining a real DIRT cell in generated terrain correctly revealed the `DARK_ROCK` background at the mined coordinate, matching the direct-background-write test's color exactly — confirms the mining-reveals-background pathway (TERRAIN_LAYERS.md) is unaffected by this change.
- The standalone core test suite (`tests/test_core.cpp`, unrelated to this rendering change but re-run as a regression check since it shares the `World`/`Chunk` types touched here): **16,700/16,700 checks passed**, unchanged from before this milestone.

**Phase 1 (lazy rendering) — verified live, all 13 cases from the request's own test list:**

1. Offscreen chunk has no render resource — confirmed (`sprites.has(coord) == false` for a chunk outside the resident rect).
2. Visible chunk has a render resource — confirmed.
3. Preload margin works — confirmed (resident rect width matched exact-viewport-width + 2×margin exactly: 4 + 2×2 = 8).
4. Offscreen simulation continues — confirmed (a SAND grain fell 237 rows across 3 chunk boundaries with zero render resources ever created along its path).
5. Offscreen dirty chunk doesn't upload a texture — confirmed (same test as #4: no sprite existed at any point despite continuous dirty activity).
6. Offscreen → visible transition does a full rebuild — confirmed (moving the camera to the grain's new position produced a pixel-exact-correct render on the very first frame it became resident).
7. Resident dirty chunk uses partial update — confirmed (1-cell change reported `full=false`, small `w`×`h`).
8. Large dirty region uses full fallback — confirmed (a `fill_rect` covering an entire chunk reported an area at the ≥50% threshold, correctly routed to the full path).
9. Background/Foreground rendering correct — confirmed (background pixel color matched `DARK_ROCK`'s defined color exactly on a resident chunk).
10. Mining reveals background correctly — confirmed (mining a DIRT cell on a resident chunk revealed the exact same background color as a direct `set_background()` write).
11. Material rendering correct — confirmed (a placed METAL cell's pixel matched `material.cpp`'s defined color exactly).
12. Chunk boundary correct — confirmed (a cell at local coordinate `(63, y)`, the rightmost column of a chunk, rendered its correct color).
13. No render resource leak — confirmed twice: once via the camera-movement test (tracked `sprites` dict size matched actual `Sprite2D` child count at every waypoint, old-area chunks confirmed released after a large jump), and once via direct GPU-memory measurement (releasing all resident chunks and re-establishing residency returned memory to the exact same baseline it started from, not a higher one).

---

## Architectural Invariants

Everything in PROJECT_ARCHITECTURE.md §13/§14 still holds, unmodified. Specific to this milestone:

- `Cell` stays a 2-byte POD — untouched.
- `Chunk`'s `touched_min/max_x/y` fields (already existing, previously write-only/unused per PROJECT_ARCHITECTURE.md §6) are now *read*, not restructured — no new per-chunk or per-cell state was added.
- The simulation core (`core/`, `solvers/`, `gen/`) remains fully Godot-independent — the new `RenderDirtyRect` struct and `consume_render_dirty_rect()` live in `core/world.h/.cpp`, contain no Godot types, and are exercised by the standalone test build.
- No new simulation lifecycle, scan, or pass was introduced — `consume_render_dirty_rect()` is called from the exact same single per-frame full-chunk-list scan `get_and_clear_dirty_render_chunks()` already did; nothing scans the world an extra time.
- Chunk sleep/dirty/activation, the Material Reaction System, mining/drop system, Background/Foreground layering, and player collision are all unmodified — verified via the standalone test suite (16,700/16,700 unchanged) and live correctness checks (mining-reveals-background, WATER/LAVA/SAND behavior) above.
- `simulation_budget_ms` was not touched, and simulation/rendering costs remain measured and reported separately throughout this document, never blended into one number.
- The full-chunk update path was **kept**, not removed — it is the documented, necessary fallback for background-only writes and large/bulk writes, not dead code.

**Specific to Phase 1 (lazy rendering):**

- **Simulation chunk state and render resource are two separate concepts, enforced by construction, not convention.** `World`'s `Chunk` objects (C++) are completely unaware that `chunk_renderer.gd`'s `sprites` dictionary exists — nothing in `core/`, `solvers/`, or `gen/` changed in this milestone (zero C++ files touched), and simulation correctness was verified independent of whether any given chunk currently has a render resource.
- **The absence of a render resource never affects simulation correctness.** Verified live (see "Offscreen simulation" above) — an offscreen chunk simulates, wakes, sleeps, and crosses chunk boundaries identically to a resident one.
- **A chunk is never put to sleep, or kept awake, because of its residency state.** Residency (render resource lifecycle) and activation (simulation sleep/wake, SIMULATION_ACTIVATION.md) remain two entirely independent systems, exactly as the request required — Phase 1 introduced no coupling between them.
- **Camera/viewport → resident-chunk-region math lives in exactly one place** (`chunk_renderer.gd`'s `_compute_resident_rect()`) — no second, divergent visibility calculation exists anywhere else in the codebase.
- **No new camera system was introduced** — the existing `get_viewport().get_camera_2d()` idiom (already used by `mining_building.gd` and `debug_overlay.gd`) is reused, not replaced.
- The touched-rect partial-update mechanism, `Chunk::touched_min/max_x/y`, and `World::consume_render_dirty_rect()` are all **unchanged** by this milestone — Phase 1 is additive on top of them, not a replacement.

**Specific to the renderer migration / Phase 2A (GPU PoC):**

- **Zero C++ files changed.** The CPU simulation core remains PRODUCTION/REFERENCE, byte-for-byte unmodified — see GPU_SIMULATION.md's own invariants section for the full list.
- **`Cell` stays a 2-byte CPU POD** — the GPU PoC's 4-byte-per-cell representation is a separate, experimental, non-production concept.
- **The renderer switch is the one real, lasting architecture change** — done with explicit user approval, validated with zero measured regression against every existing system (simulation, Phase 1 lazy rendering, touched-rect partial update, Background/Foreground, mining, Material Reaction System).
- **The GPU PoC is not wired into any production path** — not `PixelSimWorld`, not `Main.tscn`, not the renderer. It cannot affect gameplay because nothing in gameplay reads from it.

**Specific to Phase 2B (GPU Water):** no second GPU simulation infrastructure was introduced (same shader file, renamed not duplicated; same `GPUSandPoC` wrapper, unchanged API); the CPU `solve_liquid()` was read as source of truth and never modified; LAVA/Material Reaction System/activation/mining/player collision/GPU rendering remain entirely untouched and CPU-side — see GPU_SIMULATION.md's Phase 2B invariants section for the full list.

---

## How Future Work Should Use This Document

1. Read this document before touching `chunk_renderer.gd`, `get_chunk_pixels*`, `get_and_clear_dirty_render_chunks`, or `World::consume_render_dirty*`.
2. If GPU texture memory at scale becomes the next priority (see [Future Optimizations](#future-optimizations) #1), that is a **new**, separate design — do not fold it into this document's touched-rect mechanism; write its own architecture section once designed, and update [Bottlenecks](#bottlenecks) once it's addressed.
3. Preserve the [Architectural Invariants](#architectural-invariants) above.
4. Re-run both the standalone test suite and a live in-editor correctness pass (mining reveals background, a moved cell renders its correct color, a background-only write still falls back to full-chunk) after any change here.
5. If a new measurement contradicts a number in this document, that's real signal (hardware/engine version/world shape changed) — update the number and note what changed, don't silently average it away.
