#import "OPStoragePaths.h"
#import "OPSessionSupervisor.h"
#import "OPForegroundContext.h"
#import "OPOriginalContext.h"
#import "OPBluetoothBroker.h"
#import "OPGlobalProfile.h"
#import "OPServicePaths.h"
#import "OPRuntimeControl.h"
#include <notify.h>
#include <spawn.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <string>
#include <chrono>
#include <map>
#include <cstdint>
#include <vector>

const char *const OPSupervisorStopNotification="com.lixinmo.skytouch.original.supervisor.stop";
const char *const OPSupervisorProfileUpdatedNotification="com.lixinmo.skytouch.original.profile-updated";
NSString *const OPSupervisorStatusPath=OPRuntimePath(@"com.lixinmo.skytouch.original-supervisor-status.plist");
NSString *const OPSupervisorConfiguredTargetsPath=[OPDataRoot() stringByAppendingPathComponent:@"ConfiguredTargets.plist"];
NSString *const OPSupervisorConfigurationLockPath=OPRuntimePath(@"com.lixinmo.skytouch.original-config.lock");

BOOL OPManagedSessionIdentifierIsValid(NSString *identifier) {
    if (![identifier isKindOfClass:NSString.class] || identifier.length!=36) return NO;
    NSUUID *uuid=[[NSUUID alloc] initWithUUIDString:identifier];
    return uuid && [uuid.UUIDString caseInsensitiveCompare:identifier]==NSOrderedSame;
}
BOOL OPManagedTargetIsValid(NSString *bundle) {
    if (![bundle isKindOfClass:NSString.class] || !bundle.length || bundle.length>255) return NO;
    if ([bundle isEqualToString:@"com.apple.springboard"] ||
        [bundle isEqualToString:@"com.lixinmo.skytouch.app"]) return NO;
    return [bundle rangeOfString:@"^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$"
                        options:NSRegularExpressionSearch].length==bundle.length;
}
NSString *OPManagedSessionStopNotification(NSString *identifier) {
    return OPManagedSessionIdentifierIsValid(identifier) ?
        [@"com.lixinmo.skytouch.original.session." stringByAppendingFormat:@"%@.stop",identifier.uppercaseString] : nil;
}
NSString *OPManagedSessionDrainedNotification(NSString *identifier) {
    return OPManagedSessionIdentifierIsValid(identifier) ?
        [@"com.lixinmo.skytouch.original.session." stringByAppendingFormat:@"%@.drained",identifier.uppercaseString] : nil;
}
BOOL OPPostManagedSessionDrained(NSString *identifier,NSString **error) {
    NSString *name=OPManagedSessionDrainedNotification(identifier);
    if (!name) { if (error) *error=@"invalid managed session identifier"; return NO; }
    int token=-1;
    uint32_t result=notify_register_check(name.UTF8String,&token);
    if (result==NOTIFY_STATUS_OK) result=notify_set_state(token,(uint64_t)getpid());
    if (result==NOTIFY_STATUS_OK) result=notify_post(name.UTF8String);
    if (token>=0) notify_cancel(token);
    if (result!=NOTIFY_STATUS_OK && error)
        *error=[NSString stringWithFormat:@"managed cancellation acknowledgement failed (%u)",result];
    return result==NOTIFY_STATUS_OK;
}

