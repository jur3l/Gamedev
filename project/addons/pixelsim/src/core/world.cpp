#include "world.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <utility>
#include <vector>
#include "../solvers/reaction_solver.h"
#include "../solvers/solvers.h"

namespace pixelsim {

World::World(int chunks_x, int chunks_y, uint32_t seed)
    : chunks_x_(chunks_x), chunks_y_(chunks_y), rng_state_(seed ? seed : 1u) {
    chunks_.resize(static_cast<size_t>(chunks_x_) * chunks_y_);
    for (int cy = 0; cy < chunks_y_; ++cy) {
        for (int cx = 0; cx < chunks_x_; ++cx) {
            Chunk &c = chunk_at(cx, cy);
            c.chunk_x = cx;
            c.chunk_y = cy;
        }
    }
}

uint32_t World::rand_u32() {
    // xorshift32 - fast, deterministic, good enough for CA tie-breaking.
    uint32_t x = rng_state_;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    rng_state_ = x;
    return x;
}

MaterialType World::get_material(int x, int y) const {
    if (!in_bounds(x, y)) {
        return MaterialType::AIR;
    }
    int cx = x / CHUNK_SIZE, lx = x % CHUNK_SIZE;
    int cy = y / CHUNK_SIZE, ly = y % CHUNK_SIZE;
    return chunk_at(cx, cy).at(lx, ly).get_material();
}

BackgroundType World::get_background(int x, int y) const {
    if (!in_bounds(x, y)) {
        return BackgroundType::NONE;
    }
    int cx = x / CHUNK_SIZE, lx = x % CHUNK_SIZE;
    int cy = y / CHUNK_SIZE, ly = y % CHUNK_SIZE;
    return chunk_at(cx, cy).get_background(lx, ly);
}

bool World::set_background(int x, int y, BackgroundType background) {
    if (!in_bounds(x, y)) {
        return false;
    }
    int cx = x / CHUNK_SIZE, lx = x % CHUNK_SIZE;
    int cy = y / CHUNK_SIZE, ly = y % CHUNK_SIZE;
    // Intentionally bypasses ensure_chunk_begun/mark_touched/activation -
    // see the declaration in world.h and TERRAIN_LAYERS.md.
    chunk_at(cx, cy).set_background(lx, ly, background);
    return true;
}

bool World::set_cell(int x, int y, MaterialType material) {
    if (!in_bounds(x, y)) {
        return false;
    }
    int cx = x / CHUNK_SIZE, lx = x % CHUNK_SIZE;
    int cy = y / CHUNK_SIZE, ly = y % CHUNK_SIZE;
    Chunk &chunk = chunk_at(cx, cy);
    ensure_chunk_begun(chunk);
    chunk.at(lx, ly).set_material(material);
    chunk.mark_touched(lx, ly);
    activate_affected_neighbors(x, y);
    return true;
}

bool World::swap_cells(int x1, int y1, int x2, int y2) {
    if (!in_bounds(x1, y1) || !in_bounds(x2, y2)) {
        return false;
    }
    int cx1 = x1 / CHUNK_SIZE, lx1 = x1 % CHUNK_SIZE, cy1 = y1 / CHUNK_SIZE, ly1 = y1 % CHUNK_SIZE;
    int cx2 = x2 / CHUNK_SIZE, lx2 = x2 % CHUNK_SIZE, cy2 = y2 / CHUNK_SIZE, ly2 = y2 % CHUNK_SIZE;
    Chunk &ca = chunk_at(cx1, cy1);
    Chunk &cb = chunk_at(cx2, cy2);
    ensure_chunk_begun(ca);
    ensure_chunk_begun(cb);
    Cell &a = ca.at(lx1, ly1);
    Cell &b = cb.at(lx2, ly2);
    Cell tmp = a;
    a = b;
    b = tmp;
    a.mark_updated();
    b.mark_updated();
    ca.mark_touched(lx1, ly1);
    cb.mark_touched(lx2, ly2);
    activate_affected_neighbors(x1, y1);
    activate_affected_neighbors(x2, y2);
    return true;
}

void World::activate_affected_neighbors(int x, int y) {
    // Derived from the UNION of what the current solvers read about a
    // neighbor to decide whether THEY can move (see SIMULATION_ACTIVATION.md
    // "Gravity Activation"): solve_powder/solve_liquid both read the row
    // directly below themselves; solve_liquid additionally reads its own
    // row's immediate left/right. Inverting those offsets gives exactly the
    // cells that might behave differently now that (x,y) changed - the row
    // above, and the immediate same-row neighbors. Fixed size, O(1) per
    // call - never a radius, never proportional to the size of the change.
    static const int OFFSETS[5][2] = {
        { 0, -1}, {-1, -1}, {1, -1}, // row above
        {-1,  0}, { 1,  0},          // same row, left/right
    };
    for (const auto &off : OFFSETS) {
        int nx = x + off[0];
        int ny = y + off[1];
        if (!in_bounds(nx, ny)) continue;
        chunk_at(nx / CHUNK_SIZE, ny / CHUNK_SIZE).wake();
    }
}

bool World::is_cell_updated_this_step(int x, int y) const {
    if (!in_bounds(x, y)) return true;
    int cx = x / CHUNK_SIZE, lx = x % CHUNK_SIZE;
    int cy = y / CHUNK_SIZE, ly = y % CHUNK_SIZE;
    return chunk_at(cx, cy).at(lx, ly).is_updated();
}

void World::mark_cell_updated(int x, int y) {
    if (!in_bounds(x, y)) return;
    int cx = x / CHUNK_SIZE, lx = x % CHUNK_SIZE;
    int cy = y / CHUNK_SIZE, ly = y % CHUNK_SIZE;
    chunk_at(cx, cy).at(lx, ly).mark_updated();
}

bool World::is_cell_reacted_this_step(int x, int y) const {
    if (!in_bounds(x, y)) return true;
    int cx = x / CHUNK_SIZE, lx = x % CHUNK_SIZE;
    int cy = y / CHUNK_SIZE, ly = y % CHUNK_SIZE;
    return chunk_at(cx, cy).at(lx, ly).is_reacted();
}

void World::mark_cell_reacted(int x, int y) {
    if (!in_bounds(x, y)) return;
    int cx = x / CHUNK_SIZE, lx = x % CHUNK_SIZE;
    int cy = y / CHUNK_SIZE, ly = y % CHUNK_SIZE;
    chunk_at(cx, cy).at(lx, ly).mark_reacted();
}

bool World::can_displace(MaterialType mover, int x, int y) const {
    if (!in_bounds(x, y)) return false;
    return material_can_displace(mover, get_material(x, y));
}

void World::ensure_chunk_begun(Chunk &chunk) {
    if (chunk.last_begin_pass_id != current_pass_id_) {
        chunk.begin_pass();
        chunk.last_begin_pass_id = current_pass_id_;
    }
}

void World::finish_pass() {
    for (Chunk &c : chunks_) {
        if (c.last_begin_pass_id == current_pass_id_) {
            c.end_pass();
        }
    }
    current_pass_id_++;
    resume_y_ = -1;
}

StepStats World::step(double simulation_budget_ms) {
    using clock = std::chrono::steady_clock;
    auto t_start = clock::now();
    StepStats stats;
    stats.total_chunks = static_cast<int>(chunks_.size());

    if (resume_y_ < 0) {
        resume_y_ = height_cells() - 1;
    }

    // Alternate scan direction every pass to avoid a persistent left/right
    // bias in how sand/water resolve simultaneous-looking moves.
    bool left_to_right = (current_pass_id_ & 1u) == 0u;

    int y = resume_y_;
    for (; y >= 0; --y) {
        int cy = y / CHUNK_SIZE;
        int local_y = y % CHUNK_SIZE;

        for (int i = 0; i < chunks_x_; ++i) {
            int cx = left_to_right ? i : (chunks_x_ - 1 - i);
            Chunk &chunk = chunk_at(cx, cy);
            if (chunk.sleeping) {
                continue; // whole 64-wide row segment skipped in O(1)
            }
            ensure_chunk_begun(chunk);

            for (int j = 0; j < CHUNK_SIZE; ++j) {
                int local_x = left_to_right ? j : (CHUNK_SIZE - 1 - j);
                Cell &cell = chunk.at(local_x, local_y);
                if (cell.is_updated()) {
                    continue; // already moved earlier this pass (e.g. water same-row swap)
                }
                MaterialType mat = cell.get_material();
                const MaterialDef &def = get_material_def(mat);
                if (def.behavior == MovementBehavior::NONE || def.behavior == MovementBehavior::STATIC) {
                    continue;
                }
                stats.cells_evaluated++;
                int world_x = cx * CHUNK_SIZE + local_x;

                // Reaction detection piggybacks on this same visit - see
                // MATERIAL_REACTIONS.md "Simulation Integration". A cell
                // either reacts or attempts to move this pass, never both.
                stats.reaction_checks++;
                bool reacted = try_react(*this, world_x, y);
                if (reacted) {
                    stats.reactions_executed++;
                }

                bool moved = false;
                if (!reacted) {
                    if (externally_owned_movement_[static_cast<int>(mat)]) {
                        stats.movement_gated_skips++;
                    } else if (def.behavior == MovementBehavior::POWDER) {
                        moved = solve_powder(*this, world_x, y);
                    } else if (def.behavior == MovementBehavior::LIQUID) {
                        moved = solve_liquid(*this, world_x, y);
                    }
                }
                if (moved) {
                    stats.cells_moved++;
                }
            }
        }

        // Budget check once per row (not per cell) to keep overhead low.
        double elapsed_ms = std::chrono::duration<double, std::milli>(clock::now() - t_start).count();
        if (elapsed_ms >= simulation_budget_ms) {
            resume_y_ = y - 1;
            stats.sim_ms = elapsed_ms;
            for (const Chunk &c : chunks_) {
                if (!c.sleeping) stats.active_chunks++;
                else stats.sleeping_chunks++;
            }
            return stats;
        }
    }

    // Reached the top of the world: full pass complete.
    stats.pass_completed = true;
    finish_pass();
    stats.sim_ms = std::chrono::duration<double, std::milli>(clock::now() - t_start).count();
    for (const Chunk &c : chunks_) {
        if (!c.sleeping) stats.active_chunks++;
        else stats.sleeping_chunks++;
    }
    return stats;
}

int World::compute_drop_count(float &remainder, int mined_count, float ratio) {
    if (mined_count <= 0) {
        return 0;
    }
    float total = remainder + static_cast<float>(mined_count) * ratio;
    int drop_count = static_cast<int>(std::floor(total));
    if (drop_count < 0) drop_count = 0;
    if (drop_count > mined_count) drop_count = mined_count; // never fabricate drops
    remainder = total - static_cast<float>(drop_count);
    return drop_count;
}

MineResult World::mine_area(int center_x, int center_y, int size, MiningShape shape) {
    MineResult result;
    int r2 = size * size;

    // Pass 1: find every minable, non-AIR cell in the footprint and bucket
    // its coordinates by material - can_be_mined is checked here, so a
    // non-minable material never enters a bucket and is left completely
    // untouched (no clear, no drop, no wake), same as before this feature.
    std::vector<std::pair<int, int>> positions[MATERIAL_COUNT];

    for (int dy = -size; dy <= size; ++dy) {
        for (int dx = -size; dx <= size; ++dx) {
            if (shape == MiningShape::CIRCLE && dx * dx + dy * dy > r2) continue;
            // SQUARE needs no extra check - the loop bounds themselves are the box.
            int x = center_x + dx, y = center_y + dy;
            if (!in_bounds(x, y)) continue;
            MaterialType mat = get_material(x, y);
            if (mat == MaterialType::AIR) continue;

            const MaterialDef &def = get_material_def(mat);
            if (!def.can_be_mined) {
                continue;
            }

            positions[static_cast<int>(mat)].emplace_back(x, y);
        }
    }

    // Pass 2: convert each material's mined batch as a whole. The ratio is
    // applied to the batch's total quantity (via compute_drop_count), not to
    // each cell individually, so a batch of e.g. 7 DIRT at ratio 0.5 yields
    // exactly floor(7*0.5)=3 SAND drops - never "3 or 4 depending on which
    // cell you ask about". Which specific cells get the drop vs. plain AIR is
    // just "the first drop_count cells in scan order" - an implementation
    // detail; only the aggregate counts are a documented contract.
    for (int m = 0; m < MATERIAL_COUNT; ++m) {
        std::vector<std::pair<int, int>> &cells = positions[m];
        if (cells.empty()) continue;

        MaterialType mat = static_cast<MaterialType>(m);
        const MaterialDef &def = get_material_def(mat);
        int mined_count = static_cast<int>(cells.size());

        result.counts[m] = mined_count;
        result.total_removed += mined_count;

        int drop_count = compute_drop_count(mining_remainder_[m], mined_count, def.drop_ratio);

        for (int i = 0; i < mined_count; ++i) {
            // One set_cell() covers both "clear the original" and "place the
            // drop": mined_drop defaults to AIR for materials with no
            // conversion mapping, and cells past drop_count also just become
            // AIR. set_cell() wakes and dirties the owning chunk either way.
            MaterialType new_mat = (i < drop_count) ? def.mined_drop : MaterialType::AIR;
            set_cell(cells[i].first, cells[i].second, new_mat);
        }
    }

    return result;
}

MineResult World::mine_circle(int center_x, int center_y, int radius) {
    return mine_area(center_x, center_y, radius, MiningShape::CIRCLE);
}

bool World::place_cell(int x, int y, MaterialType material) {
    if (get_material(x, y) != MaterialType::AIR) {
        return false;
    }
    return set_cell(x, y, material);
}

void World::fill_rect(int x0, int y0, int w, int h, MaterialType material) {
    for (int y = y0; y < y0 + h; ++y) {
        for (int x = x0; x < x0 + w; ++x) {
            set_cell(x, y, material);
        }
    }
}

std::vector<MaterialType> World::get_materials_rect(int x0, int y0, int w, int h) const {
    std::vector<MaterialType> out;
    out.reserve(static_cast<size_t>(std::max(w, 0)) * static_cast<size_t>(std::max(h, 0)));
    for (int y = y0; y < y0 + h; ++y) {
        for (int x = x0; x < x0 + w; ++x) {
            out.push_back(get_material(x, y));
        }
    }
    return out;
}

int World::set_materials_rect(int x0, int y0, int w, int h, const std::vector<MaterialType> &materials) {
    int changed = 0;
    size_t i = 0;
    for (int y = y0; y < y0 + h; ++y) {
        for (int x = x0; x < x0 + w; ++x) {
            if (i >= materials.size()) return changed;
            MaterialType incoming = materials[i++];
            if (get_material(x, y) != incoming) {
                set_cell(x, y, incoming);
                ++changed;
            }
        }
    }
    return changed;
}

void World::set_movement_externally_owned(MaterialType material, bool owned) {
    int idx = static_cast<int>(material);
    if (idx < 0 || idx >= MATERIAL_COUNT) return;
    externally_owned_movement_[idx] = owned;
}

bool World::is_movement_externally_owned(MaterialType material) const {
    int idx = static_cast<int>(material);
    if (idx < 0 || idx >= MATERIAL_COUNT) return false;
    return externally_owned_movement_[idx];
}

bool World::consume_render_dirty(int cx, int cy) {
    if (!chunk_in_bounds(cx, cy)) return false;
    Chunk &c = chunk_at(cx, cy);
    if (!c.render_dirty) return false;
    c.render_dirty = false;
    c.reset_touched_rect();
    return true;
}

RenderDirtyRect World::consume_render_dirty_rect(int cx, int cy) {
    RenderDirtyRect result;
    if (!chunk_in_bounds(cx, cy)) return result;
    Chunk &c = chunk_at(cx, cy);
    if (!c.render_dirty) return result;
    result.was_dirty = true;
    result.has_rect = c.has_touched_rect();
    if (result.has_rect) {
        result.min_x = c.touched_min_x;
        result.min_y = c.touched_min_y;
        result.max_x = c.touched_max_x;
        result.max_y = c.touched_max_y;
    }
    c.render_dirty = false;
    c.reset_touched_rect();
    return result;
}

} // namespace pixelsim
