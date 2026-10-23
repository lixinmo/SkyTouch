#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Read-only demand from durable mapping intent and the two exclusive consumer
// leases. Unreadable/unsafe leases conservatively keep the broker alive and
// report "unknown"; a shared probe is never mistaken for an actual consumer.
NSDictionary *OPBluetoothLifetimeState(void);
BOOL OPBluetoothLifetimeRequired(void);
NS_ASSUME_NONNULL_END

#ifdef __cplusplus
#include <cmath>
namespace op_bluetooth_lifetime {
struct IdleGrace {
    bool waiting = false;
    double idleSince = 0;
    // Use a monotonic clock. Demand or an invalid/backwards clock resets the
    // countdown, so an editor or engine handoff cannot inherit old idle time.
    bool shouldStop(bool required, double now, double graceSeconds) {
        if (required || !std::isfinite(now) || !std::isfinite(graceSeconds) || graceSeconds < 0) {
            waiting = false;
            return false;
        }
        if (!waiting || now < idleSince) {
            waiting = true;
            idleSince = now;
        }
        return now - idleSince >= graceSeconds;
    }
};
}
#endif
