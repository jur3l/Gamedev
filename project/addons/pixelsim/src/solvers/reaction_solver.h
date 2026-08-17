#pragma once
#include <cstdint>

namespace pixelsim {

class World;

// Pure, directly-testable probability check - see MATERIAL_REACTIONS.md
// "Reaction Execution". probability >= 1.0 always returns true WITHOUT
// requiring a meaningful rand_value (callers should skip drawing from the
// RNG entirely for guaranteed reactions - see try_react()). probability <=
// 0.0 always returns false. In between, rand_value is expected to come from
// World::rand_u32() - never a new RNG.
bool roll_reaction_probability(uint32_t rand_value, float probability);

// Checks the cell at (x, y) against its 4 orthogonal neighbors for a
// matching reaction (see core/reaction.h), executes at most one reaction
// (first matching, probability-passing neighbor, in a fixed order), and
// returns true if one fired. See MATERIAL_REACTIONS.md "Reaction Execution"
// / "Infinite-Loop / Same-Pass Protection".
bool try_react(World &world, int x, int y);

} // namespace pixelsim
