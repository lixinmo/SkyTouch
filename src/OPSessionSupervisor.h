#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// A separate root process: no UIKit bootstrap, vendor image, BLE or HID client.
// Requires the same verified display-layout entitlement as the HUD. Call once
// from --original-supervisor, on the main thread, before creating UIApplication.
// A controlled UI launch may wait for the previous explicitly stopped service
// to release its singleton. The persisted attempt cancels superseded starts.
int OPRunSessionSupervisor(NSString * _Nullable launchAttempt = nil);
FOUNDATION_EXPORT const char *const OPSupervisorStopNotification;
FOUNDATION_EXPORT const char *const OPSupervisorProfileUpdatedNotification;
FOUNDATION_EXPORT NSString *const OPSupervisorStatusPath;
// Control-plane selection only; the vendor FDG bytes remain untouched.
// Configuration app atomically writes {schema:2, activeProfileTarget:bundleID},
// then posts profile-updated. Optional targets/display-name fields are history.
FOUNDATION_EXPORT NSString *const OPSupervisorConfiguredTargetsPath;
// Created/held by the mobile configuration process; root only inspects it.
FOUNDATION_EXPORT NSString *const OPSupervisorConfigurationLockPath;
BOOL OPConfigurationSessionAvailable(NSString * _Nullable * _Nullable reason);

// Managed engine invocation: --original-hud --engine-session --managed-session UUID
// --session-target bundleID. These are distinct from the manual UI-only flags.
BOOL OPManagedSessionIdentifierIsValid(NSString *identifier);
BOOL OPManagedTargetIsValid(NSString *bundleIdentifier);
NSString * _Nullable OPManagedSessionStopNotification(NSString *identifier);
NSString * _Nullable OPManagedSessionDrainedNotification(NSString *identifier);

// The child must FIRST stop all future input, cancel its physical mirrors and
// original touches, shutdown its output, and wait for cancellationPending=NO.
// Only then post this local-submission ACK and exit(0). This is not a target
// application delivery acknowledgement. Failure to post means do not exit as
// a successfully drained session. The supervisor also requires waitpid exit(0).
BOOL OPPostManagedSessionDrained(NSString *identifier, NSString * _Nullable * _Nullable error);
NS_ASSUME_NONNULL_END
