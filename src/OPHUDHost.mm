#import "OPStoragePaths.h"
// Global UIKit host follows Lessica/TrollSpeed (MIT), pinned at
// a609be260c8261ead36509c3bc4ded8479da9c40. See licenses/TrollSpeed-MIT.txt.
// This is an unvalidated iOS 17.1 port, not evidence of global touch delivery.
#import "OPHUDHost.h"
#import "OPOriginalBridge.h"
#import "OPOriginalMotionFix.h"
#import "OPOriginalMotionPersistence.h"
#import "OPOriginalMOBAEditor.h"
#import "OPOriginalBluetoothClient.h"
#import "OPInputSettings.h"
#import "OPPhoneInput.h"
#import "OPPhoneProfile.h"
#import "OPGlobalProfile.h"
#import "OPSystemTouch.h"
#import "OPOriginalContext.h"
#import "OPForegroundContext.h"
#import "OPSessionSupervisor.h"
#import "OPServicePaths.h"
#import "OPPhysicalTouchMirror.h"
#import "OPConfigurationUI.h"
#import "OPLocalSwitcherUI.h"
#import "OPRuntimeControl.h"
#import "OPBluetoothBroker.h"
#include "OPFloatingDockState.hpp"
#include "OPFloatingAnchor.hpp"
#include "OPMappingOrientation.hpp"
#include "OPFloatingPresentationState.hpp"
#include "OPFloatingLease.hpp"
#include "OPFloatingSystemGesture.hpp"
#import <CoreBluetooth/CoreBluetooth.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <notify.h>
#import <unistd.h>
#import <sys/file.h>
#import <sys/stat.h>
#import <fcntl.h>
#include <cmath>
#include <atomic>
#include <cstdio>
#include <cstring>
#include <chrono>
#include <algorithm>
#include <cerrno>
#include <cstdlib>
#include <climits>
#include <mach/mach_time.h>

static UIInterfaceOrientation OPOrientation = UIInterfaceOrientationUnknown;
// Original engine coordinates always use a logical landscape canvas. Output
// follows the real display, including a portrait SpringBoard desktop.
static UIInterfaceOrientation OPDisplayOrientation = UIInterfaceOrientationUnknown;
static OPSystemTouch *OPOutput;
static id OPOrientationObserver;
static NSMutableDictionary<NSNumber *, id> *OPHostingControllers;
static NSMutableDictionary<NSNumber *, NSDictionary *> *OPHostingAttempts;
static NSMutableDictionary<NSNumber *, UITouch *> *OPUITouches;
static id OPOriginalWindowOwner;
static Ivar OPOriginalWindowIvar;
using OPWindowPointInside=BOOL(*)(id,SEL,CGPoint,id);
using OPControllerPointGate=BOOL(*)(id,SEL,CGPoint);
static OPWindowPointInside OPOriginalWindowPointInside=nullptr,OPSuperWindowPointInside=nullptr;
static OPControllerPointGate OPOriginalControllerPointGate=nullptr;
static BOOL OPSessionAttempted=NO, OPStopping=NO, OPEventInputReady=NO;
static BOOL OPVerifyUIOnly=NO, OPEngineSession=NO;
static BOOL OPFloatingSession=NO, OPFloatingExpanded=NO, OPFloatingPreparing=NO;
static BOOL OPFloatingHidden=NO, OPFloatingDisplayAllowed=NO, OPFloatingInputReady=NO;
static BOOL OPFloatingMenuShown=NO;
static int OPFloatingLock=-1;
static pid_t OPFloatingParentPID=0;
static NSString *OPFloatingRuntimeGeneration;
static UIWindow *OPFloatingIconWindow,*OPFloatingPanelWindow,*OPFloatingErrorWindow;
static UIControl *OPFloatingWakeHandle;
static UIImageView *OPFloatingIcon;
static UIImage *OPFloatingConnectedIcon,*OPFloatingDisconnectedIcon;
static op_floating_anchor::State OPFloatingAnchor;
static op_floating_dock::State &OPFloatingDock=OPFloatingAnchor.dock;
static std::optional<op_floating_anchor::SavedPosition> OPFloatingSavedPosition;
static op_floating_presentation::State OPFloatingPresentation;
static NSString *OPFloatingSuspensionReason;
static op_floating_gesture::Tracker OPFloatingSystemGesture;
static BOOL OPFloatingLegacyPositionPending=NO;
static op_floating_dock::Point OPFloatingLegacyPosition;
static UIViewController *OPFloatingEditor;
static NSNumber *OPFloatingFinger;
static NSTimeInterval OPFloatingLastInteraction=0;
static NSString *OPFloatingError;
static NSString *const OPFloatingStatusPath=OPRuntimePath(@"com.lixinmo.skytouch.floating-status.plist");
static NSString *const OPFloatingPositionPath=OPSettingPath(@"com.lixinmo.skytouch.floating-position.plist");
static NSString *const OPFloatingLockPath=OPRuntimePath(@"com.lixinmo.skytouch.floating.lock");
static void OPFloatingWriteStatus(void);
static void OPFloatingStart(void);
static void OPFloatingTick(void);
static void OPFloatingClose(BOOL restart,BOOL alreadyCommitted);
static NSDictionary *OPFloatingConsumeIcon(NSDictionary *snapshot);
static void OPFloatingReveal(void);
static void OPFloatingLayoutDock(BOOL animated);
static void OPFloatingRememberPosition(void);
static void OPFloatingYieldPresentation(NSString *reason);
static void OPFloatingObserveSystemGesture(NSDictionary *snapshot);
static void OPFloatingFinishIconContact(BOOL cancelled);
static BOOL OPEngineConfigurationLoaded=NO;
static NSDictionary *OPActiveGlobalProfile;
static NSDictionary *OPSessionInputSettings;
static BOOL OPInputRevisionAccepted=YES;
static BOOL OPUsesPhoneControls(void) { return [OPSessionInputSettings[@"mode"] isEqual:@"phone"]; }
static BOOL OPUsesPhoneMotion(void) {
    return OPInputUsesPhoneMotion(OPSessionInputSettings,
        OPActiveGlobalProfile ? [OPActiveGlobalProfile[@"deviceType"] integerValue] : -1);
}
static BOOL OPCurrentInputReady(void) {
    // Both modes using phone motion share its source/worker readiness. A live
    // BLE lease alone must not reopen output after the motion worker failed.
    return OPUsesPhoneMotion() ? OPPhoneInputReady() : OPOriginalBluetoothClientReady();
}
static BOOL OPImportedProfileDefaults=NO, OPExportedProfileDefaults=NO;
static NSString *OPForcedTargetBundle;
static NSString *OPManagedSessionID;
static pid_t OPManagedParentPID=0;
static BOOL OPShutdownMayExit=NO, OPShutdownPollScheduled=NO;
static int OPShutdownExitCode=0;
static double OPShutdownNotBefore=0, OPShutdownLastReport=0;
static NSTimer *OPManagedParentTimer;
static NSString *OPSessionTarget;
static NSDictionary *OPLatestForeground;
static BOOL OPContextAllowed=NO, OPCancellingContext=NO, OPContextRejectionReported=NO;
static uint64_t OPContextCheckedNs=0;
static uint64_t OPFrameSinkCalls=0,OPFrameSinkTotalNs=0,OPFrameSinkMaxNs=0,OPStaleContextFrames=0;
static uint64_t OPContextSampleLastNs=0,OPContextSampleMaxNs=0,OPStaleContextAgeNs=0;
static uint64_t OPHostNowNs(void) {
    static const mach_timebase_info_data_t scale=[] {mach_timebase_info_data_t value{};mach_timebase_info(&value);return value;}();
    return (uint64_t)(((__uint128_t)mach_continuous_time()*scale.numer)/scale.denom);
}
static BOOL OPEngineContextFresh(void) {
    const uint64_t now=OPHostNowNs();
    return OPContextCheckedNs && now>=OPContextCheckedNs && now-OPContextCheckedNs<=250*NSEC_PER_MSEC;
}
struct OPFrameSinkTiming {
    uint64_t start=OPHostNowNs();
    ~OPFrameSinkTiming() {
        uint64_t elapsed=OPHostNowNs()-start;++OPFrameSinkCalls;OPFrameSinkTotalNs+=elapsed;
        OPFrameSinkMaxNs=std::max(OPFrameSinkMaxNs,elapsed);
    }
};
static NSUInteger OPBlockedFrames=0;
static NSString *OPStage;
static int OPInstanceLock=-1;
static uint32_t (*OPHIDType)(const void *)=nullptr;
static CFIndex (*OPHIDInteger)(const void *,uint32_t)=nullptr;
static CFArrayRef (*OPHIDChildren)(const void *)=nullptr;
using OPInboundCallback=void(*)(void *,void *,void *,const void *);
static CFTypeRef OPInboundMonitor=nullptr;
static void (*OPInboundUnregister)(CFTypeRef)=nullptr;
static void (*OPInboundUnschedule)(CFTypeRef,CFRunLoopRef,CFStringRef)=nullptr;
static BOOL OPInboundMonitorScheduled=NO;
static std::atomic<uint64_t> OPInboundCallbackCount{0};
static NSArray<NSDictionary *> *OPOwnWindowGeometry;
static NSString *OPOwnCaptureStatus=@"not-requested";
static NSString *OPOwnCaptureMethod=@"none";
static NSTimeInterval OPOwnCaptureTime=0;
static BOOL OPOwnCaptureScheduled=NO;
static std::atomic<uint64_t> OPInboundHIDFrames{0},OPInboundPhysicalPaths{0};
static uint64_t OPInboundHUDDowns=0,OPInboundHUDMisses=0,OPInboundDispatchedFrames=0,OPInboundErrors=0;
static NSString *OPInboundLastError=@"";
static NSDictionary *OPInboundLastPath;
static NSString *OPTouchesEventStatus=@"not-requested";
static BOOL OPOwnedTouchesEventCreated=NO;
static NSString *const OPOwnCapturePath=OPRuntimePath(@"com.lixinmo.skytouch.original-ui.png");
static BOOL OPInboundSignature(id object,NSString *name,const char *result,NSArray<NSString *> *arguments);
static BOOL OPValidateInboundOriginalABI(NSString **error);
static BOOL OPValidateTouchesEventABI(Class eventClass,NSString **error);
static void OPStartSessionForFrontmost(void);
static void OPCancelOwnedPhysicalInput(void);
static void OPStopInboundMonitor(void);
static void OPBeginShutdown(NSString *reason,BOOL mayExit,int exitCode);
static NSDictionary *OPOriginalBluetoothState(void);
static void OPInboundRecordError(NSString *reason) {
    ++OPInboundErrors; OPInboundLastError=[reason copy] ?: @"unknown";
}
static NSString *const OPStatusFile = OPRuntimePath(@"com.lixinmo.skytouch.original-status.plist");
static NSArray<UIWindow *> *OPFloatingOwnedWindows(void) {
    NSMutableArray<UIWindow *> *windows=[NSMutableArray array];
    void (^add)(UIWindow *)=^(UIWindow *window) {if(window && ![windows containsObject:window])[windows addObject:window];};
    add(OPFloatingIconWindow);add(OPFloatingPanelWindow);add(OPFloatingErrorWindow);
    for(UIWindow *window in OPConfigurationOverlayWindows())add(window);
    return windows;
}
static BOOL OPFloatingOwnsWindow(UIWindow *window) {
    for(UIWindow *owned in OPFloatingOwnedWindows())if(owned==window)return YES;
    return NO;
}

UIInterfaceOrientation OPTargetOrientation(void) { return OPOrientation; }
static void OPStatus(NSString *stage) {
    // Configuration has its own heartbeat; never overwrite engine diagnostics
    // while an icon-only process is running alongside the global mapper.
    if (OPFloatingSession) { if(stage)NSLog(@"[SkyTouch Floating] %@",stage);OPFloatingWriteStatus();return; }
    BOOL changed=stage && ![stage isEqual:OPStage];
    if (stage) OPStage=[stage copy];
    NSDictionary *configuration=OPOriginalCurrentConfigurationState();
    const BOOL selectedReady=OPEngineConfigurationLoaded && [configuration[@"valid"] boolValue] &&
        (!OPActiveGlobalProfile || [configuration[@"deviceType"] isEqual:OPActiveGlobalProfile[@"deviceType"]]);
    NSDictionary *state = @{@"stage":OPStage ?: @"", @"time":@(NSDate.date.timeIntervalSince1970),
        @"pid":@(getpid()), @"uid":@(geteuid()), @"hid":OPVerifyUIOnly ? @"UI-only：系统出站 HID 已禁用" : (OPOutput.status ?: @"尚未初始化"),
        @"frames":@(OPOutput.submittedFrameCount), @"orientation":@(OPOrientation),@"displayOrientation":@(OPDisplayOrientation),
        @"hidSource":@"independent-virtual-service",@"hidServiceID":@(OPOutput.serviceIdentifier),
        @"virtualService":OPOutput.sourceDiagnostics ?: @{},
        @"ready":@(!OPVerifyUIOnly && OPOutput.ready), @"running":@(!OPStopping), @"acceptedOnDevice":@NO,
        @"mode":OPVerifyUIOnly ? @"verify-ui-only" : OPEngineSession ? @"engine-session" : @"original-hud", @"outputDisabled":@(OPVerifyUIOnly),
        @"engineSession":@(OPEngineSession),@"globalWindowHostingEnabled":@(!OPEngineSession),
        @"engineConfigurationLoaded":@(selectedReady),@"originalConfiguration":configuration,
        @"inputMode":OPSessionInputSettings[@"mode"] ?: @"controller",@"inputReady":@(OPCurrentInputReady()),
        @"inputRevision":OPSessionInputSettings[@"revision"] ?: @"",@"phoneInput":OPPhoneInputStatus(),
        @"globalRevision":OPActiveGlobalProfile[@"revision"] ?: @"",@"globalPlanName":OPActiveGlobalProfile[@"planName"] ?: @"",
        @"configurationError":OPEngineConfigurationLoaded && !selectedReady ? @"当前方案与手柄类型不匹配，或当前方案没有有效映射。" : @"",
        @"outputTiming":@{@"sinkCalls":@(OPFrameSinkCalls),@"sinkMeanUs":@(OPFrameSinkCalls ? OPFrameSinkTotalNs/OPFrameSinkCalls/1000.0 : 0),
            @"sinkMaxUs":@(OPFrameSinkMaxNs/1000.0),@"staleContextFrames":@(OPStaleContextFrames),
            @"contextSampleLastUs":@(OPContextSampleLastNs/1000.0),@"contextSampleMaxUs":@(OPContextSampleMaxNs/1000.0),
            @"lastStaleContextAgeUs":@(OPStaleContextAgeNs/1000.0)},
        @"originalExecuteTouchEventCalls":@(OPOriginalExecuteTouchEventCount()),
        @"originalBridgeStatus":OPOriginalBridgeStatus() ?: @"",
        @"originalBridgeDiagnostics":OPOriginalBridgeDiagnostics(),
        @"motionConfigurationSync":OPOriginalMotionConfigurationFixStatus(),
        @"blockedFrames":@(OPBlockedFrames), @"targetOverride":OPForcedTargetBundle ?: @"",
        @"sessionTarget":OPSessionTarget ?: @"", @"contextMatchesSession":@(OPContextAllowed),
        @"managedSession":OPManagedSessionID ?: @"", @"supervisorPID":@(OPManagedParentPID),
        @"cancellationPending":@(OPOutput.cancellationPending),@"awaitingSupervisorExitRequest":@(OPStopping && !OPShutdownMayExit),
        @"foregroundValid":@([OPLatestForeground[@"valid"] boolValue]),
        @"foregroundReason":OPLatestForeground[@"reason"] ?: @"尚未读取显示布局",
        @"inboundRoute":OPEngineSession ? @"disabled-engine-session; independent-virtual-output-service" : @"IOHID-monitor-to-original-KIF-to-owned-UIApplication-sendEvent", @"inboundAcceptedOnDevice":@NO,
        @"physicalMirrorCount":@(OPOriginalPhysicalMirrorCount()),
        @"hosting":@{@"classAvailable":@(NSClassFromString(@"SBSAccessibilityWindowHostingController")!=Nil),
            @"hostCount":@(OPHostingControllers.count),@"attemptedContextCount":@(OPHostingAttempts.count),
            @"keyWindowIsOriginalFZ":@(OPEventInputReady && [UIApplication.sharedApplication.keyWindow isKindOfClass:NSClassFromString(@"FZUIWindow")]),
            @"globalVisibilityVerified":@NO},
        @"inbound":@{@"source":@"IOHIDEventSystemClientCreate",@"clientPresent":@(OPInboundMonitor!=nullptr),
            @"scheduledMainCommonModes":@(OPInboundMonitorScheduled),@"callbackCount":@(OPInboundCallbackCount.load()),
            @"hidFrames":@(OPInboundHIDFrames.load()),@"physicalPaths":@(OPInboundPhysicalPaths.load()),
            @"hudDowns":@(OPInboundHUDDowns),@"hudDownMisses":@(OPInboundHUDMisses),
            @"dispatchedFrames":@(OPInboundDispatchedFrames),@"errorCount":@(OPInboundErrors),
            @"ownedTouchesEventCreated":@(OPOwnedTouchesEventCreated),@"touchesEventStatus":OPTouchesEventStatus,
            @"lastError":OPInboundLastError,@"lastPath":OPInboundLastPath ?: @{}},
        @"originalWindows":OPOwnWindowGeometry ?: @[],
        @"originalBLE":OPOriginalBluetoothState(),
        @"uiOnlyScreenshot":@{@"path":OPOwnCapturePath,@"status":OPOwnCaptureStatus,@"method":OPOwnCaptureMethod,
            @"time":@(OPOwnCaptureTime),@"pid":@(getpid())}};
    [state writeToFile:OPStatusFile atomically:YES];
    if (changed) NSLog(@"[SkyTouch Original Port] %@; %@",OPStage,OPOutput.status ?: @"");
}
static id OPGet(id target, NSString *name) {
    SEL selector=NSSelectorFromString(name);
    if (![target respondsToSelector:selector]) return nil;
    return ((id(*)(id,SEL))objc_msgSend)(target,selector);
}
static BOOL OPYes(id object,SEL selector) { (void)object;(void)selector;return YES; }
static BOOL OPNo(id object,SEL selector) { (void)object;(void)selector;return NO; }

