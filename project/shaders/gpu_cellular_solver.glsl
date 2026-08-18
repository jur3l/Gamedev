#[compute]
#version 450

// GPU cellular automaton solver - Phase 2A (SAND) + Phase 2B (WATER) PoC
// (GPU_SIMULATION.md). EXPERIMENTAL. Not the production simulation - the CPU
// World::step()/solve_powder()/solve_liquid() (addons/pixelsim/src/solvers/
// solvers.cpp) remains the reference/production implementation, completely
// untouched by this file.
//
// Renamed from gpu_sand_solver.glsl (Phase 2A) to gpu_cellular_solver.glsl
// for Phase 2B: this is the SAME infrastructure extended with WATER/LIQUID
// behavior, not a second parallel solver - per the Phase 2B request's
// explicit instruction to reuse, not duplicate, the GPU simulation
// architecture. One shader, one ping-pong pipeline, one pull model,
// material-specific behavior dispatched per cell - mirrors
// World::step()'s own "solvers dispatch on behavior, never hardcode a
// specific MaterialType" convention (PROJECT_ARCHITECTURE.md §4).
//
// ARCHITECTURE: ping-pong (double-buffered) parallel cellular automaton,
// unchanged from Phase 2A - see the Phase 2A design note preserved below.
// Every invocation reads ONLY the previous step's buffer and writes ONLY
// its own cell in the next buffer - no shared mutable state, no write
// races, no atomics.
//
// CONFLICT RESOLUTION ("pull" model), extended for Phase 2B: a cell's next
// value is resolved in two independent, order-independent questions, both
// answered purely from the previous buffer:
//   1. "Does some neighbor successfully move INTO me this step?" -
//      resolve_winner_for(P) - checks P's up/upLeft/upRight neighbors
//      (straight-down/diagonal movers, POWDER or LIQUID) and, only for a
//      LIQUID, P's left/right same-row neighbors too (sideways spread).
//   2. "Do I successfully move AWAY this step?" - only asked if P itself is
//      POWDER/LIQUID: compute my own target via my own material's rule,
//      then check whether resolve_winner_for(target) picks ME.
// A cell's final next-value is: the winner's material if question 1 found
// one (an incoming mover always determines this cell's fate, regardless of
// whether this cell also tried to leave - see "Swap displacement" below for
// why this is still correct, not just a priority hack); otherwise, if
// question 2 succeeded, the TARGET cell's own previous material (this is
// what makes SAND-displaces-WATER a true swap, not just "vacate to AIR" -
// see below); otherwise, this cell is unchanged.
//
// SWAP DISPLACEMENT (new in Phase 2B): unlike Phase 2A's SAND-only solver,
// where a mover's only valid target was AIR (so "I moved away" always meant
// "I become AIR"), a POWDER mover can now displace into a less-dense LIQUID
// (material_can_displace()'s density rule - core/material.cpp). This is a
// genuine SWAP, not a vacate: the two cells trade materials. Because both
// cells' next-value computations read only the SAME previous-buffer
// snapshot, this resolves correctly and consistently without any special
// casing - a mover's "I successfully left" outcome is simply "my new value
// = whatever was previously at my target," which is AIR in the common case
// and the target's material in the swap case, uniformly.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer InBuf {
    uint cells[];
}
input_buf;

layout(set = 0, binding = 1, std430) restrict writeonly buffer OutBuf {
    uint cells[];
}
output_buf;

// Phase 2D (GPU_ACTIVE_REGION.md "GPU Data Structures") - accumulates the
// tight bounding box of every cell that actually changed across an entire
// dispatch BATCH (reset once per batch by the CPU, not once per tick - see
// GPUSandPoC.step()/step_region()). Purely additive: a full-world dispatch
// (rect_w == width, rect_h == height) still runs exactly Phase 2A/2B's
// movement logic, unmodified - this buffer only ever records where activity
// happened, it never influences what next_val a cell computes.
layout(set = 0, binding = 2, std430) restrict buffer BoundsBuf {
    uint min_x;
    uint min_y;
    uint max_x;
    uint max_y;
}
bounds_buf;

