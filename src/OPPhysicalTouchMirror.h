#pragma once
#import <UIKit/UIKit.h>
#include <cstdint>
#include <vector>

NS_ASSUME_NONNULL_BEGIN
struct OPPhysicalMirrorSample {
    std::uint32_t key = 0; // Stable physical (pathIndex << 8) | pathIdentity.
    CGPoint screenPoint = CGPointZero;
    UITouchPhase phase = UITouchPhaseStationary;
};

// Main-thread-only visual mirror. Pass actual physical paths, including those
// outside the HUD hit-test region, after delivering the independent HUD event.
// Coordinates are AX screen points; this adapter converts to the original
// controller.view's logical coordinates. Nothing here dispatches a UIKit/HID
// touch, changes bindings, or runs a replacement mapping algorithm.
BOOL OPMirrorOriginalPhysicalFrame(const std::vector<OPPhysicalMirrorSample> &samples,
                                   NSString * _Nullable * _Nullable error);
// Call before rotation, target loss, shutdown, or a global physical cancel/up.
// Removes only this adapter's %p entries and original physical debug markers.
void OPCancelOriginalPhysicalMirrors(void);
NSUInteger OPOriginalPhysicalMirrorCount(void);
NS_ASSUME_NONNULL_END
