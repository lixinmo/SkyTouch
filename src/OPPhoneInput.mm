#import "OPPhoneInput.h"
#import "OPPhoneMotion.h"
#import "OPPhoneProfile.h"
#import "OPPhoneButtonClient.h"
#import "OPOriginalBridge.h"
#import "OPOriginalBluetoothClient.h"
#import <objc/message.h>
#import <objc/runtime.h>
#include <array>
#include <deque>
#include <cstring>

namespace op_phone_input {
using Report=std::array<std::uint8_t,20>;
static BOOL installed=NO,started=NO,active=NO,controllerMode=NO,armed=NO,waitingRelease=YES,faulted=NO;
static BOOL motionWasReady=NO;
static __weak id owner;
static OPPhoneMotion *motion;
static NSTimer *timer;
static UIInterfaceOrientation orientation=UIInterfaceOrientationUnknown;
static std::array<std::uint32_t,4> bindings{};
static Report controls=op_phone::neutralReport();
static std::deque<Report> boundaries;
static double lastControlTime=0;
static NSUInteger frames=0,cancellations=0,rejectedReports=0,boundaryFrames=0;
static NSString *stage=@"not-started";
static BOOL matches(const char *actual,const char *expected) {
    if(!actual)return NO;while(*actual&&std::strchr("rnNoORV",*actual))++actual;
    return !std::strcmp(actual,expected);
}
static BOOL signature(Class cls,BOOL classMethod,NSString *name,const char *result,NSArray<NSString *> *args) {
    Method m=classMethod ? class_getClassMethod(cls,NSSelectorFromString(name)) : class_getInstanceMethod(cls,NSSelectorFromString(name));
    NSMethodSignature *s=m ? [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(m)] : nil;
    if(!s||s.numberOfArguments!=args.count+2||!matches(s.methodReturnType,result))return NO;
    for(NSUInteger i=0;i<args.count;++i)if(!matches([s getArgumentTypeAtIndex:i+2],args[i].UTF8String))return NO;
    return YES;
}
static BOOL vendorABI(id target) {
    Class cls=object_getClass(target),prefs=NSClassFromString(@"FZPreferRecordTool");
    return [target isKindOfClass:NSClassFromString(@"FZCentralViewController")]&&
        signature(cls,NO,@"processData:","v",@[@"*"])&&signature(cls,NO,@"setDataCache:","v",@[@"*"])&&
        signature(cls,NO,@"updateKeyWithByte4:withByte5:withByte8:withByte9:","v",@[@"i",@"i",@"i",@"i"])&&
        signature(prefs,YES,@"sharedFZPreferRecordTool","@",@[])&&
        (signature(prefs,NO,@"enablePostKeyEvent","B",@[])||signature(prefs,NO,@"enablePostKeyEvent","c",@[]));
}
static void noBLE(id target,SEL) {
    if(!NSThread.isMainThread)return;
    ((void(*)(id,SEL,id))objc_msgSend)(target,NSSelectorFromString(@"setManager:"),nil);
    ((void(*)(id,SEL,id))objc_msgSend)(target,NSSelectorFromString(@"setPeripheral:"),nil);
    // Never set connectMode=2: this is a local input provider, not a peripheral.
}
static BOOL submit(Report report,op_phone::Delta delta) {
    if(!owner||!vendorABI(owner))return NO;
    op_phone::encodeMotion(report,delta);
    @try {
        // Pinned flydigi 1.6.6, normal gamepad callback, 0x1ac9c0..1aca9c
        // and 0x1ace98..1acf58: key transitions, legacy C mapper, then modern
        // dataBuf cache when not recording keys. Do not manufacture a BLE
        // identity, call updatePeripheralState, or run a second mapping engine.
        ((void(*)(id,SEL,int,int,int,int))objc_msgSend)(owner,
            NSSelectorFromString(@"updateKeyWithByte4:withByte5:withByte8:withByte9:"),report[4],report[5],report[8],report[9]);
        ((void(*)(id,SEL,char *))objc_msgSend)(owner,NSSelectorFromString(@"processData:"),(char *)report.data());
        id prefs=((id(*)(id,SEL))objc_msgSend)(NSClassFromString(@"FZPreferRecordTool"),NSSelectorFromString(@"sharedFZPreferRecordTool"));
        if(!((BOOL(*)(id,SEL))objc_msgSend)(prefs,NSSelectorFromString(@"enablePostKeyEvent")))
            ((void(*)(id,SEL,char *))objc_msgSend)(owner,NSSelectorFromString(@"setDataCache:"),(char *)report.data());
        ++frames;return YES;
    } @catch(__unused NSException *exception) {return NO;}
}
static void cancel(NSString *reason,BOOL fatal=NO) {
    boundaries.clear();controls=op_phone::neutralReport();lastControlTime=0;waitingRelease=YES;
    motionWasReady=NO;[motion clear];++cancellations;stage=reason;
    // Feed a zero control/zero motion state before clearing vendor bookkeeping,
    // so both input representations lose held buttons, not only HID contacts.
    if(owner)submit(op_phone::neutralReport(),{});
    OPStopOriginalTouches();
    // Vendor clearTouchList (0x19da30) only removes UITouch objects; a legacy
    // release-triggered macro or type35 lock can otherwise survive a pause.
    // Reload through the installed dual-engine fix to rebuild transient state
    // from the same current entity, without writing or changing the profile.
    if(owner&&!OPReloadOriginalConfiguration(nullptr)) {
        fatal=YES;stage=@"vendor-input-reset-failed";
    }
    if(fatal){faulted=YES;active=NO;[motion setActive:NO];}
    if(armed){armed=NO;OPSetPhoneButtonClientArmed(NO);}
}
static BOOL neutralControls(const Report &report) {
    // Inactive/disconnected cleanup remains exact: even a small forwarded
    // stick displacement may own a vendor touch and must be cancelled.
    return !op_phone::buttonsIn(report)&&report[0]==128&&report[1]==128&&report[2]==128&&report[3]==128;
}
static void updateControls(Report next) {
    op_phone::encodeMotion(next,{});next[18]=0xfe;next[19]=0;
    lastControlTime=NSProcessInfo.processInfo.systemUptime;
    if(!active||faulted){controls=next;return;}
    if(waitingRelease) {
        controls=next;
        if(!op_phone::releasedControls(next))return;
        waitingRelease=NO;[motion discardPending];stage=@"ready";
    }
    if(next!=controls) {
        // Axes are held state: coalesce their newest value at the engine tick.
        // Only button edges need extra ordered frames. Queuing every changing
        // axis/transport byte would advance legacy timers at BLE rate + tick rate.
        if(op_phone::buttonsIn(next)!=op_phone::buttonsIn(controls)) {
            if(boundaries.size()>=64){cancel(@"input-boundary-overflow",YES);return;}
            boundaries.push_back(next);
        }
        controls=next;
    }
}
static BOOL controllerReport(NSData *data,NSString *uuid) {
    if(!started||!controllerMode)return NO;
    if([uuid caseInsensitiveCompare:@"2A26"]==NSOrderedSame)return NO;
    const auto *b=(const std::uint8_t *)data.bytes;
    // Only known metadata retains the vendor identity/version route. Unknown
    // input cannot leak its own gyro into the explicitly selected phone source.
    if((data.length==14&&b[6]==0xba&&b[7]==0xc0)||
       (data.length==20&&b[0]==0xac&&b[1]==0xc0))return NO;
    if(!op_phone::isControlReport(b,data.length)) {
        ++rejectedReports;cancel(@"unsupported-controller-report",YES);return YES;
    }
    Report next=op_phone::neutralReport();std::memcpy(next.data(),b,data.length);
    updateControls(next);return YES;
}
static BOOL sourceReady() {
    return controllerMode ? OPOriginalBluetoothClientReady() : OPPhoneButtonClientReady();
}
static void tick() {
    if(!started||faulted)return;
    if(!active||!sourceReady()) {
        [motion setActive:NO];
        motionWasReady=NO;
        if(armed||!boundaries.empty()||!neutralControls(controls))cancel(@"input-inactive-or-unavailable");
        return;
    }
    [motion setActive:YES];
    // Start sampling before claiming readiness or intercepting system buttons.
    // A sampling interruption releases contacts and requires a new baseline.
    if(!motion.fresh) {
        if(motionWasReady||armed)cancel(@"phone-motion-expired");
        motionWasReady=NO;stage=@"awaiting-phone-motion";return;
    }
    motionWasReady=YES;
    if(!controllerMode&&!armed) {armed=YES;OPSetPhoneButtonClientArmed(YES);}
    // A controller may emit only changes. Its held state remains valid while
    // the authenticated BLE lease is live; gyro samples never renew that lease.
    if(waitingRelease){stage=@"awaiting-buttons-release";[motion discardPending];return;}
    stage=@"ready";
    // One owner of cadence. BLE and CoreMotion callbacks only update state.
    // Preserve fast down/up boundaries. The final edge IS this tick's frame;
    // it includes the latest axes and consumes motion once. No duplicate held
    // frame follows it. Earlier edges carry zero motion.
    const auto delta=[motion consume];
    if(boundaries.empty()) {
        if(!submit(controls,delta))cancel(@"vendor-input-failed",YES);
        return;
    }
    while(!boundaries.empty()) {
        Report next=boundaries.front();boundaries.pop_front();++boundaryFrames;
        const BOOL final=boundaries.empty();if(final)next=controls;
        if(!submit(next,final ? delta : op_phone::Delta{})){cancel(@"vendor-input-failed",YES);return;}
    }
}
}