// Phase 2E (GPU_MATERIAL_INTERACTIONS.md "GPU Representation" / "Lookup
// Model") - dense MAX_MATERIALS x MAX_MATERIALS reaction rule table,
// indexed rules[a * MAX_MATERIALS + b]. Filled symmetrically by the CPU
// (GPUSandPoC.set_reaction_rule()) so a single direct read always gives the
// correct "what do I become" answer regardless of lookup order - no
// runtime ordering branch. result_a == a && result_b == b (identity) means
// "no reaction for this pair" - there is no separate has-rule flag.
struct ReactionRule {
    uint result_a;
    uint result_b;
    float probability;
    uint _reserved;
};
layout(set = 0, binding = 3, std430) restrict readonly buffer RuleBuf {
    ReactionRule rules[];
}
rule_buf;

layout(push_constant, std430) uniform Params {
    uint width;   // full world width - bounds-check reference, unchanged meaning
    uint height;  // full world height - unchanged meaning
    uint step_index;
    uint seed;
    // Phase 2D additions (GPU_ACTIVE_REGION.md "GPU Data Structures"): the
    // dispatched region's origin/size in cell space. A full-world dispatch
    // (GPUSandPoC.step(), Phase 2C compatibility) always sets
    // rect = (0, 0, width, height) - identical dispatch shape to before
    // these fields existed.
    uint rect_x;
    uint rect_y;
    uint rect_w;
    uint rect_h;
}
params;

// Material IDs - PoC scope only (GPU_SIMULATION.md "GPU State
// Representation"): AIR/STONE (Phase 2A statics), SAND (Phase 2A powder),
// WATER (Phase 2B liquid). No LAVA, no MUD - explicitly out of scope (see
// GPU_MATERIAL_INTERACTIONS.md "Future Lava").
const uint MAT_AIR = 0u;
const uint MAT_SAND = 1u;
const uint MAT_STONE = 2u;
const uint MAT_WATER = 3u;
// Phase 2E (GPU_MATERIAL_INTERACTIONS.md "Testing") - two materials that
// exist ONLY to validate the reaction architecture in isolation, never
// appearing in any Phase 2A/2B/2D test's initial state. Deliberately NOT a
// reuse of SAND/STONE/WATER, all three of which are already load-bearing
// fixtures (STONE especially, as the near-universal inert floor/wall) in
// the existing 55-test suite - see GPU_MATERIAL_INTERACTIONS.md "Testing"
// for why reusing them would repeat a mistake already made and fixed once
// on the CPU side (MATERIAL_REACTIONS.md "Current Reactions").
const uint MAT_REACT_TEST_A = 4u;
const uint MAT_REACT_TEST_B = 5u;
// Phase 2E (GPU_MATERIAL_INTERACTIONS.md "GPU Representation") - dense
// reaction-rule table dimension. A compile-time shader constant, not a
// runtime value - growing past it needs a shader recompile, same cost class
// as local_size_x/y.
const uint MAX_MATERIALS = 16u;

// Behavior + density, mirroring core/material.cpp's MATERIAL_TABLE for
// exactly the 4 materials this PoC knows about. Deliberately inlined as
// small functions rather than a general data-driven table - the CPU's
// data-driven MaterialDef table is the real source of truth; this is a
// minimal, documented duplication scoped to what Phase 2A/2B need, not a
// parallel material system (see GPU_SIMULATION.md "Known Limitations").
bool is_powder(uint mat) {
    return mat == MAT_SAND;
}
bool is_liquid(uint mat) {
    return mat == MAT_WATER;
}
bool is_movable(uint mat) {
    return is_powder(mat) || is_liquid(mat);
}
float density_of(uint mat) {
    if (mat == MAT_SAND) return 1.6;
    if (mat == MAT_WATER) return 1.0;
    if (mat == MAT_STONE) return 2.6;
    return 0.0; // AIR
}

