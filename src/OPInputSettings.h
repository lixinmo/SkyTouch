#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT const char *const OPInputSettingsChangedNotification;
// Editable presets relative to the common phone-motion unit. These are used
// for new settings or an explicit "use recommended value" action only.
FOUNDATION_EXPORT const double OPRecommendedPhoneMotionMultiplierX;
FOUNDATION_EXPORT const double OPRecommendedPhoneMotionMultiplierY;
// Reads never create files. Missing settings select controller mode with phone
// motion and the stable revision "legacy-default". Invalid files return
// conservative defaults with revision "invalid-settings".
// v1 scales are rebased in memory to v2, retaining the user's multipliers and
// revision. An explicit save persists v2; reading never rewrites a backup.
NSDictionary *OPReadInputSettings(void);
// Pass a complete record read above, with changed values. revision is an
// optimistic concurrency token; a successful write assigns a fresh UUID.
BOOL OPWriteInputSettings(NSDictionary *settings, NSString * _Nullable * _Nullable error);
BOOL OPPhoneModeSelected(void);
// Keyboard/mouse layouts retain their original input path; the phone-motion
// adapter supports gamepad and half-controller layouts only.
BOOL OPInputUsesPhoneMotion(NSDictionary *settings, NSInteger deviceType);
NSString *OPInputSettingsRevision(void);
NS_ASSUME_NONNULL_END
