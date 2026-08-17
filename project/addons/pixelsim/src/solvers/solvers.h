#pragma once

namespace pixelsim {

class World;

// Each solver looks only at the cell at (x, y) and its immediate neighbors,
// and expresses movement purely as World::swap_cells() (data swap, never
// object movement). Returns true if the cell moved this step.
bool solve_powder(World &world, int x, int y);
bool solve_liquid(World &world, int x, int y);

} // namespace pixelsim
