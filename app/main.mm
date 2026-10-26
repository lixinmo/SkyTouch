#import "../src/OPStoragePaths.h"
#import <Foundation/Foundation.h>
#import <sys/wait.h>
#import <signal.h>
#include <cmath>

static constexpr NSTimeInterval OPLaunchConfirmationTimeout=15;
static BOOL OPSupervisorHasExplicitStop(NSDictionary *state,NSDictionary *attempt) {
    return [state[@"userStopped"] boolValue] ||
        ([state[@"supervisorPID"] intValue]>1 && [state[@"supervisorPID"] isEqual:attempt[@"retiringSupervisorPID"]]) ||
        ([state[@"supervisorPID"] intValue]>1 && [state[@"supervisorPID"] isEqual:attempt[@"pid"]] &&
         [attempt[@"stopRequested"] boolValue]);
}
static BOOL OPLaunchAttemptIsPending(NSDictionary *attempt,NSTimeInterval now) {
    if(![attempt[@"state"] isEqual:@"launching"] || [attempt[@"stopRequested"] boolValue] ||
       ![attempt[@"launchedAt"] isKindOfClass:NSNumber.class] || [attempt[@"pid"] intValue]<=1)return NO;
    const double age=now-[attempt[@"launchedAt"] doubleValue];
    return std::isfinite(age) && age>=0 && age<OPLaunchConfirmationTimeout;
}
static BOOL OPRuntimeRecordMatchesIntent(NSDictionary *record,NSDictionary *intent) {
    NSString *generation=intent[@"generation"];
    return [intent[@"enabled"] boolValue] && [generation isKindOfClass:NSString.class] && generation.length>0 &&
        [record[@"runtimeGeneration"] isKindOfClass:NSString.class] && [record[@"runtimeGeneration"] isEqual:generation];
}
static BOOL OPHeartbeatMatchesLaunch(NSDictionary *state,pid_t pid,NSTimeInterval launched,NSTimeInterval now) {
    if (![state isKindOfClass:NSDictionary.class] || pid<=1 || !std::isfinite(launched) || !std::isfinite(now) ||
        ![state[@"supervisorPID"] isKindOfClass:NSNumber.class] || [state[@"supervisorPID"] intValue]!=pid ||
        ![state[@"timestamp"] isKindOfClass:NSNumber.class]) return NO;
    const NSTimeInterval stamp=[state[@"timestamp"] doubleValue];
    return std::isfinite(stamp) && stamp>=launched && now>=stamp && now-stamp<3 &&
        [@[@"waiting",@"starting",@"running",@"stopping",@"failed",@"stopped"] containsObject:state[@"phase"] ?: @""];
}
static NSDictionary *OPLauncherExitDetails(int status,BOOL observed,BOOL expected) {
    NSMutableDictionary *details=[@{@"state":expected ? @"stopped" : @"exited",@"exitObserved":@(observed)} mutableCopy];
    if(observed && WIFEXITED(status)) {
        details[@"exitCode"]=@(WEXITSTATUS(status));
        details[@"error"]=expected ? @"" : [NSString stringWithFormat:@"全局映射服务已退出（退出码 %d）。",WEXITSTATUS(status)];
    } else if(observed && WIFSIGNALED(status)) {
        details[@"exitSignal"]=@(WTERMSIG(status));
        details[@"error"]=expected ? @"" : [NSString stringWithFormat:@"全局映射服务被信号 %d 终止。",WTERMSIG(status)];
    } else details[@"error"]=expected ? @"" : @"上次启动的全局映射服务已经退出，未能取得退出原因。";
    return details;
}


// Pure presentation logic. A supervisor heartbeat confirms only the service;
// the selected revision needs its own live, matching, ready engine report.
static NSString *OPGlobalMappingStatusDescription(NSDictionary *supervisor,NSDictionary *engine,
                                                 BOOL engineFresh,NSString *selectedRevision) {
    NSString *fault=supervisor[@"fault"];
    if([fault isKindOfClass:NSString.class] && fault.length)
        return [@"全局映射服务异常：" stringByAppendingString:fault];
    NSString *phase=[supervisor[@"phase"] isKindOfClass:NSString.class] ? supervisor[@"phase"] : @"";
    if([phase isEqual:@"stopped"])return @"全局映射已停止。";
    if([phase isEqual:@"failed"])return @"全局映射服务启动失败。";
    if(![supervisor[@"userStopped"] boolValue] && [supervisor[@"configurationLeaseStatus"] isKindOfClass:NSString.class] &&
       [supervisor[@"configurationLeaseStatus"] length])return @"正在配置方案；方案保存后，切到游戏即可恢复全局映射。";
    if([phase isEqual:@"stopping"] || [supervisor[@"userStopped"] boolValue] || [supervisor[@"stopRequested"] boolValue])
        return @"正在停止全局映射并释放触点。";
    if(![@[@"waiting",@"starting",@"running"] containsObject:phase])return @"正在确认全局映射状态。";
    if(![selectedRevision isKindOfClass:NSString.class] || !selectedRevision.length)return @"请选择要使用的映射方案：在凌触内下载或编辑，悬浮图标只切换本地方案。";
    if([phase isEqual:@"waiting"])return @"正在启动全局映射。";
    if([phase isEqual:@"starting"])return @"正在加载当前映射方案。";
    const BOOL matchingEngine=engineFresh && [engine[@"running"] boolValue] &&
        [engine[@"mode"] isEqual:@"engine-session"] &&
        [supervisor[@"childPID"] isKindOfClass:NSNumber.class] && [supervisor[@"childPID"] intValue]>1 &&
        [engine[@"pid"] isKindOfClass:NSNumber.class] && [supervisor[@"childPID"] isEqual:engine[@"pid"]] &&
        [supervisor[@"supervisorPID"] isKindOfClass:NSNumber.class] && [supervisor[@"supervisorPID"] intValue]>1 &&
        [supervisor[@"supervisorPID"] isEqual:engine[@"supervisorPID"]] &&
        [supervisor[@"sessionID"] isKindOfClass:NSString.class] && [supervisor[@"sessionID"] length]>0 &&
        [supervisor[@"sessionID"] isEqual:engine[@"managedSession"]];
    if(!matchingEngine)return @"正在启动全局映射。";
    if(![selectedRevision isEqual:supervisor[@"activeRevision"]] || ![selectedRevision isEqual:engine[@"globalRevision"]])
        return @"正在加载当前映射方案。";
    NSString *configurationError=engine[@"configurationError"];
    if([configurationError isKindOfClass:NSString.class] && configurationError.length)
        return [@"映射方案加载失败：" stringByAppendingString:configurationError];
    if(![engine[@"engineConfigurationLoaded"] boolValue])return @"正在加载当前映射方案。";
    if(![engine[@"ready"] boolValue] || [engine[@"outputDisabled"] boolValue])return @"正在准备触屏通道。";
    if(![engine[@"contextMatchesSession"] boolValue])return @"全局映射已暂停，当前界面暂不输出触屏。";
    return @"全局映射已开启。当前方案用于桌面和所有 App。";
}


