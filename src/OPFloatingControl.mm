#import "OPStoragePaths.h"
#import "OPFloatingControl.h"
#import "OPSessionSupervisor.h"
#import "OPRuntimeControl.h"
#import <notify.h>
#import <signal.h>
#include <cmath>
#include <cerrno>

NSDictionary *OPFloatingConfigurationStatus(void) {
    NSDictionary *state=[NSDictionary dictionaryWithContentsOfFile:
        OPRuntimePath(@"com.lixinmo.skytouch.floating-status.plist")];
    if(![state[@"pid"] isKindOfClass:NSNumber.class] || ![state[@"time"] isKindOfClass:NSNumber.class])return nil;
    const double age=NSDate.date.timeIntervalSince1970-[state[@"time"] doubleValue];
    pid_t pid=[state[@"pid"] intValue];
    return std::isfinite(age) && age>=0 && age<4 && pid>1 && (kill(pid,0)==0 || errno==EPERM) ? state : nil;
}
NSString *OPFloatingConfigurationLaunchProblem(void) {
    if(!OPMappingRuntimeEnabled() || OPFloatingConfigurationStatus())return nil;
    NSDictionary *state=[NSDictionary dictionaryWithContentsOfFile:OPSupervisorStatusPath];
    NSString *fault=state[@"fault"];
    return [fault isKindOfClass:NSString.class] && fault.length ? fault : @"正在等待映射服务显示浮标。";
}
BOOL OPShowFloatingConfiguration(NSString *target,NSString **error) {
    if(error)*error=nil;
    if(!OPManagedTargetIsValid(target)){if(error)*error=@"请先选择游戏。";return NO;}
    if(!OPMappingRuntimeEnabled()){if(error)*error=@"请先开启映射，再显示浮标。";return NO;}
    if(notify_post("com.lixinmo.skytouch.floating.reveal")!=NOTIFY_STATUS_OK) {
        if(error)*error=@"浮标显示请求失败，请重试。";return NO;
    }
    return YES;
}
