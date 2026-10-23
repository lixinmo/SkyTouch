#pragma once

#include <cstddef>

namespace fsm {

struct BLEChannelCapabilities {
    bool present{false};
    bool writable{false};
    bool notifiable{false};
};

enum class FlydigiChannelLayout { Unsupported, Split002And003, Combined003 };

// Recovered from com.flydigi 1.6.6's characteristic-discovery callback:
// >1 characteristics uses 002 to write and 003 to receive; a single 003 can
// serve both roles. Inspect the complete service, and require advertised
// capabilities before sending anything; never guess another UUID or mode.
constexpr FlydigiChannelLayout selectFlydigiChannels(
    std::size_t characteristicCount,
    BLEChannelCapabilities channel002,
    BLEChannelCapabilities channel003) noexcept {
    if (characteristicCount > 1 && channel002.present && channel002.writable &&
        channel003.present && channel003.notifiable)
        return FlydigiChannelLayout::Split002And003;
    if (characteristicCount == 1 && !channel002.present && channel003.present &&
        channel003.writable && channel003.notifiable)
        return FlydigiChannelLayout::Combined003;
    return FlydigiChannelLayout::Unsupported;
}

} // namespace fsm