static NSDictionary *OPOwnRect(CGRect rect) {
    return @{@"x":@(rect.origin.x),@"y":@(rect.origin.y),@"width":@(rect.size.width),@"height":@(rect.size.height)};
}
static void OPCaptureOwnUI(void) {
    if (!OPVerifyUIOnly || OPFloatingSession || OPStopping) return;
    Class ownClass=NSClassFromString(@"FZUIWindow");
    UIWindow *window=nil;
    for (UIWindow *candidate in UIApplication.sharedApplication.windows.reverseObjectEnumerator) {
        if ([candidate isKindOfClass:ownClass] && !candidate.hidden && candidate.alpha>0 &&
            candidate.rootViewController.isViewLoaded && candidate.bounds.size.width>0 && candidate.bounds.size.height>0) {
            window=candidate; break;
        }
    }
    if (!window) { OPOwnCaptureStatus=@"own-FZUIWindow-not-visible"; OPStatus(nil); return; }
    @try {
        UIGraphicsImageRendererFormat *format=[UIGraphicsImageRendererFormat defaultFormat];
        format.scale=1; format.opaque=NO;
        UIGraphicsImageRenderer *renderer=[[UIGraphicsImageRenderer alloc] initWithSize:window.bounds.size format:format];
        __block BOOL drawn=NO;
        // Only this process's original FZUIWindow view tree is rendered. Never
        // call a display/screen capture API or draw the foreground game's UI.
        UIImage *image=[renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
            drawn=[window drawViewHierarchyInRect:window.bounds afterScreenUpdates:NO];
        }];
        OPOwnCaptureMethod=@"own-window-drawViewHierarchy";
        if (!drawn) {
            // UIKit plugin hosts may reject hierarchy snapshots. The fallback
            // draws only this same owned FZUIWindow's CALayer tree; it is not
            // a WindowServer/global-display screenshot or delivery evidence.
            image=[renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
                [window.layer renderInContext:context.CGContext];
            }];
            OPOwnCaptureMethod=@"own-window-CALayer-renderInContext";
        }
        NSData *png=image ? UIImagePNGRepresentation(image) : nil;
        NSError *error=nil;
        if (png.length && [png writeToFile:OPOwnCapturePath options:NSDataWritingAtomic error:&error]) {
            OPOwnCaptureTime=NSDate.date.timeIntervalSince1970;
            OPOwnCaptureStatus=@"captured-own-FZUIWindow-only";
        } else OPOwnCaptureStatus=error.localizedDescription ?: @"own-window-drawViewHierarchy-failed";
    } @catch (NSException *exception) { OPOwnCaptureStatus=[@"own-window-capture-exception:" stringByAppendingString:exception.name]; }
    OPStatus(nil);
}

