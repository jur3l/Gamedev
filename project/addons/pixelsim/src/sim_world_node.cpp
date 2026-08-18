#include "sim_world_node.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/vector2i.hpp>

#include "core/background.h"
#include "core/material.h"
#include "gen/terrain_gen.h"

using namespace pixelsim;

namespace {
// Shared by get_chunk_pixels() and get_chunk_pixels_rect() so the
// compositing rule (TERRAIN_LAYERS.md "Rendering": foreground wins wherever
// it isn't AIR, otherwise the background shows through) is defined exactly
// once, not duplicated between a full-chunk and a partial-rect code path.
inline void composite_pixel(uint8_t *dst, const Chunk &chunk, int lx, int ly) {
    const Cell &cell = chunk.at(lx, ly);
    if (cell.get_material() == MaterialType::AIR) {
        const BackgroundDef &bg = get_background_def(chunk.get_background(lx, ly));
        dst[0] = bg.color_r;
        dst[1] = bg.color_g;
        dst[2] = bg.color_b;
        dst[3] = bg.color_a;
    } else {
        const MaterialDef &def = get_material_def(cell.material);
        dst[0] = def.color_r;
        dst[1] = def.color_g;
        dst[2] = def.color_b;
        dst[3] = def.color_a;
    }
}
} // namespace

