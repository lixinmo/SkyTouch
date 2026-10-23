#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Owns one separately registered virtual digitizer. Main-thread lifecycle and
// output only. Never reuses the physical panel's sender or replays its input.
@interface OPVirtualTouchService : NSObject
@property(nonatomic,readonly) BOOL ready;
@property(nonatomic,readonly) uint64_t serviceID;
@property(nonatomic,readonly,copy) NSString *status;
@property(nonatomic,readonly) BOOL cancellationPending;
// Service disappearance is distinct from a successfully submitted touch-up.
@property(nonatomic,readonly) BOOL terminated;
@property(nonatomic,readonly) BOOL cancellationComplete;
// Bounded metadata only: rejected property keys, value types and counts.
@property(nonatomic,readonly,copy) NSDictionary *diagnostics;
// YES means registration started (or already pending/ready), not delivery.
- (BOOL)start:(NSString * _Nullable * _Nullable)error;
// Calls only this registered service's dispatchEvent: after Enumerated (10).
- (BOOL)dispatchEvent:(CFTypeRef)event;
// Idempotent. Retains service/delegate until the native cancel handler finishes.
// After cancellation, create a new wrapper for a new service session.
- (void)cancel;
@end
NS_ASSUME_NONNULL_END
