#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import "../src/OPRuntimeControl.h"
#include "OPPhoneButtonTransport.hpp"
#include "OPPhoneButtonSession.h"
#include "OPPhoneButtonHookSetup.h"
#include <atomic>
#include <algorithm>
#include <memory>

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
static OPButtonHookTable buttonHooks{};
static void originalAction(OPButtonHookKind which,id object,SEL selector,id event) {
    ((ButtonIMP)buttonHooks.entries[which].original)(object,selector,event);
}
static bool originalPhysical(id object,SEL selector,id event) {
    return ((PhysicalIMP)buttonHooks.entries[OPPhysicalEvent].original)(object,selector,event);
}
static Ownership ownership;
struct ButtonPressSession {
    PressHistory history;
    NativeClaims claims;
};
// Main-thread only. Keep a monotonic token across discarded sessions because
// outstanding native action objects may still carry the preceding binding.
static std::unique_ptr<ButtonPressSession> buttonPresses;
static uint64_t lastPressToken=0;
static std::array<double,4> nativeThrough{};
static bool buttonCaptureEnabled=false;
static ButtonPressSession &pressSession(void) {
    if(!buttonPresses) {
        buttonPresses=std::make_unique<ButtonPressSession>();
        buttonPresses->history.sequence=lastPressToken;
        buttonPresses->history.nativeThrough=nativeThrough;
    }
    return *buttonPresses;
}
static std::atomic<uint32_t> blockedGestures{0},blockedNativeActions{0};
static std::atomic<uint64_t> armedUntil{0},connectionEpoch{0},latestCommand{0},latestLeaseSequence{0};
static std::atomic<bool> requestedArmed{false};
static std::atomic<uint32_t> capabilities{0};
static std::atomic<uint32_t> pendingMainCallbacks{0};
static uint64_t mainCommand=0,mainEpoch=0;
static std::atomic<bool> maintenance{false};
static std::atomic<bool> runtimeInvalid{false};
static std::atomic<bool> hooksAttempted{false};
static std::atomic<bool> hooksInstalled{false};
static std::atomic<uint32_t> diagnosticValue{(uint32_t)Diagnostic::Starting};
static int diagnosticToken=-1;
static int suppressionToken=-1,stopToken=-1;
static uint64_t lastDiagnosticWrite=0;
static uint32_t lastDiagnosticValue=UINT32_MAX;
static uint64_t lastSuppressionCounts=UINT64_MAX;
static NSString *installationRoot,*enabledGeneration;
static dispatch_queue_t transportQueue;
static dispatch_source_t transportTimer;
// The serial queue owns the session from enable through teardown.
static OPButtonSession *buttonSession=nullptr;
static uint64_t lastHookAttempt=0;
static unsigned hookAttempt=0;
static constexpr unsigned maxHookAttempts=31;
static bool hookCheckPending=false;
static void publish(void);
static void revoke(void) {armedUntil=0;ownership.setArmed(false);}
static void trimInactivePresses(void) {
    if(buttonCaptureEnabled || !buttonPresses)return;
    auto &history=buttonPresses->history;
    auto &claims=buttonPresses->claims;
    bool retained=false;
    for(size_t i=0;i<history.records.size();++i) {
        auto &records=history.records[i];
        auto &pending=claims.pending[i];
        // A completed owned press can still receive a delayed gesture. Keep
        // its original bounded timestamp history, including newer native
        // records which take precedence at overlapping interval boundaries.
        if(history.active[i] || !pending.empty() ||
           std::any_of(records.begin(),records.end(),[](const PressRecord &r){return r.owned || !r.released;})) {
            retained=true;continue;
        }
        for(const auto &record:records)
            history.nativeThrough[i]=std::max(history.nativeThrough[i],record.up);
        std::vector<PressRecord>().swap(records);
        std::vector<NativeClaim>().swap(pending);
        history.next[i]=0;
    }
    if(!retained) {
        lastPressToken=history.sequence;
        nativeThrough=history.nativeThrough;
        buttonPresses.reset();
    }
}
static void enableButtonCaptureSession(void) {buttonCaptureEnabled=true;}
static void disableButtonCaptureSession(void) {
    buttonCaptureEnabled=false;
    revoke();
    trimInactivePresses();
}
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

