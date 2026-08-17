#include "background.h"

namespace pixelsim {

namespace {

constexpr BackgroundDef BACKGROUND_TABLE[BACKGROUND_TYPE_COUNT] = {
    // name          r   g   b    a
    {"NONE",         0,  0,  0,   0},
    {"DARK_ROCK",   52,  44, 40, 255},
};

} // namespace

const BackgroundDef &get_background_def(BackgroundType type) {
    int idx = static_cast<int>(type);
    if (idx < 0 || idx >= BACKGROUND_TYPE_COUNT) {
        idx = 0;
    }
    return BACKGROUND_TABLE[idx];
}

const BackgroundDef &get_background_def(uint8_t type) {
    return get_background_def(static_cast<BackgroundType>(type));
}

} // namespace pixelsim