// Pure lifecycle model, exercised with fake PIDs and real local child processes.
// Only the runtime below owns OS resources. No state transition sends a signal.
namespace op_supervisor {
static BOOL launchAttemptCurrent(NSDictionary *record,NSString *attempt) {
    return [record isKindOfClass:NSDictionary.class] && [record[@"version"] isEqual:@1] &&
        [record[@"attempt"] isEqual:attempt] && [record[@"stopRequested"] isKindOfClass:NSNumber.class] &&
        ![record[@"stopRequested"] boolValue];
}
// Return an errno value. No status writes while another supervisor owns the
// lease; readers must continue observing that owner's definitive state.
static int acquireSupervisorLock(int descriptor,NSString *attempt,double timeout,
                                 NSDictionary *(^readAttempt)(void)) {
    const auto deadline=std::chrono::steady_clock::now()+std::chrono::duration<double>(timeout);
    for (;;) {
        if(attempt && !launchAttemptCurrent(readAttempt(),attempt))return ECANCELED;
        if(flock(descriptor,LOCK_EX|LOCK_NB)==0) {
            if(!attempt || launchAttemptCurrent(readAttempt(),attempt))return 0;
            flock(descriptor,LOCK_UN);return ECANCELED;
        }
        const int code=errno;
        if(!attempt || (code!=EWOULDBLOCK && code!=EAGAIN) || std::chrono::steady_clock::now()>=deadline)return code;
        usleep(100000);
    }
}
static BOOL configurationLeaseFree(const char *path,NSString **reason) {
    if (reason) *reason=nil;
    // Never create this file as root: the mobile app owns its creation and
    // keeps the same flock lease through configuration, export and exit.
    int descriptor=open(path,O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK);
    if (descriptor<0) {
        if (errno==ENOENT) return YES;
        if (reason) *reason=[NSString stringWithFormat:@"无法读取配置会话锁，后台保持待机：%s",std::strerror(errno)];
        return NO;
    }
    struct stat metadata{};
    if (fstat(descriptor,&metadata)!=0 || !S_ISREG(metadata.st_mode) || metadata.st_nlink!=1) {
        close(descriptor);
        if (reason) *reason=@"配置会话锁元数据不合法，后台保持待机";
        return NO;
    }
    // Both the supervisor and engine inspect this lease. Shared probes must
    // coexist; an exclusive probe can mistake the other reader for an editor
    // and repeatedly retire an otherwise healthy mapping session. The editor
    // and its preparation helper still hold LOCK_EX for the entire handoff.
    if (flock(descriptor,LOCK_SH|LOCK_NB)!=0) {
        const int code=errno; close(descriptor);
        if (reason) *reason=(code==EWOULDBLOCK || code==EAGAIN) ?
            @"配置App或准备助手仍持有会话锁，等待配置保存及退出" :
            [NSString stringWithFormat:@"无法检查配置会话锁，后台保持待机：%s",std::strerror(code)];
        return NO;
    }
    flock(descriptor,LOCK_UN); close(descriptor);
    return YES;
}
enum class Phase { Waiting, Starting, Running, Stopping, Failed, Stopped };
static const char *phaseName(Phase phase) {
    switch (phase) {
        case Phase::Waiting:return "waiting"; case Phase::Starting:return "starting";
        case Phase::Running:return "running"; case Phase::Stopping:return "stopping";
        case Phase::Failed:return "failed"; case Phase::Stopped:return "stopped";
    }
    return "failed";
}
struct Lifecycle {
    Phase phase=Phase::Waiting;
    std::string desired,target,fault;
    pid_t pid=0;
    bool userStopped=false,stopRequested=false,ack=false,reaped=false,cleanExit=false;
    double stopDeadline=0,ackDeadline=0;
    std::uint64_t spawnCount=0,stopRequestCount=0;
    std::string lastStopReason;
    std::map<std::string,std::uint64_t> stopReasonCounts;
    void recordStop(const std::string &reason) {
        ++stopRequestCount; ++stopReasonCounts[reason]; lastStopReason=reason;
    }
    void fail(const std::string &message) {
        if (fault.empty()) fault=message;
        phase=Phase::Failed; desired.clear();
        // A fault never grants permission to abandon a still-live child.
        if (pid && !reaped && !stopRequested) { stopRequested=true; recordStop("fault"); }
    }
    void settle() {
        if (!fault.empty()) return;
        if (pid) {
            if (!(stopRequested && ack && reaped && cleanExit)) return;
            pid=0; target.clear(); stopRequested=ack=reaped=cleanExit=false;
            stopDeadline=ackDeadline=0; phase=Phase::Waiting;
        }
        if (userStopped) { phase=Phase::Stopped; return; }
        if (phase==Phase::Waiting && !desired.empty()) { target=desired; phase=Phase::Starting; }
    }
    void requestStop(double now,const std::string &reason) {
        if (pid && !stopRequested) {
            stopRequested=true; stopDeadline=now+8; phase=Phase::Stopping; recordStop(reason);
        }
    }
    void profileUpdated(double now) {
        if (userStopped || !fault.empty()) return;
        requestStop(now,"profile-updated"); settle();
    }
    void foreground(std::string bundle,double now,const std::string &reason="profile-or-output-condition") {
        if (userStopped || !fault.empty()) return;
        desired=std::move(bundle);
        if (!pid && phase==Phase::Starting) {
            target=desired; phase=desired.empty() ? Phase::Waiting : Phase::Starting;
        }
        if (pid && target!=desired) requestStop(now,reason);
        settle();
    }
    void spawned(pid_t value) {
        if (phase!=Phase::Starting || value<=1) { fail("invalid child spawn result"); return; }
        pid=value; phase=Phase::Running; ++spawnCount;
    }
    void stop(double now) {
        userStopped=true; desired.clear();
        if (!fault.empty()) return;
        if (!pid) { phase=Phase::Stopped; target.clear(); return; }
        requestStop(now,"user-stop"); settle();
    }
    void acknowledge(pid_t value) {
        if (!pid || value!=pid || !stopRequested) return;
        ack=true; settle();
    }
    void childExited(bool normal,double now) {
        if (!pid || reaped) return;
        reaped=true; cleanExit=normal;
        if (!stopRequested) { fail("managed HUD exited without a supervisor stop request"); return; }
        if (!normal) { fail("managed HUD did not exit normally with status 0"); return; }
        ackDeadline=now+1; settle();
    }
    void tick(double now) {
        if (!fault.empty()) return;
        if (pid && stopRequested && !(ack && reaped && cleanExit)) {
            if (reaped && !ack && ackDeadline>0 && now>=ackDeadline)
                fail("HUD exited without confirmed local touch cancellation; automatic restart disabled");
            else if (stopDeadline>0 && now>=stopDeadline)
                fail("HUD cancellation/exit timed out; automatic restart disabled, no replacement spawned");
        }
    }
    bool finished() const {
        // A failed live child retains this supervisor's lock. A deliberate user
        // stop can finish only once waitpid proved the child is gone.
        return phase==Phase::Stopped || (!fault.empty() && userStopped && (!pid || reaped));
    }
};
static NSString *activeProfileTarget(id document,NSString **error) {
    if (![document isKindOfClass:NSDictionary.class] || ![document[@"schema"] isKindOfClass:NSNumber.class]) {
        if (error) *error=@"请在配置App明确选择当前全局方案"; return nil;
    }
    NSNumber *schema=document[@"schema"];
    if (CFGetTypeID((__bridge CFTypeRef)schema)==CFBooleanGetTypeID() ||
        !std::strchr("cCsSiIlLqQ",schema.objCType[0]) || schema.doubleValue!=3) {
        if (error) *error=@"请在编辑器应用一个具体方案到全局；旧游戏选择记录不代表方案已应用"; return nil;
    }
    id target=document[@"activeProfileTarget"];
    if (!OPManagedTargetIsValid(target)) {
        if (error) *error=@"当前全局方案标识无效，系统触屏待机"; return nil;
    }
    return target;
}
static NSString *confirmedDisplayRetirementReason(NSDictionary *snapshot) {
    if ([snapshot[@"lockKnown"] boolValue] && [snapshot[@"locked"] isKindOfClass:NSNumber.class] &&
        [snapshot[@"locked"] boolValue]) return @"display-locked";
    // The launcher/home/source picker leave global output active. Actual editing
    // owns the configuration lease, checked before this retention policy, and
    // waits for the old engine's host lock before loading the vendor UI.
    // Unknown layout/orientation/backlight also remain output-only pauses.
    return nil;
}
static BOOL preserveChildDuringDisplayPause(const Lifecycle &state,NSString *profile,NSDictionary *snapshot) {
    return state.phase==Phase::Running && state.pid>1 && !state.stopRequested &&
        profile.length && [profile isEqualToString:@(state.target.c_str())] &&
        !confirmedDisplayRetirementReason(snapshot);
}
} // namespace op_supervisor