static bool captureAllowed(void) {
    const uint64_t deadline=armedUntil.load();
    const bool allowed=buttonCaptureEnabled && !maintenance && requestedArmed.load() && mainEpoch==connectionEpoch.load() &&
        capabilities.load()==all && deadline && nowNs()<deadline;
    if(!allowed && ownership.armed)revoke();
    return allowed;
}
static void changed(const Ownership &before) {
    if(buttonCaptureEnabled && (before.physical!=ownership.physical || before.mapped!=ownership.mapped ||
       before.armed!=ownership.armed || before.waitingRelease!=ownership.waitingRelease))publish();
}
static void actionDown(id object,SEL selector,id event) {
    if(!NSThread.isMainThread){runtimeInvalid=true;capabilities=0;armedUntil=0;originalAction(OPActionDown,object,selector,event);return;}
    const Ownership before=ownership;
    const bool swallow=ownership.event(action,true,captureAllowed());changed(before);
    if(!swallow)originalAction(OPActionDown,object,selector,event);
}
static void actionUp(id object,SEL selector,id event) {
    if(!NSThread.isMainThread){runtimeInvalid=true;capabilities=0;armedUntil=0;originalAction(OPActionUp,object,selector,event);return;}
    const Ownership before=ownership;(void)captureAllowed();
    const bool swallow=ownership.event(action,false,false);changed(before);
    if(!swallow)originalAction(OPActionUp,object,selector,event);
}
static void actionLong(id object,SEL selector,id event) {
    if(!NSThread.isMainThread){runtimeInvalid=true;capabilities=0;armedUntil=0;originalAction(OPActionLong,object,selector,event);return;}
    const Ownership before=ownership;(void)captureAllowed();changed(before);
    if(!(ownership.owned&action))originalAction(OPActionLong,object,selector,event);
}
static uint32_t bitForPress(NSInteger type) {
    switch(type){case 102:return volumeUp;case 103:return volumeDown;case 104:return side;default:return 0;}
}
static OPInstalledButtonHook *nativeHook(SEL selector) {
    for(size_t i=OPButtonCoreHooks;i<std::size(buttonHooks.entries);++i)
        if(buttonHooks.entries[i].selector==selector)return &buttonHooks.entries[i];
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
    auto &presses=pressSession();
    const PressRecord record=presses.claims.begin(ownership,presses.history,bit,captureAllowed());
    if(presses.claims.overflow){runtimeInvalid=true;capabilities=0;revoke();}
    changed(before);bindActions(object,bit,record,true);return record.owned;
}
static void nativeGesture(id object,SEL selector,id recognizer) {
    OPInstalledButtonHook *hook=nativeHook(selector);if(!hook || !hook->original)return;
    if(!NSThread.isMainThread){runtimeInvalid=true;capabilities=0;armedUntil=0;((ButtonIMP)hook->original)(object,selector,recognizer);return;}
    PressRecord record{};
    Class pressClass=objc_getClass("SBPressGestureRecognizer");
    if([recognizer isKindOfClass:pressClass]) {
        const long long type=((long long(*)(id,SEL))objc_msgSend)(recognizer,sel_registerName("latestPressType"));
        const long long phase=((long long(*)(id,SEL))objc_msgSend)(recognizer,sel_registerName("latestPressPhase"));
        const double timestamp=((double(*)(id,SEL))objc_msgSend)(recognizer,sel_registerName("latestPressTimestamp"));
        if(bitForPress(type)==hook->bit && phase>=0 && phase<=4 && std::isfinite(timestamp) && timestamp>0) {
            if(hook->primary) {
                const Ownership before=ownership;const bool allowed=captureAllowed();
                auto &presses=pressSession();
                record=presses.claims.transition(ownership,presses.history,hook->bit,(int)phase,timestamp,allowed);
                changed(before);trimInactivePresses();
            } else if(buttonPresses) {
                record=buttonPresses->claims.completed(buttonPresses->history,hook->bit,timestamp);
            }
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
    OPInstalledButtonHook *hook=nativeHook(selector);if(!hook || !hook->original)return;
    if(NSThread.isMainThread && beginNativeAction(object,hook->bit)){++blockedNativeActions;return;}
    ((void(*)(id,SEL,long long))hook->original)(object,selector,modifiers);
}
static void sideDownAction(id object,SEL selector) {
    OPInstalledButtonHook *hook=nativeHook(selector);if(!hook || !hook->original)return;
    if(NSThread.isMainThread && beginNativeAction(object,hook->bit)){++blockedNativeActions;return;}
    ((void(*)(id,SEL))hook->original)(object,selector);
}
static void nativeAction(id object,SEL selector) {
    OPInstalledButtonHook *hook=nativeHook(selector);if(!hook || !hook->original)return;
    // Keep this action token after final-up. Deferred click callbacks still
    // belong to it; the next down/identified gesture replaces it, not a timer.
    if(NSThread.isMainThread) {
        const bool owned=actionOwned(object,hook->bit);
        if(buttonPresses && !nativeScope.known &&
           (selector==sel_registerName("volumeIncreasePressUp") || selector==sel_registerName("volumeDecreasePressUp") ||
            selector==sel_registerName("performInitialButtonUpActions"))) {
            const int index=PressHistory::index(hook->bit);
            NSDictionary *binding=index>=0 ? objc_getAssociatedObject(object,&actionBindingKeys[index]) : nil;
            const Ownership before=ownership;
            buttonPresses->claims.end(ownership,buttonPresses->history,hook->bit,[binding[@"token"] unsignedLongLongValue]);
            changed(before);trimInactivePresses();
        }
        if(owned){++blockedNativeActions;return;}
    }
    ((void(*)(id,SEL))hook->original)(object,selector);
}
static bool nativeBoolAction(id object,SEL selector) {
    OPInstalledButtonHook *hook=nativeHook(selector);if(!hook || !hook->original)return false;
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
    bool hasButton=false;
    for(id press in presses) {
        if(![press isKindOfClass:UIPress.class]){runtimeInvalid=true;capabilities=0;revoke();changed(before);return originalPhysical(object,selector,event);}
        if(bitForPress(((UIPress *)press).type))hasButton=true;
    }
    if(!hasButton){changed(before);return originalPhysical(object,selector,event);}
    Ownership next=ownership;
    auto &session=pressSession();
    ButtonPressSession nextPresses=session;
    NSMutableArray *consumed=[NSMutableArray arrayWithCapacity:presses.count];
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
        const PressRecord record=nextPresses.claims.transition(next,nextPresses.history,bit,(int)phase,timestamp,allowed);
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
    ownership=next;session=std::move(nextPresses);changed(before);trimInactivePresses();
    return consumed.count==presses.count && consumed.count ? true : originalPhysical(object,selector,nativeEvent);
}
static uint32_t activeCapabilities(void) {
    if(runtimeInvalid || maintenance || !hooksInstalled.load())return 0;
    uint32_t result=all;
    for(const auto &hook:buttonHooks.entries)
        if(hook.target && class_getMethodImplementation(hook.target,hook.selector)!=hook.replacement)result&=~hook.bit;
    return result;
}
static void prepareHooks(unsigned attempt) {
    const OPButtonHookReplacements replacements={{(IMP)actionDown,(IMP)actionUp,(IMP)actionLong,(IMP)physicalEvent,
        (IMP)nativeGesture,(IMP)volumeDownAction,(IMP)sideDownAction,(IMP)nativeAction,(IMP)nativeBoolAction}};
    uint8_t detail=0;
    const auto result=OPPrepareButtonHooks(&buttonHooks,&replacements,&detail);
    if(result==OPButtonWaitingForClasses) {
        if(attempt+1==maxHookAttempts)diagnose(Diagnostic::ABIMismatch,255);
        else diagnose(Diagnostic::WaitingClasses);
        return;
    }
    hooksInstalled=result==OPButtonHooksReady;
    capabilities=activeCapabilities();
    diagnose(result==OPButtonWrongABI ? Diagnostic::ABIMismatch :
             hooksInstalled.load() ? Diagnostic::WaitingEndpoint : Diagnostic::HookConflict,detail);
    hooksAttempted=true;
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
    const char *leaf=root.lastPathComponent.UTF8String;
    const char prefix[]=".jbroot-";
    if(!leaf || strncmp(leaf,prefix,sizeof(prefix)-1)){diagnose(Diagnostic::ImagePathRejected,3);return nil;}
    const char *identifier=leaf+sizeof(prefix)-1;
    if(!*identifier || identifier[strspn(identifier,"0123456789abcdefABCDEF")]){
        diagnose(Diagnostic::ImagePathRejected,3);return nil;
    }
    NSString *library=[root stringByAppendingPathComponent:@"usr/lib/libroothide.dylib"];
    if(!regularRootFile(library.fileSystemRepresentation)){diagnose(Diagnostic::RootLibraryRejected,1);return nil;}
    void *handle=dlopen(library.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL);
    if(!handle){diagnose(Diagnostic::RootLibraryRejected,2);return nil;}
    using RootPath=const char *(*)(const char *);
    RootPath convert=(RootPath)dlsym(handle,"jbroot");
    const char *converted=convert ? convert("/") : nullptr;char convertedRoot[PATH_MAX]{};
    if(!converted || !realpath(converted,convertedRoot) || strcmp(root.fileSystemRepresentation,convertedRoot)) {
        dlclose(handle);diagnose(Diagnostic::RootMismatch,1);return nil;
    }
    NSString *expectedParent=[root stringByAppendingPathComponent:@"tmp"];
    const char *parent=convert("/tmp");char actualParent[PATH_MAX]{},trustedParent[PATH_MAX]{};
    const bool matches=parent && realpath(parent,actualParent) &&
        realpath(expectedParent.fileSystemRepresentation,trustedParent) && !strcmp(actualParent,trustedParent);
    dlclose(handle);
    if(!matches){diagnose(Diagnostic::RootMismatch,2);return nil;}
    return root;
}
static void connectionChanged(bool connected) {
    const uint64_t epoch=++connectionEpoch;
    armedUntil=0;requestedArmed=false;latestCommand=0;latestLeaseSequence=0;
    if(transportTimer) {
        const uint64_t interval=(connected ? 4 : 500)*NSEC_PER_MSEC;
        dispatch_source_set_timer(transportTimer,connected ? DISPATCH_TIME_NOW : dispatch_time(DISPATCH_TIME_NOW,interval),
                                  interval,(connected ? 1 : 50)*NSEC_PER_MSEC);
    }
    dispatch_async(dispatch_get_main_queue(),^{
        if(connectionEpoch.load()!=epoch)return;
        mainEpoch=epoch;mainCommand=0;disableButtonCaptureSession();
    });
}
static void sendPacket(Kind kind,uint64_t epoch,uint64_t command,uint32_t physical,uint32_t mapped,uint32_t flags,uint64_t timestamp) {
    if(!buttonSession || connectionEpoch.load()!=epoch)return;
    if(!OPSendButtonPacket(buttonSession,(uint16_t)kind,command,capabilities.load(),physical,mapped,flags,timestamp))
        OPDisconnectButtonSession(buttonSession);
}
static void publish(void) {
    if(!mainCommand || mainEpoch!=connectionEpoch.load())return;
    const uint64_t epoch=mainEpoch,commandValue=mainCommand,timestamp=nowNs();
    const uint32_t physical=ownership.physical,mapped=ownership.mapped;
    const uint32_t flags=(ownership.armed ? 1u : 0u)|(ownership.waitingRelease ? 2u : 0u);
    dispatch_async(transportQueue,^{
        sendPacket(Kind::State,epoch,commandValue,physical,mapped,flags,timestamp);
    });
}
static bool receiveWelcome(void) {
    if(pendingMainCallbacks.fetch_add(1)>=maximumPending){--pendingMainCallbacks;return false;}
    const uint64_t epoch=connectionEpoch.load();
    dispatch_async(dispatch_get_main_queue(),^{
        --pendingMainCallbacks;
        if(connectionEpoch.load()!=epoch)return;
        mainEpoch=epoch;mainCommand=0;revoke();enableButtonCaptureSession();
        capabilities=activeCapabilities();
        diagnose(capabilities.load()==all ? Diagnostic::Handshaking : Diagnostic::ABIMismatch);
        const uint32_t physical=ownership.physical;const uint64_t timestamp=nowNs();
        dispatch_async(transportQueue,^{sendPacket(Kind::Hello,epoch,0,physical,0,0,timestamp);});
    });
    return true;
}
static bool receiveLease(uint64_t command,uint64_t sequence,uint64_t deadline,bool armed) {
    latestCommand=command;latestLeaseSequence=sequence;requestedArmed=armed;
    if(pendingMainCallbacks.fetch_add(1)>=maximumPending){pendingMainCallbacks.fetch_sub(1);return false;}
    const uint64_t epoch=connectionEpoch.load();
    if(!armed)armedUntil=0;
    dispatch_async(dispatch_get_main_queue(),^{
        pendingMainCallbacks.fetch_sub(1);
        if(connectionEpoch.load()!=epoch || command!=latestCommand.load() || sequence!=latestLeaseSequence.load())return;
        mainEpoch=epoch;
        if(command<mainCommand){armedUntil=0;return;}
        capabilities=activeCapabilities();
        if(command!=mainCommand){ownership.setArmed(false);mainCommand=command;}
        const bool allow=armed && !maintenance && capabilities.load()==all && nowNs()<deadline;
        armedUntil=allow ? deadline : 0;ownership.setArmed(allow);publish();
        diagnose(maintenance ? Diagnostic::Maintenance : capabilities.load()!=all ?
            (hooksInstalled.load() ? Diagnostic::HookConflict : Diagnostic::ABIMismatch) :
            allow ? Diagnostic::Armed : Diagnostic::ReadyDisarmed);
    });
    return true;
}
static void tick(void) {
    flushDiagnostic();
    const uint64_t now=nowNs();
    if(hookCheckPending)return;
    if(!hooksAttempted.load() && hookAttempt<maxHookAttempts) {
        // Use the enabled transport timer for class discovery too. Turning
        // mapping off leaves no delayed retry on the SpringBoard main queue.
        if(now-lastHookAttempt<NSEC_PER_SEC)return;
        lastHookAttempt=now;
        hookCheckPending=true;
        const uint64_t epoch=connectionEpoch.load();
        const unsigned attempt=hookAttempt++;
        dispatch_async(dispatch_get_main_queue(),^{
            if(connectionEpoch.load()==epoch)prepareHooks(attempt);
            dispatch_async(transportQueue,^{hookCheckPending=false;});
        });
        return;
    }
    OPTickButtonSession(buttonSession,capabilities.load());
}
static bool openButtonSession(void) {
    const OPButtonSessionCallbacks callbacks={connectionChanged,[](uint8_t stage,uint8_t detail){
        diagnose((Diagnostic)stage,detail);
    },receiveWelcome,receiveLease};
    NSString *endpoint=[installationRoot stringByAppendingPathComponent:@"tmp/skytouch-buttons/s"];
    NSString *peer=[installationRoot stringByAppendingPathComponent:@"Applications/SkyTouch.app/SystemMapping.bundle/SkyTouchMapping"];
    buttonSession=OPCreateButtonSession(endpoint.fileSystemRepresentation,peer.fileSystemRepresentation,callbacks);
    return buttonSession!=nullptr;
}
static void closeButtonSession(void) {
    if(!buttonSession)return;
    dispatch_source_cancel(transportTimer);
    transportTimer=nil;
    if(stopToken>=0){notify_cancel(stopToken);stopToken=-1;}
    if(suppressionToken>=0){notify_cancel(suppressionToken);suppressionToken=-1;}
    connectionChanged(false);
    OPDestroyButtonSession(buttonSession);
    buttonSession=nullptr;
    enabledGeneration=nil;
}
// Subscribe before reading at startup. A coalesced off/on still has a new
// durable generation, so it retires every callback from the previous session.
static void refreshMappingIntent(void) {
    if(maintenance)return;
    NSDictionary *intent=OPMappingRuntimeIntentForInstallation(installationRoot);
    NSString *generation=[intent[@"enabled"] boolValue] ? intent[@"generation"] : nil;
    if(buttonSession && [enabledGeneration isEqualToString:generation])return;
    closeButtonSession();
    enabledGeneration=generation;
    if(!generation) {
        diagnose(Diagnostic::MappingDisabled);flushDiagnostic();return;
    }
    if(!openButtonSession()){diagnose(Diagnostic::SessionUnavailable);flushDiagnostic();return;}
    if(notify_register_check(suppressionNotification,&suppressionToken)==NOTIFY_STATUS_OK)
        lastSuppressionCounts=UINT64_MAX;
    else suppressionToken=-1;
    if(notify_register_dispatch("com.lixinmo.skytouch.runtime.maintenance-stop",&stopToken,transportQueue,^(int token){
        if(token==stopToken && buttonSession && enabledGeneration==generation)OPDisconnectButtonSession(buttonSession);
    })!=NOTIFY_STATUS_OK)stopToken=-1;
    lastHookAttempt=0;hookAttempt=0;
    diagnose(Diagnostic::WaitingEndpoint);
    transportTimer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,transportQueue);
    dispatch_source_set_event_handler(transportTimer,^{@autoreleasepool {
        if(enabledGeneration==generation)tick();
    }});
    dispatch_source_set_timer(transportTimer,DISPATCH_TIME_NOW,500*NSEC_PER_MSEC,50*NSEC_PER_MSEC);
    dispatch_resume(transportTimer);
}
}

