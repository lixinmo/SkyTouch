#pragma once

#include <cstdint>

namespace fsm {

// Logical stick axes use screen-space signs: +X right, +Y down. The BLE protocol
// adapter is responsible for calibration; physical labels must be learned.
struct InputState {
    std::uint32_t buttons{0};
    float lx{0};
    float ly{0};
    float rx{0};
    float ry{0};
    bool connected{false};
    // Raw incremental channels recovered from bytes 11..13 of one input report.
    // They are deltas, not held axes: consume only once for each nonzero
    // reportID. The authenticated transport assigns IDs; neutral clears use 0.
    std::int16_t relativeX{0};
    std::int16_t relativeY{0};
    std::uint64_t reportID{0};
};

} // namespace fsm
