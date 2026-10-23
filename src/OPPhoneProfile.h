#pragma once
#import <Foundation/Foundation.h>
#include <stdint.h>
NS_ASSUME_NONNULL_BEGIN
// Temporary engine projection only. Never save this data as a user profile.
NSData * _Nullable OPPhoneRuntimeProfile(NSData *source,NSInteger deviceType,NSString * _Nullable * _Nullable error);
NSArray<NSString *> *OPPhoneBindableKeys(NSInteger deviceType);
BOOL OPPhoneLogicalKeyMask(NSString *key,NSInteger deviceType,uint32_t * _Nullable mask);
NS_ASSUME_NONNULL_END
