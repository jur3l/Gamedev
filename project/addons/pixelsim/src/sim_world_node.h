#pragma once

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/core/binder_common.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/string.hpp>
#include <memory>

#include "core/world.h"

namespace godot {

// The single point of contact between GDScript/the scene tree and the C++
// Cellular Automata core. This node owns a pixelsim::World and nothing else;
// it never creates a Godot Node/Sprite/PhysicsBody per cell - it only ever
// hands the caller flat PackedByteArrays of pixel data for chunk rendering,
// and Dictionaries of stats/results.
class PixelSimWorld : public Node {
    GDCLASS(PixelSimWorld, Node)

public:
    // Mirrors pixelsim::MaterialType 1:1 - exposed to GDScript as
    // PixelSimWorld.MATERIAL_SAND etc. so callers never hardcode magic ints.
    enum MaterialId {
        MATERIAL_AIR = 0,
        MATERIAL_SAND,
        MATERIAL_DIRT,
        MATERIAL_STONE,
        MATERIAL_IRON_ORE,
        MATERIAL_COPPER_ORE,
        MATERIAL_WATER,
        MATERIAL_WOOD,
        MATERIAL_METAL,
        MATERIAL_GRAVEL,
        MATERIAL_MUD,
        MATERIAL_LAVA,
    };

    // Mirrors pixelsim::MiningShape 1:1 - exposed as PixelSimWorld.SHAPE_CIRCLE
    // / SHAPE_SQUARE so the mining tool's footprint is configurable from
    // GDScript without magic numbers.
    enum ToolShape {
        SHAPE_CIRCLE = 0,
        SHAPE_SQUARE,
    };

    // Mirrors pixelsim::BackgroundType 1:1 - see TERRAIN_LAYERS.md.
    enum BackgroundId {
        BACKGROUND_NONE = 0,
        BACKGROUND_DARK_ROCK,
    };

    PixelSimWorld();
    ~PixelSimWorld() override;

    void _ready() override;

    // --- Configuration (set before generate_terrain/first step) ---
    void set_world_width_chunks(int v) { world_width_chunks_ = v; }
    int get_world_width_chunks() const { return world_width_chunks_; }
    void set_world_height_chunks(int v) { world_height_chunks_ = v; }
    int get_world_height_chunks() const { return world_height_chunks_; }
    void set_simulation_cell_size(int v) { simulation_cell_size_ = v; }
    int get_simulation_cell_size() const { return simulation_cell_size_; }
    void set_simulation_budget_ms(double v) { simulation_budget_ms_ = v; }
    double get_simulation_budget_ms() const { return simulation_budget_ms_; }
    void set_world_seed(int v) { world_seed_ = v; }
    int get_world_seed() const { return world_seed_; }

    // --- Lifecycle ---
    void init_world();
    void generate_test_terrain();

    // --- Simulation ---
    Dictionary step_simulation(double delta);

    // --- Grid access ---
    int get_cell(int x, int y);
    String get_material_name(int material) const;
    // True for materials that exist only as a mining-drop product (SAND,
    // GRAVEL) - see PLAYER_COLLISION.md. Player collision code uses this to
    // decide whether mined_drop_collision applies to a given foreground
    // cell; the simulation core itself never calls this.
    bool is_mining_drop_material(int material) const;
    void set_cell(int x, int y, int material);
    bool place_cell(int x, int y, int material);
    Dictionary mine_circle(int x, int y, int radius);
    Dictionary mine_area(int x, int y, int size, int shape);
    void fill_rect(int x, int y, int w, int h, int material);

    // --- Background layer (see TERRAIN_LAYERS.md) - static, non-simulated,
    // shown wherever the foreground cell is AIR. set_background() never
    // wakes a chunk or touches simulation state, unlike set_cell(). ---
    int get_background(int x, int y);
    String get_background_name(int background) const;
    bool set_background(int x, int y, int background);

    // --- Rendering support (chunk-based, not per-cell) ---
    int get_chunk_size() const;
    Vector2i get_world_size_cells() const;
    Vector2i get_world_size_chunks() const;
    PackedByteArray get_chunk_pixels(int cx, int cy);
    // Same RGBA8 compositing as get_chunk_pixels(), but only for the
    // sub-rectangle [x, x+w) x [y, y+h) of the chunk (local coords) - see
    // PERFORMANCE_SCALABILITY.md "Rendering Scaling". Returns an empty array
    // if the chunk is out of bounds or the rect is degenerate.
    PackedByteArray get_chunk_pixels_rect(int cx, int cy, int x, int y, int w, int h);
    // Returns an Array of Dictionaries, one per chunk whose texture needs
    // re-upload, and clears their render-dirty flag as a side effect
    // (consuming read) - same single full-chunk-list-scan cost as before,
    // just returning more per-chunk information. Each entry:
    //   "coord": Vector2i, "full": bool (true => no valid touched-rect,
    //   caller must re-read the whole chunk via get_chunk_pixels()),
    //   and when "full" is false: "x", "y", "w", "h" (the touched sub-rect,
    //   local chunk coords) for use with get_chunk_pixels_rect().
    Array get_and_clear_dirty_render_chunks();
    Array get_active_chunk_coords();
    Array get_sleeping_chunk_coords();

    // --- Stats / debug ---
    Dictionary get_stats() const;

    // --- Stress testing ---
    void spawn_material_rect(int x, int y, int w, int h, int material);

protected:
    static void _bind_methods();

private:
    std::unique_ptr<pixelsim::World> world_;

    int world_width_chunks_ = 48;
    int world_height_chunks_ = 28;
    int simulation_cell_size_ = 4;
    double simulation_budget_ms_ = 4.0;
    int world_seed_ = 1337;

    pixelsim::StepStats last_stats_{};
};

} // namespace godot

// Required for BIND_ENUM_CONSTANT to work on a custom nested enum - gives
// Godot's variant/binding system a GetTypeInfo specialization for it.
VARIANT_ENUM_CAST(godot::PixelSimWorld::MaterialId);
VARIANT_ENUM_CAST(godot::PixelSimWorld::ToolShape);
VARIANT_ENUM_CAST(godot::PixelSimWorld::BackgroundId);
