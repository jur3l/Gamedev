#[compute]
#version 450

// GPU Sand/Powder solver - Phase 2A feasibility PoC (GPU_SIMULATION.md).
// EXPERIMENTAL. Not the production simulation - see GPU_SIMULATION.md and
// PROJECT_ARCHITECTURE.md for what "experimental" means here: the CPU
// World::step()/solve_powder() (addons/pixelsim/src/solvers/solvers.cpp)
// remains the reference/production implementation, completely untouched by
// this file.
//
// ARCHITECTURE: ping-pong (double-buffered) parallel cellular automaton.
// Every invocation reads ONLY the previous step's buffer (immutable during
// this dispatch) and writes ONLY its own cell in the next buffer - no
// shared mutable state, no write races, no atomics needed. This is a
// deliberately different execution model from the CPU's sequential
// bottom-to-top row scan (World::step()), which lets a whole contiguous
// stack of SAND cascade multiple rows in a single pass because later-
// scanned cells observe earlier-scanned cells' already-updated state within
// the same pass. The GPU model here cannot do that (every thread sees the
// SAME previous-state snapshot) - a stack instead moves at most one cell
// per dispatch, taking more steps to fully settle. This is a real,
// documented CPU/GPU behavioral difference, not a bug - see
// GPU_SIMULATION.md "Sand Solver" / "Correctness" for the validation
// methodology this implies (mass-conservation and final-settled-state
// equivalence, not bit-identical per-step traces, except in the
// no-contention single-cell case where the two models agree exactly).
//
// CONFLICT RESOLUTION ("pull" model): rather than a SOURCE cell deciding
// where to push its material (which risks two sources racing for the same
// destination), every cell independently computes its OWN next value by
// asking "would I receive material from a neighbor" (if currently AIR) or
// "do I successfully move away" (if currently SAND) - both questions are
// answered by re-deriving each candidate neighbor's own movement decision
// from the read-only previous buffer. Since every invocation derives this
// identically and deterministically from the same snapshot, a source cell's
// self-assessment ("do I move") and a destination cell's assessment ("does
// this source move into me") always agree - no synchronization required.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer InBuf {
    uint cells[];
}
input_buf;

layout(set = 0, binding = 1, std430) restrict writeonly buffer OutBuf {
    uint cells[];
}
output_buf;

layout(push_constant, std430) uniform Params {
    uint width;
    uint height;
    uint step_index;
    uint seed;
}
params;

// Material IDs - deliberately NOT the full CPU MaterialType enum (GPU_SIMULATION.md
// "GPU State Representation"): this PoC's scope is SAND only (per the request),
// plus AIR and one static/inert material (STONE) for floors/walls in tests.
const uint MAT_AIR = 0u;
const uint MAT_SAND = 1u;
const uint MAT_STONE = 2u;

bool in_bounds(ivec2 p) {
    return p.x >= 0 && p.y >= 0 && p.x < int(params.width) && p.y < int(params.height);
}

// Matches World::get_material()'s out-of-bounds convention (PROJECT_ARCHITECTURE.md
// §4: "reads outside world bounds return AIR"). Used only for the READ side of a
// movement decision - see sand_target()/resolve_winner_for() for how the world-edge
// WRITE rejection (World::swap_cells() rejects out-of-bounds targets, effectively
// making the edge a floor/wall) is separately enforced via an explicit in_bounds()
// gate on the chosen target, not folded into this function.
uint read_cell(ivec2 p) {
    if (!in_bounds(p)) return MAT_AIR;
    return input_buf.cells[p.y * int(params.width) + p.x];
}

// Deterministic hash-based tie-break - NOT bit-identical to the CPU's shared
// xorshift32 stream (World::rand_u32(), inherently sequential/scan-order-
// dependent - see PROJECT_ARCHITECTURE.md §4 "Randomization"). A parallel
// GPU dispatch has no well-defined "draw order" to replicate; instead this
// is a pure function of (cell, step, seed), which is what determinism means
// here - see GPU_SIMULATION.md "Randomness" for why this is a deliberate,
// documented deviation, not an oversight.
uint hash_u32(uint x) {
    x ^= x >> 16u;
    x *= 0x7feb352du;
    x ^= x >> 15u;
    x *= 0x846ca68bu;
    x ^= x >> 16u;
    return x;
}

