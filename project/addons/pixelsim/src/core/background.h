#pragma once
#include <cstdint>

namespace pixelsim {

// Background layer type. Deliberately a SEPARATE, much smaller enum/table
// than MaterialType/MaterialDef (material.h) - the background is static,
// non-simulated set-dressing (see TERRAIN_LAYERS.md), so it carries none of
// MaterialDef's simulation/mining fields (behavior, density, can_be_mined,
// mined_drop, ...). Keeping it a distinct type also makes it a compile error
// to accidentally pass a BackgroundType where a MaterialType is expected, or
// route it through a solver.
//
// Same append-only rule as MaterialType: Chunk::background stores the raw
// value directly, so existing world data depends on this ordering.
enum class BackgroundType : uint8_t {
    NONE = 0, // no background - renders fully transparent (open sky, or a
              // cell terrain generation never assigned a background to)
    DARK_ROCK,
    COUNT
};

constexpr int BACKGROUND_TYPE_COUNT = static_cast<int>(BackgroundType::COUNT);

// Deliberately minimal - a name (for debugging/tooling, see
// PixelSimWorld::get_background_name) and a render color. This is the single
// place background colors are defined; rendering code must look them up
// here rather than hardcoding a color anywhere else.
struct BackgroundDef {
    const char *name;
    uint8_t color_r, color_g, color_b, color_a;
};

const BackgroundDef &get_background_def(BackgroundType type);
const BackgroundDef &get_background_def(uint8_t type);

} // namespace pixelsim