namespace godot {

PixelSimWorld::PixelSimWorld() {}
PixelSimWorld::~PixelSimWorld() {}

void PixelSimWorld::_bind_methods() {
    ClassDB::bind_method(D_METHOD("set_world_width_chunks", "value"), &PixelSimWorld::set_world_width_chunks);
    ClassDB::bind_method(D_METHOD("get_world_width_chunks"), &PixelSimWorld::get_world_width_chunks);
    ClassDB::bind_method(D_METHOD("set_world_height_chunks", "value"), &PixelSimWorld::set_world_height_chunks);
    ClassDB::bind_method(D_METHOD("get_world_height_chunks"), &PixelSimWorld::get_world_height_chunks);
    ClassDB::bind_method(D_METHOD("set_simulation_cell_size", "value"), &PixelSimWorld::set_simulation_cell_size);
    ClassDB::bind_method(D_METHOD("get_simulation_cell_size"), &PixelSimWorld::get_simulation_cell_size);
    ClassDB::bind_method(D_METHOD("set_simulation_budget_ms", "value"), &PixelSimWorld::set_simulation_budget_ms);
    ClassDB::bind_method(D_METHOD("get_simulation_budget_ms"), &PixelSimWorld::get_simulation_budget_ms);
    ClassDB::bind_method(D_METHOD("set_world_seed", "value"), &PixelSimWorld::set_world_seed);
    ClassDB::bind_method(D_METHOD("get_world_seed"), &PixelSimWorld::get_world_seed);

    ADD_PROPERTY(PropertyInfo(Variant::INT, "world_width_chunks"), "set_world_width_chunks", "get_world_width_chunks");
    ADD_PROPERTY(PropertyInfo(Variant::INT, "world_height_chunks"), "set_world_height_chunks", "get_world_height_chunks");
    ADD_PROPERTY(PropertyInfo(Variant::INT, "simulation_cell_size"), "set_simulation_cell_size", "get_simulation_cell_size");
    ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "simulation_budget_ms"), "set_simulation_budget_ms", "get_simulation_budget_ms");
    ADD_PROPERTY(PropertyInfo(Variant::INT, "world_seed"), "set_world_seed", "get_world_seed");

    ClassDB::bind_method(D_METHOD("init_world"), &PixelSimWorld::init_world);
    ClassDB::bind_method(D_METHOD("generate_test_terrain"), &PixelSimWorld::generate_test_terrain);
    ClassDB::bind_method(D_METHOD("step_simulation", "delta"), &PixelSimWorld::step_simulation);

    ClassDB::bind_method(D_METHOD("get_cell", "x", "y"), &PixelSimWorld::get_cell);
    ClassDB::bind_method(D_METHOD("get_material_name", "material"), &PixelSimWorld::get_material_name);
    ClassDB::bind_method(D_METHOD("is_mining_drop_material", "material"), &PixelSimWorld::is_mining_drop_material);
    ClassDB::bind_method(D_METHOD("set_cell", "x", "y", "material"), &PixelSimWorld::set_cell);
    ClassDB::bind_method(D_METHOD("place_cell", "x", "y", "material"), &PixelSimWorld::place_cell);
    ClassDB::bind_method(D_METHOD("mine_circle", "x", "y", "radius"), &PixelSimWorld::mine_circle);
    ClassDB::bind_method(D_METHOD("mine_area", "x", "y", "size", "shape"), &PixelSimWorld::mine_area);
    ClassDB::bind_method(D_METHOD("fill_rect", "x", "y", "w", "h", "material"), &PixelSimWorld::fill_rect);

    ClassDB::bind_method(D_METHOD("get_background", "x", "y"), &PixelSimWorld::get_background);
    ClassDB::bind_method(D_METHOD("get_background_name", "background"), &PixelSimWorld::get_background_name);
    ClassDB::bind_method(D_METHOD("set_background", "x", "y", "background"), &PixelSimWorld::set_background);

    ClassDB::bind_method(D_METHOD("get_chunk_size"), &PixelSimWorld::get_chunk_size);
    ClassDB::bind_method(D_METHOD("get_world_size_cells"), &PixelSimWorld::get_world_size_cells);
    ClassDB::bind_method(D_METHOD("get_world_size_chunks"), &PixelSimWorld::get_world_size_chunks);
    ClassDB::bind_method(D_METHOD("get_chunk_pixels", "cx", "cy"), &PixelSimWorld::get_chunk_pixels);
    ClassDB::bind_method(D_METHOD("get_chunk_pixels_rect", "cx", "cy", "x", "y", "w", "h"), &PixelSimWorld::get_chunk_pixels_rect);
    ClassDB::bind_method(D_METHOD("get_and_clear_dirty_render_chunks"), &PixelSimWorld::get_and_clear_dirty_render_chunks);
    ClassDB::bind_method(D_METHOD("get_active_chunk_coords"), &PixelSimWorld::get_active_chunk_coords);
    ClassDB::bind_method(D_METHOD("get_sleeping_chunk_coords"), &PixelSimWorld::get_sleeping_chunk_coords);

    ClassDB::bind_method(D_METHOD("get_stats"), &PixelSimWorld::get_stats);

    ClassDB::bind_method(D_METHOD("spawn_material_rect", "x", "y", "w", "h", "material"), &PixelSimWorld::spawn_material_rect);

    // Expose MaterialType as constants so GDScript can refer to
    // PixelSimWorld.MATERIAL_SAND etc. instead of magic numbers.
    BIND_ENUM_CONSTANT(MATERIAL_AIR);
    BIND_ENUM_CONSTANT(MATERIAL_SAND);
    BIND_ENUM_CONSTANT(MATERIAL_DIRT);
    BIND_ENUM_CONSTANT(MATERIAL_STONE);
    BIND_ENUM_CONSTANT(MATERIAL_IRON_ORE);
    BIND_ENUM_CONSTANT(MATERIAL_COPPER_ORE);
    BIND_ENUM_CONSTANT(MATERIAL_WATER);
    BIND_ENUM_CONSTANT(MATERIAL_WOOD);
    BIND_ENUM_CONSTANT(MATERIAL_METAL);
    BIND_ENUM_CONSTANT(MATERIAL_GRAVEL);
    BIND_ENUM_CONSTANT(MATERIAL_MUD);
    BIND_ENUM_CONSTANT(MATERIAL_LAVA);

    BIND_ENUM_CONSTANT(SHAPE_CIRCLE);
    BIND_ENUM_CONSTANT(SHAPE_SQUARE);

    BIND_ENUM_CONSTANT(BACKGROUND_NONE);
    BIND_ENUM_CONSTANT(BACKGROUND_DARK_ROCK);
}

void PixelSimWorld::_ready() {
    if (!world_) {
        init_world();
    }
}

void PixelSimWorld::init_world() {
    world_ = std::make_unique<World>(world_width_chunks_, world_height_chunks_, static_cast<uint32_t>(world_seed_));
}

void PixelSimWorld::generate_test_terrain() {
    if (!world_) init_world();
    pixelsim::generate_test_terrain(*world_, static_cast<uint32_t>(world_seed_));
}

