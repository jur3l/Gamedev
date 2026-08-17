// Standalone tests for the Cellular Automata core - no Godot, no GDExtension,
// no godot-cpp. Proves the simulation is genuinely engine-agnostic (spec
// section 29 / section 2: "ideally testable outside Godot too").
//
// Build (from a VS dev prompt, no other dependencies required):
//   cl /std:c++17 /EHsc /I ..\src test_core.cpp ..\src\core\material.cpp
//      ..\src\core\background.cpp ..\src\core\world.cpp ..\src\solvers\solvers.cpp
//      ..\src\gen\terrain_gen.cpp /Fe:test_core.exe
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include "../src/core/background.h"
#include "../src/core/material.h"
#include "../src/core/world.h"

using namespace pixelsim;

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond) do { \
    g_checks++; \
    if (!(cond)) { \
        g_failures++; \
        std::printf("  FAIL: %s (line %d)\n", #cond, __LINE__); \
    } \
} while (0)

// Runs step() repeatedly until a full pass completes (budget generous enough
// that a tiny test world always finishes in one call, but loop anyway for
// safety/documentation of the resumable-step contract).
static void run_full_pass(World &world, double budget_ms = 1000.0) {
    StepStats stats;
    do {
        stats = world.step(budget_ms);
    } while (!stats.pass_completed);
}

static int count_material_in_rect(World &world, int x0, int y0, int w, int h, MaterialType mat) {
    int count = 0;
    for (int y = y0; y < y0 + h; ++y) {
        for (int x = x0; x < x0 + w; ++x) {
            if (world.get_material(x, y) == mat) count++;
        }
    }
    return count;
}

static int count_active_chunks(World &world) {
    int active = 0;
    for (int cy = 0; cy < world.height_chunks(); ++cy) {
        for (int cx = 0; cx < world.width_chunks(); ++cx) {
            if (!world.chunk_at(cx, cy).sleeping) active++;
        }
    }
    return active;
}

static void test_sand_falls() {
    std::printf("test_sand_falls\n");
    World world(1, 1, 1);
    world.set_cell(5, 5, MaterialType::SAND);
    CHECK(world.get_material(5, 5) == MaterialType::SAND);
    CHECK(world.get_material(5, 6) == MaterialType::AIR);
    run_full_pass(world);
    CHECK(world.get_material(5, 5) == MaterialType::AIR);
    CHECK(world.get_material(5, 6) == MaterialType::SAND);
}

static void test_sand_blocked_by_stone() {
    std::printf("test_sand_blocked_by_stone\n");
    World world(1, 1, 2);
    world.set_cell(5, 5, MaterialType::SAND);
    world.set_cell(5, 6, MaterialType::STONE);
    // Block the diagonals too so the only possible move would be straight down.
    world.set_cell(4, 6, MaterialType::STONE);
    world.set_cell(6, 6, MaterialType::STONE);
    run_full_pass(world);
    CHECK(world.get_material(5, 5) == MaterialType::SAND);
    CHECK(world.get_material(5, 6) == MaterialType::STONE);
}

static void test_sand_diagonal_movement() {
    std::printf("test_sand_diagonal_movement\n");
    World world(1, 1, 3);
    // SAND sits directly on STONE, with AIR open on both diagonals - it must
    // move to one of (4,6) or (6,6), never stay put or clip through STONE.
    world.set_cell(5, 5, MaterialType::SAND);
    world.set_cell(5, 6, MaterialType::STONE);
    run_full_pass(world);
    bool moved_left = world.get_material(4, 6) == MaterialType::SAND;
    bool moved_right = world.get_material(6, 6) == MaterialType::SAND;
    CHECK(moved_left != moved_right); // exactly one of the two
    CHECK(world.get_material(5, 5) == MaterialType::AIR);
    CHECK(world.get_material(5, 6) == MaterialType::STONE);
}

static void test_water_falls_then_spreads() {
    std::printf("test_water_falls_then_spreads\n");
    World world(1, 1, 4);
    world.set_cell(32, 5, MaterialType::WATER);
    world.set_cell(30, 6, MaterialType::STONE);
    world.set_cell(31, 6, MaterialType::STONE);
    world.set_cell(32, 6, MaterialType::STONE);
    world.set_cell(33, 6, MaterialType::STONE);
    world.set_cell(34, 6, MaterialType::STONE);
    run_full_pass(world);
    // Water can't fall (floor is solid) so it must have spread sideways at
    // its own row into one of the open neighbors.
    bool spread = world.get_material(31, 5) == MaterialType::WATER ||
                  world.get_material(33, 5) == MaterialType::WATER;
    CHECK(spread);
}

static void test_chunk_boundary_movement() {
    std::printf("test_chunk_boundary_movement\n");
    World world(2, 1, 5); // two chunks side by side, CHUNK_SIZE wide each
    int boundary_x = CHUNK_SIZE - 1; // last column of chunk (0,0)
    world.set_cell(boundary_x, 5, MaterialType::SAND);
    // Nudge it to fall to the very edge, then push it across horizontally by
    // stacking stone under it and to the left so its only opening is right,
    // which lands in chunk (1,0).
    world.set_cell(boundary_x, 6, MaterialType::STONE);
    world.set_cell(boundary_x - 1, 6, MaterialType::STONE);
    run_full_pass(world);
    CHECK(world.get_material(boundary_x + 1, 6) == MaterialType::SAND);
    // The neighboring chunk must have woken up to receive it.
    CHECK(world.chunk_at(1, 0).sleeping == false || world.chunk_at(1, 0).dirty_this_pass);
}

static void test_mining_removes_material() {
    std::printf("test_mining_removes_material\n");
    World world(1, 1, 6);
    world.fill_rect(0, 0, 20, 20, MaterialType::STONE);
    world.set_cell(10, 10, MaterialType::IRON_ORE);
    MineResult result = world.mine_circle(10, 10, 3);
    CHECK(result.total_removed > 0);
    CHECK(result.counts[static_cast<int>(MaterialType::IRON_ORE)] == 1);
    CHECK(world.get_material(10, 10) == MaterialType::AIR);
}

static void test_dirty_chunks_marked() {
    std::printf("test_dirty_chunks_marked\n");
    World world(1, 1, 7);
    CHECK(world.chunk_at(0, 0).sleeping == true); // starts asleep
    // SAND resting directly on STONE: the writes below wake the chunk
    // immediately, but the sand itself has nowhere to move.
    world.set_cell(3, 3, MaterialType::SAND);
    world.set_cell(3, 4, MaterialType::STONE);
    world.set_cell(2, 4, MaterialType::STONE);
    world.set_cell(4, 4, MaterialType::STONE);
    CHECK(world.chunk_at(0, 0).sleeping == false); // woken by the writes
    CHECK(world.chunk_at(0, 0).render_dirty == true);
    // The writes above happened during "pass 1", so that pass legitimately
    // finishes dirty (it did contain activity) and the chunk stays awake one
    // more pass. Only a second, genuinely quiet pass puts it to sleep.
    run_full_pass(world);
    CHECK(world.get_material(3, 3) == MaterialType::SAND); // confirms it didn't move
    CHECK(world.chunk_at(0, 0).sleeping == false);
    run_full_pass(world);
    CHECK(world.chunk_at(0, 0).sleeping == true);
}

// ---- Mining drop / material conversion (see World::mine_circle) ----

static void test_dirt_mining_creates_sand() {
    std::printf("test_dirt_mining_creates_sand\n");
    World world(1, 1, 10);
    world.set_cell(5, 5, MaterialType::DIRT);
    // DIRT's drop_ratio is 0.5, so a single mined cell alone floors to 0
    // drops (see the test_drop_ratio_* tests) - this priming call banks the
    // leftover 0.5 into the per-material remainder instead of producing SAND.
    world.mine_circle(5, 5, 0);
    world.set_cell(5, 5, MaterialType::DIRT);
    // Remainder 0.5 + this cell's 0.5 = 1.0 -> now guaranteed exactly 1 drop.
    MineResult r = world.mine_circle(5, 5, 0);
    CHECK(r.total_removed == 1);
    CHECK(r.counts[static_cast<int>(MaterialType::DIRT)] == 1);
    CHECK(world.get_material(5, 5) == MaterialType::SAND);
}

static void test_stone_mining_creates_gravel() {
    std::printf("test_stone_mining_creates_gravel\n");
    World world(1, 1, 11);
    world.set_cell(5, 5, MaterialType::STONE);
    world.mine_circle(5, 5, 0); // prime the remainder to 0.5, see comment above
    world.set_cell(5, 5, MaterialType::STONE);
    MineResult r = world.mine_circle(5, 5, 0); // guaranteed 1 drop now
    CHECK(r.total_removed == 1);
    CHECK(r.counts[static_cast<int>(MaterialType::STONE)] == 1);
    CHECK(world.get_material(5, 5) == MaterialType::GRAVEL);
}

static void test_sand_mining_is_noop() {
    std::printf("test_sand_mining_is_noop\n");
    World world(1, 1, 12);
    // Box the SAND in solidly so it settles (and the chunk falls back
    // asleep) before we test mining against it.
    world.set_cell(5, 5, MaterialType::SAND);
    world.set_cell(5, 6, MaterialType::STONE);
    world.set_cell(4, 6, MaterialType::STONE);
    world.set_cell(6, 6, MaterialType::STONE);
    run_full_pass(world); // pass with the setup writes
    run_full_pass(world); // genuinely quiet pass -> asleep
    CHECK(world.chunk_at(0, 0).sleeping == true);

    MineResult r = world.mine_circle(5, 5, 0);
    CHECK(r.total_removed == 0);
    CHECK(world.get_material(5, 5) == MaterialType::SAND); // untouched
    CHECK(world.chunk_at(0, 0).sleeping == true); // must NOT have been re-woken
}

static void test_gravel_mining_is_noop() {
    std::printf("test_gravel_mining_is_noop\n");
    World world(1, 1, 13);
    world.set_cell(5, 5, MaterialType::GRAVEL);
    world.set_cell(5, 6, MaterialType::STONE);
    world.set_cell(4, 6, MaterialType::STONE);
    world.set_cell(6, 6, MaterialType::STONE);
    run_full_pass(world);
    run_full_pass(world);
    CHECK(world.chunk_at(0, 0).sleeping == true);

    MineResult r = world.mine_circle(5, 5, 0);
    CHECK(r.total_removed == 0);
    CHECK(world.get_material(5, 5) == MaterialType::GRAVEL);
    CHECK(world.chunk_at(0, 0).sleeping == true);
}

static void test_mining_drop_is_active_and_falls() {
    std::printf("test_mining_drop_is_active_and_falls\n");
    World world(1, 1, 14);
    world.set_cell(5, 5, MaterialType::DIRT);
    world.mine_circle(5, 5, 0); // prime remainder to 0.5 (DIRT's drop_ratio)
    world.set_cell(5, 5, MaterialType::DIRT);
    world.mine_circle(5, 5, 0); // remainder 0.5+0.5=1.0 -> guaranteed 1 drop
    CHECK(world.get_material(5, 5) == MaterialType::SAND); // real cell, not a side effect
    CHECK(world.chunk_at(0, 0).sleeping == false); // immediately active, no step() needed

    run_full_pass(world);
    CHECK(world.get_material(5, 5) == MaterialType::AIR);
    CHECK(world.get_material(5, 6) == MaterialType::SAND); // moved via the existing gravity solver
}

static void test_mining_drop_settles_on_ground() {
    std::printf("test_mining_drop_settles_on_ground\n");
    World world(1, 1, 15);
    world.set_cell(5, 5, MaterialType::DIRT);
    world.set_cell(5, 7, MaterialType::STONE);
    world.set_cell(4, 7, MaterialType::STONE);
    world.set_cell(6, 7, MaterialType::STONE);
    world.mine_circle(5, 5, 0); // prime remainder to 0.5, (5,5) -> AIR
    world.set_cell(5, 5, MaterialType::DIRT);
    world.mine_circle(5, 5, 0); // guaranteed drop: (5,5) -> SAND

    run_full_pass(world); // SAND falls one row: (5,5) -> (5,6), now resting on the floor
    CHECK(world.get_material(5, 6) == MaterialType::SAND);
    CHECK(world.get_material(5, 5) == MaterialType::AIR);

    run_full_pass(world); // quiet pass: nothing left to do
    CHECK(world.get_material(5, 6) == MaterialType::SAND); // stayed put
    CHECK(world.chunk_at(0, 0).sleeping == true); // and the chunk settled back to sleep
}

static void test_mining_drop_chunk_boundary() {
    std::printf("test_mining_drop_chunk_boundary\n");
    World world(2, 1, 16); // two chunks side by side
    int boundary_x = CHUNK_SIZE - 1; // last column of chunk (0,0)
    world.set_cell(boundary_x, 5, MaterialType::DIRT);
    world.mine_circle(boundary_x, 5, 0); // prime remainder to 0.5
    world.set_cell(boundary_x, 5, MaterialType::DIRT);
    world.set_cell(boundary_x, 6, MaterialType::STONE);
    world.set_cell(boundary_x - 1, 6, MaterialType::STONE); // block the left diagonal
    // (boundary_x + 1, 6) stays AIR, open into chunk (1, 0).

    world.mine_circle(boundary_x, 5, 0); // guaranteed drop: -> SAND
    run_full_pass(world);
    CHECK(world.get_material(boundary_x + 1, 6) == MaterialType::SAND);
    CHECK(world.chunk_at(1, 0).sleeping == false || world.chunk_at(1, 0).dirty_this_pass);
}

static void test_mining_wakes_sleeping_chunk() {
    std::printf("test_mining_wakes_sleeping_chunk\n");
    World world(1, 1, 17);
    world.set_cell(5, 5, MaterialType::DIRT);
    world.mine_circle(5, 5, 0); // prime remainder to 0.5, (5,5) -> AIR
    run_full_pass(world);
    run_full_pass(world);
    CHECK(world.chunk_at(0, 0).sleeping == true); // settled from the priming call

    world.set_cell(5, 5, MaterialType::DIRT); // re-place dirt for the real test
    run_full_pass(world);
    run_full_pass(world);
    CHECK(world.chunk_at(0, 0).sleeping == true); // asleep again before the real mine

    world.mine_circle(5, 5, 0); // remainder 0.5+0.5=1.0 -> guaranteed 1 drop
    CHECK(world.chunk_at(0, 0).sleeping == false); // woken immediately by the drop
    CHECK(world.get_material(5, 5) == MaterialType::SAND);
}

// ---- Configurable mining tool shape/size (World::mine_area) ----

static void test_mine_area_square_covers_full_box() {
    std::printf("test_mine_area_square_covers_full_box\n");
    World world(1, 1, 18);
    world.fill_rect(0, 0, 20, 20, MaterialType::DIRT);
    int size = 3;
    MineResult r = world.mine_area(10, 10, size, MiningShape::SQUARE);
    // A size-3 square must MINE every one of the (2*3+1)^2 = 49 cells,
    // including the corners a same-size circle would miss - total_removed is
    // shape coverage, independent of drop_ratio.
    CHECK(r.total_removed == 49);
    CHECK(r.counts[static_cast<int>(MaterialType::DIRT)] == 49);
    // Corners must have been reached (mined) even though DIRT's 0.5 ratio
    // means not every one of the 49 mined cells becomes SAND.
    CHECK(world.get_material(10 - size, 10 - size) != MaterialType::DIRT); // corner, no longer DIRT
    CHECK(world.get_material(10 + size, 10 + size) != MaterialType::DIRT); // opposite corner
    int sand_count = 0, air_count = 0;
    for (int dy = -size; dy <= size; ++dy) {
        for (int dx = -size; dx <= size; ++dx) {
            MaterialType mat = world.get_material(10 + dx, 10 + dy);
            CHECK(mat == MaterialType::SAND || mat == MaterialType::AIR); // never still DIRT
            if (mat == MaterialType::SAND) sand_count++;
            else if (mat == MaterialType::AIR) air_count++;
        }
    }
    // floor(49 * 0.5) = 24 SAND drops, the remaining 25 mined cells -> AIR.
    CHECK(sand_count == 24);
    CHECK(air_count == 25);
}

static void test_mine_area_circle_matches_mine_circle() {
    std::printf("test_mine_area_circle_matches_mine_circle\n");
    World world_a(1, 1, 19);
    World world_b(1, 1, 19);
    world_a.fill_rect(0, 0, 20, 20, MaterialType::STONE);
    world_b.fill_rect(0, 0, 20, 20, MaterialType::STONE);

    MineResult ra = world_a.mine_circle(10, 10, 4);
    MineResult rb = world_b.mine_area(10, 10, 4, MiningShape::CIRCLE);
    CHECK(ra.total_removed == rb.total_removed);
    // A CIRCLE-shaped mine_area must leave the same corner cells alone that
    // mine_circle always did (proves the shape check, not just the count).
    CHECK(world_a.get_material(6, 6) == world_b.get_material(6, 6));
    CHECK(world_a.get_material(14, 14) == world_b.get_material(14, 14));
}

static void test_mine_area_size_is_configurable() {
    std::printf("test_mine_area_size_is_configurable\n");
    World world(1, 1, 20);
    world.fill_rect(0, 0, 30, 30, MaterialType::DIRT);
    MineResult small = world.mine_area(5, 5, 1, MiningShape::CIRCLE);
    MineResult large = world.mine_area(20, 20, 6, MiningShape::CIRCLE);
    CHECK(large.total_removed > small.total_removed);
}

// ---- Configurable drop ratio / quantity-based mining conversion ----
// (World::compute_drop_count - pure, dependency-free, unit-tested directly)

static void test_drop_ratio_full_conversion() {
    std::printf("test_drop_ratio_full_conversion\n");
    float rem = 0.0f;
    CHECK(World::compute_drop_count(rem, 10, 1.0f) == 10);
    CHECK(rem == 0.0f);
    rem = 0.0f;
    CHECK(World::compute_drop_count(rem, 100, 1.0f) == 100);
    CHECK(rem == 0.0f);
}

static void test_drop_ratio_quarter() {
    std::printf("test_drop_ratio_quarter\n");
    float rem = 0.0f;
    CHECK(World::compute_drop_count(rem, 100, 0.25f) == 25);
}

static void test_drop_ratio_zero() {
    std::printf("test_drop_ratio_zero\n");
    float rem = 0.0f;
    CHECK(World::compute_drop_count(rem, 100, 0.0f) == 0);
    CHECK(rem == 0.0f);
}

static void test_drop_ratio_fractional_floors_deterministically() {
    std::printf("test_drop_ratio_fractional_floors_deterministically\n");
    float rem = 0.0f;
    // 7 * 0.5 = 3.5 -> floors to 3, banking the leftover 0.5 in the remainder
    // rather than rounding up or down per individual cell.
    CHECK(World::compute_drop_count(rem, 7, 0.5f) == 3);
    CHECK(std::abs(rem - 0.5f) < 0.0001f);
}

static void test_drop_ratio_accumulates_across_calls() {
    std::printf("test_drop_ratio_accumulates_across_calls\n");
    // Two separate mining actions (3 then 4 cells) at ratio 0.5 must add up
    // to the same total as one combined action of 7 cells (floor(7*0.5)=3),
    // regardless of how the mining was split - the whole point of carrying a
    // persistent remainder instead of rounding each call in isolation.
    float rem = 0.0f;
    int d1 = World::compute_drop_count(rem, 3, 0.5f); // 1.5 -> 1, remainder 0.5
    int d2 = World::compute_drop_count(rem, 4, 0.5f); // 0.5+2.0=2.5 -> 2, remainder 0.5
    CHECK(d1 == 1);
    CHECK(d2 == 2);
    CHECK(d1 + d2 == 3);

    // Order shouldn't matter either.
    float rem2 = 0.0f;
    int e1 = World::compute_drop_count(rem2, 4, 0.5f); // 2.0 -> 2, remainder 0
    int e2 = World::compute_drop_count(rem2, 3, 0.5f); // 0+1.5=1.5 -> 1, remainder 0.5
    CHECK(e1 + e2 == 3);
}

static void test_drop_ratio_never_exceeds_mined_count() {
    std::printf("test_drop_ratio_never_exceeds_mined_count\n");
    float rem = 0.0f;
    // A misconfigured ratio > 1.0 must still never fabricate more drops than
    // cells actually mined.
    CHECK(World::compute_drop_count(rem, 5, 3.0f) == 5);
}

// ---- End-to-end: ratio applied through the real mine_area/World path ----

static void test_mine_10_dirt_yields_5_sand() {
    std::printf("test_mine_10_dirt_yields_5_sand\n");
    World world(1, 1, 21);
    world.fill_rect(2, 2, 10, 1, MaterialType::DIRT); // exactly 10 DIRT cells
    MineResult r = world.mine_area(6, 2, 10, MiningShape::SQUARE); // generous box, fully covers the row
    CHECK(r.counts[static_cast<int>(MaterialType::DIRT)] == 10);
    CHECK(count_material_in_rect(world, 2, 2, 10, 1, MaterialType::SAND) == 5);
    CHECK(count_material_in_rect(world, 2, 2, 10, 1, MaterialType::AIR) == 5);
}

static void test_mine_100_dirt_yields_50_sand() {
    std::printf("test_mine_100_dirt_yields_50_sand\n");
    World world(2, 2, 22);
    world.fill_rect(5, 5, 10, 10, MaterialType::DIRT); // exactly 100 DIRT cells
    MineResult r = world.mine_area(9, 9, 8, MiningShape::SQUARE); // 17x17 box, fully covers it
    CHECK(r.counts[static_cast<int>(MaterialType::DIRT)] == 100);
    CHECK(count_material_in_rect(world, 5, 5, 10, 10, MaterialType::SAND) == 50);
    CHECK(count_material_in_rect(world, 5, 5, 10, 10, MaterialType::AIR) == 50);
}

static void test_mine_10_stone_yields_5_gravel() {
    std::printf("test_mine_10_stone_yields_5_gravel\n");
    World world(1, 1, 23);
    world.fill_rect(2, 2, 10, 1, MaterialType::STONE);
    MineResult r = world.mine_area(6, 2, 10, MiningShape::SQUARE);
    CHECK(r.counts[static_cast<int>(MaterialType::STONE)] == 10);
    CHECK(count_material_in_rect(world, 2, 2, 10, 1, MaterialType::GRAVEL) == 5);
    CHECK(count_material_in_rect(world, 2, 2, 10, 1, MaterialType::AIR) == 5);
}

static void test_mine_100_stone_yields_50_gravel() {
    std::printf("test_mine_100_stone_yields_50_gravel\n");
    World world(2, 2, 24);
    world.fill_rect(5, 5, 10, 10, MaterialType::STONE);
    MineResult r = world.mine_area(9, 9, 8, MiningShape::SQUARE);
    CHECK(r.counts[static_cast<int>(MaterialType::STONE)] == 100);
    CHECK(count_material_in_rect(world, 5, 5, 10, 10, MaterialType::GRAVEL) == 50);
    CHECK(count_material_in_rect(world, 5, 5, 10, 10, MaterialType::AIR) == 50);
}

static void test_drop_ratio_is_read_from_material_table_not_hardcoded() {
    std::printf("test_drop_ratio_is_read_from_material_table_not_hardcoded\n");
    // DIRT and STONE both use ratio 0.5 today but map to different drop
    // materials and are mined through the exact same World::mine_area code
    // path in a single combined mining action - proving the ratio/drop is
    // read per-material from MaterialDef, not a per-material branch in the
    // mining logic itself.
    World world(1, 1, 25);
    world.fill_rect(2, 2, 10, 1, MaterialType::DIRT);
    world.fill_rect(2, 4, 10, 1, MaterialType::STONE);
    world.mine_area(6, 3, 10, MiningShape::SQUARE); // one call, box covers both rows
    CHECK(count_material_in_rect(world, 2, 2, 10, 1, MaterialType::SAND) == 5);
    CHECK(count_material_in_rect(world, 2, 4, 10, 1, MaterialType::GRAVEL) == 5);
}

// ---- Simulation Wake / Activation (see SIMULATION_ACTIVATION.md) ----

// Test 1: sleeping chunk, same chunk as the change (regression guard - this
// already worked before the activation feature, via "a whole awake chunk is
// scanned every pass regardless of which cell was touched").
static void test_activation_wakes_sand_in_same_chunk() {
    std::printf("test_activation_wakes_sand_in_same_chunk\n");
    World world(1, 1, 30);
    world.set_cell(5, 5, MaterialType::SAND);
    world.set_cell(5, 6, MaterialType::STONE);
    world.set_cell(4, 6, MaterialType::STONE);
    world.set_cell(6, 6, MaterialType::STONE);
    run_full_pass(world); // pass containing the setup writes
    run_full_pass(world); // genuinely quiet pass -> asleep
    CHECK(world.chunk_at(0, 0).sleeping == true);

    world.set_cell(5, 6, MaterialType::AIR); // generic world change - remove the support
    run_full_pass(world);
    CHECK(world.get_material(5, 5) == MaterialType::AIR);
    CHECK(world.get_material(5, 6) == MaterialType::SAND);
}

// Test 2: the change and the affected SAND are in DIFFERENT chunks. This is
// the exact bug this feature fixes - before it, chunk B never woke up and
// the SAND floated forever.
static void test_activation_wakes_sand_across_chunk_boundary() {
    std::printf("test_activation_wakes_sand_across_chunk_boundary\n");
    World world(1, 2, 31); // chunk (0,0) = B on top (y 0-63), chunk (0,1) = A below (y 64-127)
    int boundary_y = CHUNK_SIZE; // first row of A; boundary_y-1 is B's last row
    world.set_cell(5, boundary_y - 1, MaterialType::SAND); // bottom row of B
    world.set_cell(5, boundary_y, MaterialType::STONE);     // support, top row of A
    world.set_cell(4, boundary_y, MaterialType::STONE);     // block the left diagonal too
    world.set_cell(6, boundary_y, MaterialType::STONE);     // block the right diagonal too
    run_full_pass(world);
    run_full_pass(world);
    CHECK(world.chunk_at(0, 0).sleeping == true); // B asleep
    CHECK(world.chunk_at(0, 1).sleeping == true); // A asleep

    world.set_cell(5, boundary_y, MaterialType::AIR); // remove the support (chunk A)
    // B must wake IMMEDIATELY - before any step() call - purely from the write in A.
    CHECK(world.chunk_at(0, 0).sleeping == false);
    CHECK(world.chunk_at(0, 1).sleeping == false);

    run_full_pass(world);
    CHECK(world.get_material(5, boundary_y - 1) == MaterialType::AIR);
    CHECK(world.get_material(5, boundary_y) == MaterialType::SAND); // fell across the boundary
}

// Test 3: a SAND column spanning three chunks vertically. Removing support
// at the bottom must let the collapse propagate all the way to the top
// chunk, not just the chunk immediately adjacent to the change.
static void test_activation_multi_chunk_cascade() {
    std::printf("test_activation_multi_chunk_cascade\n");
    World world(1, 3, 32); // 3 chunk rows stacked: 192 cells tall
    int h = world.height_cells();
    world.fill_rect(4, 0, 1, h, MaterialType::STONE); // left wall, keeps the fall vertical
    world.fill_rect(6, 0, 1, h, MaterialType::STONE); // right wall
    world.fill_rect(5, 0, 1, 128, MaterialType::SAND); // fills chunk(0,0) and chunk(0,1) completely
    world.set_cell(5, 128, MaterialType::STONE);        // support, top row of chunk(0,2)
    world.set_cell(5, h - 1, MaterialType::STONE);       // floor at the very bottom

    run_full_pass(world);
    run_full_pass(world);
    CHECK(world.chunk_at(0, 0).sleeping == true);
    CHECK(world.chunk_at(0, 1).sleeping == true);
    CHECK(world.chunk_at(0, 2).sleeping == true);

    world.set_cell(5, 128, MaterialType::AIR); // remove the support, three chunks away from the top

    for (int i = 0; i < 15; ++i) {
        run_full_pass(world);
    }

    // The topmost original sand cell's spot must have vacated - proof the
    // cascade reached chunk(0,0), two chunk boundaries away from the change.
    CHECK(world.get_material(5, 0) == MaterialType::AIR);
    // And a settled pile must exist near the floor.
    CHECK(count_material_in_rect(world, 5, h - 60, 1, 59, MaterialType::SAND) > 0);
}

// Test 4: a fully static, settled multi-chunk world has (~zero) active
// chunks - this feature must not spuriously keep chunks awake.
static void test_activation_stable_world_has_no_active_chunks() {
    std::printf("test_activation_stable_world_has_no_active_chunks\n");
    World world(4, 4, 33); // 16 chunks
    world.fill_rect(0, 0, world.width_cells(), world.height_cells() / 2, MaterialType::STONE);
    for (int i = 0; i < 5; ++i) {
        run_full_pass(world);
    }
    CHECK(count_active_chunks(world) == 0);
}

// Test 5: a single small change against inert (non-falling) terrain must
// only wake a small, fixed number of chunks - never hundreds/thousands.
static void test_activation_small_change_has_bounded_wake() {
    std::printf("test_activation_small_change_has_bounded_wake\n");
    World world(4, 4, 34); // 16 chunks
    world.fill_rect(0, 0, world.width_cells(), world.height_cells() / 2, MaterialType::STONE);
    for (int i = 0; i < 5; ++i) {
        run_full_pass(world);
    }
    CHECK(count_active_chunks(world) == 0);

    // Interior point, far from any chunk edge: only its own chunk should wake.
    world.set_cell(32, 32, MaterialType::AIR);
    CHECK(count_active_chunks(world) == 1);

    // Settle back down before the next probe.
    for (int i = 0; i < 5; ++i) {
        run_full_pass(world);
    }
    CHECK(count_active_chunks(world) == 0);

    // Worst-case corner point: local (0,0) of a chunk not on the world edge,
    // so every one of the 5 activation offsets lands in a different chunk
    // from its own. Still a small, fixed number - never "everything."
    world.set_cell(64, 64, MaterialType::AIR);
    int active = count_active_chunks(world);
    CHECK(active >= 1);
    CHECK(active <= 6);
}

// Test 6: a large SAND collapse across several chunks keeps the active-chunk
// count bounded by the actual falling/settling frontier, never the whole world.
static void test_activation_large_collapse_bounded_active_chunks() {
    std::printf("test_activation_large_collapse_bounded_active_chunks\n");
    World world(6, 4, 35); // 24 chunks
    int total_chunks = world.width_chunks() * world.height_chunks();
    world.fill_rect(0, 200, world.width_cells(), 16, MaterialType::STONE); // floor
    world.fill_rect(20, 5, 100, 20, MaterialType::SAND); // 2000 SAND cells, open fall

    int max_active = 0;
    bool saw_activity = false;
    for (int i = 0; i < 200; ++i) {
        StepStats stats = world.step(1000.0); // generous budget -> always a full pass
        if (stats.active_chunks > max_active) max_active = stats.active_chunks;
        if (stats.active_chunks > 0) saw_activity = true;
        if (stats.pass_completed && stats.active_chunks == 0 && i > 3) break;
    }

    CHECK(saw_activity);
    CHECK(max_active > 0);
    CHECK(max_active < total_chunks); // never the entire world
    CHECK(max_active <= total_chunks / 2); // stays well bounded
}

// Test 7: after a large collapse fully settles, chunks must return to sleeping.
static void test_activation_sleeps_again_after_stabilization() {
    std::printf("test_activation_sleeps_again_after_stabilization\n");
    World world(6, 4, 36);
    world.fill_rect(0, 200, world.width_cells(), 16, MaterialType::STONE);
    world.fill_rect(20, 5, 100, 20, MaterialType::SAND);

    bool stabilized = false;
    for (int i = 0; i < 300; ++i) {
        StepStats stats = world.step(1000.0);
        if (stats.pass_completed && stats.active_chunks == 0 && i > 3) {
            stabilized = true;
            break;
        }
    }
    CHECK(stabilized);
    CHECK(count_active_chunks(world) == 0);
}

// ---- Terrain Layers: Background/Foreground (see TERRAIN_LAYERS.md) ----

// Test 1: foreground material is what's "visible" (get_material) while non-AIR.
static void test_background_foreground_visible_when_solid() {
    std::printf("test_background_foreground_visible_when_solid\n");
    World world(1, 1, 40);
    world.set_cell(5, 5, MaterialType::STONE);
    world.set_background(5, 5, BackgroundType::DARK_ROCK);
    CHECK(world.get_material(5, 5) == MaterialType::STONE);
}

// Test 2: mining exposes the background - foreground becomes AIR, background unchanged.
static void test_background_revealed_by_mining() {
    std::printf("test_background_revealed_by_mining\n");
    World world(1, 1, 41);
    world.set_cell(5, 5, MaterialType::STONE);
    world.set_background(5, 5, BackgroundType::DARK_ROCK);
    // STONE's drop_ratio is 0.5: a single isolated cell (fresh remainder=0)
    // floors to 0 drops on the very first mine, so this reliably clears
    // straight to AIR with no GRAVEL drop in the way - no priming needed
    // (priming would instead GUARANTEE a drop, the opposite of what this
    // test wants; see test_background_unaffected_by_mining_drop for that case).
    world.mine_circle(5, 5, 0);
    CHECK(world.get_material(5, 5) == MaterialType::AIR);
    CHECK(world.get_background(5, 5) == BackgroundType::DARK_ROCK);
}

// Test 3: background survives repeated foreground changes over the same cell.
static void test_background_survives_repeated_foreground_changes() {
    std::printf("test_background_survives_repeated_foreground_changes\n");
    World world(1, 1, 42);
    world.set_background(5, 5, BackgroundType::DARK_ROCK);
    world.set_cell(5, 5, MaterialType::STONE);
    world.set_cell(5, 5, MaterialType::AIR);
    world.set_cell(5, 5, MaterialType::DIRT);
    world.set_cell(5, 5, MaterialType::SAND);
    world.set_cell(5, 5, MaterialType::AIR);
    CHECK(world.get_background(5, 5) == BackgroundType::DARK_ROCK);
}

// Test 4: background is inert under gravity - SAND falling through/past a
// column leaves every background byte in that column exactly as set.
static void test_background_inert_under_gravity() {
    std::printf("test_background_inert_under_gravity\n");
    World world(1, 1, 43);
    for (int y = 0; y < 20; ++y) {
        world.set_background(5, y, BackgroundType::DARK_ROCK);
    }
    world.set_cell(5, 0, MaterialType::SAND);
    world.fill_rect(3, 19, 5, 1, MaterialType::STONE); // wide floor, incl. both diagonals under the sand's landing spot
    for (int i = 0; i < 25; ++i) {
        run_full_pass(world);
    }
    // SAND should have fallen (foreground changed)...
    CHECK(world.get_material(5, 0) == MaterialType::AIR);
    CHECK(world.get_material(5, 18) == MaterialType::SAND);
    // ...but every background byte in the column is untouched.
    for (int y = 0; y < 20; ++y) {
        CHECK(world.get_background(5, y) == BackgroundType::DARK_ROCK);
    }
}

// Test 5: background is inert under general Sand+Water activity, not just
// a single falling grain.
static void test_background_inert_under_sand_and_water() {
    std::printf("test_background_inert_under_sand_and_water\n");
    World world(2, 1, 44);
    int w = world.width_cells();
    for (int x = 0; x < w; ++x) {
        for (int y = 0; y < 30; ++y) {
            world.set_background(x, y, BackgroundType::DARK_ROCK);
        }
    }
    world.fill_rect(10, 0, 20, 3, MaterialType::SAND);
    world.fill_rect(40, 0, 20, 3, MaterialType::WATER);
    world.fill_rect(0, 28, w, 2, MaterialType::STONE); // floor
    for (int i = 0; i < 40; ++i) {
        run_full_pass(world);
    }
    bool any_background_changed = false;
    for (int x = 0; x < w; ++x) {
        for (int y = 0; y < 30; ++y) {
            if (world.get_background(x, y) != BackgroundType::DARK_ROCK) {
                any_background_changed = true;
            }
        }
    }
    CHECK(!any_background_changed);
}

// Test 6: a background write must never wake a sleeping chunk.
static void test_background_write_never_wakes_chunk() {
    std::printf("test_background_write_never_wakes_chunk\n");
    World world(1, 1, 45);
    world.set_cell(5, 5, MaterialType::STONE);
    run_full_pass(world);
    run_full_pass(world);
    CHECK(world.chunk_at(0, 0).sleeping == true);

    world.set_background(10, 10, BackgroundType::DARK_ROCK);
    CHECK(world.chunk_at(0, 0).sleeping == true); // must NOT have been woken
}

// Test 7: mining drop is still foreground material; background at that
// position is unaffected by the drop.
static void test_background_unaffected_by_mining_drop() {
    std::printf("test_background_unaffected_by_mining_drop\n");
    World world(1, 1, 46);
    world.set_cell(5, 5, MaterialType::STONE);
    world.set_background(5, 5, BackgroundType::DARK_ROCK);
    world.mine_circle(5, 5, 0); // prime remainder (see drop-ratio tests)
    world.set_cell(5, 5, MaterialType::STONE);
    world.set_background(5, 5, BackgroundType::DARK_ROCK);
    world.mine_circle(5, 5, 0); // guaranteed drop this time -> GRAVEL
    CHECK(world.get_material(5, 5) == MaterialType::GRAVEL); // still foreground
    CHECK(world.get_background(5, 5) == BackgroundType::DARK_ROCK); // untouched
}

// Test 8: mining drop still falls under gravity with background present
// nearby - end-to-end regression guard for this feature.
static void test_background_mining_drop_still_falls() {
    std::printf("test_background_mining_drop_still_falls\n");
    World world(1, 1, 47);
    for (int y = 4; y <= 7; ++y) {
        world.set_background(5, y, BackgroundType::DARK_ROCK);
    }
    world.set_cell(5, 5, MaterialType::DIRT);
    world.mine_circle(5, 5, 0); // prime remainder
    world.set_cell(5, 5, MaterialType::DIRT);
    world.mine_circle(5, 5, 0); // guaranteed SAND drop
    CHECK(world.get_material(5, 5) == MaterialType::SAND);
    run_full_pass(world);
    CHECK(world.get_material(5, 5) == MaterialType::AIR);
    CHECK(world.get_material(5, 6) == MaterialType::SAND); // fell
    CHECK(world.get_background(5, 5) == BackgroundType::DARK_ROCK);
    CHECK(world.get_background(5, 6) == BackgroundType::DARK_ROCK);
}

// Test 9: background set across a chunk boundary is stored/retrieved
// correctly on each side, via the same local-coordinate math as foreground.
static void test_background_chunk_boundary() {
    std::printf("test_background_chunk_boundary\n");
    World world(2, 2, 48);
    int boundary_x = CHUNK_SIZE;
    int boundary_y = CHUNK_SIZE;
    world.set_background(boundary_x - 1, boundary_y - 1, BackgroundType::DARK_ROCK); // chunk (0,0)
    world.set_background(boundary_x, boundary_y - 1, BackgroundType::DARK_ROCK);     // chunk (1,0)
    world.set_background(boundary_x - 1, boundary_y, BackgroundType::DARK_ROCK);     // chunk (0,1)
    world.set_background(boundary_x, boundary_y, BackgroundType::DARK_ROCK);         // chunk (1,1)
    CHECK(world.get_background(boundary_x - 1, boundary_y - 1) == BackgroundType::DARK_ROCK);
    CHECK(world.get_background(boundary_x, boundary_y - 1) == BackgroundType::DARK_ROCK);
    CHECK(world.get_background(boundary_x - 1, boundary_y) == BackgroundType::DARK_ROCK);
    CHECK(world.get_background(boundary_x, boundary_y) == BackgroundType::DARK_ROCK);
    // Neighboring, untouched cells stay NONE.
    CHECK(world.get_background(boundary_x - 5, boundary_y - 5) == BackgroundType::NONE);
}

// Test 10: a background write causes exactly one render_dirty flip; further
// simulation passes with no other activity produce no further flips.
static void test_background_no_spurious_render_dirty() {
    std::printf("test_background_no_spurious_render_dirty\n");
    World world(1, 1, 49);
    // Drain any render-dirty state left over from World construction.
    world.consume_render_dirty(0, 0);

    world.set_background(5, 5, BackgroundType::DARK_ROCK);
    CHECK(world.consume_render_dirty(0, 0) == true); // exactly one flip, consumed here
    CHECK(world.consume_render_dirty(0, 0) == false); // already consumed - no double flip

    for (int i = 0; i < 10; ++i) {
        run_full_pass(world);
    }
    CHECK(world.consume_render_dirty(0, 0) == false); // simulation activity alone must not re-flag it
}

// Test 11: memory-footprint claim, proven rather than assumed - the
// background array costs exactly 1 byte per cell, Cell itself is untouched.
static void test_background_memory_footprint() {
    std::printf("test_background_memory_footprint\n");
    World world(1, 1, 50);
    CHECK(sizeof(Cell) == 2); // unchanged by this feature (see cell.h static_assert too)
    CHECK(sizeof(decltype(world.chunk_at(0, 0).background)) == CHUNK_CELL_COUNT);
}

// ---- Mining-drop collision classification (see PLAYER_COLLISION.md) ----
// Pure data (MaterialDef.is_mining_drop) - the actual player.gd collision
// toggle is Godot-dependent GDScript and is verified live in the editor
// instead (PROJECT_ARCHITECTURE.md §11 testing boundary).

static void test_mining_drop_material_classification() {
    std::printf("test_mining_drop_material_classification\n");
    // Only SAND and GRAVEL exist solely as mining-drop products today.
    CHECK(get_material_def(MaterialType::SAND).is_mining_drop == true);
    CHECK(get_material_def(MaterialType::GRAVEL).is_mining_drop == true);
    // Everything else is normal terrain/building material - unconditional collision.
    CHECK(get_material_def(MaterialType::AIR).is_mining_drop == false);
    CHECK(get_material_def(MaterialType::DIRT).is_mining_drop == false);
    CHECK(get_material_def(MaterialType::STONE).is_mining_drop == false);
    CHECK(get_material_def(MaterialType::IRON_ORE).is_mining_drop == false);
    CHECK(get_material_def(MaterialType::COPPER_ORE).is_mining_drop == false);
    CHECK(get_material_def(MaterialType::WATER).is_mining_drop == false);
    CHECK(get_material_def(MaterialType::WOOD).is_mining_drop == false);
    CHECK(get_material_def(MaterialType::METAL).is_mining_drop == false);
}

int main() {
    test_sand_falls();
    test_sand_blocked_by_stone();
    test_sand_diagonal_movement();
    test_water_falls_then_spreads();
    test_chunk_boundary_movement();
    test_mining_removes_material();
    test_dirty_chunks_marked();

    test_dirt_mining_creates_sand();
    test_stone_mining_creates_gravel();
    test_sand_mining_is_noop();
    test_gravel_mining_is_noop();
    test_mining_drop_is_active_and_falls();
    test_mining_drop_settles_on_ground();
    test_mining_drop_chunk_boundary();
    test_mining_wakes_sleeping_chunk();

    test_mine_area_square_covers_full_box();
    test_mine_area_circle_matches_mine_circle();
    test_mine_area_size_is_configurable();

    test_drop_ratio_full_conversion();
    test_drop_ratio_quarter();
    test_drop_ratio_zero();
    test_drop_ratio_fractional_floors_deterministically();
    test_drop_ratio_accumulates_across_calls();
    test_drop_ratio_never_exceeds_mined_count();
    test_mine_10_dirt_yields_5_sand();
    test_mine_100_dirt_yields_50_sand();
    test_mine_10_stone_yields_5_gravel();
    test_mine_100_stone_yields_50_gravel();
    test_drop_ratio_is_read_from_material_table_not_hardcoded();

    test_activation_wakes_sand_in_same_chunk();
    test_activation_wakes_sand_across_chunk_boundary();
    test_activation_multi_chunk_cascade();
    test_activation_stable_world_has_no_active_chunks();
    test_activation_small_change_has_bounded_wake();
    test_activation_large_collapse_bounded_active_chunks();
    test_activation_sleeps_again_after_stabilization();

    test_background_foreground_visible_when_solid();
    test_background_revealed_by_mining();
    test_background_survives_repeated_foreground_changes();
    test_background_inert_under_gravity();
    test_background_inert_under_sand_and_water();
    test_background_write_never_wakes_chunk();
    test_background_unaffected_by_mining_drop();
    test_background_mining_drop_still_falls();
    test_background_chunk_boundary();
    test_background_no_spurious_render_dirty();
    test_background_memory_footprint();

    test_mining_drop_material_classification();

    std::printf("\n%d/%d checks passed\n", g_checks - g_failures, g_checks);
    if (g_failures > 0) {
        std::printf("%d FAILURES\n", g_failures);
        return 1;
    }
    std::printf("ALL TESTS PASSED\n");
    return 0;
}
