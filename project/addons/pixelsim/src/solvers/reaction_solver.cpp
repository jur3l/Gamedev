#include "reaction_solver.h"
#include "../core/reaction.h"
#include "../core/world.h"

namespace pixelsim {

bool roll_reaction_probability(uint32_t rand_value, float probability) {
    if (probability >= 1.0f) return true;
    if (probability <= 0.0f) return false;
    constexpr uint32_t SCALE = 1000000u;
    uint32_t threshold = static_cast<uint32_t>(probability * static_cast<float>(SCALE));
    return (rand_value % SCALE) < threshold;
}

bool try_react(World &world, int x, int y) {
    if (world.is_cell_reacted_this_step(x, y)) {
        return false;
    }
    MaterialType mat = world.get_material(x, y);

    // Orthogonal only (see MATERIAL_REACTIONS.md "Reaction Execution") -
    // fixed order, no diagonals.
    static const int DX[4] = {0, 0, -1, 1};
    static const int DY[4] = {-1, 1, 0, 0};

    for (int i = 0; i < 4; ++i) {
        int nx = x + DX[i];
        int ny = y + DY[i];
        if (!world.in_bounds(nx, ny)) continue;
        if (world.is_cell_reacted_this_step(nx, ny)) continue;

        MaterialType neighbor_mat = world.get_material(nx, ny);
        MaterialType result_self, result_neighbor;
        float probability;
        if (!find_reaction(mat, neighbor_mat, result_self, result_neighbor, probability)) {
            continue;
        }

        // Guaranteed reactions skip the RNG draw entirely - see
        // MATERIAL_REACTIONS.md "Determinism".
        if (probability < 1.0f && !roll_reaction_probability(world.rand_u32(), probability)) {
            continue;
        }

        world.set_cell(x, y, result_self);
        world.set_cell(nx, ny, result_neighbor);
        world.mark_cell_reacted(x, y);
        world.mark_cell_reacted(nx, ny);
        return true;
    }
    return false;
}

} // namespace pixelsim
