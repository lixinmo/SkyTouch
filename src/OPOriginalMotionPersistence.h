#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
#ifdef __cplusplus
extern "C" {
#endif
// Install before the first original FDG read. Preserves signed type-35 MOBA
// motion sensitivity through the original parser, copier, and JSON writer.
BOOL OPInstallOriginalMotionPersistenceFix(NSString * _Nullable * _Nullable error);
// Call after explicitly editing both sensitivities, including legitimate -1.
// Missing legacy fields otherwise retain their absent/default distinction.
void OPMarkOriginalMotionSensitivityPresent(id key);
void OPMarkOriginalMotionSensitivityAxesPresent(id key, BOOL horizontal, BOOL vertical);
BOOL OPOriginalMotionSensitivityIsPresent(id key, BOOL horizontal);
#ifdef __cplusplus
}
#endif
NS_ASSUME_NONNULL_END
