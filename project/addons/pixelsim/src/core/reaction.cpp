#include "reaction.h"

namespace pixelsim {

namespace {

// See MATERIAL_REACTIONS.md "Current Reactions" for why WATER+DIRT (water
// soaking into dirt) was chosen as the first demonstration reaction over the
// originally-suggested WATER+LAVA (LAVA does not exist in MaterialType).
// Adding a reaction is exactly one more row here - nothing else changes.
constexpr ReactionDefinition REACTION_TABLE[] = {
    // reactant_a         reactant_b         result_a            result_b             probability
    { MaterialType::WATER, MaterialType::DIRT, MaterialType::AIR, MaterialType::MUD,  1.0f },
    // Lava cools/solidifies into STONE on contact with WATER; the water
    // itself is consumed (no STEAM material exists yet - see MATERIALS.md
    // "Future Extensions"). See MATERIALS.md "Reactions".
    { MaterialType::WATER, MaterialType::LAVA, MaterialType::AIR, MaterialType::STONE, 1.0f },
};

constexpr int REACTION_COUNT = sizeof(REACTION_TABLE) / sizeof(REACTION_TABLE[0]);

} // namespace

bool find_reaction(MaterialType mat1, MaterialType mat2,
                    MaterialType &out_result1, MaterialType &out_result2,
                    float &out_probability) {
    for (int i = 0; i < REACTION_COUNT; ++i) {
        const ReactionDefinition &def = REACTION_TABLE[i];
        if (def.reactant_a == mat1 && def.reactant_b == mat2) {
            out_result1 = def.result_a;
            out_result2 = def.result_b;
            out_probability = def.probability;
            return true;
        }
        if (def.reactant_a == mat2 && def.reactant_b == mat1) {
            // Swapped order: cross the results back to the caller's order.
            out_result1 = def.result_b;
            out_result2 = def.result_a;
            out_probability = def.probability;
            return true;
        }
    }
    return false;
}

bool material_is_reaction_capable(MaterialType mat) {
    // Derived directly from REACTION_TABLE rather than a separate
    // MaterialDef flag, so this can never drift out of sync with the actual
    // reaction data - see MATERIALS.md "Reactions".
    for (int i = 0; i < REACTION_COUNT; ++i) {
        const ReactionDefinition &def = REACTION_TABLE[i];
        if (def.reactant_a == mat || def.reactant_b == mat) {
            return true;
        }
    }
    return false;
}

} // namespace pixelsim