bool left_first_for(ivec2 p, uint step_index, uint seed) {
    uint h = hash_u32(uint(p.x) * 374761393u + uint(p.y) * 668265263u + step_index * 2246822519u + seed);
    return (h & 1u) == 0u;
}

// Mirrors solve_powder() (solvers.cpp): try straight down; else one
// randomized diagonal, then the other. Returns the target cell for `s`, or
// `s` itself if blocked. Reads only the previous buffer.
ivec2 sand_target(ivec2 s, uint step_index, uint seed) {
    ivec2 down = s + ivec2(0, 1);
    if (in_bounds(down) && read_cell(down) == MAT_AIR) {
        return down;
    }

    bool left_first = left_first_for(s, step_index, seed);
    ivec2 d1 = s + (left_first ? ivec2(-1, 1) : ivec2(1, 1));
    ivec2 d2 = s + (left_first ? ivec2(1, 1) : ivec2(-1, 1));
    if (in_bounds(d1) && read_cell(d1) == MAT_AIR) {
        return d1;
    }
    if (in_bounds(d2) && read_cell(d2) == MAT_AIR) {
        return d2;
    }
    return s;
}

// For a candidate destination `dest`, determines which single SAND neighbor
// (if any) "wins" the right to move into it this step. A straight-down
// source always wins outright when present (it never contests with a
// diagonal source, exactly as solve_powder never lets a diagonal attempt
// preempt a valid straight fall). If both diagonal sources contest the same
// destination, a second, independent hash breaks the tie. Returns (-1,-1)
// if no source wants `dest`.
ivec2 resolve_winner_for(ivec2 dest, uint step_index, uint seed) {
    ivec2 up = dest + ivec2(0, -1);
    if (in_bounds(up) && read_cell(up) == MAT_SAND) {
        if (sand_target(up, step_index, seed) == dest) {
            return up;
        }
    }

    ivec2 upL = dest + ivec2(-1, -1);
    ivec2 upR = dest + ivec2(1, -1);
    bool left_wants = in_bounds(upL) && read_cell(upL) == MAT_SAND && sand_target(upL, step_index, seed) == dest;
    bool right_wants = in_bounds(upR) && read_cell(upR) == MAT_SAND && sand_target(upR, step_index, seed) == dest;

    if (left_wants && right_wants) {
        uint h = hash_u32(uint(dest.x) * 374761393u + uint(dest.y) * 668265263u + step_index * 2246822519u + seed + 12345u);
        return (h & 1u) == 0u ? upL : upR;
    }
    if (left_wants) {
        return upL;
    }
    if (right_wants) {
        return upR;
    }
    return ivec2(-1, -1);
}

void main() {
    ivec2 p = ivec2(gl_GlobalInvocationID.xy);
    if (!in_bounds(p)) {
        return;
    }

    uint current = read_cell(p);
    uint next_val = current;

    if (current == MAT_SAND) {
        ivec2 target = sand_target(p, params.step_index, params.seed);
        if (target != p) {
            ivec2 winner = resolve_winner_for(target, params.step_index, params.seed);
            next_val = (winner == p) ? MAT_AIR : MAT_SAND;
        }
    } else if (current == MAT_AIR) {
        ivec2 winner = resolve_winner_for(p, params.step_index, params.seed);
        if (winner.x >= 0) {
            next_val = MAT_SAND;
        }
    }
    // MAT_STONE (or anything else): unchanged - static, mirrors CPU
    // MovementBehavior::NONE/STATIC being skipped entirely in World::step().

    output_buf.cells[p.y * int(params.width) + p.x] = next_val;
}
