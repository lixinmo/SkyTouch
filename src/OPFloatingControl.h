#pragma once
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
// Launcher side only. The service owns the floating window and its lifecycle.
NSDictionary * _Nullable OPFloatingConfigurationStatus(void);
NSString * _Nullable OPFloatingConfigurationLaunchProblem(void);
BOOL OPShowFloatingConfiguration(NSString *target, NSString * _Nullable * _Nullable error);
NS_ASSUME_NONNULL_END