static void OPLayoutWindow(UIWindow *window) {
    Class originalWindow=NSClassFromString(@"FZUIWindow");
    if (OPFloatingSession) {
        if(!OPFloatingOwnsWindow(window))return;
        if(window==OPFloatingIconWindow) {
            CGRect fixed=UIScreen.mainScreen.fixedCoordinateSpace.bounds;
            window.transform=CGAffineTransformIdentity;window.frame=fixed;window.bounds=CGRectMake(0,0,fixed.size.width,fixed.size.height);
            window.rootViewController.view.transform=CGAffineTransformIdentity;
            window.rootViewController.view.frame=window.bounds;
            window.clipsToBounds=YES;window.rootViewController.view.clipsToBounds=YES;
            OPFloatingLayoutDock(NO);
            return;
        }
        OPLayoutFloatingConfigurationWindow(window,OPDisplayOrientation);
        return;
    }
    else if (!originalWindow || ![window isKindOfClass:originalWindow]) return;
    // The global host uses fixed portrait display coordinates. UIKit may
    // create the original FZUIWindow in current landscape UIScreen.bounds;
    // rotating a landscape root inside that landscape window clips both ends.
    // Keep the owned window native and rotate only the original root view.
    CGRect fixed=UIScreen.mainScreen.fixedCoordinateSpace.bounds;
    if (fixed.size.width<=0 || fixed.size.height<=0) return;
    UIView *view=window.rootViewController.view;
    window.transform=CGAffineTransformIdentity;
    window.bounds=CGRectMake(0,0,fixed.size.width,fixed.size.height);
    window.frame=fixed;
    CGSize native=window.bounds.size;
    CGFloat angle=OPOrientation==UIInterfaceOrientationLandscapeLeft ? -M_PI_2 : OPOrientation==UIInterfaceOrientationLandscapeRight ? M_PI_2 : OPOrientation==UIInterfaceOrientationPortraitUpsideDown ? M_PI : 0;
    view.transform=CGAffineTransformIdentity;
    view.bounds=CGRectMake(0,0,UIInterfaceOrientationIsLandscape(OPOrientation) ? MAX(native.width,native.height) : MIN(native.width,native.height),
        UIInterfaceOrientationIsLandscape(OPOrientation) ? MIN(native.width,native.height) : MAX(native.width,native.height));
    view.center=CGPointMake(CGRectGetMidX(window.bounds),CGRectGetMidY(window.bounds));
    view.transform=CGAffineTransformMakeRotation(angle);
}
static void OPRetireHostedContext(NSNumber *context) {
    id host=OPHostingControllers[context];
    // Releasing the wrapper alone is not the lifecycle contract. Explicitly
    // revoke our hosted CAContext when yielding to SpringBoard system UI.
    if(OPInboundSignature(host,@"invalidate",@encode(void),@[]))
        ((void(*)(id,SEL))objc_msgSend)(host,NSSelectorFromString(@"invalidate"));
    else if(OPInboundSignature(host,@"unregisterWindowWithContextID:",@encode(void),@[@"I"]))
        ((void(*)(id,SEL,unsigned int))objc_msgSend)(host,NSSelectorFromString(@"unregisterWindowWithContextID:"),context.unsignedIntValue);
    [OPHostingControllers removeObjectForKey:context];
}
static void OPHostWindows(void) {
    if (OPStopping) return;
    if (OPEngineSession) {
        // Retain the real controller/view hierarchy for the original engine,
        // but publish no CAContext and accept no physical UI input. This is
        // this process's own window list, never the foreground application's.
        NSMutableArray *geometry=[NSMutableArray array];
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            window.hidden=YES;
            if (![window isKindOfClass:NSClassFromString(@"FZUIWindow")]) continue;
            OPLayoutWindow(window);
            [geometry addObject:@{@"class":NSStringFromClass(window.class),@"hidden":@YES,
                @"frame":OPOwnRect(window.frame),@"bounds":OPOwnRect(window.bounds),@"hostingObjectPresent":@NO}];
        }
        OPOwnWindowGeometry=geometry;
        return;
    }
    Class hostClass=NSClassFromString(@"SBSAccessibilityWindowHostingController");
    if (!OPHostingAttempts) OPHostingAttempts=[NSMutableDictionary dictionary];
    NSMutableSet *visibleContexts=[NSMutableSet set];
    for (UIWindow *window in (OPFloatingSession ? OPFloatingOwnedWindows() : UIApplication.sharedApplication.windows)) {
        if (window.hidden) continue;
        if(OPFloatingSession) {
            const double now=NSProcessInfo.processInfo.systemUptime;
            BOOL permitted=window==OPFloatingIconWindow ? OPFloatingPresentation.iconAllowed(OPFloatingDisplayAllowed,now) :
                OPFloatingPresentation.panelAllowed(OPFloatingDisplayAllowed,now);
            if(!permitted)continue;
            {
                Class cls=window.class;
                class_addMethod(object_getClass(cls),NSSelectorFromString(@"_isSystemWindow"),(IMP)OPYes,"B@:");
                class_addMethod(cls,NSSelectorFromString(@"_isWindowServerHostingManaged"),(IMP)OPNo,"B@:");
                class_addMethod(cls,NSSelectorFromString(@"_isSecure"),(IMP)OPYes,"B@:");
                class_addMethod(cls,NSSelectorFromString(@"_shouldCreateContextAsSecure"),(IMP)OPYes,"B@:");
            }
        }
        OPLayoutWindow(window);
        SEL contextSelector=NSSelectorFromString(@"_contextId");
        if (![window respondsToSelector:contextSelector]) continue;
        unsigned int context=((unsigned int(*)(id,SEL))objc_msgSend)(window,contextSelector);
        if (!context) continue;
        [visibleContexts addObject:@(context)];
        if (OPHostingControllers[@(context)]) continue;
        id host=[[hostClass alloc] init];
        SEL registration=NSSelectorFromString(@"registerWindowWithContextID:atLevel:");
        OPHostingAttempts[@(context)]=@{@"objectCreated":@(host!=nil),
            @"registrationAvailable":@([host respondsToSelector:registration]),@"registrationInvoked":@NO,@"registrationReturned":@NO};
        if (![host respondsToSelector:registration]) continue;
        const double level=10000100.0+window.windowLevel;
        OPHostingAttempts[@(context)]=@{@"objectCreated":@YES,@"registrationAvailable":@YES,
            @"registrationInvoked":@YES,@"registrationReturned":@NO};
        ((void(*)(id,SEL,unsigned int,double))objc_msgSend)(host,registration,context,level);
        OPHostingControllers[@(context)]=host;
        OPHostingAttempts[@(context)]=@{@"objectCreated":@YES,@"registrationAvailable":@YES,
            @"registrationInvoked":@YES,@"registrationReturned":@YES};
    }
    for (NSNumber *context in OPHostingControllers.allKeys)
        if (![visibleContexts containsObject:context]) OPRetireHostedContext(context);
    NSMutableArray *geometry=[NSMutableArray array];
    Class ownClass=NSClassFromString(@"FZUIWindow");
    BOOL hasVisibleOwnWindow=NO;
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (![window isKindOfClass:ownClass]) continue;
        UIViewController *controller=OPFloatingSession ? OPFloatingWindowContentController(window) : window.rootViewController;
        UIView *root=controller.isViewLoaded ? controller.view : nil;
        SEL contextSelector=NSSelectorFromString(@"_contextId");
        const unsigned int context=[window respondsToSelector:contextSelector] ?
            ((unsigned int(*)(id,SEL))objc_msgSend)(window,contextSelector) : 0;
        [geometry addObject:@{@"class":NSStringFromClass(window.class),@"frame":OPOwnRect(window.frame),
            @"bounds":OPOwnRect(window.bounds),@"hidden":@(window.hidden),@"alpha":@(window.alpha),@"level":@(window.windowLevel),
            @"rootViewLoaded":@(root!=nil),@"rootViewFrame":OPOwnRect(root ? root.frame : CGRectZero),
            @"rootViewBounds":OPOwnRect(root ? root.bounds : CGRectZero),@"contextID":@(context),
            @"hostingObjectPresent":@(OPHostingControllers[@(context)]!=nil),
            @"hostingRegistration":OPHostingAttempts[@(context)] ?: @{},@"isKeyWindow":@(window.isKeyWindow)}];
        hasVisibleOwnWindow=hasVisibleOwnWindow || (!window.hidden && window.alpha>0 && root!=nil);
    }
    OPOwnWindowGeometry=[geometry copy];
    if (OPVerifyUIOnly && !OPFloatingSession && hasVisibleOwnWindow && !OPOwnCaptureScheduled) {
        OPOwnCaptureScheduled=YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,350*NSEC_PER_MSEC),dispatch_get_main_queue(),^{ OPCaptureOwnUI(); });
    }
}
static void OPApplyOrientation(UIInterfaceOrientation orientation) {
    if (OPStopping) return;
    if (orientation<1 || orientation>4) orientation=UIInterfaceOrientationUnknown;
    if (OPFloatingSession) {
        if(orientation==UIInterfaceOrientationUnknown)return;
        if(OPDisplayOrientation==orientation)return;
        OPFloatingSystemGesture.reset();
        if(OPFloatingPresentation.systemGesture)
            OPFloatingPresentation.endSystemGesture(NSProcessInfo.processInfo.systemUptime);
        OPCancelOwnedPhysicalInput();OPFloatingFinger=nil;
        OPDisplayOrientation=orientation;OPOrientation=UIInterfaceOrientationLandscapeLeft;
        OPSetFloatingConfigurationDisplayOrientation(orientation);
        if(OPOriginalController())OPSetTargetOrientation(UIInterfaceOrientationLandscapeLeft);
        for(UIWindow *window in UIApplication.sharedApplication.windows)OPLayoutWindow(window);
        OPHostWindows();return;
    }
    if (OPEngineSession) {
        if (orientation==UIInterfaceOrientationUnknown) return;
        if (OPDisplayOrientation==orientation && OPOrientation==UIInterfaceOrientationLandscapeLeft) return;
        if(OPUsesPhoneMotion()) {
            OPSetPhoneInputActive(NO);
            OPSetPhoneInputOrientation((UIInterfaceOrientation)op::mapping::canonicalLandscapeOrientation((int)orientation));
        }
        OPStopOriginalTouches(); OPCancelOwnedPhysicalInput(); [OPOutput reset];
        OPDisplayOrientation=orientation;
        OPOrientation=UIInterfaceOrientationLandscapeLeft;
        OPSetTargetOrientation(OPOrientation);
        for (UIWindow *window in UIApplication.sharedApplication.windows) OPLayoutWindow(window);
        OPHostWindows(); return;
    }
    if (OPOrientation == orientation) return;
    OPCancelOwnedPhysicalInput();
    [OPOutput reset]; OPDisplayOrientation=orientation; OPOrientation=orientation; OPSetTargetOrientation(orientation);
    for (UIWindow *window in UIApplication.sharedApplication.windows) OPLayoutWindow(window);
    OPHostWindows();
}
static NSString *OPContextBundle(NSDictionary *snapshot) {
    id bundle=snapshot[@"bundleIdentifier"];
    return [snapshot[@"valid"] boolValue] && [bundle isKindOfClass:NSString.class] && [bundle length] ? bundle : nil;
}
static BOOL OPContextMatchesSession(NSDictionary *snapshot) {
    if (OPEngineSession)
        return OPSessionTarget && OPContextAllowed && OPEngineContextFresh();
    NSString *bundle=OPContextBundle(snapshot);
    UIInterfaceOrientation orientation=(UIInterfaceOrientation)[snapshot[@"orientation"] integerValue];
    return OPSessionTarget && [bundle isEqualToString:OPSessionTarget] && UIInterfaceOrientationIsLandscape(orientation);
}
static void OPRejectSessionContext(void) {
    OPContextAllowed=NO;
    if(OPUsesPhoneMotion())OPSetPhoneInputActive(NO);
    if (OPCancellingContext) return;
    OPCancellingContext=YES;
    OPStopOriginalTouches();
    OPCancelOwnedPhysicalInput();
    OPCancellingContext=NO;
    if (!OPContextRejectionReported) {
        OPContextRejectionReported=YES;
        OPStatus(OPEngineSession ? @"配置界面、锁屏或显示状态暂不可用，当前方案触点已取消并暂停" :
            @"当前前台或方向不再匹配原配置目标，触点已取消；返回该目标或重新启动宿主");
    }
}
static void OPHandleForegroundContext(NSDictionary *snapshot) {
    if (OPStopping) return;
    if(OPFloatingSession) {
        const double now=NSProcessInfo.processInfo.systemUptime;
        const bool wasIconAllowed=OPFloatingPresentation.iconAllowed(OPFloatingDisplayAllowed,now);
        const bool wasPanelAllowed=OPFloatingPresentation.panelAllowed(OPFloatingDisplayAllowed,now);
        OPLatestForeground=[snapshot copy];
        BOOL allowed=OPGlobalOutputContextAllowed(snapshot,nil);
        // Page changes are not evidence of system UI. In particular, focus
        // metadata and unverified AX answers must never latch all input off.
        // Only lock, explicit backgrounding and confirmed edge swipes yield.
        if(OPFloatingPresentation.systemGesture && now-OPFloatingSystemGesture.lastActiveTime()>2) {
            OPFloatingSystemGesture.reset();OPFloatingPresentation.endSystemGesture(now);
        }
        if((wasPanelAllowed && !OPFloatingPresentation.panelAllowed(allowed,now)) ||
           (wasIconAllowed && !OPFloatingPresentation.iconAllowed(allowed,now)))
            OPCancelOwnedPhysicalInput();
        OPFloatingDisplayAllowed=allowed;
        OPApplyOrientation((UIInterfaceOrientation)[snapshot[@"orientation"] integerValue]);
        OPHostWindows();return;
    }
    if (OPEngineSession) {
        OPLatestForeground=[snapshot copy];
        if(OPSessionInputSettings && ![OPSessionInputSettings[@"revision"] isEqual:OPInputSettingsRevision()]) {
            // Parent drains this process before creating the new binding/mode.
            // Never route the up half of an old press with a new binding table.
            OPRejectSessionContext();return;
        }
        const BOOL allowed=OPGlobalOutputContextAllowed(snapshot,nil) && OPConfigurationSessionAvailable(nil);
        OPContextCheckedNs=[snapshot[@"readStartedMonotonicNs"] unsignedLongLongValue];
        const uint64_t now=OPHostNowNs();
        OPContextSampleLastNs=OPContextCheckedNs && now>=OPContextCheckedNs ? now-OPContextCheckedNs : UINT64_MAX;
        OPContextSampleMaxNs=std::max(OPContextSampleMaxNs,OPContextSampleLastNs);
        if (!allowed || !OPEngineContextFresh()) {
            OPContextAllowed=NO;
            if (OPSessionTarget) OPRejectSessionContext();
            return;
        }
        // A normal foreground bundle change does not cancel or switch the
        // chosen profile. Only a real display rotation cancels old contacts.
        OPApplyOrientation((UIInterfaceOrientation)[snapshot[@"orientation"] integerValue]);
        if (OPSessionTarget) {
            OPContextAllowed=YES;
            if (OPContextRejectionReported) {
                OPContextRejectionReported=NO;
                OPStatus(@"当前方案已恢复全局系统触屏；触点需重新按下");
            }
        }
        OPStartSessionForFrontmost();
        if(OPUsesPhoneMotion()) {
            OPSetPhoneInputOrientation((UIInterfaceOrientation)op::mapping::canonicalLandscapeOrientation((int)OPDisplayOrientation));
            OPSetPhoneInputActive(OPContextAllowed && OPEngineConfigurationLoaded && OPOutput.ready && !OPStopping);
        }
        return;
    }
    NSString *previousBundle=OPContextBundle(OPLatestForeground);
    const BOOL previouslyValid=[OPLatestForeground[@"valid"] boolValue];
    OPLatestForeground=[snapshot copy];
    NSString *current=OPContextBundle(snapshot);
    const BOOL changed=previouslyValid!=[snapshot[@"valid"] boolValue] ||
        (previousBundle!=current && ![previousBundle isEqualToString:current]);
    if (OPSessionTarget && !OPContextMatchesSession(snapshot)) {
        if (!(OPVerifyUIOnly && OPForcedTargetBundle) || OPContextAllowed || changed) OPRejectSessionContext();
    } else if (OPSessionTarget) {
        OPContextAllowed=YES;
        if (OPContextRejectionReported) {
            OPContextRejectionReported=NO;
            OPStatus(@"前台已回到当前原配置目标；触点需重新按下");
        }
    }
    // A forced Probe UI-only session may remain usable while the verification
    // shell is foreground; its output backend does not exist. Normal sessions
    // follow only a known current display-layout orientation. An unknown
    // snapshot cancels touches but preserves the last known UI direction:
    // original checkOrientation hides floating views one-way when non-landscape.
    // A real, known portrait orientation still retains that original behavior.
    if (current) OPApplyOrientation((UIInterfaceOrientation)[snapshot[@"orientation"] integerValue]);
    OPStartSessionForFrontmost();
}
static void OPStartSessionForFrontmost(void) {
    if (OPSessionAttempted || OPStopping || !OPInputRevisionAccepted || !UIInterfaceOrientationIsLandscape(OPOrientation)) return;
    if (OPManagedSessionID && getppid()!=OPManagedParentPID) {
        OPBeginShutdown(@"监督器已退出；取消原宿主触点后退出",YES,0); return;
    }
    NSDictionary *snapshot=OPForegroundContextSnapshot();
    OPLatestForeground=[snapshot copy];
    NSString *frontmost=OPContextBundle(snapshot);
    // UI-only can inspect the original UI using our Probe's configuration
    // context while the shell remains foreground. Output stays impossible.
    if (OPEngineSession && (!OPForcedTargetBundle || !OPGlobalOutputContextAllowed(snapshot,nil) || !OPConfigurationSessionAvailable(nil))) return;
    if (!OPEngineSession && OPForcedTargetBundle && !OPVerifyUIOnly && ![frontmost isEqualToString:OPForcedTargetBundle]) return;
    if (!OPEngineSession && !(OPVerifyUIOnly && OPForcedTargetBundle) &&
        (!frontmost || !UIInterfaceOrientationIsLandscape((UIInterfaceOrientation)[snapshot[@"orientation"] integerValue]))) return;
    NSString *target=OPForcedTargetBundle ?: frontmost;
    if (!target.length || [target isEqualToString:@"com.apple.springboard"] ||
        [target isEqualToString:@"com.lixinmo.skytouch.app"]) return;
    if (![target rangeOfString:@"^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$" options:NSRegularExpressionSearch].length) return;
    OPSessionAttempted=YES; OPSessionTarget=[target copy];
    if(OPEngineSession) {OPContextCheckedNs=[snapshot[@"readStartedMonotonicNs"] unsignedLongLongValue];OPContextAllowed=OPEngineContextFresh();}
    else OPContextAllowed=OPContextMatchesSession(snapshot);
    NSString *error=nil;
    if (OPEngineSession) {
        OPActiveGlobalProfile=OPReadGlobalProfile(&error);
        if(!OPActiveGlobalProfile || ![OPActiveGlobalProfile[@"activeProfileTarget"] isEqual:target]) {
            OPBeginShutdown(error ?: @"全局方案在启动时已改变，请重新启动映射。",YES,69);return;
        }
        // A committed plan includes its own mapping preferences. Do not let
        // a later editor/download change the plan already selected globally.
        // The editable source mirror is deliberately not read here: the
        // verified revision owns all defaults needed by this session.
        NSDictionary *values=OPActiveGlobalProfile[@"defaults"];
        for(NSString *key in @[@"changeConfiguration",@"isFirstDown",@"isUpdateDown",@"firstPointA_x",@"firstPointA_y",@"1800"]) {
            if(values[key])[NSUserDefaults.standardUserDefaults setObject:values[key] forKey:key];
            else [NSUserDefaults.standardUserDefaults removeObjectForKey:key];
        }
        if (![NSUserDefaults.standardUserDefaults synchronize]) {
            OPBeginShutdown(@"全局方案的映射偏好未能加载；未启动触屏输出。",YES,69);return;
        }
        OPImportedProfileDefaults=YES;
    }
    NSString *vendor=[OPApplicationBundlePath() stringByAppendingPathComponent:@"Original/flydigi.dylib"];
    OPStatus([NSString stringWithFormat:@"原库会话：准备 dlopen；目标 %@",target]);
    void *library=dlopen(vendor.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL);
    if (!library) { OPBeginShutdown([NSString stringWithFormat:@"原库加载失败：%s",dlerror()],YES,69);return; }
    if (!OPInstallOriginalMotionPersistenceFix(&error)) { OPBeginShutdown(error,YES,69);return; }
    OPStatus(@"原库会话：原始二进制已加载");
    NSString *documents=OPOriginalDocumentsForTarget(target);
    const BOOL contextReady=OPEngineSession && OPUsesPhoneControls() ?
        OPConfigureOriginalPhoneContext(library,target,OPManagedSessionID,&error) :
        OPConfigureOriginalContext(library,target,documents,&error);
    if (!contextReady) { OPBeginShutdown(error,YES,69);return; }
    if (!OPInstallOriginalMotionConfigurationFix(&error)) { OPBeginShutdown(error,YES,69);return; }
    if (!OPInstallOriginalMOBAEditor(&error)) { OPBeginShutdown(error,YES,69);return; }
    OPStatus(@"原库会话：固定配置上下文已设置");
    Class windowClass=NSClassFromString(@"FZUIWindow");
    if (!windowClass) { OPBeginShutdown(@"原 FZUIWindow 类不可用",YES,69);return; }
    if (!OPEngineSession) {
        class_addMethod(object_getClass(windowClass),NSSelectorFromString(@"_isSystemWindow"),(IMP)OPYes,"B@:");
        class_addMethod(windowClass,NSSelectorFromString(@"_isWindowServerHostingManaged"),(IMP)OPNo,"B@:");
        class_addMethod(windowClass,NSSelectorFromString(@"_isSecure"),(IMP)OPYes,"B@:");
        class_addMethod(windowClass,NSSelectorFromString(@"_shouldCreateContextAsSecure"),(IMP)OPYes,"B@:");
    }
    if (!OPInstallOriginalBridge(^BOOL(const fsm::TouchFrame &frame,UIInterfaceOrientation orientation) {
        OPFrameSinkTiming timing;
        if (OPVerifyUIOnly) {
            ++OPBlockedFrames;
            OPStatus(@"UI-only：已拦截原引擎触点，未发送任何系统出站 HID");
            return NO;
        }
        if (OPStopping || (OPEngineSession && (!OPEngineConfigurationLoaded || !OPCurrentInputReady()))) return NO;
        if(OPEngineSession) {
            NSDictionary *selection=OPOriginalCurrentConfigurationState();
            if(![selection[@"valid"] boolValue] || ![selection[@"deviceType"] isEqual:OPActiveGlobalProfile[@"deviceType"]]) {
                OPStopOriginalTouches();OPStatus(@"当前映射布局与全局方案不符，请重新应用对应方案。");return NO;
            }
        }
        // The profile stays fixed in this process while its output applies to
        // every unlocked screen. Configuration UI/lease still pause output.
        // The modern display observer updates the gate on transitions, with
        // a 100ms bounded fallback for lock/lease changes. Do not synchronously
        // query FBS and open/flock the same file twice on EVERY HID frame.
        // A stalled observer expires after 250ms; no stale permission persists.
        NSDictionary *current=OPLatestForeground;
        if(OPEngineSession) {
            if(!OPEngineContextFresh()) {
                ++OPStaleContextFrames;OPStaleContextAgeNs=OPContextCheckedNs ? OPHostNowNs()-OPContextCheckedNs : 0;
                OPRejectSessionContext();return NO;
            }
        } else {
            current=OPForegroundContextSnapshot();OPHandleForegroundContext(current);
        }
        if (!OPContextMatchesSession(current) ||
            (OPEngineSession ? orientation!=UIInterfaceOrientationLandscapeLeft :
                orientation!=(UIInterfaceOrientation)[current[@"orientation"] integerValue])) {
            OPRejectSessionContext(); return NO;
        }
        // The editor and engine share one landscape canvas. Portrait uses
        // the user's counter-clockwise virtual landscape, never x/y scaling
        // into a portrait aspect ratio. Real landscape follows UIKit's side.
        const UIInterfaceOrientation outputOrientation=OPEngineSession ?
            (UIInterfaceOrientation)op::mapping::canonicalLandscapeOrientation((int)OPDisplayOrientation) : orientation;
        BOOL sent=[OPOutput dispatchFrame:frame orientation:outputOrientation];
        if (!sent) OPStatus(OPOutput.status ?: @"系统触点提交失败");
        return sent;
    }, ^{ [OPOutput reset]; }, &error)) { OPBeginShutdown(error,YES,69);return; }
    const BOOL inputInstalled=OPUsesPhoneControls() ? OPInstallPhoneInput(&error) : OPInstallOriginalBluetoothClient(&error);
    if(!inputInstalled) {OPBeginShutdown(error,YES,69);return;}
    if(OPEngineSession && !OPDisableOriginalAutomaticCloudLoading(&error)) {
        OPBeginShutdown(error,YES,69);return;
    }
    if (!OPEngineSession && !OPValidateInboundOriginalABI(&error)) { OPBeginShutdown(error,YES,69);return; }
    OPStatus(OPEngineSession ? @"原引擎会话：系统输出桥接已安装；原UI入站及全局窗口禁用" : @"原库会话：输出桥接及入站 KIF ABI 已安装/核对");
    OPOriginalWindowOwner=OPGet(NSClassFromString(@"FLEXManager"),@"sharedManager");
    OPOriginalWindowIvar=class_getInstanceVariable(NSClassFromString(@"FLEXManager"),"_explorerWindow");
    if (!OPOriginalWindowOwner || !OPOriginalWindowIvar ||
        std::strcmp(ivar_getTypeEncoding(OPOriginalWindowIvar),"@\"FZUIWindow\"")) {
        OPBeginShutdown(@"原窗口所属实例或 _explorerWindow ABI 不符",YES,69); return;
    }
    if (!OPStartOriginalUIWithInput(!OPUsesPhoneControls(),&error)) { OPBeginShutdown(error,YES,69);return; }
    if (OPEngineSession) {
        NSInteger type=[OPActiveGlobalProfile[@"deviceType"] integerValue];
        NSData *snapshot=OPActiveGlobalProfile[@"snapshotData"];
        if(OPUsesPhoneControls())snapshot=OPPhoneRuntimeProfile(snapshot,type,&error);
        if (!snapshot || !OPApplyOriginalConfigurationSnapshotData(snapshot,type,&error)) {
            OPBeginShutdown(error,YES,69);return;
        }
        OPEngineConfigurationLoaded=YES;
        if(OPUsesPhoneMotion() && !OPStartPhoneInput(OPOriginalController(),type,OPSessionInputSettings,&error)) {
            OPBeginShutdown(error,YES,69);return;
        }
    }
    UIApplication.sharedApplication.delegate.window=object_getIvar(OPOriginalWindowOwner,OPOriginalWindowIvar);
    OPStatus(@"原库会话：原界面控制器已创建");
    OPHostWindows();
    OPStatus(OPEngineSession ? [NSString stringWithFormat:@"当前全局方案已加载（来源 %@）；系统触屏覆盖已解锁屏幕",target] :
        [NSString stringWithFormat:@"%@原库会话已载入，配置上下文固定为：%@",OPVerifyUIOnly ? @"UI-only／出站 HID 禁用；" : @"",target]);
    OPHandleForegroundContext(OPForegroundContextSnapshot());
}

@interface UIApplication (OPOriginalHostTouchesEvent)
- (UIEvent *)_touchesEvent;
@end
@interface UIEvent (OPOriginalHostTouchesEvent)
- (instancetype)_init __attribute__((objc_method_family(init)));
@end
@interface OPHUDApplication : UIApplication {
    UIEvent *_opOwnedTouchesEvent;
    BOOL _opTouchesEventAttempted;
}
@end
@implementation OPHUDApplication
- (UIInterfaceOrientation)statusBarOrientation { return OPFloatingSession ? [super statusBarOrientation] : OPOrientation; }
- (UIEvent *)_touchesEvent {
    // Only our UIApplication subclass gets this compatibility path. Preserve
    // UIKit's own object when present; no global UIApplication swizzle.
    Method base=class_getInstanceMethod(UIApplication.class,_cmd);
    NSMethodSignature *signature=base ? [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(base)] : nil;
    if (!signature || signature.numberOfArguments!=2 || std::strcmp(signature.methodReturnType,@encode(id))) {
        OPTouchesEventStatus=@"UIApplication._touchesEvent-ABI-mismatch"; return nil;
    }
    UIEvent *standard=[super _touchesEvent];
    if (standard) { OPTouchesEventStatus=@"UIKit-super-event"; return standard; }
    if (_opOwnedTouchesEvent) return _opOwnedTouchesEvent;
    if (_opTouchesEventAttempted) return nil;
    _opTouchesEventAttempted=YES;
    Class eventClass=NSClassFromString(@"UITouchesEvent");
    NSString *error=nil;
    if (!OPValidateTouchesEventABI(eventClass,&error)) { OPTouchesEventStatus=error; return nil; }
    @try {
        // iOS 17 declares _init, not an ordinary init override. Its explicit
        // init-family declaration preserves ARC's consumed-self/+1 rules.
        // The original eventWithTouches still does clear/KIF/add for each frame.
        UIEvent *candidate=[(UIEvent *)[eventClass alloc] _init];
        if (![candidate isKindOfClass:eventClass] || candidate.type!=UIEventTypeTouches) {
            OPTouchesEventStatus=@"UITouchesEvent._init-did-not-create-touch-event"; return nil;
        }
        _opOwnedTouchesEvent=candidate; OPOwnedTouchesEventCreated=YES;
        OPTouchesEventStatus=@"owned-UITouchesEvent-created-with-_init";
        return _opOwnedTouchesEvent;
    } @catch (NSException *exception) {
        OPTouchesEventStatus=[@"UITouchesEvent._init-exception:" stringByAppendingString:exception.name]; return nil;
    }
}
- (instancetype)init {
    if ((self=[super init])) {
        if (OPEngineSession) return self;
        // The independent IOHID monitor below builds the original KIF UIEvent and calls this
        // app's public sendEvent: directly. They do not enqueue into a fetcher.
        // iOS 17 has no verified _installEventRunLoopSources: implementation;
        // do not require it, instantiate an unused fetcher, or scan instructions.
        OPEventInputReady=OPInboundSignature(self,@"sendEvent:",@encode(void),@[@"@"]);
        if (!OPEventInputReady) OPStatus(@"UIApplication.sendEvent: ABI 不符，原 UI 入站尚未启动");
        else NSLog(@"[OriginalPort] direct original-KIF/sendEvent inbound selected; on-device UI interaction remains unverified");
    }
    return self;
}
@end

