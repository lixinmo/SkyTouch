#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#ifdef __cplusplus
#include "../shared/core/MappingEngine.hpp"
#endif

NS_ASSUME_NONNULL_BEGIN

// Main-thread-only output backend for the original-library migration. This
// independent root HUD port has NOT passed real-device acceptance testing.
// Only effective UID 0 plus bundle ID com.lixinmo.skytouch.app is permitted;
// SpringBoard and target apps are not supported hosts. The root signer must
// supply the private HID event-dispatch/event-monitor privileges required by
// the device. Host identity checks do not establish those privileges or prove
// delivery. No UIKit event-enqueue/sendEvent route is used as an output fallback.
// The existing fsm header supplies frame types only; no mapping engine runs here.
@interface OPSystemTouch : NSObject

// Loads private symbols and registers a separate virtual touch service.
// No synthetic event is sent by prepare. Repeated calls are idempotent.
- (BOOL)prepare;

// Ready means the independent service was enumerated, not that an App has
// acknowledged a touch. The physical digitizer's sender is never borrowed.
@property(nonatomic, readonly) BOOL ready;
// An allocation/client failure prevented even submitting cancellation. New
// gestures are blocked; a few bounded retries run on the main queue. This is
// a local-submission diagnostic, not an end-to-end delivery acknowledgement.
@property(nonatomic, readonly) BOOL cancellationPending;
@property(nonatomic, readonly, copy) NSString *status;
@property(nonatomic, readonly) uint64_t submittedFrameCount;
@property(nonatomic, readonly) uint64_t serviceIdentifier;
@property(nonatomic, readonly, copy) NSDictionary *sourceDiagnostics;

#ifdef __cplusplus
// The frame is a complete snapshot: all active touches plus this frame's
// ended/cancelled touches. Coordinates are normalized to the foreground UI.
// YES means submitted locally; end-to-end delivery requires a device test.
- (BOOL)dispatchFrame:(const fsm::TouchFrame &)frame
           orientation:(UIInterfaceOrientation)orientation;
#endif

// Cancels the backend's active contacts at their last native coordinates.
// Caller must also reset/restart the engine on a target/rotation change, or
// disarm it when output is stopped. A failed allocation is retained for retry.
- (void)reset;

// Cancels active contacts before removing this backend's independent service.
// A failed cancellation is retained for bounded retry, never new gestures.
- (void)shutdown;

@end

NS_ASSUME_NONNULL_END