// Mirrors material_can_displace() (core/material.cpp) exactly: AIR is
// always displaceable; a non-liquid mover can displace into a less-dense
// liquid (e.g. SAND sinking through WATER); nothing else is displaceable
// (solids block everything, liquid-into-liquid never displaces regardless
// of density).
bool can_displace(uint mover, uint target) {
    if (target == MAT_AIR) return true;
    if (is_liquid(target) && !is_liquid(mover) && density_of(mover) > density_of(target)) {
        return true;
    }
    return false;
}

bool in_bounds(ivec2 p) {
    return p.x >= 0 && p.y >= 0 && p.x < int(params.width) && p.y < int(params.height);
}

// Matches World::get_material()'s out-of-bounds convention (reads as AIR).
// The separate in_bounds() gate at every call site enforces the world-edge
// WRITE rejection (World::swap_cells() rejects out-of-bounds targets,
// making the edge act as a floor/wall) - see Phase 2A's design note.
uint read_cell(ivec2 p) {
    if (!in_bounds(p)) return MAT_AIR;
    return input_buf.cells[p.y * int(params.width) + p.x];
}

// Deterministic hash-based tie-break - not bit-identical to the CPU's
// shared xorshift32 stream, by design (GPU_SIMULATION.md "Randomness").
uint hash_u32(uint x) {
    x ^= x >> 16u;
    x *= 0x7feb352du;
    x ^= x >> 15u;
    x *= 0x846ca68bu;
    x ^= x >> 16u;
    return x;
}

bool left_first_for(ivec2 p, uint step_index, uint seed, uint salt) {
    uint h = hash_u32(uint(p.x) * 374761393u + uint(p.y) * 668265263u + step_index * 2246822519u + seed + salt);
    return (h & 1u) == 0u;
}

// Mirrors solve_powder(): try straight down, then one randomized diagonal,
// then the other - using the general can_displace() rule (so SAND sinking
// through WATER falls out of this unchanged, not a special case). No
// sideways spread (POWDER never spreads sideways, CPU or GPU).
ivec2 powder_target(ivec2 s, uint mover_mat, uint step_index, uint seed) {
    ivec2 down = s + ivec2(0, 1);
    if (in_bounds(down) && can_displace(mover_mat, read_cell(down))) return down;

    bool left_first = left_first_for(s, step_index, seed, 0u);
    ivec2 d1 = s + (left_first ? ivec2(-1, 1) : ivec2(1, 1));
    ivec2 d2 = s + (left_first ? ivec2(1, 1) : ivec2(-1, 1));
    if (in_bounds(d1) && can_displace(mover_mat, read_cell(d1))) return d1;
    if (in_bounds(d2) && can_displace(mover_mat, read_cell(d2))) return d2;
    return s;
}

// Mirrors solve_liquid(): try straight down, then diagonal (same
// randomized order as powder_target), then - new in Phase 2B - sideways
// one cell toward whichever side is open, same L/R order as the diagonal
// attempt (matches solve_liquid() reusing dx1/dx2 for both steps).
ivec2 liquid_target(ivec2 s, uint mover_mat, uint step_index, uint seed) {
    ivec2 down = s + ivec2(0, 1);
    if (in_bounds(down) && can_displace(mover_mat, read_cell(down))) return down;

    bool left_first = left_first_for(s, step_index, seed, 0u);
    ivec2 dx1 = s + (left_first ? ivec2(-1, 0) : ivec2(1, 0));
    ivec2 dx2 = s + (left_first ? ivec2(1, 0) : ivec2(-1, 0));
    ivec2 d1 = dx1 + ivec2(0, 1);
    ivec2 d2 = dx2 + ivec2(0, 1);

    if (in_bounds(d1) && can_displace(mover_mat, read_cell(d1))) return d1;
    if (in_bounds(d2) && can_displace(mover_mat, read_cell(d2))) return d2;

    // Can't fall - spread sideways toward whichever side is open.
    if (in_bounds(dx1) && can_displace(mover_mat, read_cell(dx1))) return dx1;
    if (in_bounds(dx2) && can_displace(mover_mat, read_cell(dx2))) return dx2;
    return s;
}