static BOOL OPOwnMappedFinger(CFIndex index,CFIndex identity) {
    return (index>=20 && index<=29) || (identity>=20 && identity<=29);
}
struct OPInboundFingerKinds {
    unsigned physical=0, mapped=0, visited=0;
    bool legacyMapped=false, physicalZero=false, malformed=false;
};
static void OPClassifyInboundFingers(const void *event,OPInboundFingerKinds &kinds,unsigned depth=0) {
    if (!event || depth>8 || ++kinds.visited>256) { kinds.malformed=true; return; }
    // Real iOS 17 samples: the parent is a Hand (transducerType=3), often
    // normalized to index/identity 0/0; its Finger children have type=2.
    // Count fingers only. A parent 0/0 must not turn an all-mapped frame into
    // a mixed frame or create an extra physical AX path.
    if (OPHIDType(event)==11 && OPHIDInteger(event,(11u<<16)+4)==2) {
        const CFIndex index=OPHIDInteger(event,(11u<<16)+5);
        const CFIndex identity=OPHIDInteger(event,(11u<<16)+6);
        const bool legacy=(index>=0x101 && index<=0x10a) || (identity>=0x101 && identity<=0x10a);
        if (OPOwnMappedFinger(index,identity) || legacy) {
            ++kinds.mapped; kinds.legacyMapped=kinds.legacyMapped || legacy;
        } else {
            ++kinds.physical;
            kinds.physicalZero=kinds.physicalZero || (index==0 && identity==0);
        }
    }
    CFArrayRef children=OPHIDChildren(event);
    if (!children) return;
    if (CFArrayGetCount(children)>256) { kinds.malformed=true; return; }
    for (CFIndex i=0;i<CFArrayGetCount(children);++i)
        OPClassifyInboundFingers(CFArrayGetValueAtIndex(children,i),kinds,depth+1);
}

static BOOL OPInboundSignature(id object,NSString *name,const char *result,NSArray<NSString *> *arguments) {
    SEL selector=NSSelectorFromString(name);
    if (![object respondsToSelector:selector]) return NO;
    NSMethodSignature *signature=[object methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments!=arguments.count+2 || std::strcmp(signature.methodReturnType,result)) return NO;
    for (NSUInteger i=0;i<arguments.count;++i)
        if (std::strcmp([signature getArgumentTypeAtIndex:i+2],arguments[i].UTF8String)) return NO;
    return YES;
}

static BOOL OPValidateTouchesEventABI(Class eventClass,NSString **error) {
    // https://github.com/MTACS/iOS-17-Runtime-Headers/blob/main/PrivateFrameworks/UIKitCore.framework/UITouchesEvent.h
    if (!eventClass || ![eventClass isSubclassOfClass:UIEvent.class]) {
        if (error) *error=@"UITouchesEvent-class-unavailable"; return NO;
    }
    for (NSArray *item in @[@[@"_init",@"@",@[]],@[@"_clearTouches",@"v",@[]],
        @[@"_addTouch:forDelayedDelivery:",@"v",@[@"@",@"B"]],@[@"type",@"q",@[]]]) {
        Method method=class_getInstanceMethod(eventClass,NSSelectorFromString(item[0]));
        NSMethodSignature *signature=method ? [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)] : nil;
        NSArray *arguments=item[2];
        BOOL valid=signature && signature.numberOfArguments==arguments.count+2 &&
            !std::strcmp(signature.methodReturnType,[item[1] UTF8String]);
        for (NSUInteger i=0;valid && i<arguments.count;++i)
            valid=!std::strcmp([signature getArgumentTypeAtIndex:i+2],[arguments[i] UTF8String]);
        if (!valid) { if (error) *error=[@"UITouchesEvent-ABI-mismatch:" stringByAppendingString:item[0]]; return NO; }
    }
    return YES;
}

static NSDictionary *OPOriginalBluetoothState(void) {
    NSDictionary *remote=OPOriginalBluetoothClientStatus();
    if([remote[@"installed"] boolValue])return remote;
    // Verified original metadata and getter bodies:
    // manager    0x1b8b58, @16@0:8, T@"CBCentralManager",&,N,V_manager
    // peripheral 0x1b8bc4, @16@0:8, T@"CBPeripheral",&,N,V_peripheral
    // Both getters only load their retained ivar. Never instantiate a central,
    // invoke a scan/retrieve/connect method, or enumerate nearby peripherals.
    id controller=OPOriginalController();
    if (!controller) return @{@"available":@NO,@"reason":@"original-controller-not-created"};
    if (!OPInboundSignature(controller,@"manager",@encode(id),@[]) ||
        !OPInboundSignature(controller,@"peripheral",@encode(id),@[]))
        return @{@"available":@NO,@"reason":@"original-BLE-getter-ABI-mismatch"};
    @try {
        id managerObject=OPGet(controller,@"manager"), peripheralObject=OPGet(controller,@"peripheral");
        if ((managerObject && ![managerObject isKindOfClass:CBCentralManager.class]) ||
            (peripheralObject && ![peripheralObject isKindOfClass:CBPeripheral.class]))
            return @{@"available":@NO,@"reason":@"original-BLE-property-class-mismatch"};
        CBCentralManager *manager=managerObject;
        CBPeripheral *peripheral=peripheralObject;
        NSMutableDictionary *state=[@{@"available":@YES,@"managerPresent":@(manager!=nil),
            @"peripheralPresent":@(peripheral!=nil)} mutableCopy];
        if (manager) {
            const CBManagerState value=manager.state;
            NSString *name=@"unrecognized";
            switch (value) {
                case CBManagerStateUnknown: name=@"unknown"; break;
                case CBManagerStateResetting: name=@"resetting"; break;
                case CBManagerStateUnsupported: name=@"unsupported"; break;
                case CBManagerStateUnauthorized: name=@"unauthorized"; break;
                case CBManagerStatePoweredOff: name=@"poweredOff"; break;
                case CBManagerStatePoweredOn: name=@"poweredOn"; break;
            }
            state[@"state"]=@(value); state[@"stateName"]=name;
            state[@"scanning"]=@(manager.isScanning);
        }
        if (peripheral) {
            const CBPeripheralState value=peripheral.state;
            NSString *name=@"unrecognized";
            switch (value) {
                case CBPeripheralStateDisconnected: name=@"disconnected"; break;
                case CBPeripheralStateConnecting: name=@"connecting"; break;
                case CBPeripheralStateConnected: name=@"connected"; break;
                case CBPeripheralStateDisconnecting: name=@"disconnecting"; break;
            }
            state[@"connectionState"]=@(value); state[@"connectionStateName"]=name;
            state[@"delegateIsOriginalController"]=@(peripheral.delegate==controller);
            // Inspect only the service/characteristic schema already discovered
            // by the original controller. Never read values or scan/connect here.
            NSMutableArray *services=[NSMutableArray array];
            for (CBService *service in peripheral.services) {
                if (services.count>=16) break;
                NSMutableArray *characteristics=[NSMutableArray array];
                for (CBCharacteristic *characteristic in service.characteristics) {
                    if (characteristics.count>=32) break;
                    [characteristics addObject:@{@"uuid":characteristic.UUID.UUIDString ?: @"",
                        @"properties":@(characteristic.properties),@"notifying":@(characteristic.isNotifying)}];
                }
                [services addObject:@{@"uuid":service.UUID.UUIDString ?: @"",@"characteristics":characteristics}];
            }
            state[@"discoveredServices"]=services;
            // Only the original library's currently connected controller is
            // named. Do not expose a stale remembered device after disconnect.
            if (value==CBPeripheralStateConnected) state[@"connectedName"]=peripheral.name ?: @"";
        }
        return state;
    } @catch (NSException *exception) {
        return @{@"available":@NO,@"reason":@"original-BLE-status-read-exception",@"exception":exception.name};
    }
}

static BOOL OPWindowPointInsideInOriginalCoordinates(id object,SEL command,CGPoint point,id event) {
    UIWindow *window=object;
    if(OPFloatingSession && !OPFloatingPresentation.panelAllowed(OPFloatingDisplayAllowed,NSProcessInfo.processInfo.systemUptime))return NO;
    UIViewController *owner=OPFloatingSession ? OPFloatingWindowContentController(window) : window.rootViewController;
    Class originalController=NSClassFromString(@"FZCentralViewController");
    if (![owner isKindOfClass:originalController] || !owner.isViewLoaded ||
        !OPOriginalControllerPointGate || !OPSuperWindowPointInside) return NO;
    UIView *root=owner.view;
    const CGPoint logical=[root convertPoint:point fromView:window];
    if (!std::isfinite(logical.x) || !std::isfinite(logical.y)) return NO;
    // Original FZUIWindow (0x18cf44..18d03c) is exactly a vendor gate followed
    // by [super pointInside:withEvent:]. FLEXManager only applies old injected
    // app orientation fixes (including special SNK prefixes) before forwarding
    // to this original controller gate. Our explicit root conversion replaces
    // that coordinate adaptation; every original button/dialog/edit test stays
    // inside the untouched shouldReceiveTouchAtWindowPoint: implementation.
    if (!OPOriginalControllerPointGate(owner,NSSelectorFromString(@"shouldReceiveTouchAtWindowPoint:"),logical)) return NO;
    // UIKit's bounds test and subsequent child hitTest conversion must still
    // see the actual native window point, never the rotated logical point.
    return OPSuperWindowPointInside(window,command,point,event);
}

static BOOL OPValidateInboundOriginalABI(NSString **error) {
    // The original eventWithTouches: (0x18ef0c) performs _clearTouches,
    // kif_setEventWithTouches: and _addTouch:forDelayedDelivery: in that order.
    // Reuse it so each complete multi-touch frame has matching KIF HID data.
    Class controller=NSClassFromString(@"FZCentralViewController");
    Class window=NSClassFromString(@"FZUIWindow");
    NSArray *requirements=@[
        @[UITouch.class,@"initAtPoint:inWindow:",@"@",@[[NSString stringWithUTF8String:@encode(CGPoint)],@"@"]],
        @[UITouch.class,@"setLocationInWindow:",@"v",@[[NSString stringWithUTF8String:@encode(CGPoint)]]],
        @[UITouch.class,@"setPhaseAndUpdateTimestamp:",@"v",@[[NSString stringWithUTF8String:@encode(NSInteger)]]],
        @[UITouch.class,@"_setIsFirstTouchForView:",@"v",@[@"B"]],
        @[controller ?: NSObject.class,@"eventWithTouches:",@"@",@[@"@"]],
        @[controller ?: NSObject.class,@"shouldReceiveTouchAtWindowPoint:",@"B",@[[NSString stringWithUTF8String:@encode(CGPoint)]]],
        @[window ?: NSObject.class,@"pointInside:withEvent:",@"B",@[[NSString stringWithUTF8String:@encode(CGPoint)],@"@"]],
        @[UIWindow.class,@"pointInside:withEvent:",@"B",@[[NSString stringWithUTF8String:@encode(CGPoint)],@"@"]]
    ];
    for (NSArray *item in requirements) {
        Method method=class_getInstanceMethod(item[0],NSSelectorFromString(item[1]));
        NSMethodSignature *signature=method ? [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)] : nil;
        NSArray *arguments=item[3];
        BOOL good=signature && signature.numberOfArguments==arguments.count+2 && !std::strcmp(signature.methodReturnType,[item[2] UTF8String]);
        for (NSUInteger index=0;good && index<arguments.count;++index)
            good=!std::strcmp([signature getArgumentTypeAtIndex:index+2],[arguments[index] UTF8String]);
        if (!good) { if (error) *error=[@"原 HUD 入站接口 ABI 不符：" stringByAppendingString:item[1]]; return NO; }
    }
    if (class_getSuperclass(window)!=UIWindow.class) { if (error) *error=@"原 FZUIWindow 超类不是已核对的 UIWindow"; return NO; }
    if (!OPOriginalWindowPointInside) {
        Method method=class_getInstanceMethod(window,@selector(pointInside:withEvent:));
        OPSuperWindowPointInside=(OPWindowPointInside)class_getMethodImplementation(UIWindow.class,@selector(pointInside:withEvent:));
        OPOriginalControllerPointGate=(OPControllerPointGate)class_getMethodImplementation(controller,NSSelectorFromString(@"shouldReceiveTouchAtWindowPoint:"));
        OPOriginalWindowPointInside=(OPWindowPointInside)method_setImplementation(method,(IMP)OPWindowPointInsideInOriginalCoordinates);
        if (!OPOriginalWindowPointInside || !OPSuperWindowPointInside || !OPOriginalControllerPointGate ||
            method_getImplementation(method)!=(IMP)OPWindowPointInsideInOriginalCoordinates) {
            if (OPOriginalWindowPointInside) method_setImplementation(method,(IMP)OPOriginalWindowPointInside);
            if (error) *error=@"原窗口坐标入口安装核验失败";
            return NO;
        }
    }
    return YES;
}

static void OPInboundSetPhase(UITouch *touch,UITouchPhase phase) {
    ((void(*)(id,SEL,NSInteger))objc_msgSend)(touch,NSSelectorFromString(@"setPhaseAndUpdateTimestamp:"),phase);
}
static BOOL OPInboundOwnTouch(UITouch *touch) {
    if(OPFloatingSession)return touch.window && touch.window!=OPFloatingIconWindow &&
        OPFloatingOwnsWindow(touch.window);
    Class own=NSClassFromString(@"FZUIWindow");
    return own && [touch.window isKindOfClass:own];
}
static void OPInboundDeliverFrame(void) {
    if (!OPUITouches.count) return;
    id controller=OPOriginalController();
    if (!controller) { [OPUITouches removeAllObjects]; return; }
    NSDictionary *frame=[OPUITouches copy];
    for (UITouch *touch in frame.allValues) {
        if (!OPInboundOwnTouch(touch)) { OPInboundRecordError(@"HUD touch lost its owned FZUIWindow"); [OPUITouches removeAllObjects]; return; }
    }
    // The original _kif_IOHIDEventWithTouches calls indexOfObject: (0x6e04cc),
    // so this must remain an ordered NSArray, not NSSet. Stable key order also
    // makes each frame's KIF child ordering deterministic.
    NSMutableArray<UITouch *> *ordered=[NSMutableArray arrayWithCapacity:frame.count];
    for (NSNumber *key in [frame.allKeys sortedArrayUsingSelector:@selector(compare:)]) [ordered addObject:frame[key]];
    id uiEvent=((id(*)(id,SEL,id))objc_msgSend)(controller,NSSelectorFromString(@"eventWithTouches:"),ordered);
    if (![uiEvent isKindOfClass:UIEvent.class]) { OPInboundRecordError(@"Original eventWithTouches did not return UIEvent"); [OPUITouches removeAllObjects]; return; }
    [UIApplication.sharedApplication sendEvent:uiEvent];
    ++OPInboundDispatchedFrames;
    // Deliver all terminal phases in this frame BEFORE removing any finger.
    // All surviving fingers become Stationary together, not one path at a time.
    for (NSNumber *key in frame) {
        UITouch *touch=frame[key];
        if (touch.phase==UITouchPhaseEnded || touch.phase==UITouchPhaseCancelled) [OPUITouches removeObjectForKey:key];
        else OPInboundSetPhase(touch,UITouchPhaseStationary);
    }
}
static void OPInboundCancelAll(void) {
    for (UITouch *touch in OPUITouches.allValues) OPInboundSetPhase(touch,UITouchPhaseCancelled);
    @try { OPInboundDeliverFrame(); }
    @catch (__unused NSException *exception) { /* Clear local tracking even if the original UI throws. */ }
    [OPUITouches removeAllObjects];
}
static void OPCancelOwnedPhysicalInput(void) {
    if(OPFloatingSession){OPFloatingFinger=nil;OPFloatingDock.cancel();OPCancelLocalSwitcherInput(OPFloatingEditor);}
    OPInboundCancelAll();
    OPCancelOriginalPhysicalMirrors();
}