BOOL OPConfigurationSessionAvailable(NSString **reason) {
    return op_supervisor::configurationLeaseFree(OPSupervisorConfigurationLockPath.fileSystemRepresentation,reason);
}

extern char **environ;
static double OPMonotonicSeconds(void) {
    return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
}
@interface OPSessionRuntime : NSObject {
@public
    op_supervisor::Lifecycle lifecycle;
}
@property(nonatomic,copy) NSString *executable;
@property(nonatomic,copy) NSString *session;
@property(nonatomic,copy) NSString *foregroundReason;
@property(nonatomic) int ackToken;
@property(nonatomic) double lastStopPost;
@property(nonatomic) double lastStatusWrite;
@property(nonatomic,copy) NSDictionary *lastStatus;
@property(nonatomic) BOOL advancing;
@property(nonatomic) BOOL observerStopped;
@property(nonatomic,copy) NSString *activeProfileTarget;
@property(nonatomic,copy) NSString *activeRevision;
@property(nonatomic,copy) NSString *activePlanName;
@property(nonatomic,copy) NSString *configurationError;
@property(nonatomic) double lastConfigurationRead;
@property(nonatomic,copy) NSString *configurationLeaseStatus;
@property(nonatomic,copy) NSString *displayContextStatus;
@property(nonatomic,copy) NSString *retirementReason;
@property(nonatomic) BOOL displayOutputAllowed;
@property(nonatomic) BOOL preservingChildForDisplayPause;
@property(nonatomic,copy) NSString *runtimeGeneration;
@property(nonatomic) pid_t floatingPID;
@property(nonatomic) BOOL floatingStarted;
@property(nonatomic) double lastFloatingStopPost;
- (BOOL)intentMatches;
- (void)startFloating;
- (void)advance;
- (void)acceptForeground:(NSDictionary *)snapshot;
- (void)reloadConfiguration;
@end
@implementation OPSessionRuntime
- (BOOL)intentMatches {
    NSDictionary *intent=OPMappingRuntimeIntent();
    return [intent[@"enabled"] boolValue] && [intent[@"generation"] isEqual:self.runtimeGeneration];
}
- (void)startFloating {
    self.floatingStarted=YES;
    NSDictionary *selection=[NSDictionary dictionaryWithContentsOfFile:OPSettingPath(@"com.lixinmo.skytouch.editor-selection.plist")];
    NSString *target=selection[@"bundle"];
    if(!OPManagedTargetIsValid(target))target=OPManagedTargetIsValid(self.activeProfileTarget) ? self.activeProfileTarget : @"com.lixinmo.skytouch.local";
    NSMutableDictionary *environment=[NSProcessInfo.processInfo.environment mutableCopy];
    environment[@"SKYTOUCH_RUNTIME_GENERATION"]=self.runtimeGeneration;
    [environment removeObjectForKey:@"SKYTOUCH_FLOATING_LOCK_FD"];
    NSMutableArray<NSString *> *entries=[NSMutableArray array];
    for(NSString *key in environment)[entries addObject:[NSString stringWithFormat:@"%@=%@",key,environment[key]]];
    std::vector<char *> env;
    for(NSString *entry in entries)env.push_back(const_cast<char *>(entry.UTF8String));
    env.push_back(nullptr);
    char *arguments[]={(char *)self.executable.fileSystemRepresentation,(char *)"--floating-configuration",
        (char *)"--session-target",(char *)target.UTF8String,nullptr};
    posix_spawnattr_t attributes;int code=posix_spawnattr_init(&attributes);pid_t child=0;
    if(!code) {
        code=posix_spawnattr_setflags(&attributes,POSIX_SPAWN_CLOEXEC_DEFAULT);
        if(!code)code=posix_spawn(&child,self.executable.fileSystemRepresentation,nullptr,&attributes,arguments,env.data());
        posix_spawnattr_destroy(&attributes);
    }
    if(code)lifecycle.fail(std::string("could not launch coupled floating UI: ")+std::strerror(code));
    else self.floatingPID=child;
}
- (instancetype)init {
    if ((self=[super init])) { _ackToken=-1; _session=@""; _foregroundReason=@"waiting for foreground layout"; }
    return self;
}
- (void)acceptForeground:(NSDictionary *)snapshot {
    NSString *target=[self allowedTarget:snapshot];
    self.foregroundReason=self.configurationLeaseStatus.length ? self.configurationLeaseStatus :
        self.displayContextStatus.length ? self.displayContextStatus : target ? @"当前方案全局应用于已解锁屏幕" :
        self.configurationError.length ? self.configurationError : @"请先选择并保存当前全局方案";
    lifecycle.foreground(target.UTF8String ?: "",OPMonotonicSeconds(),self.retirementReason.UTF8String ?: "profile-or-output-condition");
    [self advance];
}
- (void)reloadConfiguration {
    self.lastConfigurationRead=OPMonotonicSeconds();
    NSString *error=nil;
    NSDictionary *document=OPReadGlobalProfile(&error);
    NSString *previous=self.activeRevision;
    self.activeProfileTarget=document ? op_supervisor::activeProfileTarget(document,&error) : @"";
    self.activeRevision=document[@"revision"] ?: @"";self.activePlanName=document[@"planName"] ?: @"";
    if(previous.length && self.activeRevision.length && ![previous isEqual:self.activeRevision])
        lifecycle.profileUpdated(OPMonotonicSeconds());
    self.configurationError=error ?: @"";
}
- (NSString *)allowedTarget:(NSDictionary *)snapshot {
    self.displayOutputAllowed=NO; self.preservingChildForDisplayPause=NO;
    self.retirementReason=@"configuration-lease-unavailable";
    NSString *leaseReason=nil;
    BOOL leaseFree=OPConfigurationSessionAvailable(&leaseReason);
    self.configurationLeaseStatus=leaseReason ?: @"";
    if (!leaseFree) return nil;
    if (!self.activeProfileTarget || OPMonotonicSeconds()-self.lastConfigurationRead>=1) [self reloadConfiguration];
    NSString *target=self.activeProfileTarget;
    self.retirementReason=@"active-profile-unavailable";
    if (!target.length) return nil;
    // The verified revision is the source of truth. Editing/downloading into
    // the source library must not silently replace the active mapping.
    if(!self.activeRevision.length)return nil;
    NSString *displayReason=nil;
    self.displayOutputAllowed=OPGlobalOutputContextAllowed(snapshot,&displayReason);
    self.displayContextStatus=displayReason ?: @"";
    self.retirementReason=@"active-profile-changed";
    if (self.displayOutputAllowed) return target;
    NSString *confirmed=op_supervisor::confirmedDisplayRetirementReason(snapshot);
    self.retirementReason=confirmed ?: @"display-unavailable";
    if (op_supervisor::preserveChildDuringDisplayPause(lifecycle,target,snapshot)) {
        // Host independently cancels immediately and validates every mapped
        // frame against OPGlobalOutputContextAllowed. Keeping this process
        // does not grant permission to send while its display is unknown.
        self.preservingChildForDisplayPause=YES;
        return target;
    }
    if (lifecycle.pid && ![target isEqualToString:@(lifecycle.target.c_str())]) self.retirementReason=@"active-profile-changed";
    return nil;
}
- (void)closeAcknowledgement {
    if (self.ackToken>=0) notify_cancel(self.ackToken);
    self.ackToken=-1;
}
- (void)spawn {
    NSString *leaseReason=nil;
    if (!op_supervisor::configurationLeaseFree(OPSupervisorConfigurationLockPath.fileSystemRepresentation,&leaseReason)) {
        self.configurationLeaseStatus=leaseReason; self.foregroundReason=leaseReason;
        lifecycle.foreground("",OPMonotonicSeconds()); return;
    }
    self.configurationLeaseStatus=@"";
    [self closeAcknowledgement];
    self.session=NSUUID.UUID.UUIDString;
    NSString *ackName=OPManagedSessionDrainedNotification(self.session);
    int token=-1;
    uint32_t code=notify_register_check(ackName.UTF8String,&token);
    if (code!=NOTIFY_STATUS_OK) { lifecycle.fail("could not register managed cancellation acknowledgement"); return; }
    self.ackToken=token;
    if (notify_set_state(token,0)!=NOTIFY_STATUS_OK) { lifecycle.fail("could not initialize managed acknowledgement"); return; }
    NSString *target=[NSString stringWithUTF8String:lifecycle.target.c_str()];
    if (!OPManagedTargetIsValid(target)) { lifecycle.fail("invalid selected global profile"); return; }
    // argv contains no shell expression; there is no arbitrary program option.
    const char *values[]={self.executable.fileSystemRepresentation,"--original-hud","--engine-session","--managed-session",
        self.session.UTF8String,"--session-target",target.UTF8String,nullptr};
    char *arguments[8];
    for (unsigned index=0;index<8;++index) arguments[index]=const_cast<char *>(values[index]);
    posix_spawnattr_t attributes;
    int result=posix_spawnattr_init(&attributes);
    if (result) { lifecycle.fail(std::string("spawn attributes: ")+std::strerror(result)); return; }
    // Internal descriptors have CLOEXEC. Do not inherit any incidental open
    // descriptors (especially the supervisor singleton lock) into the HUD.
    result=posix_spawnattr_setflags(&attributes,POSIX_SPAWN_CLOEXEC_DEFAULT);
    pid_t child=0;
    if (!result) result=posix_spawn(&child,values[0],nullptr,&attributes,arguments,environ);
    posix_spawnattr_destroy(&attributes);
    if (result) lifecycle.fail(std::string("could not launch managed HUD: ")+std::strerror(result));
    else { lifecycle.spawned(child); self.lastStopPost=0; }
}
- (void)writeStatus:(double)now {
    NSMutableDictionary *reasons=[NSMutableDictionary dictionary];
    for (const auto &entry:lifecycle.stopReasonCounts) reasons[@(entry.first.c_str())]=@(entry.second);
    NSDictionary *status=@{@"phase":@(op_supervisor::phaseName(lifecycle.phase)),
        @"supervisorPID":@(getpid()),@"childPID":@(lifecycle.pid),@"sessionID":self.session ?: @"",
        @"runtimeGeneration":self.runtimeGeneration ?: @"",@"floatingPID":@(self.floatingPID),
        @"parentPID":@(getppid()),@"processGroupID":@(getpgrp()),
        @"sessionTarget":@(lifecycle.target.c_str()),@"desiredTarget":@(lifecycle.desired.c_str()),
        @"enabled":@(!lifecycle.userStopped && lifecycle.fault.empty()),@"userStopped":@(lifecycle.userStopped),@"drainAck":@(lifecycle.ack),
        @"childExitConfirmed":@(lifecycle.reaped),@"stopRequested":@(lifecycle.stopRequested),
        @"fault":@(lifecycle.fault.c_str()),@"foregroundReason":self.foregroundReason ?: @"",
        @"activeProfileTarget":self.activeProfileTarget ?: @"",@"activeRevision":self.activeRevision ?: @"",@"activePlanName":self.activePlanName ?: @"",
        @"scope":@"global-unlocked-display",@"configurationStatus":self.configurationError ?: @"",
        @"configurationLeaseStatus":self.configurationLeaseStatus ?: @"",
        @"displayOutputAllowed":@(self.displayOutputAllowed),@"displayPausePreservesChild":@(self.preservingChildForDisplayPause),
        @"spawnCount":@(lifecycle.spawnCount),@"stopRequestCount":@(lifecycle.stopRequestCount),
        @"lastStopReason":@(lifecycle.lastStopReason.c_str()),@"stopReasonCounts":reasons,
        @"verification":@"local cancellation submission plus normal waitpid exit; not touch delivery ACK"};
    if ([status isEqualToDictionary:self.lastStatus] && now-self.lastStatusWrite<1) return;
    NSMutableDictionary *dated=[status mutableCopy]; dated[@"timestamp"]=@(NSDate.date.timeIntervalSince1970);
    NSError *error=nil;
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:dated format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
    if (data && [data writeToFile:OPSupervisorStatusPath options:NSDataWritingAtomic error:&error]) {
        chmod(OPSupervisorStatusPath.fileSystemRepresentation,0644);
        self.lastStatus=status; self.lastStatusWrite=now;
    } else if (now-self.lastStatusWrite>=1) {
        std::fprintf(stderr,"[OPSupervisor] status write failed: %s\n",error.localizedDescription.UTF8String ?: "unknown");
        self.lastStatusWrite=now;
    }
}
- (void)advance {
    if (self.advancing) return;
    self.advancing=YES;
    double now=OPMonotonicSeconds();
    if(![self intentMatches])lifecycle.stop(now);
    if(self.floatingPID>1) {
        int status=0;pid_t result=waitpid(self.floatingPID,&status,WNOHANG);
        if(result==self.floatingPID || (result<0 && errno==ECHILD)) {
            self.floatingPID=0;
            if(!lifecycle.userStopped && lifecycle.fault.empty())lifecycle.fail("方案切换浮标已退出，映射已停止，请重新开启。");
        }
    }
    if(!lifecycle.fault.empty())lifecycle.stop(now);
    if(!lifecycle.userStopped && lifecycle.fault.empty() && !self.floatingStarted)[self startFloating];
    if((lifecycle.userStopped || !lifecycle.fault.empty()) && self.floatingPID>1 && now-self.lastFloatingStopPost>=.25) {
        NSString *name=[@"com.lixinmo.skytouch.floating.session." stringByAppendingString:self.runtimeGeneration];
        notify_post(name.UTF8String);self.lastFloatingStopPost=now;
    }
    if (lifecycle.pid && self.ackToken>=0) {
        uint64_t state=0;
        if (notify_get_state(self.ackToken,&state)!=NOTIFY_STATUS_OK) lifecycle.fail("managed acknowledgement channel unavailable");
        else if (state==(uint64_t)lifecycle.pid) lifecycle.acknowledge(lifecycle.pid);
    }
    if (lifecycle.pid && !lifecycle.reaped) {
        int status=0; pid_t result=waitpid(lifecycle.pid,&status,WNOHANG);
        if (result==lifecycle.pid) {
            NSString *completedTarget=@(lifecycle.target.c_str());
            lifecycle.childExited(WIFEXITED(status) && WEXITSTATUS(status)==0,now);
            // Reap is the definitive barrier against late writes on any
            // original worker queue. Repair ownership before another session
            // or the ordinary mobile configuration app can use this profile.
            NSString *sharingError=nil;
            if (!OPPrepareSharedOriginalProfile(completedTarget,&sharingError))
                lifecycle.fail(std::string("原进程已退出，但配置文件移交失败：")+(sharingError.UTF8String ?: "unknown"));
        }
        else if (result<0 && errno!=EINTR) lifecycle.fail(std::string("cannot confirm managed child exit: ")+std::strerror(errno));
    }
    lifecycle.tick(now);
    if (lifecycle.phase==op_supervisor::Phase::Starting) {
        // Re-read display/lease/active-profile state after waitpid, before
        // starting the selected profile in its new original-library process.
        NSString *target=[self allowedTarget:OPForegroundContextSnapshot()];
        lifecycle.foreground(target.UTF8String ?: "",now,self.retirementReason.UTF8String ?: "profile-or-output-condition");
        if (lifecycle.phase==op_supervisor::Phase::Starting) [self spawn];
    }
    if (lifecycle.pid && !lifecycle.reaped && lifecycle.stopRequested && now-self.lastStopPost>=0.25) {
        NSString *name=OPManagedSessionStopNotification(self.session);
        uint32_t result=notify_post(name.UTF8String);
        if (result!=NOTIFY_STATUS_OK) lifecycle.fail("managed stop notification failed; automatic restart disabled");
        self.lastStopPost=now;
    }
    if (!lifecycle.fault.empty() && !self.observerStopped) {
        // Keep polling the owned child and accepting explicit user stop, but
        // unsubscribe to prevent accidental automatic reconstruction.
        OPSetForegroundContextChangeHandler(nil); OPStopForegroundContext();
        self.observerStopped=YES;
    }
    [self writeStatus:now];
    self.advancing=NO;
}
- (void)dealloc { [self closeAcknowledgement]; }
@end