// The persisted switch is authoritative even while old service heartbeats
// remain fresh during their graceful teardown.
static NSString *OPMappingRuntimeStatusDescription(BOOL enabled,NSDictionary *supervisor,NSDictionary *engine,
                                                    BOOL engineFresh,BOOL floatingRunning,NSString *revision) {
    if(!enabled) {
        const BOOL draining=supervisor || floatingRunning ||
            (engineFresh && [engine[@"running"] boolValue] && [engine[@"mode"] isEqual:@"engine-session"]);
        return draining ? @"正在关闭映射和浮标，并释放触点。" : @"映射和浮标已关闭。";
    }
    return supervisor ? OPGlobalMappingStatusDescription(supervisor,engine,engineFresh,revision) : nil;
}


static BOOL OPLauncherHomeURL(NSURL *url) {
    if(![url isKindOfClass:NSURL.class])return NO;
    NSURLComponents *parts=[NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    return [parts.scheme.lowercaseString isEqualToString:@"lixinmo-skytouch"] &&
        [parts.host.lowercaseString isEqualToString:@"home"] && !parts.user && !parts.password &&
        !parts.port && !parts.query && !parts.fragment && parts.percentEncodedPath.length==0;
}

#import <UIKit/UIKit.h>
#import <notify.h>
#import <spawn.h>
#import <dlfcn.h>
#import <signal.h>
#import <errno.h>
#import <sys/file.h>
#import <sys/stat.h>
#import <fcntl.h>
#include <cstdio>
#include <cstring>
#import "../src/OPHUDHost.h"
#import "../src/OPSessionSupervisor.h"
#import "../src/OPOriginalContext.h"
#import "../src/OPConfigurationUI.h"
#import "../src/OPConfigurationManagerUI.h"
#import "../src/OPConfigurationManager.h"
#import "../src/OPFloatingControl.h"
#import "../src/OPRuntimeControl.h"
#import "../src/OPInputSettings.h"
#import "../src/OPInputSettingsUI.h"
#import "../src/OPPanelCalibration.h"
#import "../src/OPBluetoothBroker.h"
#import "../src/OPGlobalProfile.h"
#import "../src/OPServicePaths.h"
#import "../src/OPSpawnAttributes.h"
extern char **environ;

static NSString *const OPLauncherAttemptPath=OPRuntimePath(@"com.lixinmo.skytouch.original-launch.plist");
static NSDictionary *OPLauncherAttempt(void) {
    NSDictionary *record=[NSDictionary dictionaryWithContentsOfFile:OPLauncherAttemptPath];
    return [record[@"version"] isEqual:@1] && [record[@"attempt"] isKindOfClass:NSString.class] ? record : nil;
}
static BOOL OPStoreLauncherAttempt(NSDictionary *record) {
    return [record writeToFile:OPLauncherAttemptPath atomically:YES] && chmod(OPLauncherAttemptPath.fileSystemRepresentation,0600)==0;
}
static void OPUpdateLauncherAttempt(NSString *attempt,NSDictionary *fields) {
    NSDictionary *previous=OPLauncherAttempt();
    if(![previous[@"attempt"] isEqual:attempt])return;
    NSMutableDictionary *record=[previous mutableCopy];[record addEntriesFromDictionary:fields];
    record[@"updatedAt"]=@(NSDate.date.timeIntervalSince1970);OPStoreLauncherAttempt(record);
}

static BOOL OPFreshProcessState(NSDictionary *state,NSString *timeKey,NSString *pidKey) {
    if (![state[timeKey] isKindOfClass:NSNumber.class] || ![state[pidKey] isKindOfClass:NSNumber.class]) return NO;
    NSTimeInterval age=NSDate.date.timeIntervalSince1970-[state[timeKey] doubleValue];
    pid_t pid=[state[pidKey] intValue];
    if (!std::isfinite(age) || age<0 || age>=3 || pid<=1) return NO;
    return kill(pid,0)==0 || errno==EPERM; // UI hint only; flock is authoritative.
}
static NSDictionary *OPActiveSupervisor(void) {
    NSDictionary *state=[NSDictionary dictionaryWithContentsOfFile:OPSupervisorStatusPath];
    if ([state[@"phase"] isEqualToString:@"stopped"]) return nil;
    return OPFreshProcessState(state,@"timestamp",@"supervisorPID") ? state : nil;
}
static NSString *OPPreviousLaunchProblem(void) {
    NSDictionary *record=OPLauncherAttempt();
    if(!OPRuntimeRecordMatchesIntent(record,OPMappingRuntimeIntent()) || [record[@"stopRequested"] boolValue] ||
       [record[@"state"] isEqual:@"stopped"])return nil;
    NSString *error=record[@"error"];
    if([error isKindOfClass:NSString.class] && error.length)return error;
    const pid_t pid=[record[@"pid"] intValue];
    if(pid<=1)return nil;
    NSDictionary *status=[NSDictionary dictionaryWithContentsOfFile:OPSupervisorStatusPath];
    if([status[@"supervisorPID"] intValue]==pid && [status[@"phase"] isEqual:@"stopped"])return nil;
    if(kill(pid,0)<0 && errno==ESRCH) {
        NSDictionary *details=OPLauncherExitDetails(0,NO,NO);
        OPUpdateLauncherAttempt(record[@"attempt"],details);return details[@"error"];
    }
    const double age=NSDate.date.timeIntervalSince1970-[record[@"launchedAt"] doubleValue];
    return std::isfinite(age) && age>=OPLaunchConfirmationTimeout ? @"全局映射服务没有返回有效运行状态，请查看启动诊断后重试。" : @"正在开启全局映射。";
}
static NSDictionary *OPCurrentGlobalProfile(void) {
    NSDictionary *document=OPReadGlobalProfile(nil);
    return document ? @{@"target":document[@"activeProfileTarget"],@"name":document[@"planName"],@"revision":document[@"revision"]} : nil;
}


static NSString *OPSupervisorLaunchDescription(NSDictionary *supervisor) {
    NSDictionary *engine=[NSDictionary dictionaryWithContentsOfFile:OPRuntimePath(@"com.lixinmo.skytouch.original-status.plist")];
    return OPGlobalMappingStatusDescription(supervisor,engine,OPFreshProcessState(engine,@"time",@"pid"),OPCurrentGlobalProfile()[@"revision"]);
}

@interface OPLauncher : UIViewController
@property(nonatomic) UILabel *status;
@property(nonatomic) UILabel *profileStatus;
@property(nonatomic) UILabel *controllerStatus;
@property(nonatomic) UILabel *floatingStatus;
@property(nonatomic) UIButton *inputSettingsButton;
@property(nonatomic) BOOL startPending;
@property(nonatomic) NSUInteger startGeneration;
@property(nonatomic) UIButton *mappingButton;
@property(nonatomic) BOOL mappingButtonRepresentsEnabled;
@property(nonatomic) UIButton *showFloatingButton;
@property(nonatomic) pid_t retiringSupervisorPID;
@property(nonatomic) int runtimeNotificationToken;
@property(nonatomic) BOOL runtimeNotificationRegistered;
@property(nonatomic) NSTimer *statusTimer;
@property(nonatomic) NSMutableDictionary<NSNumber *,NSTimer *> *launchWatchTimers;
@property(nonatomic,copy) NSString *pendingEditorTarget;
- (void)watchSupervisorPID:(pid_t)pid launchedAt:(NSTimeInterval)launched attempt:(NSString *)attempt generation:(NSUInteger)generation;
- (void)showFloatingConfiguration;
- (void)configure;
- (void)manageConfiguration;
- (void)inputSettings;
- (void)refreshRuntimeStatus;
- (void)runtimeIntentChanged;
- (void)ensureSupervisorRunning;
- (void)refreshMappingButton;
- (void)toggleMapping;
- (void)start;
- (void)stop;
@end
@implementation OPLauncher
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor=UIColor.systemBackgroundColor; self.title=@"凌触 · 方案配置";
    self.launchWatchTimers=[NSMutableDictionary dictionary];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(configurationApplied:)
        name:OPConfigurationApplyAndStartNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(configurationSelected:)
        name:OPConfigurationSelectionDidChangeNotification object:nil];
    UIScrollView *scroll=[UIScrollView new];scroll.translatesAutoresizingMaskIntoConstraints=NO;[self.view addSubview:scroll];
    UIStackView *stack=[[UIStackView alloc] init]; stack.axis=UILayoutConstraintAxisVertical; stack.spacing=20; stack.translatesAutoresizingMaskIntoConstraints=NO;
    [scroll addSubview:stack];
    UILabel *intro=[UILabel new]; intro.numberOfLines=0;
    intro.text=@"在凌触内选择游戏、登录飞智云方案、下载和编辑映射，也可加载截图辅助配置。进入配置页面后使用横屏。\n\n开启映射后显示浮标，可在任意 App 切换本地方案。关闭映射会同时退出浮标；划掉凌触不会关闭已开启的映射和浮标。";
    [stack addArrangedSubview:intro];
    self.inputSettingsButton=[UIButton buttonWithType:UIButtonTypeSystem];
    self.inputSettingsButton.configuration=[UIButtonConfiguration borderedButtonConfiguration];
    [self.inputSettingsButton addTarget:self action:@selector(inputSettings) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:self.inputSettingsButton];
    self.profileStatus=[UILabel new];self.profileStatus.numberOfLines=0;[stack addArrangedSubview:self.profileStatus];[self updateProfileStatus];
    UIButton *configure=[UIButton buttonWithType:UIButtonTypeSystem];configure.configuration=[UIButtonConfiguration borderedButtonConfiguration];
    [configure setTitle:@"配置当前游戏方案" forState:UIControlStateNormal];[configure addTarget:self action:@selector(configure) forControlEvents:UIControlEventTouchUpInside];
    UIButton *chooseGame=[UIButton buttonWithType:UIButtonTypeSystem];chooseGame.configuration=[UIButtonConfiguration filledButtonConfiguration];
    [chooseGame setTitle:@"飞智云方案（选择游戏）" forState:UIControlStateNormal];[chooseGame addTarget:self action:@selector(chooseGame) forControlEvents:UIControlEventTouchUpInside];[stack addArrangedSubview:chooseGame];
    [stack addArrangedSubview:configure];
    UIButton *manage=[UIButton buttonWithType:UIButtonTypeSystem];manage.configuration=[UIButtonConfiguration borderedButtonConfiguration];
    [manage setTitle:@"管理配置" forState:UIControlStateNormal];[manage addTarget:self action:@selector(manageConfiguration) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:manage];
    self.mappingButton=[UIButton buttonWithType:UIButtonTypeSystem];
    self.mappingButton.configuration=[UIButtonConfiguration filledButtonConfiguration];
    [self.mappingButton addTarget:self action:@selector(toggleMapping) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:self.mappingButton];
    UIButton *showFloating=[UIButton buttonWithType:UIButtonTypeSystem];showFloating.configuration=[UIButtonConfiguration borderedButtonConfiguration];
    [showFloating setTitle:@"显示本地方案切换浮标" forState:UIControlStateNormal];
    [showFloating addTarget:self action:@selector(showFloatingConfiguration) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:showFloating];self.showFloatingButton=showFloating;
    self.floatingStatus=[UILabel new];self.floatingStatus.numberOfLines=0;[stack addArrangedSubview:self.floatingStatus];
    self.controllerStatus=[UILabel new];self.controllerStatus.numberOfLines=0;self.controllerStatus.text=@"正在读取手柄状态。";[stack addArrangedSubview:self.controllerStatus];
    self.status=[UILabel new]; self.status.numberOfLines=0; self.status.text=@"全局映射未启动。"; [stack addArrangedSubview:self.status];
    __weak OPLauncher *weakSelf=self;
    int token=0;
    if(notify_register_dispatch(OPRuntimeIntentChangedNotification,&token,dispatch_get_main_queue(),^(__unused int received) {
        [weakSelf runtimeIntentChanged];
    })==NOTIFY_STATUS_OK) {
        self.runtimeNotificationToken=token;self.runtimeNotificationRegistered=YES;
    }
    self.statusTimer=[NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(__unused NSTimer *timer) {
        if (UIApplication.sharedApplication.applicationState!=UIApplicationStateActive) return;
        [weakSelf updateProfileStatus];[weakSelf refreshRuntimeStatus];
    }];
    [self refreshRuntimeStatus];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-24],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:24],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-48]]];
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if(self.pendingEditorTarget && !self.navigationController.presentedViewController)[self configure];
    else [self refreshRuntimeStatus];
}
- (void)updateProfileStatus {
    NSDictionary *profile=OPCurrentGlobalProfile();
    NSDictionary *editor=OPCurrentEditorSelection();
    self.profileStatus.text=profile ? [NSString stringWithFormat:@"编辑方案库：%@\n全局使用：%@",editor[@"name"],profile[@"name"]] :
        [NSString stringWithFormat:@"编辑方案库：%@\n尚未选择全局方案。",editor[@"name"]];
}
- (void)configure {
    if(self.navigationController.presentedViewController || self.presentedViewController)return;
    NSString *target=self.pendingEditorTarget ?: OPCurrentEditorSelection()[@"bundle"];
    self.pendingEditorTarget=nil;
    UIViewController *editor=OPMakeConfigurationEditor(target);
    [self presentViewController:editor animated:YES completion:nil];
}
- (void)manageConfiguration {
    if(self.navigationController.presentedViewController || self.presentedViewController || OPConfigurationManagementUIIsBusy())return;
    [self.navigationController pushViewController:OPMakeConfigurationManager() animated:YES];
}
- (void)inputSettings {
    if(self.navigationController.presentedViewController || self.presentedViewController || OPConfigurationManagementUIIsBusy())return;
    [self.navigationController pushViewController:OPMakeInputSettingsController() animated:YES];
}
- (void)showFloatingConfiguration {
    if(!OPMappingRuntimeEnabled()) {
        self.floatingStatus.text=@"开启映射后才能显示浮标。";return;
    }
    // Reveal is deliberately notification-only. Only the supervisor owns
    // launching the paired floating process.
    notify_post("com.lixinmo.skytouch.floating.reveal");
    self.floatingStatus.text=@"正在显示悬浮图标…";
}
- (void)configurationSelected:(NSNotification *)notification {
    [self updateProfileStatus];
    self.pendingEditorTarget=notification.userInfo[@"bundle"] ?: OPCurrentEditorSelection()[@"bundle"];
    // The game picker pops back to this launcher after posting. Its completed
    // navigation presents the native editor from viewDidAppear, never from a
    // controller that is being removed from the navigation hierarchy.
    if(self.navigationController.visibleViewController==self && self.view.window)[self configure];
}
- (void)chooseGame {
    [self.navigationController pushViewController:OPMakeConfigurationPicker() animated:YES];
}
- (void)refreshMappingButton {
    const BOOL enabled=OPMappingRuntimeEnabled();
    self.mappingButtonRepresentsEnabled=enabled;
    [self.mappingButton setTitle:enabled ? @"关闭映射" : @"开启映射" forState:UIControlStateNormal];
    // A pending start is still cancellable through this same button.
    self.mappingButton.enabled=YES;
}
- (void)toggleMapping {
    const BOOL enabled=OPMappingRuntimeEnabled();
    // If another surface changed the switch before this tap was delivered,
    // update the stale title rather than unexpectedly reversing that action.
    if(enabled!=self.mappingButtonRepresentsEnabled){[self refreshMappingButton];return;}
    if(enabled)[self stop];else [self start];
    [self refreshMappingButton];
}
- (void)start {
    const BOOL alreadyEnabled=OPMappingRuntimeEnabled();
    if (self.startPending && alreadyEnabled) return;
    if(!alreadyEnabled) {
        // A floating-menu Stop can precede the old supervisor's next tick.
        // Do not reuse that owner or its launch attempt after a new enable.
        self.retiringSupervisorPID=[OPActiveSupervisor()[@"supervisorPID"] intValue];
        NSDictionary *previous=OPLauncherAttempt();
        if(previous)OPUpdateLauncherAttempt(previous[@"attempt"],@{@"stopRequested":@YES});
        NSString *error=nil;
        if(!OPSetMappingRuntimeEnabled(YES,&error)) {
            self.status.text=error ?: @"未能保存开启映射请求。";return;
        }
    }
    ++self.startGeneration;
    [self refreshMappingButton];
    [self ensureSupervisorRunning];
}
- (void)ensureSupervisorRunning {
    if(!OPMappingRuntimeEnabled()) {[self runtimeIntentChanged];return;}
    NSDictionary *attempt=OPLauncherAttempt();
    if(OPRuntimeRecordMatchesIntent(attempt,OPMappingRuntimeIntent()) &&
       OPLaunchAttemptIsPending(attempt,NSDate.date.timeIntervalSince1970)) {
        pid_t pid=[attempt[@"pid"] intValue];
        if(kill(pid,0)==0 || errno==EPERM) {
            self.startPending=YES;[self refreshMappingButton];self.status.text=@"正在开启全局映射。";
            [self watchSupervisorPID:pid launchedAt:[attempt[@"launchedAt"] doubleValue]
                attempt:attempt[@"attempt"] generation:self.startGeneration];
            return;
        }
    }
    NSDictionary *active=OPActiveSupervisor();
    if (OPRuntimeRecordMatchesIntent(active,OPMappingRuntimeIntent()) &&
        [active[@"supervisorPID"] intValue]!=self.retiringSupervisorPID && !OPSupervisorHasExplicitStop(active,attempt)) {
        self.status.text=OPSupervisorLaunchDescription(active);return;
    }
    self.startPending=YES; [self refreshMappingButton];
    // The broker owns its Bluetooth identity and authorization. An unrelated
    // UI CBCentralManager cannot authorize or assess that system connection.
    [self launchSupervisor];
}
- (void)configurationApplied:(NSNotification *)notification {
    (void)notification;
    [self updateProfileStatus];
    [self refreshRuntimeStatus];
}
- (void)launchSupervisor {
    if(!OPMappingRuntimeEnabled()) {[self runtimeIntentChanged];return;}
    NSDictionary *active=OPActiveSupervisor();
    if (OPRuntimeRecordMatchesIntent(active,OPMappingRuntimeIntent()) &&
        [active[@"supervisorPID"] intValue]!=self.retiringSupervisorPID && !OPSupervisorHasExplicitStop(active,OPLauncherAttempt())) {
        self.startPending=NO; [self refreshMappingButton];
        self.status.text=OPSupervisorLaunchDescription(active); return;
    }
    const NSUInteger generation=self.startGeneration;
    // Preserve the old owner across rapid Stop/Start cycles, including the
    // brief interval before it handles its first stop notification.
    const pid_t retiringPID=active && ([active[@"supervisorPID"] intValue]==self.retiringSupervisorPID ||
        !OPRuntimeRecordMatchesIntent(active,OPMappingRuntimeIntent()) ||
        OPSupervisorHasExplicitStop(active,OPLauncherAttempt())) ? [active[@"supervisorPID"] intValue] : 0;
    NSString *attempt=NSUUID.UUID.UUIDString;
    const NSTimeInterval launched=NSDate.date.timeIntervalSince1970;
    if(!OPStoreLauncherAttempt(@{@"version":@1,@"attempt":attempt,@"state":@"launching",@"launchedAt":@(launched),
        @"updatedAt":@(launched),@"pid":@0,@"retiringSupervisorPID":@(retiringPID),@"stopRequested":@NO,@"error":@"",
        @"runtimeGeneration":OPMappingRuntimeIntent()[@"generation"] ?: @""})) {
        self.startPending=NO;[self refreshMappingButton];self.status.text=@"未能保存启动请求，请重试。";return;
    }
    typedef int (*Persona)(const posix_spawnattr_t*,uid_t,uint32_t);
    typedef int (*PersonaID)(const posix_spawnattr_t*,uid_t);
    Persona persona=(Persona)dlsym(RTLD_DEFAULT,"posix_spawnattr_set_persona_np");
    PersonaID uid=(PersonaID)dlsym(RTLD_DEFAULT,"posix_spawnattr_set_persona_uid_np");
    PersonaID gid=(PersonaID)dlsym(RTLD_DEFAULT,"posix_spawnattr_set_persona_gid_np");
    if (!persona||!uid||!gid) {
        self.startPending=NO;[self refreshMappingButton];self.status.text=@"当前系统没有可用的专用宿主启动接口。";
        OPUpdateLauncherAttempt(attempt,@{@"state":@"spawn-failed",@"spawnError":@(ENOSYS),@"error":self.status.text});return;
    }
    notify_post("com.lixinmo.skytouch.stop");
    NSString *executable=OPMappingServiceExecutablePath();
    if(!executable.length) {
        self.startPending=NO;[self refreshMappingButton];self.status.text=@"无法找到映射服务，请重新安装完整包。";
        OPUpdateLauncherAttempt(attempt,@{@"state":@"spawn-failed",@"spawnError":@(ENOENT),@"error":self.status.text});return;
    }
    // Spawn before returning to UIKit. A configured App exits on background;
    // a delayed spawn could otherwise disappear when the user presses Home.
    posix_spawnattr_t attrs;int code=posix_spawnattr_init(&attrs);
    pid_t pid=0;
    if(!code) {
        code=posix_spawnattr_setflags(&attrs,POSIX_SPAWN_CLOEXEC_DEFAULT);
        if(!code)code=OPSpawnInNewProcessGroup(&attrs);
        if(!code)code=persona(&attrs,99,1);if(!code)code=uid(&attrs,0);if(!code)code=gid(&attrs,0);
        char *arguments[]={(char *)executable.fileSystemRepresentation,(char *)"--original-supervisor",
            (char *)"--launch-attempt",(char *)attempt.UTF8String,nullptr};
        if(!code)code=posix_spawn(&pid,executable.fileSystemRepresentation,nullptr,&attrs,arguments,environ);
        posix_spawnattr_destroy(&attrs);
    }
    if(code) {
        self.startPending=NO;[self refreshMappingButton];
        self.status.text=[NSString stringWithFormat:@"系统宿主启动失败：%d。没有启用映射。",code];
        OPUpdateLauncherAttempt(attempt,@{@"state":@"spawn-failed",@"spawnError":@(code),@"error":self.status.text});return;
    }
    OPUpdateLauncherAttempt(attempt,@{@"pid":@(pid)});
    self.status.text=@"已请求启动，正在确认全局映射服务运行状态。";
    [self watchSupervisorPID:pid launchedAt:launched attempt:attempt generation:generation];
}
- (void)watchSupervisorPID:(pid_t)pid launchedAt:(NSTimeInterval)launched attempt:(NSString *)attempt generation:(NSUInteger)generation {
    // Reattaching to the same child replaces its watcher. Older children of
    // this app still need their own waitpid even after a newer Start wins.
    [self.launchWatchTimers[@(pid)] invalidate];
    const NSTimeInterval began=NSProcessInfo.processInfo.systemUptime;
    const NSTimeInterval remaining=std::fmax(0,OPLaunchConfirmationTimeout-(NSDate.date.timeIntervalSince1970-launched));
    __block BOOL confirmed=NO,timedOut=NO;
    __weak OPLauncher *weakSelf=self;
    // WNOHANG only: this also records a rapid exit while the App is visible.
    // The persisted attempt lets a later App process report an unobserved exit.
    NSTimer *timer=[NSTimer timerWithTimeInterval:.2 repeats:YES block:^(NSTimer *watch) {
        NSDictionary *record=OPLauncherAttempt();
        const BOOL currentAttempt=[record[@"attempt"] isEqual:attempt];
        OPLauncher *owner=weakSelf;
        const BOOL currentUI=currentAttempt && owner && owner.startGeneration==generation &&
            OPRuntimeRecordMatchesIntent(record,OPMappingRuntimeIntent());
        NSDictionary *status=[NSDictionary dictionaryWithContentsOfFile:OPSupervisorStatusPath];
        int childStatus=0;pid_t waited=waitpid(pid,&childStatus,WNOHANG);int waitError=errno;
        const BOOL gone=waited==pid || (waited<0 && waitError==ECHILD && kill(pid,0)<0 && errno==ESRCH);
        if(gone) {
            const BOOL expected=!OPMappingRuntimeEnabled() || (currentAttempt && [record[@"stopRequested"] boolValue]) ||
                ([status[@"supervisorPID"] intValue]==pid && [status[@"phase"] isEqual:@"stopped"]);
            NSDictionary *details=OPLauncherExitDetails(childStatus,waited==pid,expected);
            OPUpdateLauncherAttempt(attempt,details);
            if(currentUI) {
                owner.startPending=NO;[owner refreshMappingButton];
                owner.status.text=expected ? @"全局映射服务已停止。" : details[@"error"];
            }
            if(owner.launchWatchTimers[@(pid)]==watch)[owner.launchWatchTimers removeObjectForKey:@(pid)];
            [watch invalidate];return;
        }
        if(OPHeartbeatMatchesLaunch(status,pid,launched,NSDate.date.timeIntervalSince1970)) {
            if(!confirmed) {
                confirmed=YES;
                OPUpdateLauncherAttempt(attempt,@{@"state":@"confirmed",@"heartbeatAt":status[@"timestamp"],@"error":@""});
                if(currentUI) {
                    owner.startPending=NO;[owner refreshMappingButton];
                    owner.status.text=OPSupervisorLaunchDescription(status);
                }
            }
            NSString *fault=status[@"fault"];
            if(currentAttempt && [fault isKindOfClass:NSString.class] && fault.length && ![record[@"state"] isEqual:@"failed"])
                OPUpdateLauncherAttempt(attempt,@{@"state":@"failed",@"error":OPSupervisorLaunchDescription(status)});
        } else if(!confirmed && !timedOut && NSProcessInfo.processInfo.systemUptime-began>=remaining) {
            timedOut=YES;
            NSString *error=@"启动进程没有返回有效运行状态；未确认全局映射已开启。";
            OPUpdateLauncherAttempt(attempt,@{@"state":@"heartbeat-timeout",@"error":error});
            if(currentUI){owner.startPending=NO;[owner refreshMappingButton];owner.status.text=error;}
        }
    }];
    self.launchWatchTimers[@(pid)]=timer;
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
}
- (void)dealloc {
    if(self.runtimeNotificationRegistered)notify_cancel(self.runtimeNotificationToken);
    [self.statusTimer invalidate];
    for(NSTimer *watch in self.launchWatchTimers.allValues)[watch invalidate];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}