static NSDictionary *OPInboundSnapshot(id representation,const OPInboundFingerKinds &kinds) {
    // iOS 17 runtime declarations, not guessed selectors or struct offsets:
    // https://github.com/MTACS/iOS-17-Runtime-Headers/blob/main/PrivateFrameworks/AccessibilityUtilities.framework/AXEventPathInfoRepresentation.h
    // Identity/index/proximity are unsigned char, mask is unsigned int, and
    // pathLocation is CGPoint. A representation-wide location/phase cannot
    // describe a frame where one finger moves while another lifts.
    if (!OPInboundSignature(representation,@"handInfo",@encode(id),@[])) return @{@"error":@"AX handInfo ABI unavailable"};
    id hand=OPGet(representation,@"handInfo");
    if (!hand) return nil; // Keyboard and other non-hand events are irrelevant.
    if (!OPInboundSignature(hand,@"paths",@encode(id),@[])) return @{@"error":@"AX hand paths ABI unavailable"};
    NSArray *paths=OPGet(hand,@"paths");
    if (![paths isKindOfClass:NSArray.class] || paths.count>256) return @{@"error":@"AX hand paths malformed"};
    auto flag=[&](NSString *name) {
        if (!OPInboundSignature(representation,name,@encode(BOOL),@[])) return NO;
        return ((BOOL(*)(id,SEL))objc_msgSend)(representation,NSSelectorFromString(name));
    };
    // In a mixed hand, whole-event flags can come from a mapped sibling.
    // The surviving physical paths retain their own touch/cancel mask, so
    // never apply that sibling's aggregate Cancel/Lift to the physical set.
    const BOOL cancel=!kinds.mapped && flag(@"isCancel");
    const BOOL lift=!kinds.mapped && (flag(@"isLift") || flag(@"isInRangeLift"));
    const BOOL knowsCount=OPInboundSignature(hand,@"currentFingerCount",@encode(unsigned short),@[]);
    const unsigned short fingers=knowsCount ? ((unsigned short(*)(id,SEL))objc_msgSend)(hand,NSSelectorFromString(@"currentFingerCount")) : 1;
    NSMutableArray *copied=[NSMutableArray arrayWithCapacity:paths.count];
    BOOL hasPathCancel=NO;
    for (id path in paths) {
        for (NSString *getter in @[@"pathIdentity",@"pathIndex",@"pathProximity"])
            if (!OPInboundSignature(path,getter,@encode(unsigned char),@[])) return @{@"error":@"AX byte path-field ABI unavailable"};
        if (!OPInboundSignature(path,@"pathEventMask",@encode(unsigned int),@[]) ||
            !OPInboundSignature(path,@"pathLocation",@encode(CGPoint),@[])) return @{@"error":@"AX mask/location ABI unavailable"};
        const unsigned char identity=((unsigned char(*)(id,SEL))objc_msgSend)(path,NSSelectorFromString(@"pathIdentity"));
        const unsigned char index=((unsigned char(*)(id,SEL))objc_msgSend)(path,NSSelectorFromString(@"pathIndex"));
        if (OPOwnMappedFinger(index,identity) || (!index && !identity && !kinds.physicalZero)) continue;
        const unsigned char proximity=((unsigned char(*)(id,SEL))objc_msgSend)(path,NSSelectorFromString(@"pathProximity"));
        const unsigned int mask=((unsigned int(*)(id,SEL))objc_msgSend)(path,NSSelectorFromString(@"pathEventMask"));
        const CGPoint normalized=((CGPoint(*)(id,SEL))objc_msgSend)(path,NSSelectorFromString(@"pathLocation"));
        // Device evidence: a native tap at (423,466.5) arrives here as
        // (0.9837189,0.5005341). AX's per-path location keeps the digitizer's
        // normalized coordinates; unlike a UIKit touch, it is not in points.
        if (!std::isfinite(normalized.x) || !std::isfinite(normalized.y) ||
            normalized.x<0 || normalized.x>1 || normalized.y<0 || normalized.y>1)
            return @{@"error":@"AX normalized path coordinate invalid"};
        CGRect nativeBounds=UIScreen.mainScreen.fixedCoordinateSpace.bounds;
        const CGPoint location=CGPointMake(CGRectGetMinX(nativeBounds)+normalized.x*CGRectGetWidth(nativeBounds),
                                          CGRectGetMinY(nativeBounds)+normalized.y*CGRectGetHeight(nativeBounds));
        hasPathCancel=hasPathCancel || (mask&(1U<<7));
        ++OPInboundPhysicalPaths;
        [copied addObject:@{@"key":@((static_cast<unsigned>(index)<<8)|identity), @"index":@(index),
            @"identity":@(identity),@"proximity":@(proximity),@"mask":@(mask),@"x":@(location.x),@"y":@(location.y)}];
    }
    // Copy scalar path values while this callback owns the HID event. Keeping
    // a shared mutable AX representation until main-queue delivery can erase
    // an earlier Down/Up when another HID event arrives in the meantime.
    return @{@"paths":[copied copy],@"cancel":@(cancel),@"cancelAll":@(cancel && !hasPathCancel),
        @"allLifted":@(knowsCount && fingers==0 && lift)};
}

static void OPInboundApplySnapshot(NSDictionary *snapshot) {
    if (OPStopping) return;
    if(OPFloatingSession)OPFloatingObserveSystemGesture(snapshot);
    if (snapshot[@"error"]) {
        OPCancelOwnedPhysicalInput();
        OPInboundRecordError(snapshot[@"error"]);
        NSLog(@"[OriginalPort] inbound frame rejected: %@",snapshot[@"error"]);
        return;
    }
    if ([snapshot[@"cancelAll"] boolValue]) { OPCancelOwnedPhysicalInput(); return; }
    if(OPFloatingSession) {
        if(!OPFloatingPresentation.iconAllowed(OPFloatingDisplayAllowed,NSProcessInfo.processInfo.systemUptime))return;
        snapshot=OPFloatingConsumeIcon(snapshot);
        if(OPFloatingInputReady && OPFloatingPresentation.panelAllowed(OPFloatingDisplayAllowed,NSProcessInfo.processInfo.systemUptime))
            OPConsumeLocalSwitcherInput(OPFloatingEditor,snapshot);
        return;
    }
    NSArray *paths=snapshot[@"paths"];
    NSMutableSet *batchKeys=[NSMutableSet set];
    Class ownWindow=NSClassFromString(@"FZUIWindow");
    if (!ownWindow || !OPOriginalController()) return;
    std::vector<OPPhysicalMirrorSample> mirrorSamples;
    auto deliver=[&]() {
        // Deliver the independent original-HUD event first. Its UITouch
        // objects never enter the vendor listener's mutable touchPoints map.
        OPInboundDeliverFrame();
        if (!mirrorSamples.empty()) {
            NSString *error=nil;
            if (!OPMirrorOriginalPhysicalFrame(mirrorSamples,&error))
                { OPInboundRecordError(error ?: @"Physical visualization failed"); NSLog(@"[OriginalPort] physical visualization unavailable: %@",error); }
            mirrorSamples.clear();
        }
    };
    for (NSDictionary *path in paths) {
        OPInboundLastPath=path;
        NSNumber *key=path[@"key"];
        // Unusual duplicate identity samples remain ordered: finish the first
        // batch before changing that same UITouch to a later phase.
        if ([batchKeys containsObject:key]) { deliver(); [batchKeys removeAllObjects]; }
        [batchKeys addObject:key];
        const unsigned mask=[path[@"mask"] unsignedIntValue];
        const BOOL touching=([path[@"proximity"] unsignedCharValue]&(1U<<1))!=0;
        const BOOL cancelled=(mask&(1U<<7)) || ([snapshot[@"cancel"] boolValue] && !touching);
        UITouch *touch=OPUITouches[key];
        CGPoint screenPoint=CGPointMake([path[@"x"] doubleValue],[path[@"y"] doubleValue]);
        // Include physical paths outside the HUD hit-test region. The mirror
        // keeps separate carriers and never dispatches UIKit/HID input; an
        // unknown Move remains a Move and cannot synthesize a missing Down.
        UITouchPhase physicalPhase=cancelled ? UITouchPhaseCancelled : !touching ? UITouchPhaseEnded :
            (mask&(1U<<1)) ? UITouchPhaseBegan : (mask&(1U<<2)) ? UITouchPhaseMoved : UITouchPhaseStationary;
        if(!OPFloatingSession)mirrorSamples.push_back({key.unsignedIntValue,screenPoint,physicalPhase});
        if (!touch) {
            // Do not turn an outside-window Move/hover into a new HUD Down.
            if (cancelled || !touching || !(mask&(1U<<1))) continue;
            // Finish a previous contact before admitting a new one in the
            // same physical frame. UIEvent._firstTouchForView: does not filter
            // terminal phases, so retaining both could hide the new first touch.
            BOOL pendingEnd=NO;
            for(UITouch *active in OPUITouches.allValues)
                if(active.phase==UITouchPhaseEnded || active.phase==UITouchPhaseCancelled){pendingEnd=YES;break;}
            if(pendingEnd){deliver();[batchKeys removeAllObjects];[batchKeys addObject:key];}
            UIWindow *window=nil; CGPoint point=CGPointZero;
            NSArray<UIWindow *> *windows=OPFloatingSession ? OPFloatingOwnedWindows() : UIApplication.sharedApplication.windows;
            if(OPFloatingSession)windows=[windows sortedArrayUsingComparator:^NSComparisonResult(UIWindow *a,UIWindow *b) {
                return a.windowLevel<b.windowLevel ? NSOrderedDescending : a.windowLevel>b.windowLevel ? NSOrderedAscending : NSOrderedSame;
            }];
            else windows=windows.reverseObjectEnumerator.allObjects;
            for (UIWindow *candidate in windows) {
                if ((OPFloatingSession ? candidate==OPFloatingIconWindow : ![candidate isKindOfClass:ownWindow]) || candidate.hidden || candidate.alpha<=0) continue;
                CGPoint local=OPFloatingSession ? [candidate convertPoint:screenPoint fromCoordinateSpace:UIScreen.mainScreen.fixedCoordinateSpace] :
                    [candidate convertPoint:screenPoint fromWindow:nil];
                UIView *hit=[candidate hitTest:local withEvent:nil];
                if (hit) {
                    window=candidate;point=local;
                    break;
                }
            }
            if (!window) { ++OPInboundHUDMisses;continue; }
            touch=((id(*)(id,SEL,CGPoint,id))objc_msgSend)([UITouch alloc],NSSelectorFromString(@"initAtPoint:inWindow:"),point,window);
            if (![touch isKindOfClass:UITouch.class] || touch.window!=window) { OPInboundRecordError(@"Original UITouch initialization did not capture the FZUIWindow"); continue; }
            // The vendor KIF initializer skips this flag on iOS 14+, but iOS
            // 17 UIControl still asks UIEvent._firstTouchForView: for it. A
            // missing flag allows gesture recognizers to work while buttons
            // receive touchesBegan without ever beginning control tracking.
            // Mark only the first active contact captured by this exact view.
            BOOL firstForView=touch.view!=nil;
            for(UITouch *active in OPUITouches.allValues)
                if(active.view==touch.view && active.phase!=UITouchPhaseEnded && active.phase!=UITouchPhaseCancelled) {
                    firstForView=NO;break;
                }
            ((void(*)(id,SEL,BOOL))objc_msgSend)(touch,NSSelectorFromString(@"_setIsFirstTouchForView:"),firstForView);
            OPUITouches[key]=touch;
            OPInboundSetPhase(touch,UITouchPhaseBegan);
            ++OPInboundHUDDowns;
        } else {
            // Continue to the captured original window even when this finger
            // moves outside it. In particular, never hit-test away its Up.
            if (!OPInboundOwnTouch(touch)) { OPCancelOwnedPhysicalInput(); return; }
            CGPoint point=OPFloatingSession ? [touch.window convertPoint:screenPoint fromCoordinateSpace:UIScreen.mainScreen.fixedCoordinateSpace] :
                [touch.window convertPoint:screenPoint fromWindow:nil];
            CGPoint previous=[touch locationInView:touch.window];
            ((void(*)(id,SEL,CGPoint))objc_msgSend)(touch,NSSelectorFromString(@"setLocationInWindow:"),point);
            UITouchPhase phase=cancelled ? UITouchPhaseCancelled : !touching ? UITouchPhaseEnded :
                ((mask&(1U<<2)) || !CGPointEqualToPoint(previous,point)) ? UITouchPhaseMoved : UITouchPhaseStationary;
            if (touch.window.hidden || touch.window.alpha<=0) phase=UITouchPhaseCancelled;
            OPInboundSetPhase(touch,phase);
        }
    }
    if ([snapshot[@"allLifted"] boolValue])
        for (UITouch *touch in OPUITouches.allValues)
            if (touch.phase!=UITouchPhaseCancelled) OPInboundSetPhase(touch,UITouchPhaseEnded);
    deliver();
    if ([snapshot[@"allLifted"] boolValue]) OPCancelOriginalPhysicalMirrors();
}

static void OPInboundEnqueue(NSDictionary *snapshot) {
    static NSMutableArray<NSDictionary *> *pending;
    static BOOL draining=NO, overflow=NO;
    if (!pending) pending=[NSMutableArray array];
    if (pending.count>=256) { [pending removeAllObjects]; overflow=YES; }
    else [pending addObject:snapshot];
    if (draining) return;
    draining=YES;
    while (pending.count || overflow) {
        if (overflow) { OPCancelOwnedPhysicalInput(); OPInboundRecordError(@"Inbound frame queue overflow"); overflow=NO; }
        if (!pending.count) break;
        NSDictionary *next=pending.firstObject; [pending removeObjectAtIndex:0];
        @try { OPInboundApplySnapshot(next); }
        @catch (NSException *exception) { OPCancelOwnedPhysicalInput(); OPInboundRecordError(exception.reason ?: exception.name); NSLog(@"[OriginalPort] original HUD input failed: %@",exception.name); }
    }
    draining=NO;
}

// Inbound events go only to the original HUD's owned FZUIWindow views. This
// UIApplication sendEvent: path is never used to deliver to a target app.
static void OPInboundHID(void *target,void *refcon,void *service,const void *event) {
    (void)target;(void)refcon;(void)service;
    ++OPInboundCallbackCount;
    if (!event || !OPHIDType || !OPHIDInteger || !OPHIDChildren) return;
    if (OPHIDType(event)==11) ++OPInboundHIDFrames;
    @autoreleasepool {
        @try {
            OPInboundFingerKinds kinds;
            OPClassifyInboundFingers(event,kinds);
            if (kinds.malformed || (kinds.legacyMapped && kinds.physical)) {
                // Old test IDs >255 alias real fingers in AX's byte fields.
                // Do not guess which truncated path belongs to the HUD.
                NSString *reason=kinds.malformed ? @"HID finger hierarchy malformed" : @"legacy mapped/physical AX identity collision";
                dispatch_async(dispatch_get_main_queue(), ^{ OPInboundEnqueue(@{@"error":reason}); });
                return;
            }
            if (kinds.mapped && !kinds.physical) return;
            id representation=((id(*)(id,SEL,const void *,id))objc_msgSend)(NSClassFromString(@"AXEventRepresentation"),
                NSSelectorFromString(@"representationWithHIDEvent:hidStreamIdentifier:"),event,@"UIApplicationEvents");
            NSDictionary *snapshot=representation ? OPInboundSnapshot(representation,kinds) : nil;
            if (snapshot) dispatch_async(dispatch_get_main_queue(), ^{ OPInboundEnqueue(snapshot); });
        } @catch (NSException *exception) {
            NSString *reason=[exception.name copy];
            dispatch_async(dispatch_get_main_queue(), ^{ OPInboundEnqueue(@{@"error":reason}); });
        }
    }
}

static BOOL OPStartInboundMonitor(void *io,NSString **error) {
    // Match the ABI already used by OPSystemTouch's calibration monitor.
    // This independent client is the ONLY original-HUD input source. A BKS
    // callback without a UIKit fetcher/run-loop source received zero frames on
    // device; do not register both paths and deliver each physical touch twice.
    auto create=(CFTypeRef(*)(CFAllocatorRef))dlsym(io,"IOHIDEventSystemClientCreate");
    auto schedule=(void(*)(CFTypeRef,CFRunLoopRef,CFStringRef))dlsym(io,"IOHIDEventSystemClientScheduleWithRunLoop");
    auto registerEvent=(void(*)(CFTypeRef,OPInboundCallback,void *,void *))dlsym(io,"IOHIDEventSystemClientRegisterEventCallback");
    OPInboundUnregister=(void(*)(CFTypeRef))dlsym(io,"IOHIDEventSystemClientUnregisterEventCallback");
    OPInboundUnschedule=(void(*)(CFTypeRef,CFRunLoopRef,CFStringRef))dlsym(io,"IOHIDEventSystemClientUnscheduleWithRunLoop");
    if (!create || !schedule || !registerEvent || !OPInboundUnregister || !OPInboundUnschedule) {
        if (error) *error=@"独立 HID 入站监视接口不完整"; return NO;
    }
    OPInboundMonitor=create(kCFAllocatorDefault);
    if (!OPInboundMonitor) { if (error) *error=@"独立 HID 入站客户端创建失败"; return NO; }
    registerEvent(OPInboundMonitor,OPInboundHID,nullptr,nullptr);
    schedule(OPInboundMonitor,CFRunLoopGetMain(),kCFRunLoopCommonModes);
    OPInboundMonitorScheduled=YES;
    return YES; // Created/scheduled is not proof of event-monitor permission.
}
static void OPStopInboundMonitor(void) {
    if (!OPInboundMonitor) return;
    // Stop outside the callback stack; all lifecycle callers run on main.
    OPInboundUnregister(OPInboundMonitor);
    if (OPInboundMonitorScheduled) OPInboundUnschedule(OPInboundMonitor,CFRunLoopGetMain(),kCFRunLoopCommonModes);
    OPInboundMonitorScheduled=NO;
    CFRelease(OPInboundMonitor); OPInboundMonitor=nullptr;
}