BOOL OPInstallPhoneInput(NSString **error) {
    using namespace op_phone_input;if(error)*error=nil;
    if(!NSThread.isMainThread){if(error)*error=@"手机输入必须在主线程安装";return NO;}
    if(installed)return YES;
    Class cls=NSClassFromString(@"FZCentralViewController");
    if(OPOriginalController()||!signature(cls,NO,@"initBLE","v",@[])||
       !signature(cls,NO,@"setManager:","v",@[@"@"])||!signature(cls,NO,@"setPeripheral:","v",@[@"@"])) {
        if(error)*error=@"手机输入的原初始化接口不匹配或控制器已创建";return NO;
    }
    Method m=class_getInstanceMethod(cls,NSSelectorFromString(@"initBLE"));
    IMP previous=method_setImplementation(m,(IMP)noBLE);
    if(!previous||method_getImplementation(m)!=(IMP)noBLE) {
        if(previous)method_setImplementation(m,previous);if(error)*error=@"无法安装本机输入初始化";return NO;
    }
    installed=YES;return YES;
}
BOOL OPStartPhoneInput(id controller,NSInteger deviceType,NSDictionary *settings,NSString **error) {
    using namespace op_phone_input;if(error)*error=nil;
    if(!NSThread.isMainThread||started||(deviceType!=0&&deviceType!=2)||!vendorABI(controller)||
       ![settings isKindOfClass:NSDictionary.class]) {if(error)*error=@"手机输入状态、布局或原引擎接口无效";return NO;}
    const BOOL useController=[settings[@"mode"] isEqual:@"controller"];
    if(!useController&&![settings[@"mode"] isEqual:@"phone"]) {
        if(error)*error=@"输入来源设置无效";return NO;
    }
    if(useController&&![settings[@"controllerMotion"] isEqual:@"phone"]) {
        if(error)*error=@"当前手柄模式未选择手机体感";return NO;
    }
    if(!useController&&!installed){if(error)*error=@"本机输入初始化尚未安装";return NO;}
    if(!useController) {
        NSDictionary *map=settings[@"phoneBindings"];
        if(![map isKindOfClass:NSDictionary.class]){if(error)*error=@"手机按键绑定无效";return NO;}
        NSArray *keys=@[@"action",@"volumeUp",@"volumeDown",@"side"];
        for(NSUInteger i=0;i<4;++i)if(!OPPhoneLogicalKeyMask(map[keys[i]],deviceType,&bindings[i])) {
            if(error)*error=@"手机按键绑定不适用于当前方案布局";return NO;
        }
    }
    if(![settings[@"motionScaleX"] isKindOfClass:NSNumber.class]||![settings[@"motionScaleY"] isKindOfClass:NSNumber.class]) {
        if(error)*error=@"手机体感定标参数无效";return NO;
    }
    const double x=[settings[@"motionScaleX"] doubleValue],y=[settings[@"motionScaleY"] doubleValue];
    motion=[OPPhoneMotion new];
    if(![motion startWithScaleX:x scaleY:y error:error]){motion=nil;return NO;}
    [motion setOrientation:orientation];owner=controller;controllerMode=useController;
    started=YES;active=NO;faulted=NO;waitingRelease=YES;motionWasReady=NO;controls=op_phone::neutralReport();lastControlTime=0;
    boundaries.clear();stage=@"awaiting-input-capability";
    if(controllerMode) {
        OPSetOriginalBluetoothInputFilter(^BOOL(NSData *value,NSString *uuid){return controllerReport(value,uuid);},^{
            if(started&&controllerMode)cancel(@"controller-session-invalidated");
        });
    } else if(!OPStartPhoneButtonClient(^(std::uint32_t physical){
        if(!started||controllerMode)return;
        if(physical&~15U){cancel(@"invalid-phone-mask",YES);return;}
        std::uint32_t logical=0;
        // OR the bindings: releasing either of two keys bound to the same
        // logical key cannot release it while the other is still held.
        for(NSUInteger i=0;i<4;++i)if(physical&(1U<<i))logical|=bindings[i];
        Report next=op_phone::neutralReport();op_phone::encodeButtons(next,logical);updateControls(next);
    },^{if(started&&!controllerMode)cancel(@"phone-button-session-invalidated");},error)) {
        OPStopPhoneInput();return NO;
    }
    timer=[NSTimer timerWithTimeInterval:.01 repeats:YES block:^(__unused NSTimer *value){tick();}];
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];return YES;
}
BOOL OPPhoneInputReady(void) {
    using namespace op_phone_input;return NSThread.isMainThread&&started&&!faulted&&owner&&sourceReady()&&motion.fresh;
}
void OPSetPhoneInputActive(BOOL value) {
    using namespace op_phone_input;if(!NSThread.isMainThread||!started||active==value)return;
    active=value;
    if(!value){[motion setActive:NO];cancel(@"paused");}
    else {
        // The button bridge independently refuses to arm across a held key.
        // A received zero baseline must not make the first real down disappear.
        waitingRelease=lastControlTime<=0 || !op_phone::releasedControls(controls);
        [motion clear];tick();
    }
}
void OPSetPhoneInputOrientation(UIInterfaceOrientation value) {
    using namespace op_phone_input;if(!NSThread.isMainThread||orientation==value)return;
    orientation=value;[motion setOrientation:value];if(started)cancel(@"orientation-changed");
}
void OPStopPhoneInput(void) {
    using namespace op_phone_input;if(!NSThread.isMainThread)return;
    if(!started)return;
    active=NO;cancel(@"stopped");started=NO;
    OPSetOriginalBluetoothInputFilter(nil,nil);
    if(!controllerMode)OPStopPhoneButtonClient();
    [timer invalidate];timer=nil;[motion stop];motion=nil;owner=nil;boundaries.clear();
}
NSDictionary *OPPhoneInputStatus(void) {
    using namespace op_phone_input;
    if(!NSThread.isMainThread)return @{@"ready":@NO,@"stage":@"requires-main-thread"};
    return @{@"started":@(started),@"ready":@(OPPhoneInputReady()),@"active":@(active),@"stage":stage,
        @"controlSource":controllerMode ? @"controller" : @"phone",@"motionSource":@"phone",
        @"waitingRelease":@(waitingRelease),@"faulted":@(faulted),@"experimental":@NO,
        @"frames":@(frames),@"boundaryFrames":@(boundaryFrames),@"cancellations":@(cancellations),
        @"rejectedReports":@(rejectedReports),@"requestedTickHz":@100,
        @"motion":motion.status ?: @{},@"buttons":controllerMode ? @{} : OPPhoneButtonClientStatus()};
}
