#import "OPConfigurationManager.h"
#import "OPConfigurationUI.h"
#import "OPStoragePaths.h"
#import "OPServicePaths.h"
#import "OPSpawnAttributes.h"
#import "OPRuntimeControl.h"
#import "OPBluetoothBroker.h"
#import <UIKit/UIKit.h>
#import <notify.h>
#include <spawn.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <unistd.h>
#include <cerrno>
#include <cstring>

extern char **environ;
namespace {
static BOOL busy=NO;
static pid_t waitChild(pid_t child,int *status,int options) {
    pid_t result;do{result=waitpid(child,status,options);}while(result<0&&errno==EINTR);return result;
}
// This pipe is private to the parent and the root helper. Configuration values
// never go through NSLog, shell arguments, status files, or Darwin notifications.
NSDictionary *runHelper(NSString *operation,NSString *basename,NSString **error) {
    if(error)*error=nil;
    NSString *program=[OPApplicationBundlePath() stringByAppendingPathComponent:@"SkyTouchStorage"];
    if(!program.length){if(error)*error=@"配置管理组件缺失，请重新安装完整包。";return nil;}
    int channel[2];
    if(pipe(channel)){if(error)*error=@"无法建立配置管理通道。";return nil;}
    for(int fd:channel)(void)fcntl(fd,F_SETFD,FD_CLOEXEC);
    (void)fcntl(channel[0],F_SETFL,O_NONBLOCK);
    posix_spawnattr_t attributes;posix_spawn_file_actions_t actions;
    int code=posix_spawnattr_init(&attributes);BOOL attributesReady=code==0;
    if(!code)code=posix_spawn_file_actions_init(&actions);
    BOOL actionsReady=code==0;
    if(!code)code=posix_spawnattr_setflags(&attributes,POSIX_SPAWN_CLOEXEC_DEFAULT);
    if(!code)code=OPSpawnInNewProcessGroup(&attributes);
    using Persona=int(*)(const posix_spawnattr_t *,uid_t,uint32_t);
    using Identity=int(*)(const posix_spawnattr_t *,uid_t);
    auto persona=(Persona)dlsym(RTLD_DEFAULT,"posix_spawnattr_set_persona_np");
    auto uid=(Identity)dlsym(RTLD_DEFAULT,"posix_spawnattr_set_persona_uid_np");
    auto gid=(Identity)dlsym(RTLD_DEFAULT,"posix_spawnattr_set_persona_gid_np");
    if(!code && (!persona||!uid||!gid))code=ENOSYS;
    if(!code)code=persona(&attributes,99,1);
    if(!code)code=uid(&attributes,0);
    if(!code)code=gid(&attributes,0);
    if(!code)code=posix_spawn_file_actions_adddup2(&actions,channel[1],STDOUT_FILENO);
    if(!code)code=posix_spawn_file_actions_addopen(&actions,STDERR_FILENO,"/dev/null",O_WRONLY,0);
    char *arguments[]={(char *)program.fileSystemRepresentation,(char *)"manage",(char *)operation.UTF8String,
        basename.length ? (char *)basename.UTF8String : nullptr,nullptr};
    pid_t child=0;
    if(!code)code=posix_spawn(&child,program.fileSystemRepresentation,&actions,&attributes,arguments,environ);
    if(actionsReady)posix_spawn_file_actions_destroy(&actions);
    if(attributesReady)posix_spawnattr_destroy(&attributes);
    close(channel[1]);
    if(code){close(channel[0]);if(error)*error=[NSString stringWithFormat:@"配置管理组件无法启动（%d）。",code];return nil;}
    NSMutableData *response=[NSMutableData data];BOOL exited=NO,complete=NO,failed=NO;
    int status=0;const double deadline=NSProcessInfo.processInfo.systemUptime+120;
    while(!complete && !failed && NSProcessInfo.processInfo.systemUptime<deadline) {
        unsigned char bytes[16384];ssize_t count=read(channel[0],bytes,sizeof(bytes));
        if(count>0){[response appendBytes:bytes length:(NSUInteger)count];if(response.length>36*1024*1024)failed=YES;}
        else if(count==0)complete=YES;
        else if(errno!=EAGAIN && errno!=EWOULDBLOCK && errno!=EINTR)failed=YES;
        if(!exited){pid_t result=waitChild(child,&status,WNOHANG);if(result==child)exited=YES;else if(result<0)failed=YES;}
        if(!complete && count<=0){pollfd poller{channel[0],POLLIN|POLLHUP,0};(void)poll(&poller,1,25);}
    }
    close(channel[0]);
    if(!exited && !failed && complete) {
        for(unsigned retry=0;retry<100 && !exited;++retry) {
            pid_t result=waitChild(child,&status,WNOHANG);
            if(result==child)exited=YES;else if(result<0&&errno!=EINTR){failed=YES;break;}
            if(!exited)usleep(10000);
        }
    }
    if(!exited){kill(child,SIGTERM);usleep(100000);if(waitChild(child,&status,WNOHANG)==0){kill(child,SIGKILL);(void)waitChild(child,&status,0);}failed=YES;}
    id envelope=response.length ? [NSPropertyListSerialization propertyListWithData:response options:NSPropertyListImmutable format:nil error:nil] : nil;
    if(failed || !complete || ![envelope isKindOfClass:NSDictionary.class]) {
        if(error)*error=@"配置管理未能完成。请重新打开凌触，未完成的恢复会自动回滚。";return nil;
    }
    if(![envelope[@"ok"] boolValue] || !WIFEXITED(status) || WEXITSTATUS(status)!=0) {
        id reason=envelope[@"error"];
        if(error)*error=[reason isKindOfClass:NSString.class] && [reason length] ? reason : @"配置管理失败，当前配置已保留。";
        return nil;
    }
    NSDictionary *result=envelope[@"result"];
    if(![result isKindOfClass:NSDictionary.class]){if(error)*error=@"配置管理返回了无效结果。";return nil;}
    return result;
}
BOOL synchronizePendingDefaults(NSDictionary *reply,NSString **error) {
    NSString *identifier=reply[@"pendingID"],*operation=reply[@"pendingOperation"];
    NSDictionary *values=reply[@"mobileDefaults"];
    if(![identifier isKindOfClass:NSString.class] || ![[NSUUID alloc] initWithUUIDString:identifier] ||
       ![@[@"restore",@"clear"] containsObject:operation] || ![values isKindOfClass:NSDictionary.class]) {
        if(error)*error=@"待确认的设置记录无效，请重新打开凌触。";return NO;
    }
    if([operation isEqual:@"clear"] || [reply[@"mobileDefaultsPresent"] isEqual:@NO])
        [NSUserDefaults.standardUserDefaults removePersistentDomainForName:@"com.lixinmo.skytouch.app"];
    else [NSUserDefaults.standardUserDefaults setPersistentDomain:values forName:@"com.lixinmo.skytouch.app"];
    if(![NSUserDefaults.standardUserDefaults synchronize]) {
        if(error)*error=@"设置缓存未能同步，请重新打开凌触继续完成操作。";return NO;
    }
    return YES;
}
}

