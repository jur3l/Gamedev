#include "terrain_gen.h"
#include <algorithm>
#include <cmath>
#include <random>
#include <vector>
#include "../core/background.h"
#include "../core/material.h"
#include "../core/world.h"

namespace pixelsim {

namespace {
constexpr double TAU = 6.28318530718;
}

void generate_test_terrain(World &world, uint32_t seed) {
    std::mt19937 rng(seed);
    const int w = world.width_cells();
    const int h = world.height_cells();

    // Smooth rolling surface height = sum of a few seeded sine waves.
    struct Wave { double freq, amp, phase; };
    std::uniform_real_distribution<double> phase_dist(0.0, TAU);
    Wave waves[3];
    double base_amp = h * 0.035;
    for (int i = 0; i < 3; ++i) {
        double periods = 2.0 + i * 3.0 + std::uniform_real_distribution<double>(0.0, 1.5)(rng);
        waves[i].freq = periods * TAU / w;
        waves[i].amp = base_amp / (i + 1);
        waves[i].phase = phase_dist(rng);
    }

    int surface_base = static_cast<int>(h * 0.35);
    std::vector<int> surface(w);
    for (int x = 0; x < w; ++x) {
        double s = 0.0;
        for (const Wave &wv : waves) {
            s += wv.amp * std::sin(wv.freq * x + wv.phase);
        }
        surface[x] = surface_base + static_cast<int>(s);
    }

    std::uniform_int_distribution<int> dirt_depth_dist(6, 12);
    std::vector<int> dirt_depth(w);
    for (int x = 0; x < w; ++x) {
        dirt_depth[x] = dirt_depth_dist(rng);
        int surf = surface[x];
        for (int y = 0; y < h; ++y) {
            MaterialType mat;
            if (y < surf) mat = MaterialType::AIR;
            else if (y < surf + dirt_depth[x]) mat = MaterialType::DIRT;
            else mat = MaterialType::STONE;
            world.set_cell(x, y, mat);
            // Background is assigned here, as part of terrain generation -
            // not at mining time (TERRAIN_LAYERS.md). Every solid cell gets
            // rock background so it's revealed however that cell later
            // becomes AIR, whether by mining or by the cave-carving pass
            // below (a natural cave should read the same as a mined one).
            if (mat != MaterialType::AIR) {
                world.set_background(x, y, BackgroundType::DARK_ROCK);
            }
        }
    }

    // Ore deposits: small random-walk blobs of IRON_ORE / COPPER_ORE inside stone.
    int world_area = w * h;
    int deposit_count = std::max(20, world_area / 6000);
    std::uniform_int_distribution<int> x_dist(0, w - 1);
    std::uniform_int_distribution<int> blob_size_dist(3, 7);
    std::uniform_int_distribution<int> ore_pick(0, 1);
    std::uniform_int_distribution<int> dir4(0, 3);
    for (int i = 0; i < deposit_count; ++i) {
        int cx = x_dist(rng);
        int min_y = surface[cx] + dirt_depth[cx] + 4;
        if (min_y >= h - 4) continue;
        int cy = std::uniform_int_distribution<int>(min_y, h - 4)(rng);
        if (world.get_material(cx, cy) != MaterialType::STONE) continue;
        MaterialType ore = ore_pick(rng) == 0 ? MaterialType::IRON_ORE : MaterialType::COPPER_ORE;
        int blob_steps = blob_size_dist(rng) * 6;
        int px = cx, py = cy;
        for (int step = 0; step < blob_steps; ++step) {
            if (world.get_material(px, py) == MaterialType::STONE) {
                world.set_cell(px, py, ore);
            }
            int dir = dir4(rng);
            px += (dir == 0) - (dir == 1);
            py += (dir == 2) - (dir == 3);
            if (!world.in_bounds(px, py)) break;
        }
    }

    // Caves: worm-carved AIR tunnels drifting gently downward through the rock.
    int cave_count = std::max(6, w / 220);
    std::uniform_int_distribution<int> len_dist(80, 220);
    std::uniform_int_distribution<int> radius_dist(2, 4);
    std::uniform_real_distribution<double> angle_dist(0.0, TAU);
    std::uniform_real_distribution<double> turn_dist(-0.4, 0.4);
    for (int i = 0; i < cave_count; ++i) {
        int cx = x_dist(rng);
        double start_y = surface[cx] + 15;
        if (start_y >= h - 10) continue;
        int len = len_dist(rng);
        double dir_angle = angle_dist(rng);
        double px = cx, py = start_y;
        for (int step = 0; step < len; ++step) {
            int radius = radius_dist(rng);
            int ix = static_cast<int>(px), iy = static_cast<int>(py);
            for (int dy = -radius; dy <= radius; ++dy) {
                for (int dx = -radius; dx <= radius; ++dx) {
                    if (dx * dx + dy * dy > radius * radius) continue;
                    if (world.in_bounds(ix + dx, iy + dy) && world.get_material(ix + dx, iy + dy) != MaterialType::AIR) {
                        world.set_cell(ix + dx, iy + dy, MaterialType::AIR);
                    }
                }
            }
            dir_angle += turn_dist(rng);
            px += std::cos(dir_angle) * 1.5;
            py += std::sin(dir_angle) * 1.0 + 0.15; // slight downward drift
            if (!world.in_bounds(static_cast<int>(px), static_cast<int>(py))) break;
        }
    }
}

} // namespace pixelsim
