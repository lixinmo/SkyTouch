#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// One shared per-target tree for the mobile configuration app and root engine.
// Invalid/unsafe bundle names return nil. This never reads another app's data.
NSString * _Nullable OPOriginalDocumentsForTarget(NSString *targetBundleID);
// Root migrates only this project's directory ancestors and this target's tree
// to mobile (501:501), directories 0700 / regular files 0600, without changing
// file contents. Symlinks, hardlinked files and special files are rejected.
// Mobile may prepare its own tree; existing root-owned items require the root
// helper. Call after the old engine has exited, and again at engine drain to
// repair any new inode written by the original root process. This is not a
// locking primitive: configuration and engine must not write concurrently.
BOOL OPPrepareSharedOriginalProfile(NSString *targetBundleID,
                                    NSString * _Nullable * _Nullable error);

// Mirror only the six verified original preference keys, preserving plist
// values/types, in Documents/skytouch-original-defaults.plist. Import before
// the first original dlopen; export on save/exit BEFORE BLE cleanup and before
// engine drain. Missing keys are removed from this process's standard defaults.
// Other defaults and the vendor account/settings archive/FDG are untouched.
// Once imported, this process's preference target cannot be changed.
BOOL OPImportOriginalProfileDefaults(NSString *targetBundleID,
                                     NSString * _Nullable * _Nullable error);
BOOL OPExportOriginalProfileDefaults(NSString *targetBundleID,
                                     NSString * _Nullable * _Nullable error);

// Call once on the main thread, after dlopen(..., RTLD_NOW) of the verified
// original arm64 image and BEFORE creating FLEXManager/FZCentralViewController.
// The target and Documents directory remain fixed for this process lifetime.
// Only the original image's Documents import, FLEXUtility.getLocalBundleID and
// FZHttpTool.getBundleId are redirected. Caller-side game-prefix normalization
// remains original. The original image's NSLog/NSLogv imports become no-ops
// before its UI can expose login fields; host diagnostic imports are unchanged.
// No NSBundle/NSHomeDirectory or process-wide replacement.
BOOL OPConfigureOriginalContext(void * _Nullable dlopenHandle, NSString *targetBundleID,
                                NSString *documentsDirectory,
                                NSString * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
