#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// One-shot recovery only when data is missing or an interrupted transaction
// exists. Called before UIKit or the original editor reads persistent state.
BOOL OPRecoverConfigurationManagementBeforeLaunch(NSString * _Nullable * _Nullable error);
// Operations: list, backup, restore (a listed basename), and clear.
// File validation, quiescing writers, and privileged mutations belong to the
// backend. The completion is delivered on the main queue.
void OPPerformConfigurationManagement(NSString *operation, NSString * _Nullable basename,
    void (^completion)(NSDictionary * _Nullable result, NSString * _Nullable error));
NS_ASSUME_NONNULL_END