// The icon is deliberately independent of the vendor's KIF categories. Until
// it is opened no vendor image, configuration lease or output backend exists.
@interface OPFloatingWindow:UIWindow
@property(nonatomic) BOOL hasHitRect;
@property(nonatomic) CGRect hitRect;
@end
@implementation OPFloatingWindow
+ (BOOL)_isSystemWindow {return YES;}
- (BOOL)_isWindowServerHostingManaged {return NO;}
- (BOOL)_isSecure {return YES;}
- (BOOL)_shouldCreateContextAsSecure {return YES;}
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    const double now=NSProcessInfo.processInfo.systemUptime;
    if(!(self==OPFloatingIconWindow ? OPFloatingPresentation.iconAllowed(OPFloatingDisplayAllowed,now) :
         OPFloatingPresentation.panelAllowed(OPFloatingDisplayAllowed,now)))return NO;
    // The edge wake target is independent of the fully off-screen image.
    // Its reserved rectangle wins over system edges, including top/bottom.
    if(self.hasHitRect)return CGRectContainsPoint(self.hitRect,point);
    return [super pointInside:point withEvent:event];
}
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if(self==OPFloatingIconWindow)
        return [self pointInside:point withEvent:event] ? OPFloatingWakeHandle : nil;
    return [super hitTest:point withEvent:event];
}
@end

static int OPFloatingDockOrientation(void) {
    return OPDisplayOrientation>=1 && OPDisplayOrientation<=4 ? (int)OPDisplayOrientation : 1;
}
static op_floating_dock::Size OPFloatingNativeSize(void) {
    CGSize size=UIScreen.mainScreen.fixedCoordinateSpace.bounds.size;
    return {size.width,size.height};
}
static CGFloat OPFloatingOriginalIconDiameter(void) {
    auto size=OPFloatingNativeSize();double length=std::max(size.width,size.height);
    // Both untouched vendor PNGs are 96x96 with alpha bounds (16,16)-(80,80).
    // Dock the visible 64px artwork, not its invisible 16px padding. Cropping
    // the layer below preserves the original artwork's actual on-screen size.
    return 81*length/(length>=736 ? 1200 : length>=568 ? 1000 : 750)*(64.0/96.0);
}
static void OPFloatingConfigureDock(void) {
    // Fixed native geometry matches both the portrait backing window and raw
    // HID. Interface rotation must not move either the icon or its wake area.
    // Insets limit along-edge travel only and never depend on UIKit rotation.
    constexpr op_floating_dock::Insets nativeSafe{64,0,34,0};
    OPFloatingAnchor.configure(OPFloatingNativeSize(),nativeSafe,OPFloatingOriginalIconDiameter());
}
static void OPFloatingLayoutDock(BOOL animated) {
    if(!OPFloatingIconWindow || !OPFloatingIcon)return;
    OPFloatingConfigureDock();
    int orientation=OPFloatingDockOrientation();auto native=OPFloatingNativeSize();
    if(OPFloatingSavedPosition) {
        const auto restored=OPFloatingAnchor.restore(*OPFloatingSavedPosition,(int)OPDisplayOrientation);
        if(restored==op_floating_anchor::RestoreResult::Restored || restored==op_floating_anchor::RestoreResult::AlreadyRestored) {
            OPFloatingSavedPosition.reset();OPFloatingRememberPosition();
        }
    }
    if(OPFloatingLegacyPositionPending && native.width>0 && native.height>0) {
        // V1 already stored normalized fixed-native coordinates.
        OPFloatingDock.dockAt({OPFloatingLegacyPosition.x*native.width,OPFloatingLegacyPosition.y*native.height});
        OPFloatingLegacyPositionPending=NO;OPFloatingRememberPosition();
    }
    auto center=OPFloatingDock.center();
    auto hit=OPFloatingDock.hitRect();
    OPFloatingWindow *window=(OPFloatingWindow *)OPFloatingIconWindow;
    window.hasHitRect=YES;window.hitRect=CGRectMake(hit.x,hit.y,hit.width,hit.height);
    OPFloatingWakeHandle.frame=window.hitRect;
    OPFloatingHidden=OPFloatingDock.hidden;
    const CGFloat diameter=OPFloatingOriginalIconDiameter();
    const CGFloat angle=op_floating_anchor::artworkRotationRadians(orientation);
    const CGAffineTransform transform=CGAffineTransformMakeRotation(angle);
    const CGPoint target=CGPointMake(center.x,center.y);
    const CGRect bounds=CGRectMake(0,0,diameter,diameter);
    if(CGPointEqualToPoint(OPFloatingIcon.center,target) && CGRectEqualToRect(OPFloatingIcon.bounds,bounds) &&
       CGAffineTransformEqualToTransform(OPFloatingIcon.transform,transform))return;
    void (^layout)(void)=^{OPFloatingIcon.bounds=bounds;OPFloatingIcon.center=target;OPFloatingIcon.transform=transform;};
    if(animated)[UIView animateWithDuration:.2 delay:0 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction
        animations:layout completion:nil];
    else [UIView performWithoutAnimation:layout];
}
static void OPFloatingRefreshOriginalIcon(void) {
    NSDictionary *bluetooth=OPBluetoothBrokerStatus();
    NSTimeInterval age=NSDate.date.timeIntervalSince1970-[bluetooth[@"time"] doubleValue];
    BOOL connected=[bluetooth[@"connected"] boolValue] && std::isfinite(age) && age>=0 && age<4;
    if(OPPhoneModeSelected()) {
        NSDictionary *engine=[NSDictionary dictionaryWithContentsOfFile:OPStatusFile];
        NSTimeInterval inputAge=NSDate.date.timeIntervalSince1970-[engine[@"time"] doubleValue];
        connected=[engine[@"inputMode"] isEqual:@"phone"] && [engine[@"inputReady"] boolValue] &&
            [engine[@"running"] boolValue] && inputAge>=0 && inputAge<3;
    }
    OPFloatingIcon.image=connected ? OPFloatingConnectedIcon : OPFloatingDisconnectedIcon;
    OPFloatingIcon.layer.contentsRect=CGRectMake(16.0/96.0,16.0/96.0,64.0/96.0,64.0/96.0);
}
static void OPFloatingYieldPresentation(NSString *reason) {
    OPFloatingPresentation.suspend();OPFloatingSuspensionReason=[reason copy];
    OPCancelOwnedPhysicalInput();OPHostWindows();OPFloatingWriteStatus();
}
static void OPFloatingObserveSystemGesture(NSDictionary *snapshot) {
    const double now=NSProcessInfo.processInfo.systemUptime;
    OPFloatingConfigureDock();
    std::vector<op_floating_gesture::Sample> samples;
    auto native=OPFloatingNativeSize();int orientation=OPFloatingDockOrientation();
    for(NSDictionary *path in snapshot[@"paths"]) {
        NSNumber *key=path[@"key"];unsigned mask=[path[@"mask"] unsignedIntValue];
        BOOL touching=([path[@"proximity"] unsignedCharValue]&(1U<<1))!=0;
        BOOL cancelled=(mask&(1U<<7)) || ([snapshot[@"cancel"] boolValue] && !touching);
        auto point=op_floating_dock::fromNative({[path[@"x"] doubleValue],[path[@"y"] doubleValue]},native,orientation);
        samples.push_back({key.unsignedIntValue,point,(mask&(1U<<1))!=0,(bool)touching,(bool)cancelled});
    }
    auto result=OPFloatingSystemGesture.update(samples,[snapshot[@"allLifted"] boolValue],
        snapshot[@"error"] || [snapshot[@"cancelAll"] boolValue],now,
        op_floating_dock::displaySize(native,orientation),op_floating_anchor::displayRect(OPFloatingDock.hitRect(),native,orientation),
        OPFloatingPresentation.iconAllowed(OPFloatingDisplayAllowed,now));
    if(result.started) {
        OPFloatingPresentation.beginSystemGesture(now);OPFloatingSuspensionReason=@"confirmed-system-edge-swipe";
    }
    if(result.ended)OPFloatingPresentation.endSystemGesture(now);
    if(result.started || result.ended){OPCancelOwnedPhysicalInput();OPHostWindows();}
}

static NSString *OPFloatingSideName(void) {
    switch(OPFloatingDock.side) {
        case op_floating_dock::Side::Left:return @"left";
        case op_floating_dock::Side::Right:return @"right";
        case op_floating_dock::Side::Top:return @"top";
        case op_floating_dock::Side::Bottom:return @"bottom";
    }
}

static void OPFloatingWriteStatus(void) {
    if(!OPFloatingSession)return;
    NSDictionary *state=@{@"pid":@(getpid()),@"time":@(NSDate.date.timeIntervalSince1970),
        @"target":OPForcedTargetBundle ?: @"",@"expanded":@(OPFloatingExpanded),
        @"panelSuspended":@(OPFloatingPresentation.suspended && OPFloatingExpanded),
        @"panelVisible":@(OPFloatingPresentation.panelAllowed(OPFloatingDisplayAllowed,NSProcessInfo.processInfo.systemUptime)),
        @"suspensionReason":OPFloatingSuspensionReason ?: @"",@"suspensionPolicy":@"background-lock-confirmed-edge-swipe",
        @"hidden":@(OPFloatingHidden),@"preparing":@(OPFloatingPreparing),
        @"displayAllowed":@(OPFloatingDisplayAllowed),@"error":OPFloatingError ?: @"",
        @"iconResource":OPFloatingIcon.image==OPFloatingConnectedIcon ? @"fz_km_logo_on.png" : @"fz_km_logo_off.png",
        @"dockSide":OPFloatingSideName(),@"dockFraction":@(OPFloatingDock.fraction),
        @"wakeRect":OPOwnRect(((OPFloatingWindow *)OPFloatingIconWindow).hitRect),@"displayOrientation":@(OPDisplayOrientation),
        @"vendorLoaded":@(OPOriginalController()!=nil),@"inputReady":@(OPFloatingInputReady),
        @"supervisorPID":@(OPFloatingParentPID),@"runtimeGeneration":OPFloatingRuntimeGeneration ?: @"",
        @"localSwitcher":OPLocalSwitcherStatus(OPFloatingEditor),
        @"menuShown":@(OPFloatingMenuShown),@"hostCount":@(OPHostingControllers.count),
        @"inboundFrames":@(OPInboundHIDFrames.load()),@"inboundError":OPInboundLastError ?: @""};
    if([state writeToFile:OPFloatingStatusPath atomically:YES]) {
        chmod(OPFloatingStatusPath.fileSystemRepresentation,0644);
        chown(OPFloatingStatusPath.fileSystemRepresentation,501,501);
    }
}
static void OPFloatingRememberPosition(void) {
    // A legacy display-side record needs one known orientation before it can
    // be replaced. V4 always stores the physical anchor and ignores rotation.
    if(OPFloatingLegacyPositionPending)return;
    const auto position=OPFloatingAnchor.snapshot();
    if(!position)return;
    NSDictionary *saved=@{@"version":@(position->version),@"coordinateSpace":@"fixed-screen",
        @"nativeSide":OPFloatingSideName(),@"side":OPFloatingSideName(),@"fraction":@(position->fraction),
        @"lastDisplayOrientation":@(OPDisplayOrientation)};
    if([saved writeToFile:OPFloatingPositionPath atomically:YES]) {
        chmod(OPFloatingPositionPath.fileSystemRepresentation,0600);chown(OPFloatingPositionPath.fileSystemRepresentation,501,501);
    }
}
static void OPFloatingShowError(NSString *message) {
    OPFloatingError=[message copy];OPFloatingReveal();OPFloatingWriteStatus();
    UILabel *notice=[[UILabel alloc] initWithFrame:CGRectMake(16,64,MAX(120,OPFloatingIconWindow.bounds.size.width-32),110)];
    notice.text=message;notice.textColor=UIColor.whiteColor;notice.textAlignment=NSTextAlignmentCenter;
    notice.numberOfLines=0;notice.font=[UIFont systemFontOfSize:15];
    notice.backgroundColor=[UIColor.blackColor colorWithAlphaComponent:.85];notice.layer.cornerRadius=12;notice.clipsToBounds=YES;
    [OPFloatingIconWindow.rootViewController.view addSubview:notice];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC),dispatch_get_main_queue(),^{[notice removeFromSuperview];});
}
static void OPFloatingReveal(void) {
    OPFloatingDock.reveal();OPFloatingLayoutDock(YES);
    OPFloatingLastInteraction=NSProcessInfo.processInfo.systemUptime;
}
static void OPFloatingClose(BOOL keepIcon,BOOL alreadyCommitted) {
    (void)alreadyCommitted;
    if(OPStopping)return;
    if(!keepIcon && OPLocalSwitcherBusy(OPFloatingEditor)) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),dispatch_get_main_queue(),^{OPFloatingClose(NO,YES);});return;
    }
    OPCancelOwnedPhysicalInput();OPFloatingRememberPosition();
    OPFloatingPanelWindow.hidden=YES;OPFloatingExpanded=NO;OPFloatingPreparing=NO;
    OPFloatingInputReady=NO;OPFloatingMenuShown=NO;OPFloatingPresentation.endEditing();
    OPFloatingReveal();OPHostWindows();OPFloatingWriteStatus();
    // The local switcher owns no vendor UI, timers or editing lease. Closing
    // it only hides the panel; the wake region and singleton stay alive.
    if(!keepIcon)exit(0);
}
static void OPFloatingOpen(void) {
    if(!OPFloatingPresentation.iconAllowed(OPFloatingDisplayAllowed,NSProcessInfo.processInfo.systemUptime))return;
    NSDictionary *selection=OPCurrentEditorSelection();
    NSString *target=selection[@"bundle"],*name=selection[@"name"];
    if(OPManagedTargetIsValid(target))OPForcedTargetBundle=[target copy];
    if(![name isKindOfClass:NSString.class] || !name.length)name=OPForcedTargetBundle;
    if(!OPFloatingEditor) {
        OPFloatingEditor=OPMakeLocalSwitcher(OPForcedTargetBundle,name,^{OPFloatingClose(YES,YES);});
        OPFloatingPanelWindow=[[OPFloatingWindow alloc] initWithFrame:UIScreen.mainScreen.fixedCoordinateSpace.bounds];
        OPFloatingPanelWindow.windowLevel=UIWindowLevelNormal;
        OPFloatingPanelWindow.backgroundColor=UIColor.clearColor;
        OPFloatingPanelWindow.rootViewController=OPFloatingEditor;
        UIApplication.sharedApplication.delegate.window=OPFloatingPanelWindow;
    } else OPRefreshLocalSwitcher(OPFloatingEditor,OPForcedTargetBundle,name);
    OPFloatingExpanded=YES;OPFloatingInputReady=YES;OPFloatingMenuShown=YES;OPFloatingError=nil;
    OPFloatingPresentation.beginEditing();OPFloatingSuspensionReason=nil;
    OPLayoutWindow(OPFloatingPanelWindow);[OPFloatingPanelWindow makeKeyAndVisible];
    OPFloatingReveal();OPHostWindows();OPFloatingWriteStatus();
}
static void OPFloatingFinishIconContact(BOOL cancelled) {
    if(!OPFloatingFinger)return;
    auto action=OPFloatingDock.end(cancelled,OPFloatingExpanded && !OPFloatingPresentation.suspended,OPFloatingPreparing);
    OPFloatingFinger=nil;OPFloatingLastInteraction=NSProcessInfo.processInfo.systemUptime;
    OPFloatingLayoutDock(YES);
    switch(action) {
        case op_floating_dock::Action::Dock:OPFloatingRememberPosition();break;
        case op_floating_dock::Action::Reveal:break;
        case op_floating_dock::Action::Open:OPFloatingOpen();break;
        case op_floating_dock::Action::Close:OPFloatingClose(YES,NO);break;
        case op_floating_dock::Action::None:break;
    }
}
static NSDictionary *OPFloatingConsumeIcon(NSDictionary *snapshot) {
    NSMutableArray *remaining=[NSMutableArray array];
    OPFloatingConfigureDock();
    for(NSDictionary *path in snapshot[@"paths"]) {
        NSNumber *key=path[@"key"];unsigned mask=[path[@"mask"] unsignedIntValue];
        BOOL touching=([path[@"proximity"] unsignedCharValue]&(1U<<1))!=0;
        BOOL cancelled=(mask&(1U<<7)) || ([snapshot[@"cancel"] boolValue] && !touching);
        const op_floating_dock::Point point{[path[@"x"] doubleValue],[path[@"y"] doubleValue]};
        if(!OPFloatingFinger && touching && !cancelled && (mask&(1U<<1)) &&
            OPFloatingDock.begin(point))OPFloatingFinger=key;
        if(![key isEqual:OPFloatingFinger]){[remaining addObject:path];continue;}
        OPFloatingDock.move(point);
        if(cancelled || !touching) {
            OPFloatingFinishIconContact(cancelled);
        } else OPFloatingLayoutDock(NO);
    }
    if([snapshot[@"allLifted"] boolValue] && OPFloatingFinger)
        OPFloatingFinishIconContact([snapshot[@"cancel"] boolValue]);
    NSMutableDictionary *result=[snapshot mutableCopy];result[@"paths"]=remaining;return result;
}
static void OPFloatingTick(void) {
    NSDictionary *intent=OPMappingRuntimeIntent();
    if(getppid()!=OPFloatingParentPID || ![intent[@"enabled"] boolValue] ||
        ![intent[@"generation"] isEqual:OPFloatingRuntimeGeneration]) {
        OPFloatingClose(NO,YES);return;
    }
    if((!OPFloatingExpanded || OPFloatingPresentation.suspended) && !OPFloatingPreparing && !OPFloatingFinger && !OPFloatingDock.hidden &&
        NSProcessInfo.processInfo.systemUptime-OPFloatingLastInteraction>3) {
        OPFloatingDock.hide();OPFloatingLayoutDock(YES);
    }
    OPFloatingRefreshOriginalIcon();
    if(OPFloatingExpanded)OPRefreshLocalSwitcherConnection(OPFloatingEditor);
    OPFloatingWriteStatus();
}
static void OPFloatingStart(void) {
    NSDictionary *initialDisplay=OPForegroundContextSnapshot();
    UIInterfaceOrientation initialOrientation=(UIInterfaceOrientation)[initialDisplay[@"orientation"] integerValue];
    if(initialOrientation>=1 && initialOrientation<=4)OPApplyOrientation(initialOrientation);
    OPFloatingIconWindow=[[OPFloatingWindow alloc] initWithFrame:UIScreen.mainScreen.fixedCoordinateSpace.bounds];
    OPFloatingIconWindow.windowLevel=UIWindowLevelAlert+10000;
    UIViewController *root=[UIViewController new];root.view.backgroundColor=UIColor.clearColor;
    root.view.clipsToBounds=YES;OPFloatingIconWindow.clipsToBounds=YES;
    OPFloatingIconWindow.rootViewController=root;
    NSString *resources=[OPApplicationBundlePath() stringByAppendingPathComponent:@"FZKeymappingHelper.bundle"];
    OPFloatingConnectedIcon=[UIImage imageWithContentsOfFile:[resources stringByAppendingPathComponent:@"fz_km_logo_on.png"]];
    OPFloatingDisconnectedIcon=[UIImage imageWithContentsOfFile:[resources stringByAppendingPathComponent:@"fz_km_logo_off.png"]];
    OPFloatingIcon=[UIImageView new];OPFloatingIcon.contentMode=UIViewContentModeScaleAspectFit;
    OPFloatingIcon.accessibilityLabel=@"凌触悬浮配置";
    OPFloatingWakeHandle=[UIControl new];OPFloatingWakeHandle.backgroundColor=UIColor.clearColor;
    OPFloatingWakeHandle.alpha=1;OPFloatingWakeHandle.hidden=NO;OPFloatingWakeHandle.userInteractionEnabled=YES;
    OPFloatingWakeHandle.accessibilityLabel=@"凌触浮标唤醒区域";
    [root.view addSubview:OPFloatingWakeHandle];
    [root.view addSubview:OPFloatingIcon];OPFloatingRefreshOriginalIcon();OPFloatingConfigureDock();
    NSDictionary *saved=[NSDictionary dictionaryWithContentsOfFile:OPFloatingPositionPath];
    if([saved[@"version"] isKindOfClass:NSNumber.class] && [saved[@"version"] unsignedIntegerValue]>=2) {
        op_floating_anchor::SavedPosition position;
        position.version=[saved[@"version"] unsignedIntValue];
        if(position.version==4) {
            NSString *space=[saved[@"coordinateSpace"] isKindOfClass:NSString.class] ? saved[@"coordinateSpace"] : @"";
            position.coordinateSpace=space.UTF8String ?: "";
        }
        NSString *side=position.version==4 && [saved[@"nativeSide"] isKindOfClass:NSString.class] ? saved[@"nativeSide"] : saved[@"side"];
        position.side=[side isEqual:@"right"] ? op_floating_dock::Side::Right : op_floating_dock::Side::Left;
        if([side isEqual:@"top"])position.side=op_floating_dock::Side::Top;
        if([side isEqual:@"bottom"])position.side=op_floating_dock::Side::Bottom;
        if([saved[@"fraction"] isKindOfClass:NSNumber.class])position.fraction=[saved[@"fraction"] doubleValue];
        for(NSString *key in @[@"displayOrientation",@"lastDisplayOrientation",@"savedOrientation"]) {
            id value=saved[key];
            if([value isKindOfClass:NSNumber.class] && op_floating_anchor::validOrientation([value intValue])) {
                position.displayOrientation=[value intValue];break;
            }
        }
        OPFloatingSavedPosition=position;
        OPFloatingAnchor.restore(position,(int)OPDisplayOrientation);
    } else if([saved[@"x"] isKindOfClass:NSNumber.class] && [saved[@"y"] isKindOfClass:NSNumber.class]) {
        double x=[saved[@"x"] doubleValue],y=[saved[@"y"] doubleValue];
        if(std::isfinite(x) && std::isfinite(y) && x>=0 && x<=1 && y>=0 && y<=1) {
            OPFloatingLegacyPosition={x,y};OPFloatingLegacyPositionPending=YES;
        }
    }
    OPFloatingLayoutDock(NO);OPFloatingRememberPosition();
    OPFloatingIconWindow.hidden=NO;OPFloatingReveal();
    if(!OPFloatingConnectedIcon || !OPFloatingDisconnectedIcon)OPFloatingShowError(@"原插件图标资源缺失，请重新安装完整包。");
    int reveal=-1,stop=-1,yield=-1,active=-1,intentToken=-1,sessionStop=-1;
    notify_register_dispatch("com.lixinmo.skytouch.floating.reveal",&reveal,dispatch_get_main_queue(),^(__unused int token) {
        NSDictionary *selected=OPCurrentEditorSelection();NSString *target=selected[@"bundle"];
        if(OPManagedTargetIsValid(target) && ![target isEqual:OPForcedTargetBundle]) {
            if(OPFloatingExpanded || OPFloatingPreparing){OPFloatingClose(YES,NO);return;}
            OPForcedTargetBundle=[target copy];
        }
        OPFloatingReveal();OPHostWindows();OPFloatingWriteStatus();
    });
    notify_register_dispatch("com.lixinmo.skytouch.floating.stop",&stop,dispatch_get_main_queue(),^(__unused int token) {OPFloatingTick();});
    notify_register_dispatch(OPRuntimeIntentChangedNotification,&intentToken,dispatch_get_main_queue(),^(__unused int token) {OPFloatingTick();});
    NSString *stopName=[@"com.lixinmo.skytouch.floating.session." stringByAppendingString:OPFloatingRuntimeGeneration];
    if(notify_register_dispatch(stopName.UTF8String,&sessionStop,dispatch_get_main_queue(),^(__unused int token){OPFloatingClose(NO,YES);})!=NOTIFY_STATUS_OK) {
        OPFloatingClose(NO,YES);return;
    }
    notify_register_dispatch("com.lixinmo.skytouch.floating.launcher-resigned",&yield,dispatch_get_main_queue(),^(__unused int token) {
        OPFloatingPresentation.launcherResigned(NSProcessInfo.processInfo.systemUptime);
        OPFloatingYieldPresentation(@"launcher-resigned");
    });
    notify_register_dispatch("com.lixinmo.skytouch.floating.launcher-active",&active,dispatch_get_main_queue(),^(__unused int token) {
        BOOL recovering=OPFloatingPresentation.suspended || OPFloatingPresentation.systemGesture ||
            OPFloatingPresentation.systemUI || OPFloatingPresentation.transitioning;
        OPFloatingPresentation.launcherActivated(NSProcessInfo.processInfo.systemUptime);
        if(recovering){OPFloatingSystemGesture.reset();OPCancelOwnedPhysicalInput();}
        OPFloatingReveal();OPHostWindows();OPFloatingWriteStatus();
    });
    // A second game selection may arrive while this process is starting (or
    // during exec), before it can receive Darwin notifications. The persisted
    // selection is authoritative until the vendor context has been loaded.
    NSString *latest=OPCurrentEditorSelection()[@"bundle"];
    if(OPManagedTargetIsValid(latest))OPForcedTargetBundle=[latest copy];
    OPHostWindows();OPFloatingWriteStatus();
}

