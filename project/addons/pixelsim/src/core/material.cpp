#include "material.h"

namespace pixelsim {

namespace {

constexpr MaterialDef MATERIAL_TABLE[MATERIAL_COUNT] = {
    // name          behavior                    density solid  liquid powder static flam  hardness  r    g    b    a    minable mined_drop              ratio  is_mining_drop
    {"AIR",        MovementBehavior::NONE,        0.0f,  false, false, false, false, false, 0.0f,    0,   0,   0,   0,   false,  MaterialType::AIR,      1.0f,  false},
    {"SAND",       MovementBehavior::POWDER,      1.6f,  true,  false, true,  false, false, 1.0f,   218, 190,  97, 255, false,  MaterialType::AIR,      1.0f,  true},
    {"DIRT",       MovementBehavior::STATIC,      1.5f,  true,  false, false, true,  false, 1.5f,   109,  74,  45, 255, true,   MaterialType::SAND,     0.5f,  false},
    {"STONE",      MovementBehavior::STATIC,      2.6f,  true,  false, false, true,  false, 4.0f,   120, 120, 120, 255, true,   MaterialType::GRAVEL,   0.5f,  false},
    {"IRON_ORE",   MovementBehavior::STATIC,      3.0f,  true,  false, false, true,  false, 5.0f,   183, 106, 100, 255, true,   MaterialType::AIR,      1.0f,  false},
    {"COPPER_ORE", MovementBehavior::STATIC,      2.9f,  true,  false, false, true,  false, 4.5f,   205, 133,  63, 255, true,   MaterialType::AIR,      1.0f,  false},
    {"WATER",      MovementBehavior::LIQUID,      1.0f,  false, true,  false, false, false, 0.0f,    60, 120, 220, 180, true,   MaterialType::AIR,      1.0f,  false},
    {"WOOD",       MovementBehavior::STATIC,      0.9f,  true,  false, false, true,  true,  2.0f,   133,  94,  53, 255, true,   MaterialType::AIR,      1.0f,  false},
    {"METAL",      MovementBehavior::STATIC,      7.8f,  true,  false, false, true,  false, 6.0f,   200, 200, 205, 255, true,   MaterialType::AIR,      1.0f,  false},
    {"GRAVEL",     MovementBehavior::POWDER,      1.9f,  true,  false, true,  false, false, 1.2f,   150, 145, 140, 255, false,  MaterialType::AIR,      1.0f,  true},
    // Reaction product (WATER + DIRT, see MATERIAL_REACTIONS.md) - never
    // placed by terrain generation. STATIC like DIRT/STONE (not a mining
    // drop; not_mining_drop == false is correct here even though MUD "only
    // exists as a product" like SAND/GRAVEL do, because is_mining_drop is
    // specifically about MINING-drop collision classification, not "any
    // non-terrain-gen origin" - see MATERIAL_REACTIONS.md "Current Reactions").
    {"MUD",        MovementBehavior::STATIC,      1.6f,  true,  false, false, true,  false, 1.0f,    70,  50,  30, 255, true,   MaterialType::AIR,      1.0f,  false},
    // Second LIQUID material - reuses solve_liquid exactly like WATER (no
    // separate solve_lava()). Density deliberately higher than every other
    // material here (including STONE) rather than following real-world lava
    // density: this is a chosen gameplay/simulation property, not physics -
    // see MATERIALS.md "Density". Consequence: SAND/GRAVEL rest ON TOP of
    // LAVA instead of sinking through it (can_displace's mover.density >
    // target.density check fails both ways), and WATER/LAVA never displace
    // each other (both liquid) - they only ever interact via the Material
    // Reaction System (see MATERIAL_REACTIONS.md), never physical swapping.
    {"LAVA",       MovementBehavior::LIQUID,      3.2f,  false, true,  false, false, false, 0.0f,   230,  70,  20, 255, true,   MaterialType::AIR,      1.0f,  false},
};

} // namespace

const MaterialDef &get_material_def(MaterialType type) {
    int idx = static_cast<int>(type);
    if (idx < 0 || idx >= MATERIAL_COUNT) {
        idx = 0;
    }
    return MATERIAL_TABLE[idx];
}

const MaterialDef &get_material_def(uint8_t type) {
    return get_material_def(static_cast<MaterialType>(type));
}

bool material_can_displace(MaterialType mover, MaterialType target) {
    if (target == MaterialType::AIR) {
        return true;
    }
    const MaterialDef &mover_def = get_material_def(mover);
    const MaterialDef &target_def = get_material_def(target);
    // A movable material can push into a lower-density liquid it can sink through
    // (e.g. sand sinking through water), but never into anything solid/static.
    if (target_def.is_liquid && !mover_def.is_liquid && mover_def.density > target_def.density) {
        return true;
    }
    return false;
}

} // namespace pixelsim