ivec2 compute_target(ivec2 s, uint mover_mat, uint step_index, uint seed) {
    if (is_powder(mover_mat)) return powder_target(s, mover_mat, step_index, seed);
    if (is_liquid(mover_mat)) return liquid_target(s, mover_mat, step_index, seed);
    return s; // not movable
}

// For a candidate destination `dest`, determines which single neighbor (if
// any) "wins" the right to move into it this step - generalized from Phase
// 2A to (a) use can_displace() instead of a plain AIR check, so a denser
// POWDER can win against a LIQUID-occupied dest too, and (b) also consider
// same-row left/right neighbors, since a LIQUID may reach `dest` via
// sideways spread, not just falling.
//
// Priority: a straight-down source always wins outright when present
// (mirrors the CPU solvers always taking a valid straight fall before ever
// attempting a diagonal/sideways move - a straight-down mover's own
// decision is never in doubt, so it never needs to contend). Among the
// remaining diagonal/sideways candidates, if more than one legitimately
// targets `dest`, a second deterministic hash breaks the tie.
//
// "Shallow" = does NOT check whether a candidate is itself simultaneously
// being displaced by someone else this step - see resolve_winner_for()
// below for why that matters and is checked there, one level up, instead
// of here (this function must NOT call itself: SPIR-V/GPU compute shaders
// do not support recursion, so the "am I myself being displaced" check is
// implemented as exactly one extra, bounded level via a second function,
// not literal recursion).
ivec2 resolve_winner_shallow(ivec2 dest, uint step_index, uint seed) {
    uint dest_mat = read_cell(dest);

    ivec2 up = dest + ivec2(0, -1);
    if (in_bounds(up)) {
        uint m = read_cell(up);
        if (is_movable(m) && can_displace(m, dest_mat) && compute_target(up, m, step_index, seed) == dest) {
            return up;
        }
    }

    ivec2 candidates[4] = ivec2[4](
        dest + ivec2(-1, -1), // upLeft
        dest + ivec2(1, -1), // upRight
        dest + ivec2(-1, 0), // left (liquid sideways only)
        dest + ivec2(1, 0) // right (liquid sideways only)
    );
    bool wants[4];
    int want_count = 0;
    for (int i = 0; i < 4; i++) {
        wants[i] = false;
        ivec2 c = candidates[i];
        if (!in_bounds(c)) continue;
        uint m = read_cell(c);
        if (!is_movable(m)) continue;
        if (!can_displace(m, dest_mat)) continue;
        if (compute_target(c, m, step_index, seed) == dest) {
            wants[i] = true;
            want_count++;
        }
    }
    if (want_count == 0) return ivec2(-1, -1);
    if (want_count == 1) {
        for (int i = 0; i < 4; i++) {
            if (wants[i]) return candidates[i];
        }
    }
    // Multiple legitimate contenders - deterministic tie-break among them.
    uint h = hash_u32(uint(dest.x) * 374761393u + uint(dest.y) * 668265263u + step_index * 2246822519u + seed + 98765u);
    uint pick = h % uint(want_count);
    uint seen = 0u;
    for (int i = 0; i < 4; i++) {
        if (wants[i]) {
            if (seen == pick) return candidates[i];
            seen++;
        }
    }
    return ivec2(-1, -1); // unreachable
}