- (void)stop {
    ++self.startGeneration;self.startPending=NO;[self refreshMappingButton];
    NSString *error=nil;
    if(!OPStopMappingRuntime(&error)) {
        self.status.text=error ?: @"未能保存关闭映射请求，请重试。";return;
    }
    NSDictionary *attempt=OPLauncherAttempt();
    if(attempt)OPUpdateLauncherAttempt(attempt[@"attempt"],@{@"stopRequested":@YES});
    [self refreshRuntimeStatus];
}
- (void)runtimeIntentChanged {
    if(!OPMappingRuntimeEnabled()) {
        ++self.startGeneration;self.startPending=NO;
        NSDictionary *attempt=OPLauncherAttempt();
        if(attempt && ![attempt[@"stopRequested"] boolValue])
            OPUpdateLauncherAttempt(attempt[@"attempt"],@{@"stopRequested":@YES});
    }
    [self refreshRuntimeStatus];
}
- (void)refreshRuntimeStatus {
    NSDictionary *inputSettings=OPReadInputSettings();
    BOOL phoneMode=[inputSettings[@"mode"] isEqual:@"phone"];
    BOOL phoneMotion=OPInputUsesPhoneMotion(inputSettings,[OPCurrentGlobalProfile()[@"deviceType"] integerValue]);
    [self.inputSettingsButton setTitle:phoneMode ? @"输入模式：手机 · 按键与体感设置" : @"输入模式：手柄 · 按键与体感设置" forState:UIControlStateNormal];
    NSDictionary *intent=OPMappingRuntimeIntent();
    const BOOL enabled=[intent[@"enabled"] boolValue];
    // Notifications can be coalesced while UIKit is suspended. Reading the
    // durable off state must also unlock a pending Start button on return.
    if(!enabled && self.startPending) {++self.startGeneration;self.startPending=NO;}
    NSDictionary *floating=OPFloatingConfigurationStatus();
    NSDictionary *supervisor=OPActiveSupervisor();
    NSDictionary *engine=[NSDictionary dictionaryWithContentsOfFile:OPRuntimePath(@"com.lixinmo.skytouch.original-status.plist")];
    const BOOL engineFresh=OPFreshProcessState(engine,@"time",@"pid");
    const BOOL stopping=!enabled && (supervisor || floating ||
        (engineFresh && [engine[@"running"] boolValue] && [engine[@"mode"] isEqual:@"engine-session"]));
    [self refreshMappingButton];
    self.showFloatingButton.enabled=enabled;
    if(!enabled)self.floatingStatus.text=stopping ? @"正在退出悬浮图标。" : @"开启映射时会同时显示浮标。";
    else if(OPRuntimeRecordMatchesIntent(floating,intent)) {
        NSString *error=[floating[@"error"] isKindOfClass:NSString.class] ? floating[@"error"] : nil;
        if(error.length)self.floatingStatus.text=error;
        else if(![floating[@"displayAllowed"] boolValue])self.floatingStatus.text=@"方案切换浮标正在等待屏幕可用。";
        else if([floating[@"hostCount"] unsignedIntegerValue]==0)self.floatingStatus.text=@"正在准备悬浮图标…";
        else self.floatingStatus.text=[floating[@"expanded"] boolValue] ?
            @"正在显示本地方案列表；再次点击浮标收起。" : @"可在桌面和任意 App 点击浮标切换本地方案。";
    } else self.floatingStatus.text=OPFloatingConfigurationLaunchProblem() ?: @"正在等待映射服务启动浮标。";
    NSDictionary *bluetooth=OPBluetoothBrokerStatus();
    if(phoneMode) {
        NSDictionary *bindings=inputSettings[@"phoneBindings"];
        self.controllerStatus.text=[NSString stringWithFormat:@"手机输入：操作按钮 → %@，音量 + → %@，音量 − → %@，侧边按钮 → %@。\n转动手机控制体感视野；映射生效期间，四键执行方案动作，原系统功能暂停。方案中的摇杆设置会保留。",bindings[@"action"],bindings[@"volumeUp"],bindings[@"volumeDown"],bindings[@"side"]];
    } else if(OPFreshProcessState(bluetooth,@"time",@"pid")) {
        self.controllerStatus.text=[bluetooth[@"connected"] boolValue] ?
            ([bluetooth[@"receivedThisConnection"] unsignedLongLongValue] ? @"系统后台已收到手柄数据。" : @"手柄链路已连接，等待输入。") :
            [bluetooth[@"scanning"] boolValue] ? @"系统后台正在寻找手柄。" : @"系统后台等待手柄连接。";
    } else self.controllerStatus.text=@"手柄连接服务尚未启动。";
    if(!phoneMode) {
        NSString *motionSource=phoneMotion ?
            @"体感来源：手机，跟随手机转动；手柄按键与摇杆继续使用。" :
            [inputSettings[@"controllerMotion"] isEqual:@"phone"] ? @"体感来源：手柄原体感（当前键鼠方案）。" : @"体感来源：手柄原体感。";
        self.controllerStatus.text=[self.controllerStatus.text stringByAppendingFormat:@"\n%@",motionSource];
    }
    NSDictionary *currentSupervisor=OPRuntimeRecordMatchesIntent(supervisor,intent) ? supervisor : nil;
    NSString *runtimeStatus=OPMappingRuntimeStatusDescription(enabled,enabled ? currentSupervisor : supervisor,
        engine,engineFresh,floating!=nil,OPCurrentGlobalProfile()[@"revision"]);
    if(enabled && phoneMode && engineFresh && [engine[@"inputMode"] isEqual:@"phone"] &&
       ![engine[@"inputReady"] boolValue] && [engine[@"running"] boolValue]) {
        NSDictionary *phone=engine[@"phoneInput"],*buttons=phone[@"buttons"],*motion=phone[@"motion"];
        NSString *buttonStage=buttons[@"stage"],*motionError=motion[@"error"];
        if([buttonStage isEqual:@"unsupported-button-abi"])
            runtimeStatus=@"当前系统的实体键接口不兼容，手机按键保持原功能。";
        else if([buttonStage isEqual:@"waiting-for-SpringBoard"])
            runtimeStatus=@"正在连接手机按键组件；首次安装或更新后需重新加载桌面。";
        else if(motionError.length)runtimeStatus=[@"手机体感暂不可用：" stringByAppendingString:motionError];
        else if(![phone[@"active"] boolValue])runtimeStatus=@"手机映射已暂停，退出编辑或解锁后恢复。";
        else runtimeStatus=@"正在准备手机按键和体感输入，系统按键暂未接管。";
    }
    if(enabled && !phoneMode && phoneMotion && engineFresh &&
       [engine[@"inputMode"] isEqual:@"controller"] && ![engine[@"inputReady"] boolValue] && [engine[@"running"] boolValue]) {
        NSDictionary *phone=engine[@"phoneInput"];
        NSString *motionError=phone[@"motion"][@"error"];
        if(motionError.length)runtimeStatus=[@"手机体感暂不可用：" stringByAppendingString:motionError];
        else if(![phone[@"active"] boolValue])runtimeStatus=@"手柄与手机体感映射已暂停，退出编辑或解锁后恢复。";
        else runtimeStatus=@"正在等待手柄连接和手机体感输入。";
    }
    if(!enabled || currentSupervisor) {self.status.text=runtimeStatus;return;}
    if(supervisor) {self.status.text=@"正在等待上次映射和浮标退出。";return;}
    if(self.startPending) return;
    NSDictionary *attempt=OPLauncherAttempt();
    if(OPRuntimeRecordMatchesIntent(attempt,OPMappingRuntimeIntent()) &&
       OPLaunchAttemptIsPending(attempt,NSDate.date.timeIntervalSince1970)) {
        pid_t pendingPID=[attempt[@"pid"] intValue];
        if(kill(pendingPID,0)==0 || errno==EPERM) {self.status.text=@"正在开启映射和浮标。";return;}
    }
    self.status.text=OPPreviousLaunchProblem() ?: @"映射服务尚未运行，请点“开启映射”重试。";
}
@end
static NSString *OPConfigurationTargetFromURL(NSURL *url) {
    if(![url isKindOfClass:NSURL.class])return nil;
    NSURLComponents *parts=[NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if(![parts.scheme.lowercaseString isEqualToString:@"lixinmo-skytouch"] || ![parts.host.lowercaseString isEqualToString:@"configure"] ||
        parts.user || parts.password || parts.port || parts.query || parts.fragment)return nil;
    NSString *path=parts.percentEncodedPath;
    if(![path hasPrefix:@"/"] || path.length<2)return nil;
    NSString *target=[[path substringFromIndex:1] stringByRemovingPercentEncoding];
    return OPManagedTargetIsValid(target) ? target : nil;
}
@interface OPLauncherDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic) UIWindow *window;
@property(nonatomic,copy) NSString *pendingConfigurationTarget;
@property(nonatomic) BOOL configurationNavigationScheduled;
@end
@implementation OPLauncherDelegate
- (UIInterfaceOrientationMask)application:(UIApplication *)application supportedInterfaceOrientationsForWindow:(UIWindow *)window {
    (void)application;(void)window;
    return OPConfigurationNativeEditorActive() ? UIInterfaceOrientationMaskLandscape : UIInterfaceOrientationMaskAllButUpsideDown;
}
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application;
    self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController=[[UINavigationController alloc] initWithRootViewController:[OPLauncher new]];
    [self.window makeKeyAndVisible];
    self.pendingConfigurationTarget=OPConfigurationTargetFromURL(options[UIApplicationLaunchOptionsURLKey]);
    return YES;
}
- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenURLOptionsKey,id> *)options {
    (void)application;(void)options;
    if(OPConfigurationManagementUIIsBusy())return NO;
    if(OPLauncherHomeURL(url)) {
        self.pendingConfigurationTarget=nil;
        UINavigationController *navigation=[self.window.rootViewController isKindOfClass:UINavigationController.class] ?
            (UINavigationController *)self.window.rootViewController : nil;
        // Opening the App must preserve an editor, photo picker or login
        // dialog already in progress; returning home must never discard it.
        if(navigation && !navigation.presentedViewController && !OPConfigurationNativeEditorActive())
            [navigation popToRootViewControllerAnimated:NO];
        return YES;
    }
    NSString *target=OPConfigurationTargetFromURL(url);if(!target)return NO;
    self.pendingConfigurationTarget=target;[self scheduleConfigurationNavigation];return YES;
}
- (void)applicationDidBecomeActive:(UIApplication *)application {
    (void)application;
    if(OPMappingRuntimeEnabled()) {
        notify_post("com.lixinmo.skytouch.floating.launcher-active");
        notify_post("com.lixinmo.skytouch.floating.reveal");
    }
    if(self.pendingConfigurationTarget)[self scheduleConfigurationNavigation];
}
- (void)scheduleConfigurationNavigation {
    if(OPConfigurationManagementUIIsBusy())return;
    if(self.configurationNavigationScheduled || !self.pendingConfigurationTarget)return;
    self.configurationNavigationScheduled=YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,150*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        self.configurationNavigationScheduled=NO;
        if(OPConfigurationManagementUIIsBusy())return;
        if(UIApplication.sharedApplication.applicationState!=UIApplicationStateActive || !self.pendingConfigurationTarget)return;
        UINavigationController *navigation=[self.window.rootViewController isKindOfClass:UINavigationController.class] ?
            (UINavigationController *)self.window.rootViewController : nil;
        // Leave an existing editor, picker or permission dialog intact. A
        // later activation can process this request; never discard live edits.
        if(!navigation || navigation.presentedViewController)return;
        NSString *target=self.pendingConfigurationTarget;self.pendingConfigurationTarget=nil;
        UIViewController *launcher=navigation.viewControllers.firstObject;
        if(launcher)[navigation setViewControllers:@[launcher] animated:NO];
        NSString *error=nil;
        if(!OPSelectConfigurationTarget(target,&error) && [launcher isKindOfClass:OPLauncher.class])
            ((OPLauncher *)launcher).floatingStatus.text=error ?: @"未能选择游戏，请从列表重试。";
        else if([launcher isKindOfClass:OPLauncher.class])[(OPLauncher *)launcher configure];
    });
}
- (void)applicationDidEnterBackground:(UIApplication *)application {
    (void)application;notify_post("com.lixinmo.skytouch.floating.launcher-resigned");OPConfigurationDidEnterBackground();
}
@end
@interface OPConfigurationApplication:UIApplication
@end
@implementation OPConfigurationApplication
- (void)sendEvent:(UIEvent *)event {
    OPRecordPanelFromConfigurationEvent(event);
    [super sendEvent:event];
}
@end
int main(int argc,char **argv) { @autoreleasepool {
    NSString *storageError=nil;
    if(!OPRecoverConfigurationManagementBeforeLaunch(&storageError)) {
        NSLog(@"[SkyTouch] Configuration recovery unavailable: %@",storageError);return 74;
    }
    if(!OPStorageDirectoriesReady(&storageError)) {
        NSLog(@"[SkyTouch] Storage unavailable: %@",storageError);return 74;
    }
    // Safe under the same reader/writer lock as normal snapshot publication.
    // A missing profile on first installation simply has nothing to prune.
    (void)OPPruneGlobalProfileHistory(nil);
    if(argc==2 && strcmp(argv[1],"--original-bluetooth-broker")==0)return OPRunBluetoothBroker();
    if(argc==3 && strcmp(argv[1],"--prepare-profile")==0) {
        NSString *target=[NSString stringWithUTF8String:argv[2]];
        if(geteuid()!=0 || !OPManagedTargetIsValid(target))return 64;
        int lock=open(OPRuntimePath(@"com.lixinmo.skytouch.original-host.lock").fileSystemRepresentation,O_CREAT|O_RDWR|O_CLOEXEC|O_NOFOLLOW,0600);
        if(lock<0)return 74;
        if(flock(lock,LOCK_EX|LOCK_NB)!=0){close(lock);return 75;}
        NSString *error=nil;BOOL ready=OPPrepareSharedOriginalProfile(target,&error);
        if(!ready)std::fprintf(stderr,"Profile preparation failed: %s\n",error.UTF8String ?: "unknown");
        close(lock);return ready ? 0 : 74;
    }
    if (argc>1) {
        BOOL hud=NO, inspect=NO, uiOnly=NO, supervisor=NO, stopUIOnly=NO,engineSession=NO;
        NSString *target=nil,*session=nil,*sessionTarget=nil;
        for (int i=1;i<argc;++i) {
            if (strcmp(argv[i],"--original-hud")==0) hud=YES;
            else if (strcmp(argv[i],"--engine-session")==0) engineSession=YES;
            else if (strcmp(argv[i],"--original-supervisor")==0) supervisor=YES;
            else if (strcmp(argv[i],"--stop-ui-only")==0) stopUIOnly=YES;
            else if (strcmp(argv[i],"--inspect-host")==0) inspect=YES;
            else if (strcmp(argv[i],"--verify-ui-only")==0) uiOnly=YES;
            else if (strcmp(argv[i],"--managed-session")==0 && i+1<argc && !session)
                session=[NSString stringWithUTF8String:argv[++i]];
            else if (strcmp(argv[i],"--session-target")==0 && i+1<argc && !sessionTarget)
                sessionTarget=[NSString stringWithUTF8String:argv[++i]];
            else if (strcmp(argv[i],"--target-bundle")==0 && i+1<argc) {
                target=[NSString stringWithUTF8String:argv[++i]];
                if (![target isEqualToString:@"com.lixinmo.skytouch.probe"]) {
                    std::fputs("--target-bundle only accepts com.lixinmo.skytouch.probe\n",stderr); return 64;
                }
            } else { std::fputs("Unknown or incomplete original-host option\n",stderr); return 64; }
        }
        if (supervisor && argc==2) return OPRunSessionSupervisor();
        if (stopUIOnly && argc==2) return notify_post("com.lixinmo.skytouch.original.ui-only.stop")==NOTIFY_STATUS_OK ? 0 : 69;
        if (inspect && argc==2) return OPInspectHost();
        if (hud && !inspect && !supervisor && !stopUIOnly) {
            if (session || sessionTarget) {
                if (engineSession && !uiOnly && !target && OPManagedSessionIdentifierIsValid(session) && OPManagedTargetIsValid(sessionTarget))
                    return OPRunManagedHUD(session,sessionTarget);
            } else if(!engineSession) return OPRunHUDWithOptions(uiOnly,target);
        }
        std::fputs("Use one mode: --original-supervisor, --inspect-host, --stop-ui-only, or --original-hud with its matching options\n",stderr); return 64;
    }
    return UIApplicationMain(argc,argv,NSStringFromClass(OPConfigurationApplication.class),NSStringFromClass(OPLauncherDelegate.class));
} }
