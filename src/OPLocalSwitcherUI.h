#pragma once
#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN
UIViewController *OPMakeLocalSwitcher(NSString *target,NSString *name,dispatch_block_t close);
void OPRefreshLocalSwitcher(UIViewController *controller,NSString *target,NSString *name);
void OPRefreshLocalSwitcherConnection(UIViewController * _Nullable controller);
void OPConsumeLocalSwitcherInput(UIViewController *controller,NSDictionary *snapshot);
void OPCancelLocalSwitcherInput(UIViewController * _Nullable controller);
BOOL OPLocalSwitcherBusy(UIViewController * _Nullable controller);
NSDictionary *OPLocalSwitcherStatus(UIViewController * _Nullable controller);
NS_ASSUME_NONNULL_END
