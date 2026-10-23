#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Global across games and executables. This is device metadata only: never a
// report, input state, mapping-enable flag or assertion of a live connection.
FOUNDATION_EXPORT NSString *const OPControllerIdentityPath;
FOUNDATION_EXPORT const char *const OPControllerIdentityChangedNotification;
BOOL OPControllerIdentityTypeIsValid(NSInteger peripheralType);
// Returns {version:1, identifier:UUID, name:NSString, peripheralType:0|1|2}.
// Unknown, malformed, unsafe or missing records return nil, never a guessed 0.
NSDictionary * _Nullable OPLastKnownControllerIdentity(void);
// Caller supplies the original library's resolved type of a real peripheral:
// 0 gamepad, 1 keyboard/mouse, 2 half-controller. Do not pass editor fallback
// defaults or an unvalidated name-derived guess. Repeated observations are
// coalesced in memory; writes are atomic and shared by root/mobile (0600).
BOOL OPRememberControllerIdentity(NSString *identifier, NSString *name, NSInteger peripheralType);
NS_ASSUME_NONNULL_END
