#import "OPPhysicalTouchMirror.h"
#import "OPOriginalBridge.h"
#import <objc/message.h>
#include <cmath>

// Exact observed vendor consumers of touchPoints: onTouchNotification:,
// onExecuteTouchEvent, numeric-slot onTouchBegin/Move/End, clearTouchList and
// getTouchPoints. The physical %p entries need phase/window/locationInView: and
// setPhaseAndUpdateTimestamp:. updateTimestamp/timestamp are also provided for
// the vendor's collection timestamp pass. Numeric 0..5 entries remain UITouch.
// This carrier deliberately is NOT a UITouch/UIEvent sent to UIApplication:
// the old periodic cleanup mutates its phases, and must never mutate HUD input.
@interface OPPhysicalMirrorTouch : NSObject
@property(nonatomic) UITouchPhase phase;
@property(nonatomic,weak) UIWindow *window;
@property(nonatomic,weak) UIView *coordinateView;
@property(nonatomic) CGPoint point;
@property(nonatomic) NSTimeInterval timestamp;
- (CGPoint)locationInView:(nullable UIView *)view;
- (void)updateTimestamp;
- (void)setPhaseAndUpdateTimestamp:(UITouchPhase)phase;
@end
@implementation OPPhysicalMirrorTouch
- (CGPoint)locationInView:(UIView *)view {
    // The original listener requests locationInView:touch.window and uses the
    // result directly as a marker.center in controller.view. Its old injected
    // host had an oriented application window; our physical HUD window stays
    // portrait with a rotated root view. Expose that original logical point.
    if (view==self.window || view==self.coordinateView) return self.point;
    return [self.coordinateView convertPoint:self.point toView:view];
}
- (void)updateTimestamp { self.timestamp=NSProcessInfo.processInfo.systemUptime; }
- (void)setPhaseAndUpdateTimestamp:(UITouchPhase)phase { self.phase=phase; [self updateTimestamp]; }
@end

@interface OPPhysicalMirrorEvent : NSObject
@property(nonatomic,copy) NSSet<OPPhysicalMirrorTouch *> *allTouches;
@end
@implementation OPPhysicalMirrorEvent
@end

namespace {
NSMutableDictionary<NSNumber *,OPPhysicalMirrorTouch *> *mirrors;
id get(id object,NSString *name) {
    SEL selector=NSSelectorFromString(name);
    return [object respondsToSelector:selector] ? ((id(*)(id,SEL))objc_msgSend)(object,selector) : nil;
}
NSMutableDictionary *dictionary(id controller,NSString *name) {
    id value=get(controller,name);
    return [value isKindOfClass:NSMutableDictionary.class] ? value : nil;
}
NSString *pointerKey(OPPhysicalMirrorTouch *touch) { return [NSString stringWithFormat:@"%p",(__bridge void *)touch]; }
void removeVendorEntry(id controller,OPPhysicalMirrorTouch *touch) {
    NSString *key=pointerKey(touch);
    NSMutableDictionary *points=dictionary(controller,@"touchPoints");
    if (points[key]==touch) [points removeObjectForKey:key];
    NSMutableDictionary *images=dictionary(controller,@"mappingDict");
    id image=images[key];
    if ([image isKindOfClass:UIView.class]) [image setHidden:YES];
    [images removeObjectForKey:key];
}
bool known(UITouchPhase phase) {
    return phase==UITouchPhaseBegan || phase==UITouchPhaseMoved || phase==UITouchPhaseStationary ||
        phase==UITouchPhaseEnded || phase==UITouchPhaseCancelled;
}
BOOL post(NSArray<OPPhysicalMirrorTouch *> *touches) {
    if (!touches.count) return YES;
    OPPhysicalMirrorEvent *event=[OPPhysicalMirrorEvent new];
    event.allTouches=[NSSet setWithArray:touches];
    return OPPostOriginalPhysicalEvent(event);
}
void finish(id controller,NSNumber *key) {
    OPPhysicalMirrorTouch *touch=mirrors[key];
    if (!touch) return;
    // Vendor onTouchNotification/onExecute handle Ended (3), not Cancelled (4).
    // This only releases a visual mirror; actual HUD input keeps its Cancelled.
    [touch setPhaseAndUpdateTimestamp:UITouchPhaseEnded];
    (void)post(@[touch]);
    removeVendorEntry(controller,touch);
    [mirrors removeObjectForKey:key];
}
} // namespace

