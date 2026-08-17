#pragma once
#include "material.h"

namespace pixelsim {

// Static, per-material-pair reaction data - see MATERIAL_REACTIONS.md
// "Reaction Model". Deliberately separate from MaterialDef (mirrors how
// background.h is a separate, smaller table from material.h): a reaction is
// data about a PAIR of materials, not a property of one material.
struct ReactionDefinition {
    MaterialType reactant_a;
    MaterialType reactant_b;
    MaterialType result_a; // what the cell holding reactant_a becomes
    MaterialType result_b; // what the cell holding reactant_b becomes
    float probability;     // 1.0 = guaranteed, 0.5 = 50% per attempt, ...
};

// Looks up a reaction between mat1 and mat2, checked in BOTH orderings (a
// reaction is authored once and matches A+B and B+A alike - see
// MATERIAL_REACTIONS.md "Reaction Matching"). On a match, out_result1/
// out_result2 are filled with what mat1/mat2 respectively become (always
// mapped back to the caller's argument order, never the table's internal
// a/b order) and out_probability with the reaction's configured chance.
// Returns false (outputs untouched) if no reaction pairs mat1 with mat2.
bool find_reaction(MaterialType mat1, MaterialType mat2,
                    MaterialType &out_result1, MaterialType &out_result2,
                    float &out_probability);

// True if `mat` appears as a reactant in any REACTION_TABLE row (either
// side). Purely derived from the table - not a separate per-material flag -
// so it can't disagree with what find_reaction() actually matches. Used for
// documentation/tooling (see MATERIALS.md's material table) and tests.
bool material_is_reaction_capable(MaterialType mat);

} // namespace pixelsim
