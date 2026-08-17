#pragma once
#include <cstdint>

namespace pixelsim {

class World;

// Simple seed-based test terrain: rolling dirt/stone layers, scattered ore
// deposits inside the stone, and a handful of worm-carved caves. Not meant
// to be a "real" world generator - just enough to exercise mining, building
// and the falling-sand/water solvers on a non-trivial world.
void generate_test_terrain(World &world, uint32_t seed);

} // namespace pixelsim
