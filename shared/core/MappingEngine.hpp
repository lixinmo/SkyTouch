#pragma once

#include "InputState.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace fsm {

constexpr std::size_t kMaxTouches = 10;

enum class TouchPhase : std::uint8_t {
    Began,
    Moved,
    Stationary,
    Ended,
    Cancelled,
};

struct Touch {
    // IDs are 1-based, stable for each mapping until the profile is replaced.
    std::uint32_t id = 0;
    float x = 0.0F;
    float y = 0.0F;
    TouchPhase phase = TouchPhase::Stationary;
};

struct TouchFrame {
    // Monotonic nanoseconds supplied by the caller; regressions are clamped.
    std::uint64_t timestampNs = 0;
    std::array<Touch, kMaxTouches> touches{};
    std::size_t count = 0;

    bool empty() const noexcept { return count == 0; }
    const Touch* begin() const noexcept { return touches.data(); }
    const Touch* end() const noexcept { return touches.data() + count; }
};

struct StickMapping {
    bool enabled = false;
    float centerX = 0.5F;
    float centerY = 0.5F;
    float radiusX = 0.1F;
    float radiusY = 0.1F;
};

enum class ButtonMode : std::uint8_t { Hold, Tap, RapidFire, Swipe, Macro };
enum class MacroStepKind : std::uint8_t { Tap, Swipe, Wait };

struct MacroStep {
    MacroStepKind kind = MacroStepKind::Tap;
    float x = 0.5F;
    float y = 0.5F;
    float endX = 0.5F;
    float endY = 0.5F;
    std::uint32_t durationMs = 60;
    std::uint32_t gapMs = 0;
};

struct ButtonMapping {
    // All bits in a nonzero mask must be down. Repeated masks may produce
    // separate contacts, allowing one physical control to touch several points.
    std::uint32_t buttonMask = 0;
    float x = 0.5F;
    float y = 0.5F;
    ButtonMode mode = ButtonMode::Hold;
    std::uint32_t pressMs = 60;
    // Beginning-to-beginning period; at least pressMs + 17 after sanitization.
    std::uint32_t intervalMs = 120;
    float endX = 0.5F;
    float endY = 0.5F;
    std::uint32_t durationMs = 200;
    std::vector<MacroStep> steps{};
};

enum class FpsSource : std::uint8_t { Relative, RightStick };
struct FpsMapping {
    bool enabled = false;
    FpsSource source = FpsSource::Relative;
    float centerX = 0.5F;
    float centerY = 0.5F;
    float sensitivityX = 0.0005F; // normalized displacement per relative raw unit
    float sensitivityY = 0.0005F;
    float stickSpeedX = 0.6F;     // normalized displacement per second
    float stickSpeedY = 0.6F;
    bool invertX = false;
    bool invertY = false;
    std::uint32_t activationMask = 0; // zero means no activation button required
    bool edgeReset = true;
    std::uint32_t idleReleaseMs = 80;
};

enum class ProfileError : std::uint8_t { None, TooManyMappings };

struct Profile {
    float deadzone = 0.15F;
    StickMapping leftStick{};
    StickMapping rightStick{};
    std::vector<ButtonMapping> buttons{};
    FpsMapping view{};
};

// Deterministic disk sticks, button actions and relative/right-stick view drag.
//
// Coordinates are normalized in the oriented application's screen: x points
// right, y points down. InputState axes use the same signs, nominally [-1, 1].
// Device-specific calibration/inversion and display rotation belong outside
// this class. Configure and step it on one serialized queue (not thread-safe).
// Tap, Swipe and Macro trigger on a rising mask edge and finish after release;
// further edges during a running action are ignored. Macro steps execute in
// order with their post-step gaps; no repeated/held macro mode is implied.
// RapidFire repeats while held and releases immediately when its mask is up.
// Timing uses actual steps: overdue actions end once, never burst through
// multiple Began/Ended events in one frame or skip configured macro actions.
//
// Relative view requires nonzero monotonically increasing InputState.reportID
// within a BLE session; repeated/older reports are consumed only once, including
// while disarmed or the activation mask is up. reset/profile/re-arm preserve
// deduplication; disconnected input allows a new session to restart its IDs.
// The caller must mask any pre-arm latched delta (or step it while disarmed).
// A new view drag Begins at its center and applies pending displacement on the
// next step. Relative inactivity ends the drag; zero displacement reports do
// not extend its lifetime. Edge reset Ends at the boundary, Begins at center
// on the next step, then applies relative overshoot. RightStick view integrates
// deadzone-adjusted axes using dt capped at 100ms; centering releases its drag.
//
// IMPORTANT: deliver every returned nonempty frame to the touch backend,
// including frames returned by lifecycle/configuration methods. Cancelling
// internally without delivering those frames would leave system contacts down.
class MappingEngine {
public:
    MappingEngine() = default;

