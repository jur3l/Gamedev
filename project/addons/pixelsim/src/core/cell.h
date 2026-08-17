#pragma once
#include <cstdint>
#include "material.h"

namespace pixelsim {

// Plain, cache-friendly cell data - NOT a Godot Object/Node/Sprite/PhysicsBody.
// Kept intentionally tiny (2 bytes) so a full chunk (64x64 = 4096 cells) is
// only 8KB and a large world of thousands of chunks stays contiguous and
// cache-friendly rather than scattering pointer-chasing allocations.
struct Cell {
    uint8_t material = static_cast<uint8_t>(MaterialType::AIR);
    uint8_t flags = 0;

    static constexpr uint8_t FLAG_UPDATED_THIS_STEP = 1 << 0;

    MaterialType get_material() const { return static_cast<MaterialType>(material); }
    void set_material(MaterialType m) { material = static_cast<uint8_t>(m); }

    bool is_updated() const { return (flags & FLAG_UPDATED_THIS_STEP) != 0; }
    void mark_updated() { flags |= FLAG_UPDATED_THIS_STEP; }
    void clear_updated() { flags &= ~FLAG_UPDATED_THIS_STEP; }
};

static_assert(sizeof(Cell) == 2, "Cell must stay a tiny POD - do not add heavy fields");

} // namespace pixelsim
