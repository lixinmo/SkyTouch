#pragma once
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT BOOL OPConfigurationArchiveNeedsRecovery(void);
// Called only by the privileged, one-shot storage helper after the caller has
// stopped mapping/BLE and excluded configuration writers. No arbitrary path
// is accepted. Restore takes a backup basename; acknowledge takes pendingID.
// Restore/clear/recover may return pendingID + pendingOperation + mobileDefaults.
// The App must synchronize its domain, then acknowledge before other operations.
FOUNDATION_EXPORT NSDictionary * _Nullable OPConfigurationArchivePerform(NSString *operation,
    NSString * _Nullable basename, NSString * _Nullable * _Nullable error);
// The storage helper may hold Library across its recovery probe and writer
// guards. The descriptor must refer to the exact RootHide Library inode.
FOUNDATION_EXPORT NSDictionary * _Nullable OPConfigurationArchivePerformWithLockedLibrary(NSString *operation,
    NSString * _Nullable basename, int lockedLibrary, NSString * _Nullable * _Nullable error);
NS_ASSUME_NONNULL_END
