#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
#ifdef __cplusplus
extern "C" {
#endif
// Call on the main thread after the original classes are registered and before
// creating the configuration controller. No vendor image or gain is changed.
// Every reload then applies the same current entity to both original engines.
BOOL OPInstallOriginalMotionConfigurationFix(NSString * _Nullable * _Nullable error);
// Main-thread diagnostics; includes counters, device type, and numeric motion
// gains, never profile names, coordinates, account identifiers, or inputs.
NSDictionary *OPOriginalMotionConfigurationFixStatus(void);
#ifdef __cplusplus
}
#endif
NS_ASSUME_NONNULL_END
