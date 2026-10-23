#pragma once
#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN
// In-process, synchronous request after a complete global snapshot was saved.
// The launcher starts/confirms the service before UIKit can background the app.
FOUNDATION_EXPORT NSNotificationName const OPConfigurationApplyAndStartNotification;
// The launcher selects the cloud source before opening its native editor.
FOUNDATION_EXPORT NSNotificationName const OPConfigurationSelectionDidChangeNotification;
UIViewController *OPMakeConfigurationPicker(void);
BOOL OPSelectConfigurationTarget(NSString *targetBundleID, NSString * _Nullable * _Nullable error);
// A local/current editor, with no app-list controller in its navigation path.
UIViewController *OPMakeConfigurationEditor(NSString * _Nullable targetBundleID);
// The floating host owns the configuration lease, original-host lock and
// profile preparation before presenting this controller. Close fires only
// after local edits have been saved and any current plan published.
UIViewController *OPMakeFloatingConfigurationEditor(NSString *targetBundleID, dispatch_block_t didCommitAndClose);
BOOL OPCommitConfigurationSession(NSString * _Nullable * _Nullable error);
NSArray<UIWindow *> *OPConfigurationOverlayWindows(void);
// Display direction comes exclusively from the host's accepted layout snapshot.
// Plan coordinates remain landscape. Portrait uses the user's counter-clockwise
// virtual landscape rule; actual landscape follows the corresponding display side.
void OPSetFloatingConfigurationDisplayOrientation(UIInterfaceOrientation orientation);
void OPLayoutFloatingConfigurationWindow(UIWindow *window, UIInterfaceOrientation orientation);
UIViewController * _Nullable OPFloatingWindowContentController(UIWindow *window);
// A screenshot picker or its image transfer is still active. The host can keep
// that presentation alive when temporarily hiding its ordinary overlay windows.
BOOL OPConfigurationPresentationInProgress(void);
NSDictionary *OPCurrentEditorSelection(void);
// Compatibility alias for directly opening a source library editor. This does not
// select a global scheme, enable the supervisor, or generate touch input.
UIViewController *OPMakeConfigurationPickerForTarget(NSString *targetBundleID);
BOOL OPConfigurationSessionLoaded(void);
// True while the App's native editor (including its system photo picker) is
// presented. The launcher can remain portrait outside this full-screen flow.
BOOL OPConfigurationNativeEditorActive(void);
void OPHideConfigurationSession(void);
// Called only for real application backgrounding, never transient resign-active.
// A loaded original singleton belongs to one target for this process lifetime.
void OPConfigurationDidEnterBackground(void);
// Management is entered only after closing the native editor. Replacement
// permanently quiesces this process after saving its local preferences; the
// caller must require a relaunch even if subsequent replacement fails.
BOOL OPPrepareConfigurationForManagement(BOOL replacing, NSString * _Nullable * _Nullable error);
NS_ASSUME_NONNULL_END
