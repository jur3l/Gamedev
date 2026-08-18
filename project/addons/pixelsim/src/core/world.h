#pragma once
#include <cstdint>
#include <vector>
#include "chunk.h"
#include "material.h"
#include "sim_config.h"

namespace pixelsim {

struct StepStats {
    double sim_ms = 0.0;
    bool pass_completed = false; // did this call finish a full bottom-to-top pass?
    uint64_t cells_evaluated = 0;
    uint64_t cells_moved = 0;
    uint64_t reaction_checks = 0;    // try_react() invocations (see MATERIAL_REACTIONS.md)
    uint64_t reactions_executed = 0; // of which actually fired a reaction
    // Cells whose movement dispatch (solve_powder/solve_liquid) was skipped
    // this call because set_movement_externally_owned() is true for that
    // cell's material (GPU production bridge) - see the gate at step()'s
    // dispatch site. A material with this gate enabled can NEVER contribute
    // to cells_moved via movement (the dispatch simply never runs) - this
    // counter exists so that claim is measured, not just structurally
    // argued, per SIMULATION_TIMESCALE.md's regression-investigation
    // instrumentation.
    uint64_t movement_gated_skips = 0;
    int active_chunks = 0;   // not sleeping
    int sleeping_chunks = 0;
    int total_chunks = 0;
};

struct MineResult {
    int counts[MATERIAL_COUNT] = {0};
    int total_removed = 0;
};

// Result of World::consume_render_dirty_rect() - see its declaration below
// and PERFORMANCE_SCALABILITY.md "Rendering Scaling" for why this exists
// (avoiding a full 4096-cell re-serialize for a chunk where only a handful
// of cells actually changed).
struct RenderDirtyRect {
    bool was_dirty = false; // chunk was render-dirty (same meaning as consume_render_dirty()'s bool return)
    bool has_rect = false;  // a valid touched-rect was available (false => caller must fall back to full chunk)
    int min_x = 0, min_y = 0, max_x = 0, max_y = 0; // local chunk coords, inclusive
};

// Mining tool footprint. Deliberately just a shape + a single size value
// (radius for CIRCLE, half-side-length for SQUARE) rather than a generic
// mask, so it stays trivial to extend with new shapes later.
enum class MiningShape : uint8_t {
    CIRCLE = 0,
    SQUARE = 1,
};

// Owns the full simulation grid as a flat, contiguous array of Chunk. This is
// the "Godot-agnostic" core: no Godot types appear anywhere in this class, so
// it is usable/testable outside the engine (see tests/).
class World {
public:
    World(int chunks_x, int chunks_y, uint32_t seed);

    int width_cells() const { return chunks_x_ * CHUNK_SIZE; }
    int height_cells() const { return chunks_y_ * CHUNK_SIZE; }
    int width_chunks() const { return chunks_x_; }
    int height_chunks() const { return chunks_y_; }

    bool in_bounds(int x, int y) const {
        return x >= 0 && y >= 0 && x < width_cells() && y < height_cells();
    }

    // Read access; out-of-bounds always reads as AIR (an implicit infinite
    // sky / void boundary), so solvers don't need special-case bounds checks
    // beyond "can I move here".
    MaterialType get_material(int x, int y) const;

    // Background layer (see TERRAIN_LAYERS.md) - static, non-simulated,
    // rendered wherever the foreground cell is AIR. Out-of-bounds reads as
    // BackgroundType::NONE (fully transparent), same spirit as get_material.
    BackgroundType get_background(int x, int y) const;

    // Deliberately NOT equivalent to set_cell(): does not wake the chunk,
    // does not mark dirty_this_pass, does not call
    // activate_affected_neighbors() - a background write is never a "world
    // change" for simulation purposes (TERRAIN_LAYERS.md / SIMULATION_
    // ACTIVATION.md). Only flags the chunk render_dirty. Returns false if
    // out of bounds.
    bool set_background(int x, int y, BackgroundType background);

    // Directly overwrites a cell and wakes its chunk (and creates no new
    // chunks - the world's chunk grid is pre-allocated at construction).
    // Returns false if out of bounds.
    bool set_cell(int x, int y, MaterialType material);

    // Swaps two cells (used by solvers for "move" == data swap, never object
    // movement) and marks both chunks touched/awake. Returns false if either
    // coordinate is out of bounds.
    bool swap_cells(int x1, int y1, int x2, int y2);

    bool is_cell_updated_this_step(int x, int y) const;
    void mark_cell_updated(int x, int y);

    // See MATERIAL_REACTIONS.md "Infinite-Loop / Same-Pass Protection" - a
    // cell may react at most once per pass. Cleared per-chunk in
    // Chunk::begin_pass(), alongside is_cell_updated_this_step's flag.
    bool is_cell_reacted_this_step(int x, int y) const;
    void mark_cell_reacted(int x, int y);

    // Activation propagation for a world change at (x,y) - see
    // SIMULATION_ACTIVATION.md. Wakes (Chunk::wake(), not mark_touched()) the
    // chunks of every cell whose CURRENT solver behavior reads (x,y) as a
    // neighbor - a small fixed set derived from solve_powder/solve_liquid's
    // actual read patterns, not a radius. Never marks any cell dirty/touched
    // itself. Called automatically by set_cell()/swap_cells(); feature code
    // (mining, building, future world-changing features, ...) should not
    // need to call this directly - writing through those two primitives is
    // sufficient to get correct cross-chunk wake propagation.
    void activate_affected_neighbors(int x, int y);

    bool can_displace(MaterialType mover, int x, int y) const;