// The real, displacement-aware winner resolution used everywhere else in
// this shader. New in Phase 2B: a candidate source is only eligible to move
// INTO `dest` if that candidate is not itself simultaneously the target of
// some OTHER, higher-priority incoming move this same step.
//
// Why this matters (found via a live mass-conservation test, not assumed -
// see GPU_SIMULATION.md "Phase 2B" "Correctness"): consider SAND directly
// above WATER, which is directly above open AIR. Per resolve_winner_shallow
// alone, BOTH of the following are independently "true" reading only the
// previous buffer: (a) the WATER cell is a legitimate winner for the AIR
// cell below it (water's own down-check succeeds, since AIR is open); (b)
// the SAND cell is a legitimate winner for the WATER cell (density
// displacement). If both are allowed to resolve independently, the WATER
// cell's material gets duplicated - it "moves" to the AIR cell below AND
// "backfills" the SAND cell's old position as part of the SAND/WATER swap,
// producing two water cells from one. Requiring a candidate to have no
// shallow incoming winner of its own before its OUTGOING move is honored
// closes this gap: the WATER cell, being displaced by SAND, is no longer
// eligible to independently claim the AIR cell below it - it simply gets
// overwritten by SAND, exactly one hop, matching the general "a chain moves
// at most one hop per dispatch" rule already documented for Phase 2A.
ivec2 resolve_winner_for(ivec2 dest, uint step_index, uint seed) {
    uint dest_mat = read_cell(dest);

    ivec2 up = dest + ivec2(0, -1);
    if (in_bounds(up)) {
        uint m = read_cell(up);
        if (is_movable(m) && can_displace(m, dest_mat) && compute_target(up, m, step_index, seed) == dest) {
            if (resolve_winner_shallow(up, step_index, seed).x < 0) {
                return up;
            }
        }
    }

    ivec2 candidates[4] = ivec2[4](
        dest + ivec2(-1, -1),
        dest + ivec2(1, -1),
        dest + ivec2(-1, 0),
        dest + ivec2(1, 0)
    );
    bool wants[4];
    int want_count = 0;
    for (int i = 0; i < 4; i++) {
        wants[i] = false;
        ivec2 c = candidates[i];
        if (!in_bounds(c)) continue;
        uint m = read_cell(c);
        if (!is_movable(m)) continue;
        if (!can_displace(m, dest_mat)) continue;
        if (compute_target(c, m, step_index, seed) != dest) continue;
        if (resolve_winner_shallow(c, step_index, seed).x >= 0) continue; // c is itself being displaced - not eligible
        wants[i] = true;
        want_count++;
    }
    if (want_count == 0) return ivec2(-1, -1);
    if (want_count == 1) {
        for (int i = 0; i < 4; i++) {
            if (wants[i]) return candidates[i];
        }
    }
    uint h = hash_u32(uint(dest.x) * 374761393u + uint(dest.y) * 668265263u + step_index * 2246822519u + seed + 98765u);
    uint pick = h % uint(want_count);
    uint seen = 0u;
    for (int i = 0; i < 4; i++) {
        if (wants[i]) {
            if (seen == pick) return candidates[i];
            seen++;
        }
    }
    return ivec2(-1, -1); // unreachable
}

// Phase 2E (GPU_MATERIAL_INTERACTIONS.md "Reaction Resolution") - checks
// p's 4 orthogonal neighbors, in a fixed priority order (up, down, left,
// right - matches the CPU reference's own order, MATERIAL_REACTIONS.md), for
// the first one with a non-identity rule against mat. Pure function of the
// previous buffer only - does NOT itself check mutual agreement (that's one
// level up, in try_mutual_reaction() - GPU compute shaders don't support
// recursion, so this stays a single, bounded, non-recursive helper, exactly
// mirroring resolve_winner_shallow()'s role for movement).
ivec2 shallow_reaction_partner(ivec2 p, uint mat) {
    ivec2 offsets[4] = ivec2[4](ivec2(0, -1), ivec2(0, 1), ivec2(-1, 0), ivec2(1, 0));
    for (int i = 0; i < 4; i++) {
        ivec2 n = p + offsets[i];
        if (!in_bounds(n)) continue;
        uint nm = read_cell(n);
        ReactionRule rule = rule_buf.rules[mat * MAX_MATERIALS + nm];
        if (rule.result_a != mat || rule.result_b != nm) {
            return n;
        }
    }
    return ivec2(-1, -1);
}

