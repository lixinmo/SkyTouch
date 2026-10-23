#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT const char *const OPInputSettingsChangedNotification;
// Reads never create files. Missing settings preserve the original controller
// mode and return the stable revision "legacy-default". Invalid files return
// conservative defaults with revision "invalid-settings".
NSDictionary *OPReadInputSettings(void);
// Pass a complete record read above, with changed values. revision is an
// optimistic concurrency token; a successful write assigns a fresh UUID.
BOOL OPWriteInputSettings(NSDictionary *settings, NSString * _Nullable * _Nullable error);
BOOL OPPhoneModeSelected(void);
NSString *OPInputSettingsRevision(void);
NS_ASSUME_NONNULL_END