BOOL OPMirrorOriginalPhysicalFrame(const std::vector<OPPhysicalMirrorSample> &samples,NSString **error) {
    if (error) *error=nil;
    if (![NSThread isMainThread]) { if (error) *error=@"Physical mirror requires the main thread"; return NO; }
    id controller=OPOriginalController();
    if (![controller isKindOfClass:UIViewController.class]) { if (error) *error=@"Original controller unavailable"; return NO; }
    UIViewController *owner=controller;
    UIView *view=owner.isViewLoaded ? owner.view : nil;
    UIWindow *window=view.window;
    if (!view || !window || !dictionary(controller,@"touchPoints") || !dictionary(controller,@"mappingDict")) {
        OPCancelOriginalPhysicalMirrors();
        if (error) *error=@"Original physical visualization context unavailable";
        return NO;
    }
    if (samples.size()>256) { OPCancelOriginalPhysicalMirrors(); if (error) *error=@"Physical mirror batch too large"; return NO; }
    for (const auto &sample:samples) {
        if (!known(sample.phase) || !std::isfinite(sample.screenPoint.x) || !std::isfinite(sample.screenPoint.y)) {
            OPCancelOriginalPhysicalMirrors(); if (error) *error=@"Physical mirror sample invalid"; return NO;
        }
    }
    if (!mirrors) mirrors=[NSMutableDictionary dictionary];
    NSMutableSet<NSNumber *> *batchKeys=[NSMutableSet set];
    auto commit=[&]() -> BOOL {
        NSArray<NSNumber *> *keys=mirrors.allKeys.copy;
        const BOOL success=post(mirrors.allValues);
        for (NSNumber *key in keys) {
            OPPhysicalMirrorTouch *touch=mirrors[key];
            if (!success || touch.phase==UITouchPhaseEnded || touch.phase==UITouchPhaseCancelled) {
                removeVendorEntry(controller,touch); [mirrors removeObjectForKey:key];
            } else [touch setPhaseAndUpdateTimestamp:UITouchPhaseStationary];
        }
        return success;
    };
    for (const auto &sample:samples) {
        NSNumber *key=@(sample.key);
        if ([batchKeys containsObject:key]) { if (!commit()) { if (error) *error=@"Original physical listener failed"; return NO; } [batchKeys removeAllObjects]; }
        [batchKeys addObject:key];
        OPPhysicalMirrorTouch *touch=mirrors[key];
        if (sample.phase==UITouchPhaseBegan) {
            if (touch) finish(controller,key);
            touch=[OPPhysicalMirrorTouch new]; touch.window=window; touch.coordinateView=view;
            mirrors[key]=touch;
        } else if (!touch) continue; // Do not synthesize a missing physical Down.
        touch.point=[view convertPoint:sample.screenPoint fromView:nil];
        [touch setPhaseAndUpdateTimestamp:sample.phase==UITouchPhaseCancelled ? UITouchPhaseEnded : sample.phase];
    }
    if (samples.empty()) return YES;
    if (!commit()) { if (error) *error=@"Original physical listener failed"; return NO; }
    return YES;
}

void OPCancelOriginalPhysicalMirrors(void) {
    if (![NSThread isMainThread]) return;
    if (!mirrors.count) return;
    id controller=OPOriginalController();
    NSArray<OPPhysicalMirrorTouch *> *touches=mirrors.allValues;
    for (OPPhysicalMirrorTouch *touch in touches) [touch setPhaseAndUpdateTimestamp:UITouchPhaseEnded];
    (void)post(touches);
    for (OPPhysicalMirrorTouch *touch in touches) removeVendorEntry(controller,touch);
    [mirrors removeAllObjects];
}
NSUInteger OPOriginalPhysicalMirrorCount(void) { return mirrors.count; }
