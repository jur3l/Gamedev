#pragma once
#include <cstdint>

namespace pixelsim {

// Number of simulation cells per chunk edge. A chunk is CHUNK_SIZE x CHUNK_SIZE cells.
constexpr int CHUNK_SIZE = 64;
constexpr int CHUNK_CELL_COUNT = CHUNK_SIZE * CHUNK_SIZE;

// Default world bounds, in chunks. Chosen to comfortably host the 500k-cell
// stress test (see docs) while staying inside a single contiguous allocation.
constexpr int DEFAULT_WORLD_CHUNKS_X = 48;
constexpr int DEFAULT_WORLD_CHUNKS_Y = 28;

// Default screen/world pixels per simulation cell. Purely a rendering scale
// factor - the simulation itself never reads this value.
constexpr int DEFAULT_SIMULATION_CELL_SIZE = 4;

constexpr double DEFAULT_SIMULATION_BUDGET_MS = 4.0;

} // namespace pixelsim
