#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#include "OPPhoneButtonTransport.hpp"
#include <atomic>

// ABI references (interfaces only; implementation below is independent):
// MTACS/iOS-17-Runtime-Headers, PrivateFrameworks/SpringBoard.framework/
// SpringBoard.h, SBRingerHardwareButton.h; UIKitCore.framework/UIPressesEvent.h.
// Physical button type 102/103/104 is also documented by Kurrt's example:
// https://gist.github.com/Kurrt/37ba802bd473d623e6c5266058b9daab
// No runtime capability is a claim of completed device acceptance testing.
using namespace op_phone_buttons;
namespace {
using ButtonIMP=void(*)(id,SEL,id);
using PhysicalIMP=bool(*)(id,SEL,id);
static ButtonIMP originalActionDown,originalActionUp,originalActionLong;
static PhysicalIMP originalPhysical;
static Ownership ownership;
static PressHistory pressHistory;
static NativeClaims nativeClaims;
static std::atomic<uint32_t> blockedGestures{0},blockedNativeActions{0};
static std::atomic<uint64_t> armedUntil{0},connectionEpoch{0},latestCommand{0},latestLeaseSequence{0};
static std::atomic<bool> requestedArmed{false};
static std::atomic<uint32_t> capabilities{0};
static std::atomic<uint32_t> pendingMainCallbacks{0};
static uint64_t mainCommand=0,mainEpoch=0;
static bool maintenance=false;
static std::atomic<bool> runtimeInvalid{false};
static std::atomic<bool> hooksAttempted{false};
static std::atomic<bool> hooksInstalled{false};
static std::atomic<uint32_t> diagnosticValue{(uint32_t)Diagnostic::Starting};
static int diagnosticToken=-1;
static int suppressionToken=-1;
static uint64_t lastDiagnosticWrite=0;
static uint32_t lastDiagnosticValue=UINT32_MAX;
static uint64_t lastSuppressionCounts=UINT64_MAX;
static NSString *installationRoot,*endpoint;
static dispatch_queue_t transportQueue;
static dispatch_source_t transportTimer;
static Stream connection;
static Packet session;
static Sequence incoming;
static uint64_t outgoing=0,lastSeen=0,lastAttempt=0;
static bool connecting=false,welcomed=false;
static void disconnect(void);
static void publish(void);
static void revoke(void) {armedUntil=0;ownership.setArmed(false);}
static void diagnose(Diagnostic stage,uint8_t detail=0) {
    diagnosticValue=(uint32_t)stage|((uint32_t)detail<<8);
}
// The volatile notify state is a support hint, not an authentication channel.
// Update freshness without posting repeated notifications for unchanged state.
static void flushDiagnostic(void) {
    if(diagnosticToken<0)return;
    const uint64_t now=nowNs();const uint32_t value=diagnosticValue.load()|
        (capabilities.load()<<16)|((uint32_t)version<<24);
    const uint64_t counts=((uint64_t)blockedNativeActions.load()<<32)|blockedGestures.load();
    if(value==lastDiagnosticValue && counts==lastSuppressionCounts && now-lastDiagnosticWrite<5*NSEC_PER_SEC)return;
    const uint64_t state=((now/NSEC_PER_SEC)<<32)|value;
    if(notify_set_state(diagnosticToken,state)==NOTIFY_STATUS_OK) {
        if(value!=lastDiagnosticValue)(void)notify_post(diagnosticNotification);
        lastDiagnosticWrite=now;lastDiagnosticValue=value;
    }
    if(suppressionToken>=0 && notify_set_state(suppressionToken,counts)==NOTIFY_STATUS_OK)lastSuppressionCounts=counts;
}

static bool methodABI(Class cls,const char *name,const char *result,NSArray<NSString *> *arguments) {
    Method method=class_getInstanceMethod(cls,sel_registerName(name));
    NSMethodSignature *signature=method ? [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)] : nil;
    if(!signature || strcmp(signature.methodReturnType,result) || signature.numberOfArguments!=arguments.count+2)return false;
    for(NSUInteger i=0;i<arguments.count;++i) {
        const char *actual=[signature getArgumentTypeAtIndex:i+2],*expected=arguments[i].UTF8String;
        if(expected[0]=='@' ? actual[0]!='@' : strcmp(actual,expected))return false;
    }
    return true;
}
static bool captureAllowed(void) {
    const uint64_t deadline=armedUntil.load();
    const bool allowed=!maintenance && requestedArmed.load() && capabilities.load()==all && deadline && nowNs()<deadline;
    if(!allowed && ownership.armed)revoke();
    return allowed;
}
static void changed(const Ownership &before) {
    if(before.physical!=ownership.physical || before.mapped!=ownership.mapped ||
       before.armed!=ownership.armed || before.waitingRelease!=ownership.waitingRelease)publish();
}
static void actionDown(id object,SEL selector,id event) {
    if(!NSThread.isMainThread){runtimeInvalid=true;capabilities=0;armedUntil=0;originalActionDown(object,selector,event);return;}
    const Ownership before=ownership;
    const bool swallow=ownership.event(action,true,captureAllowed());changed(before);
    if(!swallow)originalActionDown(object,selector,event);
}
static void actionUp(id object,SEL selector,id event) {
    if(!NSThread.isMainThread){runtimeInvalid=true;capabilities=0;armedUntil=0;originalActionUp(object,selector,event);return;}
    const Ownership before=ownership;(void)captureAllowed();
    const bool swallow=ownership.event(action,false,false);changed(before);
    if(!swallow)originalActionUp(object,selector,event);
}
static void actionLong(id object,SEL selector,id event) {
    if(!NSThread.isMainThread){runtimeInvalid=true;capabilities=0;armedUntil=0;originalActionLong(object,selector,event);return;}
    const Ownership before=ownership;(void)captureAllowed();changed(before);
    if(!(ownership.owned&action))originalActionLong(object,selector,event);
}
static uint32_t bitForPress(NSInteger type) {
    switch(type){case 102:return volumeUp;case 103:return volumeDown;case 104:return side;default:return 0;}
}
static void nativeGesture(id,SEL,id);
static void volumeDownAction(id,SEL,long long);
static void sideDownAction(id,SEL);
static void nativeAction(id,SEL);
static bool nativeBoolAction(id,SEL);
struct NativeHook {
    const char *className,*name,*result,*argument;
    IMP replacement;
    uint32_t bit;
    bool primary;
    SEL selector=nullptr;
    IMP original=nullptr;
    bool installed=false;
};
// ABI diagnostic.detail 32 + index identifies this stable list. Primary
// gesture + ordinary down/up/single action routes are mandatory. Additional
// gesture outcomes are hooked when present; an absent outcome cannot execute.
static NativeHook nativeHooks[]={
    {"SBVolumeHardwareButton","volumeIncreasePress:","v","@",(IMP)nativeGesture,volumeUp,true},
    {"SBVolumeHardwareButton","volumeDecreasePress:","v","@",(IMP)nativeGesture,volumeDown,true},
    {"SBLockHardwareButton","buttonDown:","v","@",(IMP)nativeGesture,side,true},
    {"SBLockHardwareButton","singlePress:","v","@",(IMP)nativeGesture,side,false},
    {"SBLockHardwareButton","doublePress:","v","@",(IMP)nativeGesture,side,false},
    {"SBLockHardwareButton","triplePress:","v","@",(IMP)nativeGesture,side,false},
    {"SBLockHardwareButton","quadruplePress:","v","@",(IMP)nativeGesture,side,false},
    {"SBLockHardwareButton","longPress:","v","@",(IMP)nativeGesture,side,false},
    {"SBLockHardwareButton","terminalLockLongPress:","v","@",(IMP)nativeGesture,side,false},
    {"SBVolumeHardwareButtonActions","volumeIncreasePressDownWithModifiers:","v","q",(IMP)volumeDownAction,volumeUp,false},
    {"SBVolumeHardwareButtonActions","volumeDecreasePressDownWithModifiers:","v","q",(IMP)volumeDownAction,volumeDown,false},
    {"SBVolumeHardwareButtonActions","volumeIncreasePressUp","v",nullptr,(IMP)nativeAction,volumeUp,false},
    {"SBVolumeHardwareButtonActions","volumeDecreasePressUp","v",nullptr,(IMP)nativeAction,volumeDown,false},
    {"SBLockHardwareButtonActions","performInitialButtonDownActions","v",nullptr,(IMP)sideDownAction,side,false},
    {"SBLockHardwareButtonActions","performSecondButtonDownActions","v",nullptr,(IMP)sideDownAction,side,false},
    {"SBLockHardwareButtonActions","performInitialButtonUpActions","v",nullptr,(IMP)nativeAction,side,false},
    {"SBLockHardwareButtonActions","performFinalButtonUpActions","v",nullptr,(IMP)nativeAction,side,false},
    {"SBLockHardwareButtonActions","performSinglePressAction","v",nullptr,(IMP)nativeAction,side,false},
    {"SBLockHardwareButtonActions","performSinglePressDidFailActions","v",nullptr,(IMP)nativeAction,side,false},
    {"SBLockHardwareButtonActions","performDoublePressActions","v",nullptr,(IMP)nativeAction,side,false},
    {"SBLockHardwareButtonActions","performTriplePressActions","v",nullptr,(IMP)nativeAction,side,false},
    {"SBLockHardwareButtonActions","performLongPressActions","v",nullptr,(IMP)nativeAction,side,false},
    {"SBLockHardwareButtonActions","performLongPressCancelledActions","v",nullptr,(IMP)nativeAction,side,false},
    {"SBLockHardwareButtonActions","performTerminalLockLongPressActions","v",nullptr,(IMP)nativeAction,side,false},
    {"SBLockHardwareButtonActions","performButtonUpPreActions","B",nullptr,(IMP)nativeBoolAction,side,false},
};
static NativeHook *nativeHook(SEL selector) {
    for(auto &hook:nativeHooks)if(hook.selector==selector)return &hook;
    return nullptr;
}
static char actionBindingKeys[4];
struct NativeScope {
    __unsafe_unretained id object=nil;
    uint32_t bit=0;
    bool known=false,owned=false;
};
static NativeScope nativeScope;
static void bindActions(id object,uint32_t bit,const PressRecord &record,bool force=false) {
    const int index=PressHistory::index(bit);if(!object || index<0)return;
    NSDictionary *previous=objc_getAssociatedObject(object,&actionBindingKeys[index]);
    if(!force && [previous[@"token"] unsignedLongLongValue]>record.token)return;
    objc_setAssociatedObject(object,&actionBindingKeys[index],@{@"token":@(record.token),@"owned":@(record.owned)},OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static bool actionOwned(id object,uint32_t bit) {
    if(nativeScope.known && nativeScope.object==object && nativeScope.bit==bit)return nativeScope.owned;
    const int index=PressHistory::index(bit);if(index<0)return false;
    NSDictionary *binding=objc_getAssociatedObject(object,&actionBindingKeys[index]);
    return [binding[@"owned"] boolValue];
}
static bool beginNativeAction(id object,uint32_t bit) {
    if(nativeScope.known && nativeScope.object==object && nativeScope.bit==bit)return nativeScope.owned;
    // A new native down replaces the preceding action token immediately. The
    // preceding up/action may have been delayed, but cannot own this new press.
    const Ownership before=ownership;
    const PressRecord record=nativeClaims.begin(ownership,pressHistory,bit,captureAllowed());
    if(nativeClaims.overflow){runtimeInvalid=true;capabilities=0;revoke();}
    changed(before);bindActions(object,bit,record,true);return record.owned;
}
static void nativeGesture(id object,SEL selector,id recognizer) {
    NativeHook *hook=nativeHook(selector);if(!hook || !hook->original)return;
    if(!NSThread.isMainThread){runtimeInvalid=true;capabilities=0;armedUntil=0;((ButtonIMP)hook->original)(object,selector,recognizer);return;}
    PressRecord record{};
    Class pressClass=objc_getClass("SBPressGestureRecognizer");
    if([recognizer isKindOfClass:pressClass]) {
        const long long type=((long long(*)(id,SEL))objc_msgSend)(recognizer,sel_registerName("latestPressType"));
        const long long phase=((long long(*)(id,SEL))objc_msgSend)(recognizer,sel_registerName("latestPressPhase"));
        const double timestamp=((double(*)(id,SEL))objc_msgSend)(recognizer,sel_registerName("latestPressTimestamp"));
        if(bitForPress(type)==hook->bit && phase>=0 && phase<=4 && std::isfinite(timestamp) && timestamp>0) {
            record=pressHistory.find(hook->bit,timestamp);
            if(hook->primary) {
                const Ownership before=ownership;const bool allowed=captureAllowed();
                record=nativeClaims.transition(ownership,pressHistory,hook->bit,(int)phase,timestamp,allowed);changed(before);
            } else if(!record.token)record=nativeClaims.completed(pressHistory,hook->bit,timestamp);
        }
    }
    id actions=((id(*)(id,SEL))objc_msgSend)(object,sel_registerName("buttonActions"));
    if(record.token)bindActions(actions,hook->bit,record);
    if(record.token && record.owned){++blockedGestures;return;}
    const NativeScope previous=nativeScope;
    nativeScope={actions,hook->bit,true,false};
    @try {((ButtonIMP)hook->original)(object,selector,recognizer);}
    @finally {nativeScope=previous;}
}
static void volumeDownAction(id object,SEL selector,long long modifiers) {
    NativeHook *hook=nativeHook(selector);if(!hook || !hook->original)return;
    if(NSThread.isMainThread && beginNativeAction(object,hook->bit)){++blockedNativeActions;return;}
    ((void(*)(id,SEL,long long))hook->original)(object,selector,modifiers);
}
static void sideDownAction(id object,SEL selector) {
    NativeHook *hook=nativeHook(selector);if(!hook || !hook->original)return;
    if(NSThread.isMainThread && beginNativeAction(object,hook->bit)){++blockedNativeActions;return;}
    ((void(*)(id,SEL))hook->original)(object,selector);
}
static void nativeAction(id object,SEL selector) {
    NativeHook *hook=nativeHook(selector);if(!hook || !hook->original)return;
    // Keep this action token after final-up. Deferred click callbacks still
    // belong to it; the next down/identified gesture replaces it, not a timer.
    if(NSThread.isMainThread) {
        const bool owned=actionOwned(object,hook->bit);
        if(!nativeScope.known &&
           (selector==sel_registerName("volumeIncreasePressUp") || selector==sel_registerName("volumeDecreasePressUp") ||
            selector==sel_registerName("performInitialButtonUpActions"))) {
            const int index=PressHistory::index(hook->bit);
            NSDictionary *binding=index>=0 ? objc_getAssociatedObject(object,&actionBindingKeys[index]) : nil;
            const Ownership before=ownership;
            nativeClaims.end(ownership,pressHistory,hook->bit,[binding[@"token"] unsignedLongLongValue]);changed(before);
        }
        if(owned){++blockedNativeActions;return;}
    }
    ((void(*)(id,SEL))hook->original)(object,selector);
}
static bool nativeBoolAction(id object,SEL selector) {
    NativeHook *hook=nativeHook(selector);if(!hook || !hook->original)return false;
    if(NSThread.isMainThread && actionOwned(object,hook->bit)){++blockedNativeActions;return true;}
    return ((bool(*)(id,SEL))hook->original)(object,selector);
}
static bool physicalEvent(id object,SEL selector,id event) {
    if(!NSThread.isMainThread){runtimeInvalid=true;capabilities=0;armedUntil=0;return originalPhysical(object,selector,event);}
    const Ownership before=ownership;
    const bool allowed=captureAllowed();
    if(![event isKindOfClass:UIPressesEvent.class]){changed(before);return originalPhysical(object,selector,event);}
    NSSet *presses=[event allPresses];
    if(![presses isKindOfClass:NSSet.class] || presses.count>16){changed(before);return originalPhysical(object,selector,event);}
    Ownership next=ownership;
    PressHistory nextHistory=pressHistory;
    NativeClaims nextClaims=nativeClaims;
    NSMutableArray *consumed=[NSMutableArray arrayWithCapacity:presses.count];
    for(id press in presses) {
        if(![press isKindOfClass:UIPress.class]){runtimeInvalid=true;capabilities=0;revoke();changed(before);return originalPhysical(object,selector,event);}
    }
    // Processing the complete set preserves simultaneous button transitions.
    // Stable order also makes same-timestamp input deterministic.
    NSArray *ordered=[presses.allObjects sortedArrayUsingComparator:^NSComparisonResult(UIPress *a,UIPress *b) {
        if(a.type<b.type)return NSOrderedAscending;if(a.type>b.type)return NSOrderedDescending;return NSOrderedSame;
    }];
    for(UIPress *press in ordered) {
        const uint32_t bit=bitForPress(press.type);if(!bit)continue;
        const UIPressPhase phase=press.phase;
        const double timestamp=press.timestamp;
        if(phase<UIPressPhaseBegan || phase>UIPressPhaseCancelled || !std::isfinite(timestamp) || timestamp<=0) {
            runtimeInvalid=true;capabilities=0;revoke();changed(before);return originalPhysical(object,selector,event);
        }
        const PressRecord record=nextClaims.transition(next,nextHistory,bit,(int)phase,timestamp,allowed);
        if(record.owned)[consumed addObject:press];
    }
    id nativeEvent=event;
    if(consumed.count && consumed.count!=presses.count) {
        nativeEvent=((id(*)(id,SEL))objc_msgSend)(event,sel_registerName("_cloneEvent"));
        if(nativeEvent==event || ![nativeEvent isKindOfClass:UIPressesEvent.class]) {
            runtimeInvalid=true;capabilities=0;revoke();changed(before);return originalPhysical(object,selector,event);
        }
        for(id press in consumed)((void(*)(id,SEL,id))objc_msgSend)(nativeEvent,sel_registerName("_removePress:"),press);
        if([[nativeEvent allPresses] count]!=presses.count-consumed.count || [[event allPresses] count]!=presses.count) {
            runtimeInvalid=true;capabilities=0;revoke();changed(before);return originalPhysical(object,selector,event);
        }
    }
    ownership=next;pressHistory=nextHistory;nativeClaims=nextClaims;changed(before);
    return consumed.count==presses.count && consumed.count ? true : originalPhysical(object,selector,nativeEvent);
}
static bool replace(Class cls,const char *name,IMP replacement,IMP *old) {
    const SEL selector=sel_registerName(name);Method method=class_getInstanceMethod(cls,selector);
    if(!method)return false;
    *old=method_getImplementation(method);
    if(!*old || *old==replacement)return false;
    // Never mutate a superclass method while intending to hook one class.
    if(!class_addMethod(cls,selector,replacement,method_getTypeEncoding(method))) {
        Method own=class_getInstanceMethod(cls,selector);method_setImplementation(own,replacement);
    }
    return class_getMethodImplementation(cls,selector)==replacement;
}
static uint32_t activeCapabilities(void) {
    if(runtimeInvalid || maintenance || !hooksInstalled.load())return 0;
    Class actionClass=objc_getClass("SBRingerHardwareButton"),springboard=objc_getClass("SpringBoard");
    uint32_t result=0;
    if(class_getMethodImplementation(actionClass,sel_registerName("performActionsForButtonDown:"))==(IMP)actionDown &&
       class_getMethodImplementation(actionClass,sel_registerName("performActionsForButtonUp:"))==(IMP)actionUp &&
       class_getMethodImplementation(actionClass,sel_registerName("performActionsForButtonLongPress:"))==(IMP)actionLong)result|=action;
    if(class_getMethodImplementation(springboard,sel_registerName("_handlePhysicalButtonEvent:"))==(IMP)physicalEvent) {
        uint32_t native=volumeUp|volumeDown|side;
        for(const auto &hook:nativeHooks)if(hook.installed &&
            class_getMethodImplementation(objc_getClass(hook.className),hook.selector)!=hook.replacement)native&=~hook.bit;
        result|=native;
    }
    return result;
}
static void installHooks(void) {
    Class actionClass=objc_getClass("SBRingerHardwareButton"),springboard=objc_getClass("SpringBoard");
    // The all-or-nothing preflight leaves unsupported systems entirely native.
    struct Check {Class cls;const char *name,*result,*argument;};
    // Stable ABI diagnostic.detail 1..15, in this order.
    const Check checks[]={
        {actionClass,"performActionsForButtonDown:","v","@"},
        {actionClass,"performActionsForButtonUp:","v","@"},
        {actionClass,"performActionsForButtonLongPress:","v","@"},
        {springboard,"_handlePhysicalButtonEvent:","B","@"},
        {UIPressesEvent.class,"allPresses","@",nullptr},
        {UIPressesEvent.class,"_cloneEvent","@",nullptr},
        {UIPressesEvent.class,"_removePress:","v","@"},
        {UIPress.class,"type","q",nullptr},{UIPress.class,"phase","q",nullptr},{UIPress.class,"timestamp","d",nullptr},
        {objc_getClass("SBPressGestureRecognizer"),"latestPressType","q",nullptr},
        {objc_getClass("SBPressGestureRecognizer"),"latestPressPhase","q",nullptr},
        {objc_getClass("SBPressGestureRecognizer"),"latestPressTimestamp","d",nullptr},
        {objc_getClass("SBVolumeHardwareButton"),"buttonActions","@",nullptr},
        {objc_getClass("SBLockHardwareButton"),"buttonActions","@",nullptr},
    };
    for(size_t i=0;i<std::size(checks);++i) {
        const auto &check=checks[i];
        if(!methodABI(check.cls,check.name,check.result,check.argument ? @[@(check.argument)] : @[])) {
            diagnose(Diagnostic::ABIMismatch,(uint8_t)(i+1));return;
        }
    }
    for(size_t i=0;i<std::size(nativeHooks);++i) {
        auto &hook=nativeHooks[i];hook.selector=sel_registerName(hook.name);
        Class cls=objc_getClass(hook.className);Method method=class_getInstanceMethod(cls,hook.selector);
        const bool required=hook.primary || i==3 || (i>=9 && i<=17);
        if(!method && !required)continue;
        if(!methodABI(cls,hook.name,hook.result,hook.argument ? @[@(hook.argument)] : @[])) {
            diagnose(Diagnostic::ABIMismatch,(uint8_t)(32+i));return;
        }
    }
    bool ok=replace(actionClass,"performActionsForButtonDown:",(IMP)actionDown,(IMP *)&originalActionDown) &&
        replace(actionClass,"performActionsForButtonUp:",(IMP)actionUp,(IMP *)&originalActionUp) &&
        replace(actionClass,"performActionsForButtonLongPress:",(IMP)actionLong,(IMP *)&originalActionLong) &&
        replace(springboard,"_handlePhysicalButtonEvent:",(IMP)physicalEvent,(IMP *)&originalPhysical);
    for(auto &hook:nativeHooks) {
        Class cls=objc_getClass(hook.className);
        if(class_getInstanceMethod(cls,hook.selector)) {
            hook.installed=replace(cls,hook.name,hook.replacement,&hook.original);ok=ok && hook.installed;
        }
    }
    hooksInstalled=ok;
    capabilities=ok ? activeCapabilities() : 0;
    diagnose(ok ? Diagnostic::WaitingEndpoint : Diagnostic::HookConflict);
}
static void prepareHooks(unsigned attempt) {
    if(!objc_getClass("SpringBoard") || !objc_getClass("SBRingerHardwareButton") ||
       !objc_getClass("SBVolumeHardwareButton") || !objc_getClass("SBLockHardwareButton") ||
       !objc_getClass("SBVolumeHardwareButtonActions") || !objc_getClass("SBLockHardwareButtonActions")) {
        diagnose(Diagnostic::WaitingClasses);
        if(attempt<30)dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{prepareHooks(attempt+1);});
        else {hooksAttempted=true;diagnose(Diagnostic::ABIMismatch,255);}
        return;
    }
    installHooks();hooksAttempted=true;
}
static NSString *resolveInstallation(void) {
    Dl_info image{};char resolved[PATH_MAX]{};
    diagnose(Diagnostic::ResolvingRoot);
    if(!dladdr((const void *)&resolveInstallation,&image) || !image.dli_fname || !realpath(image.dli_fname,resolved)) {
        diagnose(Diagnostic::ImagePathRejected,1);return nil;
    }
    NSString *path=@(resolved),*suffix=nil;
    // RootHide's shipped DynamicLibraries directory is a symlink to this
    // canonical TweakInject directory. Accept exactly our own filename in
    // either layout, then verify the same installation root through libroothide.
    for(NSString *candidate in @[@"/Library/MobileSubstrate/DynamicLibraries/SkyTouchButtons.dylib",
                                @"/usr/lib/TweakInject/SkyTouchButtons.dylib"])
        if([path hasSuffix:candidate]){suffix=candidate;break;}
    if(!suffix || !regularRootFile(resolved)){diagnose(Diagnostic::ImagePathRejected,2);return nil;}
    NSString *root=[path substringToIndex:path.length-suffix.length];
    NSString *leaf=root.lastPathComponent;
    if(!leaf.length || [leaf rangeOfString:@"^\\.jbroot-[0-9A-Fa-f]+$" options:NSRegularExpressionSearch].length!=leaf.length) {
        diagnose(Diagnostic::ImagePathRejected,3);return nil;
    }
    NSString *library=[root stringByAppendingPathComponent:@"usr/lib/libroothide.dylib"];
    if(!regularRootFile(library.fileSystemRepresentation)){diagnose(Diagnostic::RootLibraryRejected,1);return nil;}
    void *handle=dlopen(library.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL);
    using RootPath=const char *(*)(const char *);
    RootPath convert=handle ? (RootPath)dlsym(handle,"jbroot") : nullptr;
    const char *converted=convert ? convert("/") : nullptr;char convertedRoot[PATH_MAX]{};
    if(!converted || !realpath(converted,convertedRoot) || strcmp(root.fileSystemRepresentation,convertedRoot)) {
        diagnose(Diagnostic::RootMismatch,1);return nil;
    }
    NSString *expectedParent=[root stringByAppendingPathComponent:@"tmp"];
    const char *parent=convert("/tmp");char actualParent[PATH_MAX]{},trustedParent[PATH_MAX]{};
    if(!parent || !realpath(parent,actualParent) || !realpath(expectedParent.fileSystemRepresentation,trustedParent) ||
       strcmp(actualParent,trustedParent)){diagnose(Diagnostic::RootMismatch,2);return nil;}
    endpoint=[root stringByAppendingPathComponent:@"tmp/skytouch-buttons/s"];
    sockaddr_un check{};if(!address(endpoint.fileSystemRepresentation,check)){diagnose(Diagnostic::EndpointTooLong);return nil;}
    return root;
}
static bool endpointTrusted(void) {
    struct stat directory{},socket{};
    NSString *parent=endpoint.stringByDeletingLastPathComponent;
    int fd=open(parent.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(fd<0){if(capabilities.load()==all)diagnose(errno==ENOENT ? Diagnostic::WaitingEndpoint : Diagnostic::EndpointRejected,1);return false;}
    const bool ok=!fstat(fd,&directory) && directory.st_uid==0 && (directory.st_mode&0777)==0755 &&
        !fstatat(fd,socketName,&socket,AT_SYMLINK_NOFOLLOW) && S_ISSOCK(socket.st_mode) &&
        socket.st_uid==501 && (socket.st_mode&0777)==0600;
    close(fd);if(!ok && capabilities.load()==all)diagnose(Diagnostic::EndpointRejected,2);return ok;
}
static void disconnect(void) {
    armedUntil=0;requestedArmed=false;latestCommand=0;latestLeaseSequence=0;
    connection.close();connecting=welcomed=false;incoming={};outgoing=lastSeen=0;
    if(transportTimer)dispatch_source_set_timer(transportTimer,dispatch_time(DISPATCH_TIME_NOW,500*NSEC_PER_MSEC),500*NSEC_PER_MSEC,50*NSEC_PER_MSEC);
    const uint64_t epoch=++connectionEpoch;
    dispatch_async(dispatch_get_main_queue(),^{
        if(connectionEpoch.load()!=epoch)return;
        mainEpoch=epoch;mainCommand=0;revoke();
    });
}
static bool sendPacket(Kind kind,uint64_t epoch,uint64_t commandValue,uint32_t physical,uint32_t mapped,uint32_t flags,uint64_t timestamp) {
    if(connection.fd<0 || !welcomed || connectionEpoch.load()!=epoch)return false;
    Packet packet=session;packet.kind=kind;packet.sequence=++outgoing;packet.timestamp=timestamp;
    packet.command=commandValue;packet.capabilities=capabilities.load();packet.physical=physical;packet.mapped=mapped;packet.flags=flags;
    return connection.queue(packet) && connection.flush();
}
static void publish(void) {
    if(!transportQueue || !mainEpoch)return;
    const uint64_t epoch=mainEpoch,commandValue=mainCommand,timestamp=nowNs();
    const uint32_t physical=ownership.physical,mapped=ownership.mapped;
    const uint32_t flags=(ownership.armed ? 1u : 0u)|(ownership.waitingRelease ? 2u : 0u);
    dispatch_async(transportQueue,^{
        if(connectionEpoch.load()!=epoch || !welcomed || !commandValue)return;
        if(!sendPacket(Kind::State,epoch,commandValue,physical,mapped,flags,timestamp))disconnect();
    });
}
static bool receive(const Packet &packet) {
    const uint64_t now=nowNs();
    if(!valid(packet,now) || !incoming.accept(packet.sequence))return false;
    if(!welcomed) {
        if(packet.kind!=Kind::Welcome || packet.capabilities || packet.flags || packet.mapped || packet.physical)return false;
        if(pendingMainCallbacks.fetch_add(1)>=maximumPending){pendingMainCallbacks.fetch_sub(1);return false;}
        session=packet;welcomed=true;lastSeen=now;
        const uint64_t epoch=connectionEpoch.load();
        dispatch_async(dispatch_get_main_queue(),^{
            pendingMainCallbacks.fetch_sub(1);
            if(connectionEpoch.load()!=epoch)return;
            mainEpoch=epoch;mainCommand=0;revoke();capabilities=activeCapabilities();
            diagnose(capabilities.load()==all ? Diagnostic::Handshaking : Diagnostic::ABIMismatch);
            const uint32_t physical=ownership.physical;const uint64_t timestamp=nowNs();
            dispatch_async(transportQueue,^{
                if(connectionEpoch.load()!=epoch)return;
                if(!sendPacket(Kind::Hello,epoch,0,physical,0,0,timestamp))disconnect();
            });
        });
        return true;
    }
    if(!sameGeneration(packet,session) || packet.kind!=Kind::Lease || !packet.command ||
       packet.command<latestCommand.load() || packet.capabilities || packet.mapped || packet.physical || (packet.flags&~1u))return false;
    latestCommand=packet.command;
    latestLeaseSequence=packet.sequence;requestedArmed=(packet.flags&1)!=0;
    if(pendingMainCallbacks.fetch_add(1)>=maximumPending){pendingMainCallbacks.fetch_sub(1);return false;}
    lastSeen=now;
    const uint64_t epoch=connectionEpoch.load(),deadline=packet.timestamp+leaseNs;
    // The atomic deadline is read directly by the hook: a stalled main queue
    // cannot keep a stale lease armed. Commands themselves apply on main.
    if(!(packet.flags&1))armedUntil=0;
    const Packet copy=packet;
    dispatch_async(dispatch_get_main_queue(),^{
        pendingMainCallbacks.fetch_sub(1);
        if(connectionEpoch.load()!=epoch || copy.command!=latestCommand.load() || copy.sequence!=latestLeaseSequence.load())return;
        mainEpoch=epoch;
        if(copy.command<mainCommand){armedUntil=0;return;}
        capabilities=activeCapabilities();
        if(copy.command!=mainCommand){ownership.setArmed(false);mainCommand=copy.command;}
        const bool allow=(copy.flags&1) && !maintenance && capabilities.load()==all && nowNs()<deadline;
        armedUntil=allow ? deadline : 0;ownership.setArmed(allow);publish();
        diagnose(maintenance ? Diagnostic::Maintenance : capabilities.load()!=all ?
            (hooksInstalled.load() ? Diagnostic::HookConflict : Diagnostic::ABIMismatch) :
            allow ? Diagnostic::Armed : Diagnostic::ReadyDisarmed);
    });
    return true;
}
static void tick(void) {
    flushDiagnostic();
    if(!installationRoot || !hooksAttempted.load())return;
    const uint64_t now=nowNs();
    if(connection.fd<0) {
        if(now-lastAttempt<500*NSEC_PER_MSEC)return;
        lastAttempt=now;if(!endpointTrusted())return;
        sockaddr_un destination{};if(!address(endpoint.fileSystemRepresentation,destination))return;
        int fd=socket(AF_UNIX,SOCK_STREAM,0);
        if(fd<0)return;
        if(!configureSocket(fd)){close(fd);return;}
        const int result=connect(fd,(sockaddr *)&destination,sizeof(destination));
        if(result && errno!=EINPROGRESS){close(fd);return;}
        connection.fd=fd;connecting=true;lastSeen=now;welcomed=false;incoming={};outgoing=0;++connectionEpoch;
        diagnose(Diagnostic::Connecting);
        dispatch_source_set_timer(transportTimer,DISPATCH_TIME_NOW,4*NSEC_PER_MSEC,NSEC_PER_MSEC);
    }
    if(connecting) {
        int code=0;socklen_t length=sizeof(code);
        if(getsockopt(connection.fd,SOL_SOCKET,SO_ERROR,&code,&length) || code){diagnose(Diagnostic::TransportLost,1);disconnect();return;}
        const std::string expected=[[installationRoot stringByAppendingPathComponent:@"Applications/SkyTouch.app/SystemMapping.bundle/SkyTouchMapping"] fileSystemRepresentation];
        PeerFailure failure=PeerFailure::None;
        if(!peerIs(connection.fd,0,expected,&failure)){diagnose(Diagnostic::PeerRejected,(uint8_t)failure);disconnect();return;}
        connecting=false;
        diagnose(Diagnostic::Handshaking);
    }
    if(!connection.read([](const Packet &packet){return receive(packet);}) || !connection.flush()) {diagnose(Diagnostic::TransportLost,2);disconnect();return;}
    if(nowNs()-lastSeen>staleNs){diagnose(Diagnostic::TransportLost,3);disconnect();return;}
}
}

__attribute__((constructor)) static void OPInitializePhoneButtonCapture(void) {
    @autoreleasepool {
        if(![NSBundle.mainBundle.bundleIdentifier isEqual:@"com.apple.springboard"] || geteuid()!=501)return;
        // Resolve files off main. Hook installation itself is serialized on main.
        transportQueue=dispatch_queue_create("com.lixinmo.skytouch.phone-buttons.bridge",DISPATCH_QUEUE_SERIAL);
        dispatch_async(transportQueue,^{@autoreleasepool {
            if(notify_register_check(diagnosticNotification,&diagnosticToken)!=NOTIFY_STATUS_OK)diagnosticToken=-1;
            if(notify_register_check(suppressionNotification,&suppressionToken)!=NOTIFY_STATUS_OK)suppressionToken=-1;
            flushDiagnostic();
            transportTimer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,transportQueue);
            dispatch_source_set_timer(transportTimer,DISPATCH_TIME_NOW,500*NSEC_PER_MSEC,50*NSEC_PER_MSEC);
            dispatch_source_set_event_handler(transportTimer,^{@autoreleasepool {tick();}});
            dispatch_resume(transportTimer);
            installationRoot=resolveInstallation();if(!installationRoot)return;
            dispatch_async(dispatch_get_main_queue(),^{
                prepareHooks(0);
                int token=-1,ordinaryToken=-1;
                notify_register_dispatch("com.lixinmo.skytouch.buttons.maintenance",&token,dispatch_get_main_queue(),^(__unused int value){
                    maintenance=true;revoke();publish();diagnose(Diagnostic::Maintenance);
                });
                notify_register_dispatch("com.lixinmo.skytouch.runtime.maintenance-stop",&ordinaryToken,dispatch_get_main_queue(),^(__unused int value){
                    revoke();publish();dispatch_async(transportQueue,^{disconnect();});
                });
            });
        }});
    }
}
