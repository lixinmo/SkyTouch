#pragma once
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
NS_ASSUME_NONNULL_BEGIN
// Main thread, after original dlopen + fixed profile context + original-image
// NSLog silencing, and before creating the original account/cloud UI.
// Hooks this process's original login, native HTTP and cloud-file download.
// Downloads are staged with the original FDG serializer and become visible
// only after a successful atomic commit and read-back; they are not applied.
BOOL OPInstallOriginalCloudTransport(NSString *targetBundleID,
                                    NSString * _Nullable * _Nullable error);
// True only after a valid HTTPS login in this process. A matching persisted
// verification marker permits cloud requests but does not make this true.
BOOL OPOriginalCloudNetworkVerified(void);
// Keep a configuration session open while its explicit login/download is in
// progress. No Bluetooth ownership or global mapping is changed by this API.
BOOL OPOriginalCloudTransferInProgress(void);
// The local/probe profile aliases are storage namespaces, never game package
// IDs for Flydigi cloud queries. Main-thread UI owners can route the original
// cloud button to their game-source picker without replacing account login.
void OPSetOriginalCloudSourceRequiredHandler(dispatch_block_t _Nullable handler);
// Main-thread precondition for publishing: compare the original serializer's
// current slot for deviceType (0/1/2) with the same slot on disk. Never saves
// editor drafts or applies a downloaded library item on the caller's behalf.
BOOL OPValidateOriginalCurrentPlanOnDisk(NSInteger deviceType,
                                        NSString * _Nullable * _Nullable error);
// Main-thread diagnostic snapshot: no account, URL, query, body or token values.
NSDictionary *OPOriginalCloudStatus(void);
NS_ASSUME_NONNULL_END
