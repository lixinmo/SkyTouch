#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Install only in the native configuration App, after loading the original
// library and before creating its controller. This never enables BLE/output.
BOOL OPInstallOriginalOfflineEditor(NSString *_Nullable *_Nullable error);
// Freeze the editing slot until Finish, so reconnecting a different device
// cannot discard an in-progress draft. Identity storage is owned by the caller.
BOOL OPPrepareOriginalOfflineEditor(NSInteger deviceType, NSString *deviceName,
                                   NSString *_Nullable *_Nullable error);
void OPFinishOriginalOfflineEditor(void);
BOOL OPOriginalOfflineEditorEnabled(void);
NSDictionary *OPOriginalOfflineEditorStatus(void);
NS_ASSUME_NONNULL_END