Dictionary PixelSimWorld::step_simulation(double delta) {
    Dictionary d;
    if (!world_) {
        return d;
    }
    last_stats_ = world_->step(simulation_budget_ms_);
    d["sim_ms"] = last_stats_.sim_ms;
    d["pass_completed"] = last_stats_.pass_completed;
    d["cells_evaluated"] = static_cast<int64_t>(last_stats_.cells_evaluated);
    d["cells_moved"] = static_cast<int64_t>(last_stats_.cells_moved);
    d["reaction_checks"] = static_cast<int64_t>(last_stats_.reaction_checks);
    d["reactions_executed"] = static_cast<int64_t>(last_stats_.reactions_executed);
    d["active_chunks"] = last_stats_.active_chunks;
    d["sleeping_chunks"] = last_stats_.sleeping_chunks;
    d["total_chunks"] = last_stats_.total_chunks;
    return d;
}

int PixelSimWorld::get_cell(int x, int y) {
    if (!world_) return 0;
    return static_cast<int>(world_->get_material(x, y));
}

String PixelSimWorld::get_material_name(int material) const {
    return String(get_material_def(static_cast<uint8_t>(material)).name);
}

bool PixelSimWorld::is_mining_drop_material(int material) const {
    return get_material_def(static_cast<uint8_t>(material)).is_mining_drop;
}

void PixelSimWorld::set_cell(int x, int y, int material) {
    if (!world_) return;
    world_->set_cell(x, y, static_cast<MaterialType>(material));
}

bool PixelSimWorld::place_cell(int x, int y, int material) {
    if (!world_) return false;
    return world_->place_cell(x, y, static_cast<MaterialType>(material));
}

Dictionary PixelSimWorld::mine_circle(int x, int y, int radius) {
    Dictionary result;
    if (!world_) return result;
    MineResult mr = world_->mine_circle(x, y, radius);
    Dictionary counts;
    for (int i = 0; i < MATERIAL_COUNT; ++i) {
        if (mr.counts[i] > 0) {
            counts[i] = mr.counts[i];
        }
    }
    result["counts"] = counts;
    result["total_removed"] = mr.total_removed;
    return result;
}

Dictionary PixelSimWorld::mine_area(int x, int y, int size, int shape) {
    Dictionary result;
    if (!world_) return result;
    MineResult mr = world_->mine_area(x, y, size, static_cast<MiningShape>(shape));
    Dictionary counts;
    for (int i = 0; i < MATERIAL_COUNT; ++i) {
        if (mr.counts[i] > 0) {
            counts[i] = mr.counts[i];
        }
    }
    result["counts"] = counts;
    result["total_removed"] = mr.total_removed;
    return result;
}

void PixelSimWorld::fill_rect(int x, int y, int w, int h, int material) {
    if (!world_) return;
    world_->fill_rect(x, y, w, h, static_cast<MaterialType>(material));
}

int PixelSimWorld::get_background(int x, int y) {
    if (!world_) return 0;
    return static_cast<int>(world_->get_background(x, y));
}

String PixelSimWorld::get_background_name(int background) const {
    return String(get_background_def(static_cast<uint8_t>(background)).name);
}

bool PixelSimWorld::set_background(int x, int y, int background) {
    if (!world_) return false;
    return world_->set_background(x, y, static_cast<BackgroundType>(background));
}

int PixelSimWorld::get_chunk_size() const {
    return CHUNK_SIZE;
}

Vector2i PixelSimWorld::get_world_size_cells() const {
    if (!world_) return Vector2i();
    return Vector2i(world_->width_cells(), world_->height_cells());
}

Vector2i PixelSimWorld::get_world_size_chunks() const {
    if (!world_) return Vector2i();
    return Vector2i(world_->width_chunks(), world_->height_chunks());
}

