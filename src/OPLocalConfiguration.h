#pragma once
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
// Pure local selection: no UIKit, vendor image, account archive, or networking.
// Rows: id, target, name, deviceType (0/1/2), deviceTypeName, sourceIndex,
// isCurrent (global selection), isSourceCurrent (source slot zero), mappingCount.
// IDs fingerprint the full plan + source + device type and survive reordering.
NSArray<NSDictionary *> * _Nullable OPLocalConfigurationsForTarget(NSString *target,
    NSString * _Nullable * _Nullable error);
// Rereads the library and resolves the fingerprint instead of trusting a stale
// row index. Publishes a new global snapshot without changing local.fdg. Signals
// the running supervisor; an explicitly stopped service remains stopped.
BOOL OPApplyLocalConfiguration(NSString *target,NSString *identifier,NSString *sourceDisplayName,
    NSString * _Nullable * _Nullable error);
NS_ASSUME_NONNULL_END
