# GPU Simulation — Phase 2A PoC

Source of truth for PixelSim's GPU-simulation feasibility investigation. This document is explicitly about a **prototype**, not a production system — see the status markers throughout. Companion to [PROJECT_ARCHITECTURE.md](PROJECT_ARCHITECTURE.md) and [PERFORMANCE_SCALABILITY.md](PERFORMANCE_SCALABILITY.md) (which this extends with a "Phase 2A" section). Read those first for the CPU simulation model this document assumes and never modifies.

**Status: EXPERIMENTAL.** Everything under "GPU Backend" below is a proof-of-concept, isolated from and never called by production code. The CPU simulation (`addons/pixelsim/src/core`, `solvers`) remains **PRODUCTION / REFERENCE**, completely unmodified by this work — zero C++ files changed in this milestone.

---

## Goals

Answer one question with measurements, not assumptions: **is it worth continuing to migrate PixelSim's cellular simulation to the GPU?** Per the request's explicit scope, this phase (2A) only had to prove or disprove feasibility for the smallest meaningful slice — a SAND/powder solver — not build the real thing. Not in scope: WATER/LAVA GPU solvers, Material Reaction System on GPU, GPU-side activation/sleeping, GPU rendering, GPU player collision/mining. See [Future Phases](#future-phases).

A second, unplanned question got added mid-milestone and answered first, because it turned out to be a hard prerequisite: **does the project's current renderer even support the API this PoC needs?** See [Renderer Prerequisite](#renderer-prerequisite) — the answer was no, and fixing it was itself measured.

---

## Current CPU Reference

Unmodified. `World::step()` (`core/world.cpp`) scans the grid bottom-to-top, row by row, dispatching `solve_powder()`/`solve_liquid()` per POWDER/LIQUID cell (`solvers/solvers.cpp`); a `Cell` is a 2-byte POD (`uint8_t material; uint8_t flags;`); a chunk is 64×64 cells; sleeping/dirty/activation are unchanged — see PROJECT_ARCHITECTURE.md §4/§6/§7 for the authoritative description. This PoC's CPU-side comparisons used the **real** `PixelSimWorld`/`World` (via the same GDExtension API the game uses), not a reimplementation — so "CPU" in every result below is the actual production code, already validated by the standalone 16,700-check test suite.

---

## Renderer Prerequisite

**Not originally in scope, but became the first, hardest blocker.** PixelSim's `project.godot` was configured with `renderer/rendering_method = "gl_compatibility"` (OpenGL/GLES3) — an explicit, documented choice (PROJECT_ARCHITECTURE.md §2: "not Forward+/Mobile"). Live-tested in the running editor before writing any shader code:

```
RenderingServer.get_rendering_device()        -> null
RenderingServer.create_local_rendering_device() -> null
```

**`gl_compatibility` does not implement the `RenderingDevice` abstraction at all** — compute shaders, storage buffers, and everything else this PoC needs are categorically unavailable under it, in any Godot 4.7.1 configuration. This is not a bug or a missing feature flag; GLES3-based rendering in Godot 4 is a separate code path from the Vulkan/D3D12/Metal-based `RenderingDevice` pipeline that `Forward+`/`Mobile` use.

**Decision (explicit user approval obtained before acting — this changes a documented architectural choice):** switch `renderer/rendering_method` to `"forward_plus"` in `project.godot`, keep `renderer/rendering_method.mobile` untouched (`gl_compatibility` — mobile export is out of this project's scope per PROJECT_ARCHITECTURE.md §16), restart the editor, and validate the existing game before touching anything GPU-related. **This is now the project's development renderer going forward, not a temporary experiment reverted after this PoC** (explicit user decision) — see PROJECT_ARCHITECTURE.md for the corresponding update.

### Forward+ validation (before any GPU work)

Live-tested, one-line renderer change, editor restart, then:

- Game boots, terrain/background/foreground/mining/SAND/WATER/LAVA/reaction/lazy-rendering all re-verified — see [Correctness](#correctness) below for the exact checks. **Zero regressions found.**
- `sim_ms` at the stress-test tiers (10k/100k/500k SAND) is statistically unchanged from the `gl_compatibility` baseline (e.g. 500k: 3.878 ms `gl_compatibility` vs. 3.899 ms Forward+) — expected, since simulation is pure C++ GDExtension code with zero rendering-backend dependency; this is a sanity check, not a new finding.
- Per-dirty-chunk CPU render cost (marshal/apply/update — PERFORMANCE_SCALABILITY.md's own instrumentation) is also statistically unchanged: **5.07 µs/chunk under Forward+ vs. 5.14 µs/chunk under `gl_compatibility`** (both post-touched-rect-and-lazy-rendering). The CPU-side steps (`PackedByteArray` marshalling, `Image.blit_rect`/`set_data`) don't depend on the rendering backend either.
- Reported FPS dropped from a ~144 Hz ceiling (`gl_compatibility`) to a ~120 Hz ceiling (Forward+) in this test environment, uniformly across every workload tier — this pattern (a flat ratio regardless of simulation/render workload) is the signature of a different default vsync/present-mode/swapchain behavior between the OpenGL and Vulkan backends, **not** increased rendering cost (which the per-chunk timing above rules out directly). Not root-caused further — flagged as a real, observed difference worth investigating if it matters for a shipped build, not a blocker for this PoC's own goals.
- `RenderingServer.get_rendering_device()` / `create_local_rendering_device()` now both return valid, usable `RenderingDevice` instances — proven by actually creating a storage buffer and reading its data back (not just checking for non-null).

**Conclusion:** Forward+ is a safe, low-cost switch for this project — no measured regression in simulation or rendering CPU cost, no correctness regression, and it unlocks the entire `RenderingDevice` API this PoC (and any future GPU work) needs.

---

## GPU Technology

Confirmed against this project's own `addons/pixelsim/api_dump/extension_api.json` (the exact Godot 4.7.1 API surface, not general documentation) before writing any code:

- **`RenderingServer.create_local_rendering_device() -> RenderingDevice`** — an independent compute-only device, not tied to the main viewport's rendering. `RenderingDevice` itself is `RefCounted` (frees automatically once unreferenced — no explicit "destroy the device" call exists or is needed).
- **Compute shader compilation:** `.glsl` file with a `#[compute]` header, imported by Godot's own asset pipeline into an `RDShaderFile` resource; `load()` it, call `.get_spirv()`, then `RenderingDevice.shader_create_from_spirv()`. (An alternative, source-string-based path — `RDShaderSource` + `shader_compile_spirv_from_source()` — was used for the minimal smoke test below and works identically; the `.glsl`-resource path was used for the real Sand shader since it's the more maintainable, documented-in-the-repo form.)
- **Buffers:** `storage_buffer_create(size_bytes, initial_data)`, `buffer_get_data(rid) -> PackedByteArray`, `buffer_update()`.
- **Dispatch:** `compute_list_begin()` → `compute_list_bind_compute_pipeline()` → `compute_list_bind_uniform_set()` → `compute_list_set_push_constant()` → `compute_list_dispatch(x_groups, y_groups, z_groups)` → `compute_list_end()` → `submit()` → `sync()` (blocking wait for GPU completion).

No deprecated or wrong-version API was assumed — everything above was checked against the dump first, and every method call was proven to actually work live (see [Minimal Compute Shader Smoke Test](#minimal-compute-shader-smoke-test)) before the Sand solver was attempted.

### Minimal Compute Shader Smoke Test

Before attempting Sand: a trivial compute shader (`buf.data[i] = buf.data[i] * 2 + 1`) compiled from source, dispatched over a 64-element buffer, read back, and checked element-by-element. **Passed exactly** (all 64 values correct). This is the full `CPU → RenderingDevice → GPU compute → buffer → CPU readback` pipeline proven end-to-end before any simulation-specific complexity was introduced.

---

## GPU State Representation

**Deliberately not a copy of the CPU `Cell` struct** (per the request's own instruction). GPU state is one `uint32` (4 bytes) per cell holding only a material ID (`0 = AIR, 1 = SAND, 2 = STONE`) — no flags, no per-cell metadata. `uint32` rather than a tighter packing (e.g. `uint8`) was chosen for this PoC because GLSL storage buffers are naturally word-aligned and a byte-packed buffer would need explicit bit-shifting/masking logic in the shader for no benefit at this stage — see [Memory](#memory) for what this costs, and [Future Work](#future-work) for the tighter packing a production version would want.

**Double-buffered (ping-pong), not in-place.** Every compute dispatch reads one buffer (immutable for the whole dispatch) and writes the other; buffers swap roles each step. This is the direct GPU-appropriate answer to the CPU's `is_updated()` same-pass movement guard — see [Compute Pipeline](#compute-pipeline) for why this was chosen over trying to replicate the CPU's sequential in-place scan.

---

## Chunk Representation

**One flat, contiguous buffer per test grid — not per-64×64-chunk tiled buffers with explicit neighbor/halo exchange.** The request's own scope note ("ne építs komplett GPU world storage rendszert... A cél egyetlen vagy kis számú chunk korrekt szimulációja") was read as: prove correctness for a small case, and prove the mechanism scales, without committing to a full multi-chunk storage architecture yet. Concretely:

- **Chunk size (64×64) is unchanged** and was used as the correctness-test grid size, but the GPU buffer itself has no concept of "chunk" — a 128×128 test grid (4× a real chunk's area) was used specifically to prove that material crosses what *would be* a chunk boundary in the real architecture (world x=64/y=64) with **zero special-case code**, exactly mirroring the CPU's own "no special-case boundary handling" philosophy (PROJECT_ARCHITECTURE.md §4) — see [Testing Requirements](#testing-requirements)'s chunk-boundary result.
- This is a genuine, explicitly-flagged open question for any real migration: a production GPU backend would need to decide between "one giant flat world buffer" (what this PoC effectively assumes, simple, but doesn't obviously support the CPU's per-chunk sleep/stream/preallocation model) vs. "per-chunk tiled buffers with explicit neighbor access" (matches the existing architecture more closely, more complex). **Not decided here** — flagged in [Future Work](#future-work).

---

## Compute Pipeline

```
CPU: build initial PackedInt32Array
  → storage_buffer_create() ×2 (buffer A, buffer B)
  → for each step:
      compute_list_begin()
      bind pipeline, bind uniform set (read=A/write=B or vice versa), push constants (width, height, step_index, seed)
      compute_list_dispatch(width/8, height/8, 1)
      compute_list_end()
      swap "current" buffer
      barrier() between steps (a step's output is the next step's input)
  → submit() once for the whole batch, sync() once (blocking)
  → buffer_get_data() (readback - measured separately, see Performance)
```

Local workgroup size `8×8` (64 threads/group) — a 64×64 chunk dispatches as exactly `8×8` workgroups, matching the chunk size cleanly.

**Why ping-pong and one `submit()`/`sync()` per batch, not per step:** recording all N steps' dispatches (with a `BARRIER_MASK_COMPUTE` barrier between consecutive ones, since step K+1 depends on step K's output) into one command batch, then submitting/syncing once, avoids N unnecessary CPU↔GPU round-trip stalls a real per-frame driver wouldn't pay either — see [Performance](#performance) for why per-step sync would have misrepresented the GPU's actual cost.

---

## Sand Solver

**Architecture: "pull" model, not "push."** A naive GPU port of `solve_powder()` (each SAND cell decides where to move *to*) has an obvious race: two different source cells could independently decide to move into the *same* destination cell in the same dispatch, since every thread reads the same frozen snapshot and there's no mechanism (without atomics) to let one "claim" the destination first. Instead, **every cell — whether currently AIR or SAND — independently computes its own next value** by asking:

- If I'm `AIR`: would a neighbor move into me? (Check my 3 upward neighbors — straight-up, diagonal-up-left, diagonal-up-right — and re-derive *their* own movement decision from the same read-only snapshot.)
- If I'm `SAND`: do I successfully move away? (Compute my own target the same way `solve_powder()` would — straight down first, then a randomized diagonal — then check: am I the *winning* source for that destination, using the identical logic the destination cell itself would use?)

Because every invocation derives this identically and deterministically from the same previous-buffer snapshot, a source's self-assessment and a destination's assessment of that source always agree — **no shared mutable state, no atomics, no write races**, by construction, not by locking. Full commented implementation: `project/shaders/gpu_sand_solver.glsl`.

**Conflict resolution priority**, chosen to mirror `solve_powder()`'s own priority as closely as the parallel model allows: a straight-down source always wins outright when present (never contested by a diagonal, exactly as the CPU never lets a diagonal attempt preempt a valid straight fall); if two diagonal sources contest the same destination, a second deterministic hash breaks the tie.

**Known, documented CPU/GPU behavioral difference — not a bug:** the CPU's sequential bottom-to-top row scan lets a whole contiguous stack of SAND shift down multiple rows in a *single pass*, because later-scanned cells observe earlier-scanned cells' already-updated state within that same pass. The GPU's parallel model cannot do this — every thread sees the *same* previous-state snapshot, so a stack moves at most one cell per dispatch, taking more steps to fully settle. This directly shaped the correctness methodology below.

---

## Randomness

Per the request's own explicit allowance: **not** bit-identical to the CPU's shared `xorshift32` stream (`World::rand_u32()`), which is inherently sequential and scan-order-dependent — a parallel dispatch has no well-defined "draw order" to replicate, and forcing one would mean serializing the GPU work, defeating the point. Instead: a pure hash function of `(cell coordinate, step index, seed)` (`hash_u32()` in the shader, a standard integer-mixing hash), giving **determinism** in the sense that actually matters here — same initial state + seed + step sequence always reproduces the same result — verified directly (see [Correctness](#correctness)), not assumed.

---

## CPU vs GPU Validation

Two distinct methodologies, matched to the behavioral-difference note above — validated live, not assumed:

**1. No-contention case (isolated single cell, nothing else nearby to conflict with):** CPU and GPU are expected — and were confirmed — to match **exactly**, every single step. A single SAND cell falling through 30 open rows onto a floor: **0 mismatches across 30 steps**, checked step-by-step.

**2. Contested case (a 5-cell vertical stack, which must spread into a pile):** per-step traces are expected to diverge (see the behavioral-difference note) — confirmed (60/60 steps showed at least a positional difference somewhere in the tracked column). The meaningful checks instead:
- **Mass conservation:** both CPU and GPU always retained exactly 5 SAND cells, full-grid-scanned, at every checkpoint — no material was ever created or destroyed on either side.
- **Final settled-state equivalence:** after 60 steps, CPU settled into a pile at `[(6,30), (7,30), (8,29), (8,30), (9,30)]`; GPU settled into `[(7,30), (8,29), (8,30), (9,30), (10,30)]` — **the same physically valid pile shape** (4 cells on the floor row + 1 resting on top of the middle), shifted by one column left/right depending on which side each implementation's independent tie-break happened to favor. This is exactly the outcome the methodology predicted, not a discrepancy to explain away.

**Determinism:** two fully independent `GPUSandPoC` instances, same seed, same initial state, 60 steps each — **byte-identical final buffers**.

---

## Performance

**Never measured as FPS** — every number below is a directly-timed stage, matching the request's explicit "GPU compute time ≠ GPU + readback time" requirement.

| Chunks (64×64 cells each) | Total cells | CPU `sim_ms` | GPU compute (incl. sync) | GPU compute + readback |
|---:|---:|---:|---:|---:|
| 1 | 4,096 | 0.061 ms | 0.086 ms | 0.159 ms |
| 10 | 40,960 | 0.599 ms | 0.127 ms | 0.573 ms |
| 100 | 409,600 | 4.058 ms | 0.093 ms | 0.790 ms |
| 500 | 2,048,000 | 4.901 ms | 0.145 ms | 1.985 ms |
| 1,000 | 4,096,000 | 6.919 ms | 0.194 ms | 2.697 ms |

**Workload shape:** top 20 rows of each tier's grid filled with SAND falling into open space onto a floor (matches the existing stress-test harness's own slab shape) — identical initial content given to both CPU (via the real `PixelSimWorld`) and GPU. One dispatch/step measured after a warm-up dispatch (to exclude one-time pipeline/driver warm-up cost from the timed number).

**Crossover point:** GPU compute-only is already faster than CPU at the very first tested tier (1 chunk) is actually a near-tie leaning CPU (61 µs CPU vs. 86 µs GPU compute) — the GPU's small fixed dispatch overhead dominates at trivial scale, exactly as the request anticipated ("Egyetlen aktív chunknál a CPU lehet gyorsabb. Ez elfogadható."). **By 10 chunks, GPU compute-only is already ~4.7× faster; by 100 chunks, ~44× faster; the ratio stays in the 34–44× range through 1,000 chunks** (GPU compute time barely grows at all — 86 µs → 194 µs, a 2.3× increase for 1,000× more cells — while CPU cost grows in line with active-cell count, as expected from its own architecture). **Even including the full readback** (the conservative, "what if you needed the data back on CPU every frame" number, which a real GPU-resident pipeline would *not* pay every frame — see PERFORMANCE_SCALABILITY.md's Phase 1 principle of not needing CPU readback for rendering either): GPU+readback overtakes CPU by roughly the 10–100-chunk range and stays 2.5–5× faster through 1,000 chunks.

**Readback cost dominates the "+readback" column and scales with cell count** (0.073 ms at 1 chunk → 2.5 ms at 1,000 chunks) — this is expected (it's a `PackedByteArray` copy proportional to buffer size) and is exactly why the request was right to insist compute-only and compute+readback be reported separately: a production design that keeps state GPU-resident (no readback) would see only the "GPU compute" column's cost, not the combined one.

---

## Memory

| | CPU (existing, unmodified) | GPU PoC (this milestone) |
|---|---:|---:|
| Per-cell simulation state | 2 bytes (`Cell`: material + flags) | 4 bytes (`uint32` material only) × 2 buffers (ping-pong) = **8 bytes/cell** |
| 1,000-chunk-equivalent total | 11.75 MB (measured `Chunk` size incl. background+bookkeeping — PERFORMANCE_SCALABILITY.md) | 31.25 MB (2 × 15.625 MB storage buffers) |
| Ratio | — | **2.66× more GPU memory than the equivalent CPU `Chunk` footprint**, for material-only state with no background/bookkeeping equivalent yet |

Kept entirely separate from the lazy-rendering GPU **texture** memory (PERFORMANCE_SCALABILITY.md Phase 1, ~17 MB for the current world's resident chunks) — these are two unrelated GPU memory pools (simulation storage buffers vs. render textures), not to be added together or confused, per the request's explicit instruction.

---

## Limitations

Explicitly out of this PoC's scope, not oversights:

- SAND/POWDER only — no WATER/LAVA/liquid solver, no Material Reaction System, no MUD.
- No GPU-side activation or sleeping — every dispatch evaluates every cell in the buffer, always (there is no per-thread skip/sleep equivalent to the CPU's chunk-sleeping O(1) row-segment skip). This is a real, current limitation, not a hidden cost: GPU dispatch time in the table above is driven by *buffer size*, not by how much of it is "active," unlike the CPU's activity-scaled cost.
- No GPU rendering — this backend's output is never consumed by `chunk_renderer.gd` or any render path; every readback in this document was for validation/benchmarking only, exactly as the request required ("A readback ebben a phase-ben teljesen megengedett. Ez NEM production rendering path").
- No per-chunk tiled storage / streaming — one flat buffer per test grid (see [Chunk Representation](#chunk-representation)); a real multi-chunk world's storage strategy is undecided.
- 4 bytes/cell state is not memory-optimized (see [Memory](#memory)) — a production version would likely want a tighter packing.
- Not wired into `PixelSimWorld`, not a selectable "backend" in any project setting — `GPUSandPoC` is a standalone, disposable `RefCounted` class, instantiated only by test/benchmark scripts. There is no "CPU/GPU switch" in the game itself yet, because there is nothing in the game that reads GPU simulation output.

---

## Results

All 12 requested test cases passed:

1. **GPU backend init** — succeeds under Forward+ (`available = true`, clear log message); previously (under `gl_compatibility`, before the renderer switch) failed gracefully (`available = false`, clear log message, no crash) — both outcomes verified live.
2. **Empty world** — an all-`AIR` 64×64 grid stays all-`AIR` after 10 steps.
3. **Single SAND cell** — falls exactly one row per step, matching `solve_powder()`.
4. **Small SAND pile** — settles into a stable, mass-conserved configuration.
5. **Gravity** — a cell dropped from the top of a 16-row-tall open shaft reaches the floor after exactly the expected number of steps.
6. **Diagonal movement** — a SAND cell blocked straight-down correctly slides to a diagonal, mass conserved.
7. **Chunk boundary** — a cell falls 126 rows through a 128×128 buffer (crossing two would-be chunk boundaries) with zero special-case code, settling correctly on the floor.
8. **Multi-step** — verified at 1, 5, 10, 20, and 60 steps across the above tests.
9. **CPU vs GPU comparison** — exact match (no-contention case), mass-conservation + final-state-equivalence match (contested case) — see [CPU vs GPU Validation](#cpu-vs-gpu-validation).
10. **Deterministic repeatability** — byte-identical results across two independent runs, same seed.
11. **GPU unavailable → CPU fallback** — confirmed under the original `gl_compatibility` configuration: graceful `false` return, clear log message, no crash, CPU backend fully unaffected.
12. **GPU resource cleanup** — `cleanup()` frees all RIDs; calling `step()`/`read_back()` afterward is a safe no-op (empty result), not a crash.

---

## Decision

# Phase 2A Decision

## GO

## Why

Every one of the request's 10 success-criterion questions (§29) now has a measured answer:

1. **Does compute-shader Sand simulation work?** Yes — 12/12 tests passed, including gravity, diagonal movement, and a 126-row chunk-boundary-crossing fall.
2. **Compatible with the current chunk architecture?** Yes, with one open question flagged, not resolved: a real migration needs to decide flat-buffer-per-region vs. per-chunk-tiled storage (see [Chunk Representation](#chunk-representation)) — not a blocker, a design decision for Phase 2B+.
3. **Correct vs. CPU reference?** Yes — exact match where the models are expected to agree (no contention), mass-conservation and final-state equivalence where they're expected to diverge (contested cascades), with the divergence itself understood and documented, not hand-waved.
4. **Cost per GPU step?** 86–194 µs across 1–1,000 chunks-worth of cells — essentially flat, dominated by fixed dispatch overhead at this scale, not by cell count.
5. **Synchronization cost?** Included in the "GPU compute" column above (the measurement spans `submit()`→`sync()`); not separately decomposable with the API used, and not the dominant cost at any tested scale.
6. **Readback cost?** 73 µs – 2.5 ms, scaling with buffer size — measured separately as required, and irrelevant to a production design that keeps state GPU-resident.
7. **GPU memory needed?** 8 bytes/cell (2.66× the equivalent CPU `Chunk` footprint) for material-only state, no background/bookkeeping yet.
8. **Crossover point?** Compute-only: GPU wins from ~10 chunks onward, by 34–44× at 100–1,000 chunks. Including full readback: GPU wins from roughly 10–100 chunks onward, staying 2.5–5× faster through 1,000 chunks — a realistic, favorable result even under the pessimistic assumption that CPU needs the data back every frame.
9. **Architecture changes needed for full migration?** The renderer switch (done, validated, zero regressions). Beyond that: a chunk-storage strategy decision (flat vs. tiled), a GPU-side activation/sleeping equivalent (currently every cell is always evaluated — fine at the tested scale, a real cost at much larger idle worlds), and — per the phased roadmap the original request laid out (Phase 2B onward) — solver-by-solver migration of WATER, the Material Reaction System, and eventually rendering itself.
10. **Worth continuing?** Yes — see below.

The single largest risk going in — whether `RenderingDevice`/compute shaders would even be available to this project at all — turned out to be real (blocked entirely under `gl_compatibility`) but cheaply resolved (one renderer setting, zero measured regression). With that resolved, every subsequent GPU-specific measurement was favorable: correct, deterministic, and dramatically faster at any scale beyond trivial (10+ active chunks), which is the scale that actually matters for a "much larger final game world."

## Next Step

**Recommended: Phase 2B — WATER/liquid solver on GPU**, following the exact roadmap the original request already laid out (2B liquid → 2C validation → 2D reactions → ...). This is the natural next slice: it reuses the same ping-pong/pull-model infrastructure this PoC already validated, and liquids are the next material class after powders in the CPU's own solver hierarchy (`solve_liquid()` already shares almost all of `solve_powder()`'s structure, differing only in the sideways-spread step). Two things should be decided explicitly, in writing, *before* 2B starts (not discovered mid-implementation): the flat-vs-tiled chunk storage question, and whether a GPU activation/sleeping equivalent is needed yet or can stay deferred at the scale 2B targets.

**Per the original request's explicit instruction: this document stops here.** No Water/Lava/Reaction/Activation GPU work has been started.

---

## Future Phases

**FUTURE / OPTIONAL — none of this is decided architecture, and none of it is implied scope.** Restated from the original request's own roadmap (§24), unchanged:

- Phase 2B: liquid (WATER) solver.
- Phase 2C: formal CPU/GPU validation harness (this PoC's validation was manual/scripted; a real one would be a repeatable automated test).
- Phase 2D: Material Reaction System, data-driven (never hardcoded per-pair logic in a shader — same invariant as the CPU's `REACTION_TABLE`).
- Phase 2E: activation/sleeping equivalent on GPU.
- Phase 2F: GPU simulation → GPU rendering (removing the CPU readback from the production path entirely).
- The chunk-storage architecture decision (flat buffer vs. tiled with neighbor/halo exchange) flagged above.
- A tighter GPU state packing (e.g. `uint8` material with explicit bit-packing) if the 2.66× memory ratio becomes a real constraint at production scale.

---

## Architectural Invariants

Everything in PROJECT_ARCHITECTURE.md §13/§14 and PERFORMANCE_SCALABILITY.md's own invariants sections still hold. Specific to this milestone:

- **Zero C++ files changed.** The CPU simulation core, `World`, `Chunk`, `Cell`, solvers, mining, activation, Background/Foreground, Material Reaction System — all byte-for-byte unmodified. The GPU PoC is GDScript + GLSL only, added alongside, never touching or importing from `addons/pixelsim/src/`.
- **`Cell` stays a 2-byte CPU POD.** The GPU's 4-byte `uint32` representation is a separate, parallel concept for the experimental backend only — never proposed as a replacement.
- **64×64 chunk size unchanged** — used as the PoC's own test-grid unit throughout.
- **CPU remains the only backend anything in the actual game reads from.** `GPUSandPoC` is not instantiated anywhere in `Main.tscn`, `main.gd`, or any production script — it exists only for the test/benchmark scripts described in this document.
- **The renderer switch (gl_compatibility → Forward+) is the one genuine, lasting architecture change this milestone made**, done with explicit user approval, validated with zero regressions, and now the project's ongoing development renderer per that approval — see PROJECT_ARCHITECTURE.md for where this is now documented as current state, not experimental.

---

## How Future Work Should Use This Document

1. Read this document, PROJECT_ARCHITECTURE.md, and PERFORMANCE_SCALABILITY.md before starting Phase 2B.
2. Phase 2B (WATER) should follow this document's validated pattern (ping-pong, pull-model conflict resolution, hash-based determinism, compute-only vs. compute+readback measured separately) rather than re-deriving it from scratch.
3. Decide the chunk-storage question explicitly before it's implicitly decided by whatever Phase 2B's code happens to do first.
4. Keep the GO/NO-GO decision format for future phases — a real number, not a vibe.
5. If a future measurement contradicts a number here (different hardware, different Godot version, different workload shape), update the number and say what changed — don't silently average it away.