@interface OPHUDDelegate : NSObject <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@property(nonatomic) NSTimer *hostTimer;
@property(nonatomic) NSTimer *contextTimer;
@end
@implementation OPHUDDelegate
@synthesize window=_window;
- (UIInterfaceOrientationMask)application:(UIApplication *)application supportedInterfaceOrientationsForWindow:(UIWindow *)window {
    (void)application;(void)window;
    // The global host's backing surface is always native portrait. The
    // independent child canvas owns landscape orientation, including when
    // the frontmost app or SpringBoard itself is portrait.
    return OPFloatingSession ? UIInterfaceOrientationMaskPortrait : UIInterfaceOrientationMaskAll;
}
- (UIWindow *)window {
    // Original novice-guide/property views read delegate.window.safeAreaInsets.
    // FLEXManager stores _explorerWindow at 0x18834c BEFORE constructing the
    // controller at 0x188398. Read that already-created, owned FZUIWindow even
    // during controller init; calling explorerWindow here could recurse.
    id original=OPOriginalWindowOwner && OPOriginalWindowIvar ?
        object_getIvar(OPOriginalWindowOwner,OPOriginalWindowIvar) : nil;
    if ([original isKindOfClass:NSClassFromString(@"FZUIWindow")]) return original;
    return _window;
}
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application;(void)options;
    if(OPFloatingSession)OPFloatingStart();
    OPOrientationObserver=(OPEngineSession || OPFloatingSession) ? nil : [[NSClassFromString(@"FBSOrientationObserver") alloc] init];
    SEL handler=NSSelectorFromString(@"setHandler:");
    if ([OPOrientationObserver respondsToSelector:handler]) {
        void (^block)(id)=^(id update) {
            NSInteger value=((NSInteger(*)(id,SEL))objc_msgSend)(update,NSSelectorFromString(@"orientation"));
            dispatch_async(dispatch_get_main_queue(), ^{ OPApplyOrientation((UIInterfaceOrientation)value); });
        };
        ((void(*)(id,SEL,id))objc_msgSend)(OPOrientationObserver,handler,block);
    }
    SEL active=NSSelectorFromString(@"activeInterfaceOrientation");
    if ([OPOrientationObserver respondsToSelector:active]) OPApplyOrientation((UIInterfaceOrientation)((long long(*)(id,SEL))objc_msgSend)(OPOrientationObserver,active));
    OPSetForegroundContextChangeHandler(^(NSDictionary *snapshot) {
        OPHandleForegroundContext(snapshot); OPStatus(nil);
    });
    OPHandleForegroundContext(OPForegroundContextSnapshot());
    if(OPEngineSession || OPFloatingSession) {
        self.contextTimer=[NSTimer timerWithTimeInterval:.1 repeats:YES block:^(__unused NSTimer *timer) {
            OPHandleForegroundContext(OPForegroundContextSnapshot());
        }];
        [NSRunLoop.mainRunLoop addTimer:self.contextTimer forMode:NSRunLoopCommonModes];
    }
    self.hostTimer=[NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(__unused NSTimer *timer) {
        if(!OPEngineSession)OPHandleForegroundContext(OPForegroundContextSnapshot());
        if(OPFloatingSession)OPFloatingTick();
        OPHostWindows(); OPStatus(nil);
    }];
    return YES;
}
@end

static double OPShutdownClock(void) {
    return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
}
static void OPContinueShutdown(void) {
    OPShutdownPollScheduled=NO;
    if (!OPStopping) return;
    double now=OPShutdownClock();
    if (OPManagedSessionID && getppid()!=OPManagedParentPID) OPShutdownMayExit=YES;
    if (OPShutdownMayExit && !OPOutput.cancellationPending && now>=OPShutdownNotBefore) {
        NSString *error=nil;
        if(OPEngineSession && OPActiveGlobalProfile)OPExportedProfileDefaults=YES;
        // Runtime preferences belonging to the committed revision must never
        // overwrite newer, unapplied edits in the source profile.
        if (OPEngineSession && OPImportedProfileDefaults && !OPExportedProfileDefaults) {
            OPExportedProfileDefaults=OPExportOriginalProfileDefaults(OPSessionTarget,&error);
            if (!OPExportedProfileDefaults) { OPShutdownExitCode=70; OPStatus(error); }
        }
        if (OPManagedSessionID && OPSessionTarget && !OPPrepareSharedOriginalProfile(OPSessionTarget,&error)) {
            // HID is drained, but a failed profile handover is not a normal
            // successful session. Parent will reap then recheck ownership.
            OPShutdownExitCode=70; OPStatus(error);
        }
        if (!OPManagedSessionID || OPPostManagedSessionDrained(OPManagedSessionID,&error)) {
            OPStatus(OPShutdownExitCode ? @"失败会话的本地触点取消已提交；原宿主退出" : @"本地触点取消提交完成；原宿主正常退出");
            exit(OPShutdownExitCode);
        }
        if (now-OPShutdownLastReport>=1) { OPStatus(error); OPShutdownLastReport=now; }
    } else if (now-OPShutdownLastReport>=1) {
        OPStatus(OPOutput.cancellationPending ? @"触点取消尚未提交，保留宿主且禁止新输入；没有发送退出成功回执" :
            @"触点已取消，等待监督器请求当前会话退出");
        OPShutdownLastReport=now;
    }
    OPShutdownPollScheduled=YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,100*NSEC_PER_MSEC),dispatch_get_main_queue(),^{ OPContinueShutdown(); });
}
static void OPBeginShutdown(NSString *reason,BOOL mayExit,int exitCode) {
    OPShutdownMayExit=OPShutdownMayExit || mayExit;
    if (exitCode) OPShutdownExitCode=exitCode;
    if (!OPStopping) {
        // Gate new callbacks before cancelling the owned UIKit/mirror state.
        OPStopping=YES; OPContextAllowed=NO; OPShutdownNotBefore=OPShutdownClock()+0.3;
        OPHUDDelegate *delegate=(OPHUDDelegate *)UIApplication.sharedApplication.delegate;
        [delegate.contextTimer invalidate];[delegate.hostTimer invalidate];
        OPStopPhoneInput();
        OPStopOriginalBluetoothClient();
        OPStopInboundMonitor(); OPCancelOwnedPhysicalInput();
        OPSetForegroundContextChangeHandler(nil); OPStopForegroundContext();
        OPStopOriginalTouches(); [OPOutput shutdown];
        [OPHostingControllers removeAllObjects];
        for (UIWindow *window in UIApplication.sharedApplication.windows)
            if ([window isKindOfClass:NSClassFromString(@"FZUIWindow")]) window.hidden=YES;
        [OPManagedParentTimer invalidate]; OPManagedParentTimer=nil;
    }
    OPStatus(reason);
    if (!OPShutdownPollScheduled) OPContinueShutdown();
}

