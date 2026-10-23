#pragma once

#include <cmath>
#include <optional>

namespace fsm {

// Interface orientations, not UIDeviceOrientation. In UIKit LandscapeLeft
// means the Home-button edge is on the left (USB-C edge on a modern iPhone).
enum class DisplayOrientation {
    Portrait,
    PortraitUpsideDown,
    LandscapeLeft,
    LandscapeRight,
};

struct NormalizedPoint {
    float x;
    float y;
};

inline bool validNormalizedPoint(float x, float y) noexcept {
    return std::isfinite(x) && std::isfinite(y) &&
           x >= 0.0f && x <= 1.0f && y >= 0.0f && y <= 1.0f;
}

// Screen digitizer coordinates stay in the panel's native portrait space.
// Callers must provide the *foreground app's* interface orientation, never
// SpringBoard's own window orientation or accelerometer/device orientation.
inline std::optional<NormalizedPoint> toNativePortrait(
    float x, float y, DisplayOrientation orientation) noexcept {
    if (!validNormalizedPoint(x, y)) return std::nullopt;
    switch (orientation) {
        case DisplayOrientation::Portrait: return NormalizedPoint{x, y};
        case DisplayOrientation::PortraitUpsideDown:
            return NormalizedPoint{1.0f - x, 1.0f - y};
        case DisplayOrientation::LandscapeLeft:
            return NormalizedPoint{y, 1.0f - x};
        case DisplayOrientation::LandscapeRight:
            return NormalizedPoint{1.0f - y, x};
    }
    return std::nullopt;
}

// Inverse for placement/dragging UI markers in a portrait-fixed overlay.
inline std::optional<NormalizedPoint> fromNativePortrait(
    float x, float y, DisplayOrientation orientation) noexcept {
    if (!validNormalizedPoint(x, y)) return std::nullopt;
    switch (orientation) {
        case DisplayOrientation::Portrait: return NormalizedPoint{x, y};
        case DisplayOrientation::PortraitUpsideDown:
            return NormalizedPoint{1.0f - x, 1.0f - y};
        case DisplayOrientation::LandscapeLeft:
            return NormalizedPoint{1.0f - y, x};
        case DisplayOrientation::LandscapeRight:
            return NormalizedPoint{y, 1.0f - x};
    }
    return std::nullopt;
}

} // namespace fsm
