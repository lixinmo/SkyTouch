#pragma once
#import <UIKit/UIKit.h>
#include "../shared/core/MappingEngine.hpp"

NS_ASSUME_NONNULL_BEGIN
typedef BOOL (^OPSubmitOriginalFrame)(const fsm::TouchFrame &, UIInterfaceOrientation);

// Call on the main thread after loading the original arm64 library, before
// creating any FZCentralViewController. This never creates a replacement UI.
BOOL OPInstallOriginalBridge(OPSubmitOriginalFrame submit, dispatch_block_t cancel,
                             NSString * _Nullable * _Nullable error);
void OPSetTargetOrientation(UIInterfaceOrientation orientation);
BOOL OPStartOriginalUI(NSString * _Nullable * _Nullable error);
// Invoke the verified vendor method once after controller creation for a
// hidden engine session, without relying on a visible viewDidAppear callback.
BOOL OPReloadOriginalConfiguration(NSString * _Nullable * _Nullable error);
// Reads only the original current mapping entity; never reads account data.
NSDictionary *OPOriginalCurrentConfigurationState(void);
// Before controller creation in engine and configuration sessions. Disables
// only the startup/retry auto-download; explicit account/cloud UI is unchanged.
BOOL OPDisableOriginalAutomaticCloudLoading(NSString * _Nullable * _Nullable error);
// Loads an immutable, full original FDG snapshot through the vendor parser.
BOOL OPApplyOriginalConfigurationSnapshot(NSString *fdgPath, NSInteger deviceType,
                                         NSString * _Nullable * _Nullable error);
BOOL OPApplyOriginalConfigurationSnapshotData(NSData *fdgData, NSInteger deviceType,
                                              NSString * _Nullable * _Nullable error);
// Counts calls entering the original onExecuteTouchEvent implementation. This
// is a cadence diagnostic, not a claim that any touch was submitted/delivered.
std::uint64_t OPOriginalExecuteTouchEventCount(void);
// Counter-only diagnostic; no report bytes, buttons, positions, names or IDs.
NSDictionary *OPOriginalBridgeDiagnostics(void);
id _Nullable OPOriginalController(void);
void OPStopOriginalTouches(void);
NSString *OPOriginalBridgeStatus(void);
// Internal adapter boundary: posts the original physical-touch notification
// while suppressing only its nested sendTouchEvent/flush. The event-like object
// must expose allTouches; it is never passed to UIApplication or system HID.
BOOL OPPostOriginalPhysicalEvent(id event);
NS_ASSUME_NONNULL_END