__attribute__((constructor)) static void OPInitializePhoneButtonCapture(void) {
    @autoreleasepool {
        if(![NSBundle.mainBundle.bundleIdentifier isEqual:@"com.apple.springboard"] || geteuid()!=501)return;
        // Resolve files off main. Hook installation itself is serialized on main.
        transportQueue=dispatch_queue_create("com.lixinmo.skytouch.phone-buttons.bridge",DISPATCH_QUEUE_SERIAL);
        dispatch_async(transportQueue,^{@autoreleasepool {
            if(notify_register_check(diagnosticNotification,&diagnosticToken)!=NOTIFY_STATUS_OK)diagnosticToken=-1;
            flushDiagnostic();
            installationRoot=resolveInstallation();if(!installationRoot){flushDiagnostic();return;}
            int token=-1,intentToken=-1;
            notify_register_dispatch("com.lixinmo.skytouch.buttons.maintenance",&token,transportQueue,^(__unused int value){
                maintenance=true;closeButtonSession();diagnose(Diagnostic::Maintenance);flushDiagnostic();
            });
            // Subscribe before sampling to cover changes during SpringBoard startup.
            if(notify_register_dispatch(OPRuntimeIntentChangedNotification,&intentToken,transportQueue,^(__unused int value){
                @autoreleasepool {refreshMappingIntent();}
            })==NOTIFY_STATUS_OK)refreshMappingIntent();
        }});
    }
}