    // Cancels all old contacts and disarms, even when replacing an identical
    // profile. Invalid mappings are discarded, coordinates/radii are bounded,
    // and allocation order is left, right, view, buttons. More than 10 valid
    // mappings rejects the ENTIRE replacement (profileError=TooManyMappings),
    // leaves an empty disarmed engine and returns the old cancellation frame.
    // No capacity truncation silently removes configured buttons.
    // Invalid masks, enums, nonfinite coordinates, empty/invalid/>32-step
    // macros are discarded and counted by rejectedMappingCount(). Finite
    // coordinates clamp to [0,1]; durations clamp to 17..10000ms, press to
    // 17..5000ms, gaps to 0..10000ms, idle release to 17..1000ms. Sensitivities
    // clamp to 0..0.05/raw unit and stick speeds to 0..10/second; negative or
    // nonfinite view parameters reject that view mapping. Each action reserves
    // one stable contact ID even during an idle macro step or a rapid-fire gap.
    TouchFrame setProfile(const Profile& profile, std::uint64_t timestampNs);

    // Starts disarmed. Arming never synthesizes a touch until step(); repeated
    // arming preserves current contacts. Disarming emits their cancellation.
    TouchFrame setArmed(bool armed, std::uint64_t timestampNs) noexcept;

    // Establishes the already-observed button baseline after a profile/reset
    // transition, without starting/ending contacts or actions. Prime before
    // rearming to keep a latched held mask from retriggering Tap/Swipe/Macro.
    // Hold and RapidFire remain level-triggered and can resume while held.
    void primeButtons(std::uint32_t buttons) noexcept;

    // Cancels active touches and disarms, preserving the configured profile.
    TouchFrame reset(std::uint64_t timestampNs) noexcept;

    // Each normal frame includes all active contacts (including Stationary)
    // and contacts ending in this step. A disconnected input instead emits
    // Cancelled and disarms; reconnection does NOT automatically re-arm.
    TouchFrame step(const InputState& input, std::uint64_t timestampNs) noexcept;

    bool isArmed() const noexcept { return armed_; }
    std::size_t activeTouchCount() const noexcept;
    std::size_t configuredTouchCount() const noexcept { return mappingCount_; }
    const Profile& profile() const noexcept { return profile_; }
    ProfileError profileError() const noexcept { return profileError_; }
    std::size_t rejectedMappingCount() const noexcept { return rejectedMappingCount_; }

private:
    enum class MappingKind : std::uint8_t { LeftStick, RightStick, View, Button };

    struct Mapping {
        MappingKind kind = MappingKind::Button;
        std::uint32_t buttonMask = 0;
        float x = 0.0F;
        float y = 0.0F;
        float radiusX = 0.0F;
        float radiusY = 0.0F;
        std::size_t buttonIndex = 0;
    };

    struct ContactState {
        bool active = false;
        float x = 0.0F;
        float y = 0.0F;
        bool wasDown = false;
        bool running = false;
        bool segmentStarted = false;
        bool recenterPending = false;
        std::size_t stepIndex = 0;
        std::uint64_t startedNs = 0;
        std::uint64_t readyNs = 0;
        std::uint64_t nextPressNs = 0;
        std::uint64_t lastMotionNs = 0;
        float pendingX = 0.0F;
        float pendingY = 0.0F;
    };

    TouchFrame newFrame(std::uint64_t timestampNs) noexcept;
    TouchFrame cancelAndDisarm(std::uint64_t timestampNs) noexcept;
    void append(TouchFrame& frame, std::size_t index, TouchPhase phase) const noexcept;
    bool desiredPoint(const Mapping& mapping, const InputState& input,
                      float& x, float& y) const noexcept;
    void updateContact(TouchFrame& frame, std::size_t index, bool down,
                       float x, float y) noexcept;
    void stepButton(TouchFrame& frame, std::size_t index,
                    const InputState& input) noexcept;
    void stepView(TouchFrame& frame, std::size_t index, const InputState& input,
                  bool freshReport, std::uint64_t deltaNs) noexcept;

    Profile profile_{};
    std::array<Mapping, kMaxTouches> mappings_{};
    std::array<ContactState, kMaxTouches> contacts_{};
    std::size_t mappingCount_ = 0;
    std::uint64_t lastTimestampNs_ = 0;
    bool armed_ = false;
    ProfileError profileError_ = ProfileError::None;
    std::size_t rejectedMappingCount_ = 0;
    std::uint64_t lastRelativeReportID_ = 0;
    bool hasRelativeReport_ = false;
};

} // namespace fsm
