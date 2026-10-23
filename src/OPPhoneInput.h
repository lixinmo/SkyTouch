#pragma once
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN
BOOL OPInstallPhoneInput(NSString * _Nullable * _Nullable error);
// After profile load. In controller mode, only controllerMotion=phone uses this
// adapter; the ordinary controller path remains untouched.
BOOL OPStartPhoneInput(id controller,NSInteger deviceType,NSDictionary *settings,NSString * _Nullable * _Nullable error);
BOOL OPPhoneInputReady(void);
void OPSetPhoneInputActive(BOOL active);
void OPSetPhoneInputOrientation(UIInterfaceOrientation orientation);
void OPStopPhoneInput(void);
NSDictionary *OPPhoneInputStatus(void);
NS_ASSUME_NONNULL_END
