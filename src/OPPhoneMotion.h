#pragma once
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include "OPPhoneMotionMath.hpp"
NS_ASSUME_NONNULL_BEGIN
// Root mapping-service wrapper, main-thread lifecycle. A private mobile child
// owns CoreMotion; timestamps remain seconds since boot in both processes.
// Start means the child was spawned, not that fresh sensor data has arrived.
@interface OPPhoneMotion : NSObject
- (BOOL)startWithScaleX:(double)x scaleY:(double)y error:(NSString * _Nullable * _Nullable)error;
- (void)setActive:(BOOL)active;
- (void)setOrientation:(UIInterfaceOrientation)orientation;
- (op_phone::Delta)consume;
// Clear movement at a button/release boundary without invalidating the latest
// sensor timestamp. A tick preceding the next sample remains legitimately fresh.
- (void)discardPending;
- (void)clear;
- (void)stop;
@property(nonatomic,readonly) BOOL fresh;
@property(nonatomic,readonly,copy) NSDictionary *status;
@end
NS_ASSUME_NONNULL_END
