#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Main-thread, read-only display-layout observer. No UIKit bootstrap, windows,
// original-library loading, input generation, or target-app injection.
// Starts a monitor only after verifying the iOS-17 selector ABI. A successful
// start means the observer was constructed, not that the server supplied data.
BOOL OPStartForegroundContext(NSString * _Nullable * _Nullable error);
void OPStopForegroundContext(void);
// Delivered on the main queue after a modern layout transition; nil removes
// the callback. Snapshots may be invalid during transitions or on the launcher.
void OPSetForegroundContextChangeHandler(void (^ _Nullable handler)(NSDictionary *snapshot));
NSDictionary *OPForegroundContextSnapshot(void);
NSString * _Nullable OPForegroundBundleIdentifier(void);
// Global output needs a known, lit, unlocked display, including SpringBoard
// and portrait, regardless of the foreground app. Editing ownership is checked
// separately through the configuration session lease.
BOOL OPGlobalOutputContextAllowed(NSDictionary *snapshot, NSString * _Nullable * _Nullable reason);
NS_ASSUME_NONNULL_END
