#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
extern const char *const OPRuntimeIntentChangedNotification;

// A missing or invalid record is disabled and has no generation. Merely
// reading runtime intent never creates files or starts a service.
NSDictionary *OPMappingRuntimeIntent(void);
BOOL OPMappingRuntimeEnabled(void);
// Every explicit action commits a new generation. Success means the durable
// intent was replaced; notifications are hints and consumers re-read intent.
BOOL OPSetMappingRuntimeEnabled(BOOL enabled, NSString * _Nullable * _Nullable error);
BOOL OPStopMappingRuntime(NSString * _Nullable * _Nullable error);
NS_ASSUME_NONNULL_END