int OPRunSessionSupervisor(NSString *launchAttempt) {
    @autoreleasepool {
        if (![NSThread isMainThread] || geteuid()!=0) {
            std::fputs("original supervisor requires the root main thread\n",stderr); return 77;
        }
        if(launchAttempt && !OPManagedSessionIdentifierIsValid(launchAttempt))return 64;
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"SkyTouchMapping"] ||
            !OPServiceExecutablePathsMatch(NSBundle.mainBundle.executablePath,OPMappingServiceExecutablePath())) {
            std::fputs("original supervisor must run from its independent mapping service bundle\n",stderr); return 64;
        }
        NSString *path=OPRuntimePath(@"com.lixinmo.skytouch.original-supervisor.lock");
        int lock=open(path.fileSystemRepresentation,O_CREAT|O_RDWR|O_CLOEXEC|O_NOFOLLOW,0600);
        struct stat metadata{};
        if (lock<0 || fstat(lock,&metadata)!=0 || !S_ISREG(metadata.st_mode) || metadata.st_uid!=0 ||
            metadata.st_nlink!=1) {
            if (lock>=0) close(lock);
            std::fputs("original supervisor is already running or its singleton lock is unavailable\n",stderr); return 75;
        }
        NSDictionary *(^readAttempt)(void)=^{return [NSDictionary dictionaryWithContentsOfFile:
            OPRuntimePath(@"com.lixinmo.skytouch.original-launch.plist")];};
        const int lockResult=op_supervisor::acquireSupervisorLock(lock,launchAttempt,10,readAttempt);
        if(lockResult) {
            close(lock);
            if(lockResult==ECANCELED)return 0;
            std::fprintf(stderr,"original supervisor singleton unavailable: %s\n",std::strerror(lockResult));return 75;
        }
        OPSessionRuntime *runtime=[OPSessionRuntime new]; runtime.executable=NSBundle.mainBundle.executablePath;
        if (!runtime.executable.length) { close(lock); return 64; }
        NSDictionary *intent=OPMappingRuntimeIntent();
        if(![intent[@"enabled"] boolValue] || !OPManagedSessionIdentifierIsValid(intent[@"generation"])) {close(lock);return 0;}
        runtime.runtimeGeneration=intent[@"generation"];
        NSString *bluetoothError=nil;
        if(!OPEnsureBluetoothBrokerRunning(&bluetoothError)) {
            runtime->lifecycle.fail(bluetoothError.UTF8String ?: "system Bluetooth service unavailable");
            [runtime advance];close(lock);return 69;
        }
        // An ignored SIGCHLD can survive exec from a launcher and cause kernel
        // auto-reaping. This process owns its children and requires waitpid.
        struct sigaction childAction{}; childAction.sa_handler=SIG_DFL;
        sigemptyset(&childAction.sa_mask);
        if (sigaction(SIGCHLD,&childAction,nullptr)!=0) { close(lock); return 69; }
        int stopToken=-1,lockToken=-1,profileToken=-1,intentToken=-1,maintenanceToken=-1;
        uint32_t registration=notify_register_dispatch(OPSupervisorStopNotification,&stopToken,dispatch_get_main_queue(),^(__unused int token) {
            // A delayed notification from an older off/on cycle must not stop
            // the newly enabled generation. The persisted intent is decisive.
            if(![runtime intentMatches])runtime->lifecycle.stop(OPMonotonicSeconds());
            [runtime advance];
        });
        if (registration!=NOTIFY_STATUS_OK) { close(lock); return 69; }
        notify_register_dispatch(OPRuntimeIntentChangedNotification,&intentToken,dispatch_get_main_queue(),^(__unused int token){[runtime advance];});
        registration=notify_register_dispatch("com.lixinmo.skytouch.runtime.maintenance-stop",&maintenanceToken,dispatch_get_main_queue(),^(__unused int token){
            runtime->lifecycle.stop(OPMonotonicSeconds());[runtime advance];
        });
        if(registration!=NOTIFY_STATUS_OK) {
            notify_cancel(stopToken);if(intentToken>=0)notify_cancel(intentToken);close(lock);return 69;
        }
        if(launchAttempt && !op_supervisor::launchAttemptCurrent(readAttempt(),launchAttempt)) {
            notify_cancel(stopToken);close(lock);return 0;
        }
        registration=notify_register_dispatch("com.apple.springboard.lockcomplete",&lockToken,dispatch_get_main_queue(),^(__unused int token) {
            // A very brief lock/unlock may be over before a layout read. The
            // HUD also sees this event and awaits our unique stop request.
            // Retire this process even if the lock was brief; the next spawn
            // still requires a known lit/unlocked display and no configuration.
            runtime->lifecycle.foreground("",OPMonotonicSeconds(),"lock-notification"); [runtime advance];
        });
        if (registration!=NOTIFY_STATUS_OK) { notify_cancel(stopToken); close(lock); return 69; }
        registration=notify_register_dispatch(OPSupervisorProfileUpdatedNotification,&profileToken,dispatch_get_main_queue(),^(__unused int token) {
            // Preserve the disk FDG format and original load logic. Rebuild
            // its fixed singleton in a new process after the old one drains.
            [runtime reloadConfiguration]; runtime->lifecycle.profileUpdated(OPMonotonicSeconds()); [runtime advance];
        });
        if (registration!=NOTIFY_STATUS_OK) { notify_cancel(stopToken); notify_cancel(lockToken); close(lock); return 69; }
        NSString *error=nil;
        if (!OPStartForegroundContext(&error)) {
            runtime->lifecycle.fail(error.UTF8String ?: "foreground provider unavailable");
            [runtime advance]; notify_cancel(stopToken); notify_cancel(lockToken); notify_cancel(profileToken); close(lock); return 69;
        }
        OPSetForegroundContextChangeHandler(^(NSDictionary *snapshot) { [runtime acceptForeground:snapshot]; });
        double lastRead=0;
        while (!runtime->lifecycle.finished() || runtime.floatingPID>1) {
            @autoreleasepool {
                double now=OPMonotonicSeconds();
                if (runtime->lifecycle.fault.empty() && now-lastRead>=0.5) {
                    lastRead=now; [runtime acceptForeground:OPForegroundContextSnapshot()];
                }
                [runtime advance];
                CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.1,true);
            }
        }
        OPSetForegroundContextChangeHandler(nil); OPStopForegroundContext();
        [runtime advance]; notify_cancel(stopToken); notify_cancel(lockToken); notify_cancel(profileToken);
        if(intentToken>=0)notify_cancel(intentToken);if(maintenanceToken>=0)notify_cancel(maintenanceToken);
        close(lock);
        return runtime->lifecycle.fault.empty() ? 0 : 70;
    }
}