PackedByteArray PixelSimWorld::get_chunk_pixels(int cx, int cy) {
    PackedByteArray bytes;
    if (!world_ || !world_->chunk_in_bounds(cx, cy)) {
        return bytes;
    }
    bytes.resize(CHUNK_CELL_COUNT * 4);
    const Chunk &chunk = world_->chunk_at(cx, cy);
    uint8_t *w = bytes.ptrw();
    for (int ly = 0; ly < CHUNK_SIZE; ++ly) {
        for (int lx = 0; lx < CHUNK_SIZE; ++lx) {
            size_t idx = (static_cast<size_t>(ly) * CHUNK_SIZE + lx) * 4;
            composite_pixel(w + idx, chunk, lx, ly);
        }
    }
    return bytes;
}

PackedByteArray PixelSimWorld::get_chunk_pixels_rect(int cx, int cy, int x, int y, int w, int h) {
    PackedByteArray bytes;
    if (!world_ || !world_->chunk_in_bounds(cx, cy)) {
        return bytes;
    }
    if (w <= 0 || h <= 0 || x < 0 || y < 0 || x + w > CHUNK_SIZE || y + h > CHUNK_SIZE) {
        return bytes;
    }
    bytes.resize(static_cast<size_t>(w) * h * 4);
    const Chunk &chunk = world_->chunk_at(cx, cy);
    uint8_t *out = bytes.ptrw();
    for (int ly = 0; ly < h; ++ly) {
        for (int lx = 0; lx < w; ++lx) {
            size_t idx = (static_cast<size_t>(ly) * w + lx) * 4;
            composite_pixel(out + idx, chunk, x + lx, y + ly);
        }
    }
    return bytes;
}

Array PixelSimWorld::get_and_clear_dirty_render_chunks() {
    Array out;
    if (!world_) return out;
    int cw = world_->width_chunks(), ch = world_->height_chunks();
    for (int cy = 0; cy < ch; ++cy) {
        for (int cx = 0; cx < cw; ++cx) {
            RenderDirtyRect r = world_->consume_render_dirty_rect(cx, cy);
            if (!r.was_dirty) continue;
            Dictionary entry;
            entry["coord"] = Vector2i(cx, cy);
            if (r.has_rect) {
                entry["full"] = false;
                entry["x"] = r.min_x;
                entry["y"] = r.min_y;
                entry["w"] = r.max_x - r.min_x + 1;
                entry["h"] = r.max_y - r.min_y + 1;
            } else {
                entry["full"] = true;
            }
            out.push_back(entry);
        }
    }
    return out;
}

Array PixelSimWorld::get_active_chunk_coords() {
    Array out;
    if (!world_) return out;
    int cw = world_->width_chunks(), ch = world_->height_chunks();
    for (int cy = 0; cy < ch; ++cy) {
        for (int cx = 0; cx < cw; ++cx) {
            if (!world_->chunk_at(cx, cy).sleeping) {
                out.push_back(Vector2i(cx, cy));
            }
        }
    }
    return out;
}

Array PixelSimWorld::get_sleeping_chunk_coords() {
    Array out;
    if (!world_) return out;
    int cw = world_->width_chunks(), ch = world_->height_chunks();
    for (int cy = 0; cy < ch; ++cy) {
        for (int cx = 0; cx < cw; ++cx) {
            if (world_->chunk_at(cx, cy).sleeping) {
                out.push_back(Vector2i(cx, cy));
            }
        }
    }
    return out;
}

Dictionary PixelSimWorld::get_stats() const {
    Dictionary d;
    d["sim_ms"] = last_stats_.sim_ms;
    d["pass_completed"] = last_stats_.pass_completed;
    d["cells_evaluated"] = static_cast<int64_t>(last_stats_.cells_evaluated);
    d["cells_moved"] = static_cast<int64_t>(last_stats_.cells_moved);
    d["reaction_checks"] = static_cast<int64_t>(last_stats_.reaction_checks);
    d["reactions_executed"] = static_cast<int64_t>(last_stats_.reactions_executed);
    d["active_chunks"] = last_stats_.active_chunks;
    d["sleeping_chunks"] = last_stats_.sleeping_chunks;
    d["total_chunks"] = last_stats_.total_chunks;
    d["total_cells"] = world_ ? static_cast<int64_t>(world_->total_cell_count()) : 0;
    return d;
}

void PixelSimWorld::spawn_material_rect(int x, int y, int w, int h, int material) {
    if (!world_) return;
    world_->fill_rect(x, y, w, h, static_cast<MaterialType>(material));
}

} // namespace godot
