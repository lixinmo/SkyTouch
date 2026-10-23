#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
#ifdef __cplusplus
extern "C" {
#endif
// Adds a compatibility editor for existing type-35 MOBA motion keys. It does
// not create keys, convert other functions, or reinterpret lock-duration units.
BOOL OPInstallOriginalMOBAEditor(NSString * _Nullable * _Nullable error);
#ifdef __cplusplus
}
#endif
NS_ASSUME_NONNULL_END
