#pragma once

#include "InputState.hpp"

#include <array>
#include <cstddef>
#include <cstdint>

namespace fsm {

struct AxisCalibration {
    std::uint8_t offset{0};
    int minimum{0};
    int center{128};
    int maximum{255};
    bool inverted{false};
    bool enabled{true};
};

struct DecoderConfig {
    // The original plugin handles 14-byte input without a user format switch.
    // The BLE owner validates the service/channels before decoding; metadata
    // and unsupported keyboard/mouse reports remain excluded by the decoder.
    bool allowLegacy14{true};
    std::array<AxisCalibration, 4> axes{{
        {0, 0, 128, 255, false, true},
        {1, 0, 128, 255, false, true},
        {2, 0, 128, 255, false, true},
        {3, 0, 128, 255, false, true},
    }};
};

enum class ReportKind { None, Legacy14, Marked20 };

enum class DecodeStatus {
    Input,
    InvalidArgument,
    InvalidConfiguration,
    UnsupportedLength,
    MissingInputMarker,
    Legacy14Disabled,
    NonInputMetadata,
    UnsupportedKeyboardMouseMode,
};

struct DecodeResult {
    DecodeStatus status{DecodeStatus::InvalidArgument};
    ReportKind kind{ReportKind::None};
    InputState input{};
    // Raw calibrated-channel samples are useful for a local monitor. They are
    // input bytes, not a device identifier, and this module never persists them.
    std::array<std::uint8_t, 4> rawAxes{};

    bool accepted() const noexcept { return status == DecodeStatus::Input; }
};

// Enabled channels must refer to bytes common to both supported report sizes.
// Disabled channels always return zero and need no valid calibration.
bool validateDecoderConfig(const DecoderConfig &config) noexcept;

// Stateless and bounds checked. Does not set input.connected: only the owner of
// a live BLE connection can assert that. No physical button names are inferred.
DecodeResult decodeFlydigiReport(const std::uint8_t *bytes, std::size_t length,
                                const DecoderConfig &config = {}) noexcept;

const char *decodeStatusName(DecodeStatus status) noexcept;

} // namespace fsm