// Phase 2E: p reacts with a neighbor q this tick IFF q is p's own first
// choice (shallow_reaction_partner(p)) AND p is ALSO q's own first choice
// (shallow_reaction_partner(q) == p) - mutual agreement, computed
// independently by both cells' threads from the same read-only snapshot,
// no cross-thread communication. This is what prevents the class of
// mass-duplication bug Phase 2B found in movement (GPU_MATERIAL_
// INTERACTIONS.md "Reaction Resolution"). Returns true and writes
// out_next_val if a reaction fires this tick; false (out_next_val
// untouched) if p's first choice doesn't reciprocate, or the probability
// roll fails - in either case p falls through to normal movement/
// interaction evaluation, unchanged.
bool try_mutual_reaction(ivec2 p, uint mat, uint step_index, uint seed, out uint out_next_val) {
    ivec2 q = shallow_reaction_partner(p, mat);
    if (q.x < 0) return false;
    uint mat_q = read_cell(q);
    if (shallow_reaction_partner(q, mat_q) != p) return false;

    ReactionRule rule = rule_buf.rules[mat * MAX_MATERIALS + mat_q];
    if (rule.probability < 1.0) {
        // Guaranteed rules (probability >= 1.0) skip this draw entirely -
        // same "don't perturb the shared deterministic stream for a
        // guaranteed outcome" optimization the CPU reference uses
        // (MATERIAL_REACTIONS.md "Determinism") - no second RNG, reuses
        // the same hash_u32() every other GPU tie-break already uses.
        uint h = hash_u32(uint(p.x) * 374761393u + uint(p.y) * 668265263u + step_index * 2246822519u + seed + 555555u);
        float roll = float(h % 1000000u) / 1000000.0;
        if (roll >= rule.probability) return false;
    }
    out_next_val = rule.result_a;
    return true;
}

void main() {
    // Phase 2D: dispatched threads cover [rect_x, rect_x+rect_w) x
    // [rect_y, rect_y+rect_h), not necessarily the whole world - offset by
    // the rect origin to get the real world position. For a full-world
    // dispatch (rect_x=rect_y=0), this is identical to Phase 2A/2B's
    // ivec2(gl_GlobalInvocationID.xy).
    ivec2 p = ivec2(int(params.rect_x), int(params.rect_y)) + ivec2(gl_GlobalInvocationID.xy);
    if (!in_bounds(p)) {
        return;
    }

    uint current = read_cell(p);
    uint next_val = current;

    // Phase 2E: reaction is checked FIRST and, if it fires, movement/
    // interaction is skipped entirely for this cell this tick - mutually
    // exclusive, same rule the CPU reference uses (MATERIAL_REACTIONS.md
    // "Simulation Integration"). The movement/interaction branch below is
    // completely unmodified from Phase 2A/2B.
    uint reacted_val;
    bool reacted = try_mutual_reaction(p, current, params.step_index, params.seed, reacted_val);
    if (reacted) {
        next_val = reacted_val;
    } else {
        ivec2 winner = resolve_winner_for(p, params.step_index, params.seed);
        if (winner.x >= 0) {
            // Something displaces into me this step - my fate is decided
            // regardless of whether I also tried to move away (see the file
            // header's "Swap displacement" note for why this is correct).
            next_val = read_cell(winner);
        } else if (is_movable(current)) {
            ivec2 target = compute_target(p, current, params.step_index, params.seed);
            if (target != p) {
                ivec2 target_winner = resolve_winner_for(target, params.step_index, params.seed);
                if (target_winner == p) {
                    next_val = read_cell(target); // AIR in the common case, the displaced material in a swap
                }
                // else: I tried to move but lost the contention - stay put (next_val already == current).
            }
            // else: blocked, stays put.
        }
        // STATIC (STONE) or AIR-with-no-winner: unchanged.
    }

    output_buf.cells[p.y * int(params.width) + p.x] = next_val;

    // Phase 2D: record this cell in the batch's activity bounding box if its
    // material actually changed - purely observational, never read by
    // anything above that affects next_val.
    if (next_val != current) {
        atomicMin(bounds_buf.min_x, uint(p.x));
        atomicMin(bounds_buf.min_y, uint(p.y));
        atomicMax(bounds_buf.max_x, uint(p.x));
        atomicMax(bounds_buf.max_y, uint(p.y));
    }
}
