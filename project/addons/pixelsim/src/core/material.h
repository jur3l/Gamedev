#pragma once
#include <cstdint>

namespace pixelsim {

// Every material the simulation knows about. Values are stable and stored
// directly inside Cell::material, so existing world saves would depend on
// this ordering - append new materials at the end, never reorder.
enum class MaterialType : uint8_t {
    AIR = 0,
    SAND,
    DIRT,
    STONE,
    IRON_ORE,
    COPPER_ORE,
    WATER,
    WOOD,
    METAL,
    GRAVEL,
    COUNT
};

constexpr int MATERIAL_COUNT = static_cast<int>(MaterialType::COUNT);

enum class MovementBehavior : uint8_t {
    NONE = 0,     // AIR - nothing to simulate
    STATIC = 1,   // immovable solid, only removable via mining (dirt/stone/ore/wood/metal)
    POWDER = 2,   // falls straight down, then diagonally (sand)
    LIQUID = 3,   // falls straight down, then spreads horizontally (water)
};

// Plain-data material properties table. Solvers dispatch on `behavior` and
// never hardcode a specific MaterialType, so adding FIRE/OIL/LAVA/... later
// only means adding a row here plus (if it needs a genuinely new movement
// rule) a new MovementBehavior case.
struct MaterialDef {
    const char *name;
    MovementBehavior behavior;
    float density;        // higher sinks below lower-density movable materials
    bool is_solid;         // occupies space / blocks other materials
    bool is_liquid;
    bool is_powder;
    bool is_static;         // mining-only removal, never simulated for movement
    bool is_flammable_stub; // reserved for future FIRE material, unused now
    float hardness;         // reserved for future mining-speed-per-material
    uint8_t color_r, color_g, color_b, color_a; // debug/base render color

    // Mining drop / material conversion. Deliberately independent of each
    // other: a material can be minable with no drop (mined_drop == AIR,
    // meaning "just clear it"), and something can have a drop mapping without
    // that alone making it minable. Mining code must always check
    // can_be_mined first and never infer it from mined_drop.
    bool can_be_mined;
    MaterialType mined_drop; // material left behind as a real cell, AIR = none

    // Fraction of a mined QUANTITY of this material that becomes mined_drop
    // cells - applied to the whole mined batch (see World::compute_drop_count),
    // never rounded per individual cell. 1.0 = every mined cell drops, 0.0 =
    // none do, 0.5 = half (e.g. 100 mined -> 50 drops). Irrelevant when
    // mined_drop == AIR (converting some vs. all of a batch to AIR looks the
    // same either way).
    float drop_ratio;

    // True for materials that exist ONLY as a mining drop product in the
    // current game content (SAND from DIRT, GRAVEL from STONE - neither is
    // ever placed by terrain generation or building). This is a per-TYPE
    // classification, not per-cell state - see PLAYER_COLLISION.md "Data
    // Model" for why that distinction is safe today and what would have to
    // change if it ever stopped being true (a material that is both
    // naturally placed AND someone's mined_drop). Consumed by the player's
    // collision code (PixelSimWorld::is_mining_drop_material) to decide
    // whether mined_drop_collision applies - the simulation core itself
    // never reads this field.
    bool is_mining_drop;
};

const MaterialDef &get_material_def(MaterialType type);
const MaterialDef &get_material_def(uint8_t type);

bool material_can_displace(MaterialType mover, MaterialType target);

} // namespace pixelsim