static int OPRunHUDInternal(BOOL verifyUIOnly,NSString *targetBundle) {
    OPVerifyUIOnly=verifyUIOnly; OPForcedTargetBundle=[targetBundle copy];
    OPSessionInputSettings=OPReadInputSettings();
    NSString *expectedInput=NSProcessInfo.processInfo.environment[@"SKYTOUCH_INPUT_REVISION"];
    if(OPEngineSession && expectedInput && ![expectedInput isEqual:OPSessionInputSettings[@"revision"]]) {
        // The settings changed between parent spawn and exec. Start paused;
        // parent receives the revision notification and drains this generation.
        OPContextAllowed=NO;OPInputRevisionAccepted=NO;
    }
    if (geteuid()!=0) { OPStatus(@"HUD 需要专用特权宿主；没有启动原映射"); return 77; }
    // This process consumes authenticated packets. Only the separate broker
    // owns a CBCentralManager and evaluates its actual Bluetooth permissions.
    if(!OPFloatingSession) {
        OPInstanceLock=open(OPRuntimePath(@"com.lixinmo.skytouch.original-host.lock").fileSystemRepresentation,O_CREAT|O_RDWR|O_CLOEXEC|O_NOFOLLOW,0600);
        if (OPInstanceLock<0 || flock(OPInstanceLock,LOCK_EX|LOCK_NB)!=0) { OPStatus(@"已有宿主或无法取得单实例锁；没有创建第二套映射");return 75; }
    }
    const char *frameworks[]={"GraphicsServices","BackBoardServices","SpringBoardServices","FrontBoardServices","AccessibilityUtilities"};
    for (auto name:frameworks) {
        if (OPEngineSession && std::strcmp(name,"AccessibilityUtilities")==0) continue;
        NSString *path=[NSString stringWithFormat:@"/System/Library/PrivateFrameworks/%s.framework/%s",name,name];
        if (!dlopen(path.fileSystemRepresentation,RTLD_NOW|RTLD_GLOBAL)) { OPStatus([@"框架不可用：" stringByAppendingString:path]);return 69; }
    }
    using VoidFunction=void(*)(void);
    auto gs=(VoidFunction)dlsym(RTLD_DEFAULT,"GSInitialize");
    auto displays=(VoidFunction)dlsym(RTLD_DEFAULT,"BKSDisplayServicesStart");
    auto initialize=(VoidFunction)dlsym(RTLD_DEFAULT,"UIApplicationInitialize");
    auto singleton=(void(*)(Class))dlsym(RTLD_DEFAULT,"UIApplicationInstantiateSingleton");
    auto eventInit=(void(*)(Boolean))dlsym(RTLD_DEFAULT,"GSEventInitialize");
    auto eventMode=(void(*)(CFStringRef))dlsym(RTLD_DEFAULT,"GSEventPushRunLoopMode");
    if (!gs||!displays||!initialize||!singleton||!eventInit||!eventMode) { OPStatus(@"缺少全局 UIKit 宿主接口");return 69; }
    ((void(*)(id,SEL))objc_msgSend)(UIScreen.class,NSSelectorFromString(@"initialize"));
    CFRunLoopGetCurrent(); gs(); displays(); initialize(); singleton(OPHUDApplication.class);
    void *io=nullptr;
    if (!OPEngineSession) {
        if (!OPEventInputReady) { OPStatus(@"未建立可验证的 UI 事件入口，原界面没有启动");return 69; }
        for (NSString *name in @[@"SBSAccessibilityWindowHostingController",@"FBSOrientationObserver",@"AXEventRepresentation"])
            if (!NSClassFromString(name)) { OPStatus([@"缺少原 UI 托管所需系统类：" stringByAppendingString:name]);return 69; }
        OPHostingControllers=[NSMutableDictionary dictionary]; OPUITouches=[NSMutableDictionary dictionary];
        io=dlopen("/System/Library/Frameworks/IOKit.framework/IOKit",RTLD_NOW|RTLD_LOCAL);
        OPHIDType=(uint32_t(*)(const void *))dlsym(io,"IOHIDEventGetType");
        OPHIDInteger=(CFIndex(*)(const void *,uint32_t))dlsym(io,"IOHIDEventGetIntegerValue");
        OPHIDChildren=(CFArrayRef(*)(const void *))dlsym(io,"IOHIDEventGetChildren");
        if (!io || !OPHIDType || !OPHIDInteger || !OPHIDChildren) { OPStatus(@"无法校验入站 HID，未启动原 UI");return 69; }
    }
    // No output backend exists in UI-only mode: even reset/shutdown cannot
    // emit a cancellation frame. Inbound original-UI interaction is retained.
    if (!OPVerifyUIOnly) { OPOutput=[OPSystemTouch new]; [OPOutput prepare]; }
    NSString *foregroundError=nil;
    if (!OPStartForegroundContext(&foregroundError)) {
        OPStatus([@"显示布局上下文不可用：" stringByAppendingString:foregroundError ?: @"未知错误"]);
        if (OPFloatingSession || !(OPVerifyUIOnly && OPForcedTargetBundle)) return 69;
    }
    static OPHUDDelegate *delegate; delegate=[OPHUDDelegate new];
    UIApplication.sharedApplication.delegate=delegate;
    SEL accessibility=NSSelectorFromString(@"_accessibilityInit");
    if (!OPEngineSession) ((void(*)(id,SEL))objc_msgSend)(UIApplication.sharedApplication,accessibility);
    eventInit(false);eventMode(kCFRunLoopDefaultMode);
    NSString *inputError=nil;
    if (!OPEngineSession && !OPStartInboundMonitor(io,&inputError)) { OPStatus(inputError); return 69; }
    int stopToken=-1,lockToken=-1,captureToken=-1,managedStopToken=-1,manualStopToken=-1;
    if (OPVerifyUIOnly && !OPFloatingSession)
        notify_register_dispatch("com.lixinmo.skytouch.original.capture-ui",&captureToken,dispatch_get_main_queue(),^(__unused int token) {
            OPCaptureOwnUI();
        });
    notify_register_dispatch("com.lixinmo.skytouch.original.stop",&stopToken,dispatch_get_main_queue(),^(__unused int token) {
        if(OPFloatingSession){OPFloatingClose(NO,NO);return;}
        // Legacy external stop remains supported. Route the managed request
        // through its parent so the parent observes a requested, drained exit.
        if (OPManagedSessionID) {
            notify_post("com.lixinmo.skytouch.runtime.maintenance-stop");return;
        }
        OPBeginShutdown(@"已请求停止原版系统宿主",YES,0);
    });
    notify_register_dispatch("com.apple.springboard.lockcomplete",&lockToken,dispatch_get_main_queue(),^(__unused int token) {
        if(OPFloatingSession) {
            OPFloatingDisplayAllowed=NO;
            OPFloatingSystemGesture.reset();
            OPFloatingPresentation.endSystemGesture(NSProcessInfo.processInfo.systemUptime);
            OPFloatingYieldPresentation(@"locked");return;
        }
        // The parent's verified layout observer requests this child's exit;
        // keep the ACK until that unique request arrives to avoid a lock race.
        OPBeginShutdown(@"锁屏：已取消原宿主输入",!OPManagedSessionID,0);
    });
    if (OPManagedSessionID) {
        NSString *name=OPManagedSessionStopNotification(OPManagedSessionID);
        if (notify_register_dispatch(name.UTF8String,&managedStopToken,dispatch_get_main_queue(),^(__unused int token) {
            OPBeginShutdown(@"监督器正在结束当前目标会话",YES,0);
        })!=NOTIFY_STATUS_OK) { OPStopInboundMonitor(); OPStatus(@"无法注册受监督会话停止通知"); return 69; }
        OPManagedParentTimer=[NSTimer timerWithTimeInterval:0.5 repeats:YES block:^(__unused NSTimer *timer) {
            // Parenthood cannot silently attach to a reused PID: on parent
            // death the kernel reparents this child, even if that PID recurs.
            if (getppid()!=OPManagedParentPID) OPBeginShutdown(@"监督器已退出；取消原宿主触点后退出",YES,0);
        }];
        [NSRunLoop.mainRunLoop addTimer:OPManagedParentTimer forMode:NSRunLoopCommonModes];
    } else if (OPVerifyUIOnly && !OPFloatingSession) {
        notify_register_dispatch("com.lixinmo.skytouch.original.ui-only.stop",&manualStopToken,dispatch_get_main_queue(),^(__unused int token) {
            OPBeginShutdown(@"已停止独立原界面验证",YES,0);
        });
    }
    SEL complete=NSSelectorFromString(@"__completeAndRunAsPlugin");
    if (![UIApplication.sharedApplication respondsToSelector:complete]) { OPStopInboundMonitor(); OPStatus(@"UIKit 不支持插件宿主启动"); return 69; }
    OPStatus(OPFloatingSession ? @"本地方案悬浮入口已启动；点开图标即可切换已保存方案" : OPVerifyUIOnly ? @"UI-only：原界面验证宿主已启动，系统出站 HID 始终禁用" :
        OPEngineSession ? @"原引擎系统会话启动，正在加载当前全局方案" : @"独立调试宿主已启动，等待指定验证界面");
    ((void(*)(id,SEL))objc_msgSend)(UIApplication.sharedApplication,complete);
    // didFinishLaunching can synchronously publish a more specific session
    // stage while completing startup. Keep that stage on return.
    OPStatus(nil);
    CFRunLoopRun(); OPStopInboundMonitor(); return 0;
}

int OPRunHUD(void) { return OPRunHUDWithOptions(NO,nil); }
int OPRunHUDWithOptions(BOOL verifyUIOnly,NSString *targetBundle) {
    if (targetBundle && ![targetBundle isEqualToString:@"com.lixinmo.skytouch.probe"]) {
        std::fputs("--target-bundle only accepts com.lixinmo.skytouch.probe\n",stderr); return 64;
    }
    return OPRunHUDInternal(verifyUIOnly,targetBundle);
}
int OPRunManagedHUD(NSString *session,NSString *targetBundle) {
    const pid_t parent=getppid();
    if (!OPManagedSessionIdentifierIsValid(session) || !OPManagedTargetIsValid(targetBundle) || parent<=1) {
        std::fputs("managed HUD requires a valid session, target and living parent\n",stderr); return 64;
    }
    OPManagedSessionID=[session.uppercaseString copy]; OPManagedParentPID=parent; OPEngineSession=YES;
    return OPRunHUDInternal(NO,targetBundle);
}
int OPRunFloatingConfiguration(NSString *targetBundle) {
    if(geteuid()!=0 || !OPManagedTargetIsValid(targetBundle))return 64;
    NSDictionary *intent=OPMappingRuntimeIntent();
    const char *generation=getenv("SKYTOUCH_RUNTIME_GENERATION");
    NSString *expected=generation ? [NSString stringWithUTF8String:generation] : nil;
    if(![intent[@"enabled"] boolValue] || !OPManagedSessionIdentifierIsValid(expected) ||
        ![intent[@"generation"] isEqual:expected])return 0;
    // Only the live mapping supervisor can own the global floating process.
    // Neither App activation nor a standalone reveal command launches it.
    pid_t parent=getppid();char parentPath[4096]={};
    auto processPath=(int(*)(int,void *,uint32_t))dlsym(RTLD_DEFAULT,"proc_pidpath");
    if(parent<=1 || !processPath || processPath(parent,parentPath,sizeof(parentPath))<=0 ||
        !OPServiceExecutablePathsMatch([NSString stringWithUTF8String:parentPath],OPMappingServiceExecutablePath()))return 77;
    OPFloatingParentPID=parent;OPFloatingRuntimeGeneration=expected;
    const auto lease=op_floating_lease::acquire(OPFloatingLockPath.fileSystemRepresentation,0,getenv("SKYTOUCH_FLOATING_LOCK_FD"));
    unsetenv("SKYTOUCH_FLOATING_LOCK_FD");
    if(lease.descriptor<0)return lease.status;
    OPFloatingLock=lease.descriptor;
    OPFloatingSession=YES;
    // Logical editor layout remains landscape on a portrait desktop. The
    // physical icon stays in fixed display coordinates through every rotation.
    OPOrientation=UIInterfaceOrientationLandscapeLeft;
    return OPRunHUDInternal(YES,targetBundle);
}

static NSDictionary *OPInspectSelector(NSString *className,NSString *selectorName,BOOL classMethod) {
    Class cls=NSClassFromString(className); SEL selector=NSSelectorFromString(selectorName);
    Method method=cls ? (classMethod ? class_getClassMethod(cls,selector) : class_getInstanceMethod(cls,selector)) : nullptr;
    const char *encoding=method ? method_getTypeEncoding(method) : nullptr;
    return @{@"class":className,@"selector":selectorName,@"classMethod":@(classMethod),
        @"available":@(method!=nullptr),@"encoding":encoding ? [NSString stringWithUTF8String:encoding] : @""};
}

int OPInspectHost(void) {
    @autoreleasepool {
        // Deliberately do not use OPRunHUD/OPStatus here: inspection must not
        // take the host lock, create a status file, bootstrap UIKit, or load the
        // original library. Only system framework availability is inspected.
        NSMutableDictionary *frameworks=[NSMutableDictionary dictionary];
        for (NSString *name in @[@"GraphicsServices",@"BackBoardServices",@"SpringBoardServices",@"FrontBoardServices",@"AccessibilityUtilities"]) {
            NSString *path=[NSString stringWithFormat:@"/System/Library/PrivateFrameworks/%@.framework/%@",name,name];
            dlerror(); void *handle=dlopen(path.fileSystemRepresentation,RTLD_NOW|RTLD_GLOBAL);
            const char *failure=handle ? nullptr : dlerror();
            frameworks[name]=@{@"available":@(handle!=nullptr),@"path":path,
                @"error":failure ? [NSString stringWithUTF8String:failure] : @""};
        }
        NSMutableDictionary *symbols=[NSMutableDictionary dictionary];
        for (NSString *name in @[@"GSInitialize",@"BKSDisplayServicesStart",@"UIApplicationInitialize",@"UIApplicationInstantiateSingleton",
            @"GSEventInitialize",@"GSEventPushRunLoopMode",@"BKSHIDEventRegisterEventCallback",@"SBSCopyFrontmostApplicationDisplayIdentifier"])
            symbols[name]=@(dlsym(RTLD_DEFAULT,name.UTF8String)!=nullptr);
        NSMutableArray *selectors=[NSMutableArray array];
        for (NSArray *item in @[
            @[@"SBSAccessibilityWindowHostingController",@"registerWindowWithContextID:atLevel:",@NO],
            @[@"UIWindow",@"_contextId",@NO],@[@"UIEventDispatcher",@"_installEventRunLoopSources:",@NO],
            @[@"UIEventFetcher",@"setEventFetcherSink:",@NO],@[@"FBSOrientationObserver",@"setHandler:",@NO],
            @[@"FBSOrientationObserver",@"activeInterfaceOrientation",@NO],
            @[@"AXEventRepresentation",@"representationWithHIDEvent:hidStreamIdentifier:",@YES],
            @[@"UIApplication",@"_accessibilityInit",@NO],@[@"UIApplication",@"__completeAndRunAsPlugin",@NO]])
            [selectors addObject:OPInspectSelector(item[0],item[1],[item[2] boolValue])];
        NSString *frontmost=@"", *frontmostError=@"";
        auto copyFrontmost=(CFStringRef(*)(void))dlsym(RTLD_DEFAULT,"SBSCopyFrontmostApplicationDisplayIdentifier");
        if (copyFrontmost) {
            @try { id value=CFBridgingRelease(copyFrontmost()); if ([value isKindOfClass:NSString.class]) frontmost=value; }
            @catch (NSException *exception) { frontmostError=exception.reason ?: exception.name; }
        }
        void *security=dlopen("/System/Library/Frameworks/Security.framework/Security",RTLD_NOW|RTLD_LOCAL);
        auto createTask=security ? (CFTypeRef(*)(CFAllocatorRef))dlsym(security,"SecTaskCreateFromSelf") : nullptr;
        auto entitlement=security ? (CFTypeRef(*)(CFTypeRef,CFStringRef,CFErrorRef *))dlsym(security,"SecTaskCopyValueForEntitlement") : nullptr;
        CFTypeRef task=createTask ? createTask(kCFAllocatorDefault) : nullptr;
        NSMutableDictionary *entitlements=[NSMutableDictionary dictionary];
        for (NSString *key in @[@"platform-application",@"com.apple.private.security.no-sandbox",@"com.apple.private.persona-mgmt",
            @"com.apple.QuartzCore.displayable-context",@"com.apple.QuartzCore.secure-mode",@"com.apple.backboard.client",
            @"com.apple.springboard.accessibility-window-hosting",@"com.apple.private.hid.client.event-dispatch",
            @"com.apple.private.hid.client.event-monitor",@"com.apple.private.hid.client.event-filter",
            @"com.apple.private.hid.client.service-protected",@"com.apple.private.hid.manager.client"]) {
            CFErrorRef issue=nullptr;
            id value=task && entitlement ? CFBridgingRelease(entitlement(task,(__bridge CFStringRef)key,&issue)) : nil;
            NSError *error=CFBridgingRelease(issue);
            id jsonValue=value ?: NSNull.null;
            if (![NSJSONSerialization isValidJSONObject:@[jsonValue]]) jsonValue=[jsonValue description];
            entitlements[key]=@{@"declared":jsonValue,@"error":error.localizedDescription ?: @""};
        }
        if (task) CFRelease(task);
        void *io=dlopen("/System/Library/Frameworks/IOKit.framework/IOKit",RTLD_NOW|RTLD_LOCAL);
        auto createClient=io ? (CFTypeRef(*)(CFAllocatorRef))dlsym(io,"IOHIDEventSystemClientCreate") : nullptr;
        CFTypeRef client=nullptr;
        NSString *clientError=@"";
        @try { if (createClient) client=createClient(kCFAllocatorDefault); }
        @catch (NSException *exception) { clientError=exception.reason ?: exception.name; }
        const BOOL clientCreated=client!=nullptr;
        if (client) CFRelease(client);
#if defined(__arm64e__)
        NSString *architecture=@"arm64e";
#elif defined(__arm64__)
        NSString *architecture=@"arm64";
#else
        NSString *architecture=@"other";
#endif
        NSDictionary *report=@{@"mode":@"inspect-host",@"pid":@(getpid()),@"uid":@(geteuid()),@"architecture":architecture,
            @"bundleIdentifier":NSBundle.mainBundle.bundleIdentifier ?: @"",@"systemVersion":NSProcessInfo.processInfo.operatingSystemVersionString,
            @"frameworks":frameworks,@"symbols":symbols,@"selectors":selectors,
            @"frontmostBundle":frontmost,@"frontmostError":frontmostError,
            @"entitlementReadAvailable":@(task!=nullptr && entitlement!=nullptr),@"entitlements":entitlements,
            @"iohid":@{@"libraryAvailable":@(io!=nullptr),@"createSymbolAvailable":@(createClient!=nullptr),
                @"dispatchSymbolAvailable":@(io && dlsym(io,"IOHIDEventSystemClientDispatchEvent")),
                @"clientCreated":@(clientCreated),@"clientError":clientError,@"eventCallbacksRegistered":@NO,
                @"dispatchAttempted":@NO,@"dispatchAuthorizationVerified":@NO,@"deliveryVerified":@NO},
            @"originalLibraryLoaded":@NO,@"windowsHosted":@NO,@"touchesGenerated":@NO,
            @"note":@"仅检查接口、自身声明权限及只读客户端创建；没有发送事件，不代表已获准发送或触屏已送达。"};
        NSData *json=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil];
        if (!json) { std::fputs("{\"mode\":\"inspect-host\",\"error\":\"JSON serialization failed\"}\n",stdout); return 70; }
        std::fwrite(json.bytes,1,json.length,stdout); std::fputc('\n',stdout); std::fflush(stdout);
        return 0;
    }
}
