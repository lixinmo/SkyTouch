#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>

namespace op_moba_editor {
// A missing vendor value is also represented by -1, which is a valid explicit
// "reverse, sensitivity 1" setting. Presence must travel separately.
struct AxisDraft {
    int original = 0;
    bool present = false;
    int magnitude = 30;
    bool reversed = false;
    bool touched = false;

    AxisDraft() = default;
    AxisDraft(int value, bool hasValue) : original(value), present(hasValue) {
        if (present) {
            const std::int64_t wide = value;
            const std::int64_t absolute = wide < 0 ? -wide : wide;
            magnitude = static_cast<int>(std::max<std::int64_t>(1, std::min<std::int64_t>(127, absolute)));
            reversed = value < 0;
        }
    }
    void setMagnitude(float value) {
        if (!std::isfinite(value)) return;
        magnitude = static_cast<int>(std::lround(std::max(1.0f, std::min(127.0f, value))));
        touched = true;
    }
    void setReversed(bool value) { reversed = value; touched = true; }
    int value() const { return reversed ? -magnitude : magnitude; }
    bool changed() const { return touched && (!present || value() != original); }
    void accepted() {
        if (changed()) { original = value(); present = true; }
        touched = false;
    }
};
struct EditDraft {
    AxisDraft horizontal;
    AxisDraft vertical;
    template<class Writer> void writeChanged(Writer writer) const {
        if (horizontal.changed()) writer(true, horizontal.value());
        if (vertical.changed()) writer(false, vertical.value());
    }
};
} // namespace op_moba_editor