    // Advances the simulation. Processes rows bottom-to-top, chunk by chunk,
    // stopping early once simulation_budget_ms has elapsed for this call and
    // resuming from that row on the next call - so a single call never blocks
    // the frame indefinitely regardless of world size.
    StepStats step(double simulation_budget_ms);

    // General mining entry point: `size` is a radius for CIRCLE, or a
    // half-side-length for SQUARE (so size=8 gives a 17x17 box). The mined
    // quantity of each material is converted to a drop quantity via that
    // material's MaterialDef::drop_ratio - see compute_drop_count() below.
    MineResult mine_area(int center_x, int center_y, int size, MiningShape shape);
    // Back-compat convenience wrapper - identical to mine_area(..., CIRCLE).
    MineResult mine_circle(int center_x, int center_y, int radius);
    bool place_cell(int x, int y, MaterialType material);

    // Converts a mined QUANTITY of one material into a drop quantity using
    // `ratio`, without rounding per individual cell: `ratio` is applied to
    // the whole mined batch via floor(), and any leftover fraction is banked
    // in `remainder` (the caller owns this state - mine_area() uses one slot
    // per material, persisted for the lifetime of the World) so a material
    // mined across several separate mining actions still yields the same
    // total drop count as one big mining action would, regardless of how the
    // mining got split up. E.g. at ratio 0.5: 7 cells mined in one call
    // yields floor(7*0.5)=3 drops; 3 cells then 4 cells mined in two separate
    // calls also yields 1 then 2 drops = 3 total, not 1+2 by coincidence but
    // by construction (the leftover 0.5 from the first call carries into the
    // second). Never returns more drops than cells mined, even if `ratio` is
    // misconfigured above 1.0. Exposed as a static, side-effect-free-besides-
    // remainder function so this rounding policy is directly unit-testable
    // without needing a full World/MaterialDef fixture.
    static int compute_drop_count(float &remainder, int mined_count, float ratio);

    // Fills a rectangle with a material, waking affected chunks. Used by
    // terrain generation and the stress-test harness.
    void fill_rect(int x0, int y0, int w, int h, MaterialType material);

    // Bulk material-id rect I/O (GPU production bridge - see
    // SIMULATION_TIMESCALE.md "GPU Production Wiring"). Read is a plain
    // per-cell get_material() loop (no side effects). Write goes through
    // set_cell() for every cell that actually differs from its current
    // value - reuses set_cell()'s existing wake/dirty/touched-rect/
    // activate_affected_neighbors() bookkeeping "for free", and a no-op
    // write (materials[i] == current value) costs a single comparison, no
    // wake/dirty churn. Returns the number of cells actually changed.
    // Out-of-bounds sub-rects are clamped to the world, never asserted.
    std::vector<MaterialType> get_materials_rect(int x0, int y0, int w, int h) const;
    int set_materials_rect(int x0, int y0, int w, int h, const std::vector<MaterialType> &materials);

    // Movement-dispatch gate (GPU production bridge): when true for a
    // material, World::step() still runs reactions for that material
    // normally, but skips solve_powder()/solve_liquid() for it entirely -
    // see the call site in step(). Defaults to false for every material, so
    // this has zero effect on behavior unless a caller explicitly opts a
    // material in. Intended for exactly one external owner at a time (the
    // GPU bridge) - this is a simple boolean gate, not a general-purpose
    // ownership/locking mechanism.
    void set_movement_externally_owned(MaterialType material, bool owned);
    bool is_movement_externally_owned(MaterialType material) const;

    // Simple deterministic xorshift32 RNG shared by all solvers so that a
    // fixed world seed reproduces a fixed simulation history.
    uint32_t rand_u32();

    Chunk &chunk_at(int cx, int cy) { return chunks_[static_cast<size_t>(cy) * chunks_x_ + cx]; }
    const Chunk &chunk_at(int cx, int cy) const { return chunks_[static_cast<size_t>(cy) * chunks_x_ + cx]; }
    bool chunk_in_bounds(int cx, int cy) const {
        return cx >= 0 && cy >= 0 && cx < chunks_x_ && cy < chunks_y_;
    }

    // Consumes (and clears) the render-dirty flag for a chunk. Returns false
    // if the chunk wasn't render-dirty.
    bool consume_render_dirty(int cx, int cy);

    // Same consuming-read contract as consume_render_dirty() (clears
    // render_dirty and resets the touched-rect), but captures the
    // touched-rect BOUNDS before clearing them, so a caller can upload just
    // that sub-region instead of always re-serializing the whole chunk - see
    // PERFORMANCE_SCALABILITY.md "Rendering Scaling". `has_rect` is false
    // whenever there is no valid touched-rect to report - in particular,
    // when render_dirty was set by a Background-only write (TERRAIN_LAYERS.md
    // set_background() deliberately never touches the touched-rect, since a
    // background change can affect any cell currently AIR, not a bounded
    // region) - callers MUST fall back to a full-chunk read in that case.
    RenderDirtyRect consume_render_dirty_rect(int cx, int cy);

    uint64_t total_cell_count() const { return static_cast<uint64_t>(width_cells()) * height_cells(); }

private:
    int chunks_x_;
    int chunks_y_;
    std::vector<Chunk> chunks_;
    uint32_t rng_state_;
    uint32_t current_pass_id_ = 1;
    int resume_y_ = -1; // -1 == start a fresh pass at the top of the next step() call
    float mining_remainder_[MATERIAL_COUNT] = {}; // per-material fractional carry, see compute_drop_count()
    bool externally_owned_movement_[MATERIAL_COUNT] = {}; // see set_movement_externally_owned()

    void ensure_chunk_begun(Chunk &chunk);
    void finish_pass();
};

} // namespace pixelsim
