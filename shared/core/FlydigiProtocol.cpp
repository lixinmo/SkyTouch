#include "FlydigiProtocol.hpp"

#include <algorithm>

namespace fsm {
namespace {

float normalizeAxis(std::uint8_t value, const AxisCalibration &axis) noexcept {
    if (!axis.enabled) {
        return 0.0F;
    }
    const int delta = static_cast<int>(value) - axis.center;
    const int range = delta < 0 ? axis.center - axis.minimum
                                : axis.maximum - axis.center;
    float normalized = static_cast<float>(delta) / static_cast<float>(range);
    normalized = std::max(-1.0F, std::min(1.0F, normalized));
    return axis.inverted ? -normalized : normalized;
}

std::int16_t signed12(std::uint16_t value) noexcept {
    // Arithmetic sign extension avoids implementation-defined unsigned-to-
    // signed narrowing for negative samples, including the -2048 endpoint.
    return static_cast<std::int16_t>((value & 0x800U) ? static_cast<int>(value) - 4096
                                                    : static_cast<int>(value));
}

} // namespace

bool validateDecoderConfig(const DecoderConfig &config) noexcept {
    for (const auto &axis : config.axes) {
        if (axis.enabled && (axis.offset >= 14 || axis.minimum < 0 ||
                             axis.maximum > 255 || axis.minimum >= axis.center ||
                             axis.center >= axis.maximum)) {
            return false;
        }
    }
    return true;
}

DecodeResult decodeFlydigiReport(const std::uint8_t *bytes, std::size_t length,
                                const DecoderConfig &config) noexcept {
    DecodeResult result;
    if (bytes == nullptr) {
        return result;
    }
    if (!validateDecoderConfig(config)) {
        result.status = DecodeStatus::InvalidConfiguration;
        return result;
    }

    // Sample flydigi 1.6.6: -[FZCentralViewController
    // peripheral:didUpdateValueForCharacteristic:error:], 0x1ac278.
    // Deliberately narrower than its >=20 / >=14 tests: unknown lengths do not
    // become touches. The 20-byte branch requires bytes 18/19 == FE/00.
    if (length == 20) {
        if (bytes[18] != 0xFE || bytes[19] != 0) {
            result.status = bytes[0] == 0xAC && bytes[1] == 0xC0
                                ? DecodeStatus::NonInputMetadata
                                : DecodeStatus::MissingInputMarker;
            return result;
        }
        result.kind = ReportKind::Marked20;
    } else if (length == 14) {
        // The old MAC reply occupies bytes 0..5 and has BA C0 at 6/7. Never
        // expose its payload to the input monitor or interpret it as controls.
        if (bytes[6] == 0xBA && bytes[7] == 0xC0) {
            result.status = DecodeStatus::NonInputMetadata;
            return result;
        }
        if (!config.allowLegacy14) {
            result.status = DecodeStatus::Legacy14Disabled;
            return result;
        }
        result.kind = ReportKind::Legacy14;
    } else {
        result.status = DecodeStatus::UnsupportedLength;
        return result;
    }

    // This implementation targets the V1 gamepad path, not the Q1 keyboard /
    // mouse path (nor the Apex2 exception found in the original plugin).
    if ((bytes[9] & 0x80U) != 0) {
        result.kind = ReportKind::None;
        result.status = DecodeStatus::UnsupportedKeyboardMouseMode;
        return result;
    }

    // Recovered directly from processData: 0x1b0ad4..0x1b0b38. These are raw
    // bit positions; assigning A/B/L1/etc without hardware evidence is unsafe.
    result.input.buttons = static_cast<std::uint32_t>(bytes[4]) |
                           (static_cast<std::uint32_t>(bytes[5]) << 8U) |
                           (static_cast<std::uint32_t>(bytes[9]) << 16U) |
                           (static_cast<std::uint32_t>(bytes[8] & 0x7FU) << 24U);

    // processData: uses bytes 0/1, 2/3 as its first two joystick pairs; the C
    // engine converts offset-binary samples around 0x80 at 0x706c48..0x706c74.
    // Physical left/right/up/down still require the user's local calibration.
    std::array<float, 4> normalized{};
    for (std::size_t index = 0; index < config.axes.size(); ++index) {
        const auto &axis = config.axes[index];
        if (axis.enabled) {
            result.rawAxes[index] = bytes[axis.offset];
            normalized[index] = normalizeAxis(result.rawAxes[index], axis);
        }
    }
    result.input.lx = normalized[0];
    result.input.ly = normalized[1];
    result.input.rx = normalized[2];
    result.input.ry = normalized[3];
    // Original processData:, 0x1b0b40..0x1b0bb4: two packed signed 12-bit
    // incremental inputs passed to touch_fps_process at 0x1b0c74. Do not infer
    // a sensor name or replay these deltas at the mapper's display tick rate.
    result.input.relativeX = signed12(static_cast<std::uint16_t>(bytes[11]) |
        (static_cast<std::uint16_t>(bytes[12] & 0x0FU) << 8U));
    result.input.relativeY = signed12(static_cast<std::uint16_t>(bytes[12] >> 4U) |
        (static_cast<std::uint16_t>(bytes[13]) << 4U));
    result.status = DecodeStatus::Input;
    return result;
}

const char *decodeStatusName(DecodeStatus status) noexcept {
    switch (status) {
    case DecodeStatus::Input: return "input";
    case DecodeStatus::InvalidArgument: return "invalid-argument";
    case DecodeStatus::InvalidConfiguration: return "invalid-calibration";
    case DecodeStatus::UnsupportedLength: return "unsupported-length";
    case DecodeStatus::MissingInputMarker: return "missing-FE00-marker";
    case DecodeStatus::Legacy14Disabled: return "legacy14-disabled";
    case DecodeStatus::NonInputMetadata: return "metadata-hidden";
    case DecodeStatus::UnsupportedKeyboardMouseMode: return "unsupported-keyboard-mouse-mode";
    }
    return "unknown";
}

} // namespace fsm