BOOL OPRecoverConfigurationManagementBeforeLaunch(NSString **error) {
    NSString *data=OPDataRoot();
    NSString *transaction=OPStorageRootedPath(@"/var/mobile/Library/Application Support/.com.lixinmo.skytouch.configuration-transaction-v1");
    NSString *pending=OPStorageRootedPath(@"/var/mobile/Library/Application Support/.com.lixinmo.skytouch.pending-mobile-defaults-v1.plist");
    if(!data.length || !transaction.length || !pending.length){if(error)*error=@"无法定位 RootHide 数据目录。";return NO;}
    struct stat state{};
    const BOOL recovery=lstat(transaction.fileSystemRepresentation,&state)==0 || lstat(pending.fileSystemRepresentation,&state)==0;
    const BOOL absent=lstat(data.fileSystemRepresentation,&state)<0 && errno==ENOENT;
    if(!recovery && !absent)return YES;
    NSDictionary *reply=runHelper(@"recover",nil,error);if(!reply)return NO;
    if(reply[@"pendingID"]) {
        if(!synchronizePendingDefaults(reply,error))return NO;
        if(!runHelper(@"acknowledge",reply[@"pendingID"],error))return NO;
        // Only after a clear's preference acknowledgement may a later launch
        // construct fresh empty directories. Clear itself leaves none behind.
        if(!runHelper(@"recover",nil,error))return NO;
    }
    return YES;
}

void OPPerformConfigurationManagement(NSString *operation,NSString *basename,
        void (^completion)(NSDictionary *,NSString *)) {
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{OPPerformConfigurationManagement(operation,basename,completion);});return;}
    if(busy){completion(nil,@"正在处理配置，请稍候。");return;}
    if(![@[@"list",@"backup",@"restore",@"clear"] containsObject:operation]){completion(nil,@"未知的配置操作。");return;}
    const BOOL replacing=[operation isEqual:@"restore"] || [operation isEqual:@"clear"];
    NSString *failure=nil;
    if(![operation isEqual:@"list"]) {
        if(!OPPrepareConfigurationForManagement(replacing,&failure)){completion(nil,failure);return;}
        if(!OPStopMappingRuntime(&failure)){completion(replacing ? @{@"restartRequired":@YES} : nil,failure);return;}
        if(replacing)notify_post(OPBluetoothBrokerStopNotification);
    }
    busy=YES;
    const UIBackgroundTaskIdentifier task=[UIApplication.sharedApplication beginBackgroundTaskWithName:@"管理配置" expirationHandler:nil];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        NSString *error=nil;NSDictionary *reply=runHelper(operation,basename,&error);
        dispatch_async(dispatch_get_main_queue(),^{
            NSString *completionError=error;
            NSMutableDictionary *result=reply ? [reply mutableCopy] : nil;
            if(replacing) {
                if(!result)result=[NSMutableDictionary dictionary];
                result[@"restartRequired"]=@YES;
                if(reply) {
                    (void)synchronizePendingDefaults(reply,&completionError);
                    [result removeObjectForKey:@"mobileDefaults"];
                }
            }
            if(reply && replacing && !completionError) {
                // A durable pending record survives until both the App's
                // preferences cache and the helper's disk view agree.
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
                    NSString *finishError=nil;NSDictionary *finished=runHelper(@"acknowledge",reply[@"pendingID"],&finishError);
                    dispatch_async(dispatch_get_main_queue(),^{
                        busy=NO;
                        if(task!=UIBackgroundTaskInvalid)[UIApplication.sharedApplication endBackgroundTask:task];
                        completion(result,finished ? nil : (finishError ?: @"设置同步尚未完成，请重新打开凌触继续处理。"));
                    });
                });
                return;
            }
            busy=NO;
            if(task!=UIBackgroundTaskInvalid)[UIApplication.sharedApplication endBackgroundTask:task];
            completion(result,completionError);
        });
    });
}
