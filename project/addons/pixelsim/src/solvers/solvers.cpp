#include "solvers.h"
#include "../core/world.h"

namespace pixelsim {

bool solve_powder(World &world, int x, int y) {
    MaterialType mat = world.get_material(x, y);

    if (world.can_displace(mat, x, y + 1)) {
        world.swap_cells(x, y, x, y + 1);
        return true;
    }

    // Randomize which diagonal is tried first so repeated ties (e.g. a flat
    // sand surface) don't all resolve toward the same side every pass.
    bool left_first = (world.rand_u32() & 1u) == 0u;
    int dx1 = left_first ? -1 : 1;
    int dx2 = -dx1;

    if (world.can_displace(mat, x + dx1, y + 1)) {
        world.swap_cells(x, y, x + dx1, y + 1);
        return true;
    }
    if (world.can_displace(mat, x + dx2, y + 1)) {
        world.swap_cells(x, y, x + dx2, y + 1);
        return true;
    }
    return false;
}

bool solve_liquid(World &world, int x, int y) {
    MaterialType mat = world.get_material(x, y);

    if (world.can_displace(mat, x, y + 1)) {
        world.swap_cells(x, y, x, y + 1);
        return true;
    }

    bool left_first = (world.rand_u32() & 1u) == 0u;
    int dx1 = left_first ? -1 : 1;
    int dx2 = -dx1;

    if (world.can_displace(mat, x + dx1, y + 1)) {
        world.swap_cells(x, y, x + dx1, y + 1);
        return true;
    }
    if (world.can_displace(mat, x + dx2, y + 1)) {
        world.swap_cells(x, y, x + dx2, y + 1);
        return true;
    }

    // Can't fall - spread sideways one cell toward whichever side is open.
    if (world.can_displace(mat, x + dx1, y)) {
        world.swap_cells(x, y, x + dx1, y);
        return true;
    }
    if (world.can_displace(mat, x + dx2, y)) {
        world.swap_cells(x, y, x + dx2, y);
        return true;
    }
    return false;
}

} // namespace pixelsim
