#pragma once
#include <array>
#include <cstdint>
#include "background.h"
#include "cell.h"
#include "sim_config.h"

namespace pixelsim {

// A CHUNK_SIZE x CHUNK_SIZE block of the simulation grid. The cell array is a
// std::array (inline, contiguous) member so that a std::vector<Chunk> in
// World places every chunk's cells back-to-back in one contiguous heap
// block - no per-chunk heap allocation, no pointer chasing between chunks.
class Chunk {
public:
    int32_t chunk_x = 0;
    int32_t chunk_y = 0;

    // Simulation state.
    bool sleeping = true;        // skip this chunk entirely during stepping
    bool dirty_this_pass = false; // any cell in this chunk changed during the current pass
    uint32_t last_begin_pass_id = 0; // World::current_pass_id_ this chunk last had begin_pass() called for

    // Rendering state, decoupled from simulation sleep state: a chunk can be
    // asleep (no simulation work) while still needing one more texture
    // upload from the pass that just put it to sleep.
    bool render_dirty = true;

    // Bounding rect (local coords, inclusive) of cells touched during the
    // current pass. Used to avoid re-uploading/rescanning a whole chunk when
    // only a small region changed. min_x > max_x means "empty".
    int16_t touched_min_x = CHUNK_SIZE, touched_min_y = CHUNK_SIZE;
    int16_t touched_max_x = -1, touched_max_y = -1;

    std::array<Cell, CHUNK_CELL_COUNT> cells{};

    // Background layer: one BackgroundType byte per cell, parallel to
    // `cells` but intentionally NOT part of Cell itself (see
    // TERRAIN_LAYERS.md "Data Model" - Cell stays a 2-byte POD). Static,
    // non-simulated set-dressing revealed wherever the foreground cell is
    // AIR; never read by any solver and never written by simulation code.
    std::array<uint8_t, CHUNK_CELL_COUNT> background{};

    Cell &at(int local_x, int local_y) {
        return cells[static_cast<size_t>(local_y) * CHUNK_SIZE + local_x];
    }
    const Cell &at(int local_x, int local_y) const {
        return cells[static_cast<size_t>(local_y) * CHUNK_SIZE + local_x];
    }

    BackgroundType get_background(int local_x, int local_y) const {
        return static_cast<BackgroundType>(background[static_cast<size_t>(local_y) * CHUNK_SIZE + local_x]);
    }

    // Deliberately NOT part of the simulation lifecycle: unlike
    // mark_touched(), this does not clear `sleeping`, does not set
    // dirty_this_pass, and does not touch the touched-rect - a background
    // write must never wake a chunk or count as simulation activity (see
    // TERRAIN_LAYERS.md / SIMULATION_ACTIVATION.md). It only flags
    // render_dirty, since the visible pixel at this cell can change (if the
    // foreground here is already AIR, the new background becomes visible).
    void set_background(int local_x, int local_y, BackgroundType bg) {
        background[static_cast<size_t>(local_y) * CHUNK_SIZE + local_x] = static_cast<uint8_t>(bg);
        render_dirty = true;
    }

    // Marks a local cell as changed: wakes the chunk, flags it dirty for both
    // simulation bookkeeping and rendering, and grows the touched-rect.
    void mark_touched(int local_x, int local_y) {
        sleeping = false;
        dirty_this_pass = true;
        render_dirty = true;
        if (local_x < touched_min_x) touched_min_x = static_cast<int16_t>(local_x);
        if (local_y < touched_min_y) touched_min_y = static_cast<int16_t>(local_y);
        if (local_x > touched_max_x) touched_max_x = static_cast<int16_t>(local_x);
        if (local_y > touched_max_y) touched_max_y = static_cast<int16_t>(local_y);
    }

    // Marks the chunk eligible for simulation again, WITHOUT implying any
    // cell's material actually changed - contrast with mark_touched(), which
    // is for actual writes and also flags dirty_this_pass/render_dirty/the
    // touched-rect. Used by World::activate_affected_neighbors() (see
    // SIMULATION_ACTIVATION.md) to wake a neighboring chunk that might now
    // have work to do, purely on suspicion. If nothing actually moves here
    // this pass, dirty_this_pass stays false and end_pass() puts it right
    // back to sleep - a false-positive wake costs at most one quiet pass.
    void wake() { sleeping = false; }

    bool has_touched_rect() const { return touched_min_x <= touched_max_x; }

    void reset_touched_rect() {
        touched_min_x = CHUNK_SIZE;
        touched_min_y = CHUNK_SIZE;
        touched_max_x = -1;
        touched_max_y = -1;
    }

    // Called once at the start of every new full simulation pass.
    void begin_pass() {
        dirty_this_pass = false;
        for (Cell &c : cells) {
            c.clear_updated();
            c.clear_reacted();
        }
    }

    // Called once a full pass has finished for this chunk: chunks with no
    // activity this pass go to sleep and stay out of future passes until
    // woken by a neighbor, mining, building, or explicit API call.
    void end_pass() {
        sleeping = !dirty_this_pass;
    }
};

} // namespace pixelsim
