#import "OPStoragePaths.h"
#import "OPOriginalBridge.h"
#include "OPTouchAdapter.hpp"
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach/mach_time.h>
#import <CoreBluetooth/CoreBluetooth.h>
#include <algorithm>
#include <cstring>
#include <cstdlib>
#include <atomic>
#include <unistd.h>
#include <sys/stat.h>
#include <cerrno>

namespace {
using VoidMethod=void (*)(id,SEL);
using PointMethod=void (*)(id,SEL,int,float,float);
using EndMethod=void (*)(id,SEL,int);
using ObjectMethod=id (*)(id,SEL);
using BLEValueMethod=void (*)(id,SEL,id,id,id);
using ProcessDataMethod=void (*)(id,SEL,char *);
static PointMethod originalBegin=nullptr, originalMove=nullptr;
static EndMethod originalEnd=nullptr;
static VoidMethod originalClear=nullptr;
static VoidMethod originalExecute=nullptr, originalReload=nullptr;
static std::atomic<std::uint64_t> originalExecuteCalls{0};
static BLEValueMethod originalBLEValue=nullptr;
static ProcessDataMethod originalProcessData=nullptr;
static BOOL bleValueCounterInstalled=NO,processDataCounterInstalled=NO;
static std::atomic<std::uint64_t> bleValueCalls{0},bleValueErrors{0},bleValueReturns{0},bleWhileNotifying{0},processDataCalls{0};
static std::atomic<std::uint64_t> beginCalls{0},beginReturns{0},beginTouchesCreated{0},beginTouchesRejected{0};
static std::atomic<std::uint64_t> moveCalls{0},endCalls{0},clearCalls{0},flushCalls{0},flushSuppressed{0},flushNonLandscape{0};
static std::atomic<std::uint64_t> emptyFrames{0},preparedFrames{0},submittedFrames{0},rejectedFrames{0};
static OPSubmitOriginalFrame submitFrame;
static dispatch_block_t cancelOutput;
static originalport::TouchAdapter adapter;
static UIInterfaceOrientation targetOrientation=UIInterfaceOrientationUnknown;
static id controller;
static BOOL installed=NO, flushing=NO;
static BOOL automaticCloudDisabled=NO;
static NSUInteger physicalMirrorDepth=0;
static std::uint64_t generation=0;
static NSString *bridgeStatus=@"原库桥接尚未安装";
static NSString *lastCancelReason=@"", *lastCancelCategory=@"";
static NSMutableDictionary<NSString *,NSNumber *> *cancelReasonCounts;
static std::uint64_t bridgeCancelCount=0;

// Last few contact boundaries only: no BLE payloads and no per-move log.
// The two clocks separate queued-main-thread delay from output flush delay.
struct BoundaryTrace {
    static constexpr std::size_t capacity=64;
    struct Entry {
        std::uint64_t sequence=0, generation=0, observedNs=0, handledNs=0, flush=0;
        int slot=-1; float x=0,y=0; bool began=false,accepted=false;
    };
    std::array<Entry,capacity> entries{};
    std::size_t next=0,count=0;
    std::uint64_t total=0;
    void append(int slot,bool began,float x,float y,std::uint64_t observed,std::uint64_t handled,
                std::uint64_t eventGeneration,std::uint64_t flush,bool accepted) {
        entries[next]={++total,eventGeneration,observed,handled,flush,slot,x,y,began,accepted};
        next=(next+1)%capacity;if(count<capacity)++count;
    }
    NSArray *snapshot(void) const {
        NSMutableArray *result=[NSMutableArray arrayWithCapacity:count];
        for(std::size_t i=0;i<count;++i) {
            const auto &entry=entries[(next+capacity-count+i)%capacity];
            NSMutableDictionary *value=[@{@"sequence":@(entry.sequence),@"generation":@(entry.generation),
                @"observedNs":@(entry.observedNs),@"handledNs":@(entry.handledNs),@"flush":@(entry.flush),
                @"slot":@(entry.slot),@"phase":entry.began ? @"begin" : @"end",@"accepted":@(entry.accepted)} mutableCopy];
            if(entry.began) {
                value[@"x"]=std::isfinite(entry.x) ? (id)@(entry.x) : (id)@"nonfinite";
                value[@"y"]=std::isfinite(entry.y) ? (id)@(entry.y) : (id)@"nonfinite";
            }
            [result addObject:value];
        }
        return result;
    }
};
static BoundaryTrace sourceBoundaries,submittedBoundaries;
static std::array<bool,originalport::TouchAdapter::slotCount> sourceContactActive{};

static NSDictionary *configurationState(void);

static BOOL landscape() { return UIInterfaceOrientationIsLandscape(targetOrientation); }
static std::uint64_t nowNs() {
    static mach_timebase_info_data_t scale;
    static dispatch_once_t once;
    dispatch_once(&once,^{ mach_timebase_info(&scale); });
    return static_cast<std::uint64_t>((long double)mach_absolute_time()*scale.numer/scale.denom);
}
static id object(id target, NSString *name) {
    SEL selector=NSSelectorFromString(name);
    return target && [target respondsToSelector:selector] ? ((ObjectMethod)objc_msgSend)(target,selector) : nil;
}
static void invoke(id target, NSString *name) {
    SEL selector=NSSelectorFromString(name);
    if (target && [target respondsToSelector:selector]) ((VoidMethod)objc_msgSend)(target,selector);
}
static void cancel(NSString *reason,NSString *category) {
    ++bridgeCancelCount;lastCancelReason=[reason copy];lastCancelCategory=[category copy];
    if(!cancelReasonCounts)cancelReasonCounts=[NSMutableDictionary dictionary];
    cancelReasonCounts[category]=@([cancelReasonCounts[category] unsignedLongLongValue]+1);
    ++generation; adapter.clear(); sourceContactActive={}; bridgeStatus=[reason copy];
    if (cancelOutput) cancelOutput();
}
static void caught(NSException *exception) {
    cancel([NSString stringWithFormat:@"原触屏接口失败：%@",exception.reason ?: exception.name],@"original-exception");
    NSLog(@"[OriginalPort] %@",bridgeStatus);
    NSLog(@"[OriginalPort] exception stack: %@",exception.callStackSymbols);
}
static void noTouchSwizzle(id,SEL) {}
static void noAutomaticCloudLoad(id,SEL) {}
static void beginObserved(id self,SEL command,int slot,float x,float y,std::uint64_t observedNs) {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(),^{ beginObserved(self,command,slot,x,y,observedNs); }); return; }
    const auto eventGeneration=generation;
    ++beginCalls;
    @try {
        NSString *key=[NSString stringWithFormat:@"%d",slot];
        id previousCollection=object(self,@"touchPoints");
        id previousTouch=[previousCollection isKindOfClass:NSDictionary.class] ? previousCollection[key] : nil;
        originalBegin(self,command,slot,x,y);
        ++beginReturns;
        controller=self;
        // Preserve the original UITouch creation result. If UIKit rejected its
        // object, do not manufacture a touch the original did not create.
        id touches=object(self,@"touchPoints");
        id touch=[touches isKindOfClass:NSDictionary.class] ? touches[key] : nil;
        const BOOL created=[touch isKindOfClass:UITouch.class] && touch!=previousTouch;
        if(created)++beginTouchesCreated;else ++beginTouchesRejected;
        const BOOL queued=landscape() && created && adapter.begin(slot,x,y);
        sourceBoundaries.append(slot,true,x,y,observedNs,nowNs(),eventGeneration,flushCalls.load(),queued);
        if(slot>=0 && slot<(int)sourceContactActive.size())sourceContactActive[slot]=queued;
        if (landscape()) {
            if (!created)
                cancel(@"原 UIKit 触点对象未成功创建，未模拟额外触点",@"touch-create");
            else if (!queued) cancel(@"原触点槽位、坐标无效或输出队列已满，已停止系统触摸",@"adapter-begin");
        }
    } @catch (NSException *exception) { caught(exception); }
}
static void begin(id self,SEL command,int slot,float x,float y) {
    beginObserved(self,command,slot,x,y,nowNs());
}
static void move(id self,SEL command,int slot,float x,float y) {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(),^{ move(self,command,slot,x,y); }); return; }
    ++moveCalls;
    @try {
        originalMove(self,command,slot,x,y);
        if (landscape() && !adapter.move(slot,x,y)) cancel(@"原触点槽位、坐标无效或输出队列已满，已停止系统触摸",@"adapter-move");
    } @catch (NSException *exception) { caught(exception); }
}
static void endObserved(id self,SEL command,int slot,std::uint64_t observedNs) {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(),^{ endObserved(self,command,slot,observedNs); }); return; }
    const auto eventGeneration=generation;
    const BOOL hadContact=slot>=0 && slot<(int)sourceContactActive.size() && sourceContactActive[slot];
    ++endCalls;
    @try {
        originalEnd(self,command,slot);
        const BOOL accepted=adapter.end(slot);
        // Legacy processData emits no-op End for every unused slot/report.
        // Keep those out of the bounded trace so one macro stays inspectable.
        if(hadContact)sourceBoundaries.append(slot,false,0,0,observedNs,nowNs(),eventGeneration,flushCalls.load(),accepted);
        if(slot>=0 && slot<(int)sourceContactActive.size())sourceContactActive[slot]=false;
        if (!accepted) cancel(@"原触点槽位无效或输出队列已满，已停止系统触摸",@"adapter-end");
    } @catch (NSException *exception) { caught(exception); }
}
static void end(id self,SEL command,int slot) {
    endObserved(self,command,slot,nowNs());
}
static void clear(id self,SEL command) {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(),^{ clear(self,command); }); return; }
    ++clearCalls;
    cancel(@"原引擎已清空触点，系统触摸已取消",@"vendor-clear");
    @try { originalClear(self,command); } @catch (NSException *exception) { caught(exception); }
}
static void execute(id self,SEL command) {
    originalExecuteCalls.fetch_add(1,std::memory_order_relaxed);
    // Count only. The vendor IMP still flushes first, removes ended touches,
    // and advances Began phases itself; no alternate timer or phase handling.
    originalExecute(self,command);
}
static id mainWindow(id self,SEL) {
    Class originalWindow=NSClassFromString(@"FZUIWindow");
    // The original fallback enumerates host windows and only accepts the
    // literal class name UIWindow. Use its real FZUIWindow directly instead;
    // calling that fallback first can fail in a daemon UIKit environment.
    UIViewController *owner=[self isKindOfClass:UIViewController.class] ? self : nil;
    id candidate=owner.isViewLoaded ? owner.view.window : nil;
    if ([candidate isKindOfClass:originalWindow]) return candidate;
    id manager=object(NSClassFromString(@"FLEXManager"),@"sharedManager");
    candidate=object(manager,@"explorerWindow");
    return [candidate isKindOfClass:originalWindow] ? candidate : nil;
}
static void flush(id self,SEL) {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(),^{ flush(self,nullptr); }); return; }
    ++flushCalls;
    if (flushing || physicalMirrorDepth) { ++flushSuppressed;return; }
    if (!landscape()) { ++flushNonLandscape;if (adapter.hasOutput()) cancel(@"等待横屏目标画面",@"non-landscape"); return; }
    controller=self;
    // Detect removal performed by original UIKit bookkeeping in addition to
    // clearTouchList. Never let a missing source slot remain pressed globally.
    id touches=object(self,@"touchPoints");
    if (![touches isKindOfClass:NSDictionary.class]) { cancel(@"原触点集合不可用",@"source-collection"); return; }
    std::array<fsm::TouchPhase,originalport::TouchAdapter::slotCount> sourcePhases;
    sourcePhases.fill(fsm::TouchPhase::Ended);
    for (int slot=0;slot<(int)originalport::TouchAdapter::slotCount;++slot) {
        UITouch *touch=touches[[NSString stringWithFormat:@"%d",slot]];
        if (!touch) {
            if (!adapter.end(slot)) { cancel(@"原触点输出队列已满，已取消未提交触点",@"source-reconcile"); return; }
            continue;
        }
        if (![touch isKindOfClass:UITouch.class]) { cancel(@"原触点集合包含无效对象",@"source-object"); return; }
        switch (touch.phase) {
            case UITouchPhaseBegan: sourcePhases[slot]=fsm::TouchPhase::Began; break;
            case UITouchPhaseMoved: sourcePhases[slot]=fsm::TouchPhase::Moved; break;
            case UITouchPhaseStationary: sourcePhases[slot]=fsm::TouchPhase::Stationary; break;
            case UITouchPhaseEnded: sourcePhases[slot]=fsm::TouchPhase::Ended; break;
            case UITouchPhaseCancelled: sourcePhases[slot]=fsm::TouchPhase::Cancelled; break;
            default: cancel(@"原触点阶段不受支持，系统触摸已取消",@"source-phase"); return;
        }
        if ((sourcePhases[slot]==fsm::TouchPhase::Ended || sourcePhases[slot]==fsm::TouchPhase::Cancelled) &&
            !adapter.end(slot,sourcePhases[slot])) { cancel(@"原触点输出队列已满，已取消未提交触点",@"source-reconcile"); return; }
    }
    const CGRect bounds=UIScreen.mainScreen.bounds;
    const auto submittingGeneration=generation;
    flushing=YES;
    // Keep the vendor's sendTouchEvent as the only flush trigger, but drain
    // every observed lifecycle boundary in order. A report batch or a delayed
    // macro tick must not turn Begin/End into only its latest mutable phase.
    do {
        fsm::TouchFrame frame;
        if (!adapter.prepare((float)std::max(bounds.size.width,bounds.size.height),
                             (float)std::min(bounds.size.width,bounds.size.height),nowNs(),frame,&sourcePhases)) {
            cancel(@"原触点坐标非有限值、屏幕尺寸或队列无效，系统触摸已取消",@"adapter-prepare"); break;
        }
        if (!frame.count) { ++emptyFrames; break; }
        ++preparedFrames;
        BOOL sent=NO;
        @try { sent=submitFrame && submitFrame(frame,targetOrientation); }
        @catch (NSException *exception) { caught(exception); }
        const auto submittedNs=nowNs();
        for(const auto &touch:frame) {
            if(touch.phase==fsm::TouchPhase::Began || touch.phase==fsm::TouchPhase::Ended || touch.phase==fsm::TouchPhase::Cancelled)
                submittedBoundaries.append((int)touch.id-1,touch.phase==fsm::TouchPhase::Began,touch.x,touch.y,
                    frame.timestampNs,submittedNs,submittingGeneration,flushCalls.load(),sent);
        }
        if (generation!=submittingGeneration) break;
        if (!sent) { ++rejectedFrames;cancel(@"系统触点提交失败，已取消；松开后重新按键",@"submit-failed"); break; }
        ++submittedFrames;
        adapter.acknowledge(frame);
        bridgeStatus=@"原引擎触点已提交系统通道；送达需以实际画面为准";
    } while (adapter.hasPending());
    flushing=NO;
}
static BOOL matches(const char *type,char expected) {
    if (!type) return NO;
    while (*type && std::strchr("rnNoORV",*type)) ++type;
    if (*type!=expected) return NO;
    return expected=='@' ? (type[1]=='\0' || type[1]=='"') : type[1]=='\0';
}
static BOOL signature(Class klass,BOOL classMethod,NSString *name,char result,const char *arguments,NSString **error) {
    Method method=classMethod ? class_getClassMethod(klass,NSSelectorFromString(name)) : class_getInstanceMethod(klass,NSSelectorFromString(name));
    BOOL good=method && method_getNumberOfArguments(method)==2+std::strlen(arguments);
    if (good) {
        char *type=method_copyReturnType(method); good=matches(type,result); std::free(type);
        for (unsigned i=0;good && i<method_getNumberOfArguments(method);++i) {
            type=method_copyArgumentType(method,i);
            good=matches(type,i==0 ? '@' : i==1 ? ':' : arguments[i-2]); std::free(type);
        }
    }
    if (!good && error) *error=[NSString stringWithFormat:@"原库接口 ABI 不符：%@[%@ %@]，拒绝安装桥接",classMethod ? @"+" : @"-",NSStringFromClass(klass) ?: @"(missing class)",name];
    return good;
}
static IMP replace(Class klass,NSString *name,IMP implementation) {
    return method_setImplementation(class_getInstanceMethod(klass,NSSelectorFromString(name)),implementation);
}
static void bleValue(id self,SEL command,id peripheral,id characteristic,id error) {
    ++bleValueCalls;if(error)++bleValueErrors;
    // Read only notification state, never characteristic.value/UUID/name.
    if(signature(object_getClass(characteristic),NO,@"isNotifying",'B',"",nullptr) ||
        signature(object_getClass(characteristic),NO,@"isNotifying",'c',"",nullptr)) {
        if(!error && ((BOOL(*)(id,SEL))objc_msgSend)(characteristic,NSSelectorFromString(@"isNotifying"))) {
            ++bleWhileNotifying;
        }
    }
    originalBLEValue(self,command,peripheral,characteristic,error);
    ++bleValueReturns;
}
static void processData(id self,SEL command,char *data) {
    ++processDataCalls;
    // Preserve the original byte-pointer ABI, without dereferencing/logging it.
    originalProcessData(self,command,data);
}
} // namespace

BOOL OPInstallOriginalBridge(OPSubmitOriginalFrame submit,dispatch_block_t cancelBlock,NSString **error) {
    if (error) *error=nil;
    if (![NSThread isMainThread] || !submit || !cancelBlock) {
        if (error) *error=@"桥接必须在主线程安装，并提供系统发送与取消接口"; return NO;
    }
    if (installed) { if (error) *error=@"原库桥接已安装，不能在运行中替换回调"; return NO; }
    Class cls=NSClassFromString(@"FZCentralViewController"), managerClass=NSClassFromString(@"FLEXManager");
    if (!cls || !managerClass || !NSClassFromString(@"FZUIWindow")) {
        if (error) *error=@"原库必需的 UI 类未加载"; return NO;
    }
    for (NSString *name in @[@"swizzleSendEvent",@"registerTouchNotification",@"sendTouchEvent",@"onExecuteTouchEvent",@"clearTouchList",@"checkOrientation",@"hideFloatingWindow",@"reloadCurrentFDG"])
        if (!signature(cls,NO,name,'v',"",error)) return NO;
    if (!signature(cls,NO,@"onTouchNotification:",'v',"@",error)) return NO;
    for (NSString *name in @[@"getMainWindow",@"touchPoints"])
        if (!signature(cls,NO,name,'@',"",error)) return NO;
    for (NSString *name in @[@"onTouchBegin:param_x:parma_y:",@"onTouchMove:param_x:parma_y:"])
        if (!signature(cls,NO,name,'v',"iff",error)) return NO;
    if (!signature(cls,NO,@"onTouchEnd:",'v',"i",error) || !signature(managerClass,YES,@"sharedManager",'@',"",error)) return NO;
    for (NSString *name in @[@"fzVC",@"explorerWindow"])
        if (!signature(managerClass,NO,name,'@',"",error)) return NO;
    for (NSString *name in @[@"showExplorer",@"doScanBluetooth"])
        if (!signature(managerClass,NO,name,'v',"",error)) return NO;
    @try {
        id manager=object(managerClass,@"sharedManager");
        if (object(manager,@"fzVC") || class_getInstanceMethod(UIApplication.class,NSSelectorFromString(@"sendEventOriginal:"))) {
            if (error) *error=@"原控制器或触摸 swizzle 已启动；请在新宿主进程中更早安装桥接"; return NO;
        }
    } @catch (NSException *exception) { if (error) *error=exception.reason; return NO; }
    // All selectors are checked before the first mutation. The execute counter
    // forwards to the original IMP, including its complete phase cleanup.
    submitFrame=[submit copy]; cancelOutput=[cancelBlock copy];
    originalReload=(VoidMethod)method_getImplementation(class_getInstanceMethod(cls,NSSelectorFromString(@"reloadCurrentFDG")));
    replace(cls,@"swizzleSendEvent",(IMP)noTouchSwizzle);
    // Keep the vendor listener: it also maintains physical-touch debug images.
    // Only our independent mirror carrier posts HOOK_SENDEVENT. The original
    // UIApplication swizzle remains disabled and cannot swallow real UI input.
    replace(cls,@"getMainWindow",(IMP)mainWindow);
    originalBegin=(PointMethod)replace(cls,@"onTouchBegin:param_x:parma_y:",(IMP)begin);
    originalMove=(PointMethod)replace(cls,@"onTouchMove:param_x:parma_y:",(IMP)move);
    originalEnd=(EndMethod)replace(cls,@"onTouchEnd:",(IMP)end);
    originalClear=(VoidMethod)replace(cls,@"clearTouchList",(IMP)clear);
    originalExecute=(VoidMethod)replace(cls,@"onExecuteTouchEvent",(IMP)execute);
    replace(cls,@"sendTouchEvent",(IMP)flush);
    // Optional observation hooks never substitute a parser or BLE behavior.
    // The pinned original has v40@0:8@16@24@32 and v24@0:8*16 respectively.
    if(signature(cls,NO,@"peripheral:didUpdateValueForCharacteristic:error:",'v',"@@@",nullptr)) {
        originalBLEValue=(BLEValueMethod)replace(cls,@"peripheral:didUpdateValueForCharacteristic:error:",(IMP)bleValue);
        bleValueCounterInstalled=originalBLEValue!=nullptr;
    }
    if(signature(cls,NO,@"processData:",'v',"*",nullptr)) {
        originalProcessData=(ProcessDataMethod)replace(cls,@"processData:",(IMP)processData);
        processDataCounterInstalled=originalProcessData!=nullptr;
    }
    installed=YES; bridgeStatus=@"原库输出桥接已安装，等待原界面与横屏目标";
    return YES;
}

void OPSetTargetOrientation(UIInterfaceOrientation orientation) {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(),^{ OPSetTargetOrientation(orientation); }); return; }
    if (orientation==targetOrientation) return;
    targetOrientation=orientation;
    cancel(@"目标方向已变化，旧触点已取消；松开后重新按键",@"orientation");
    if (controller) invoke(controller,@"checkOrientation");
}
BOOL OPStartOriginalUI(NSString **error) {
    if (error) *error=nil;
    if (![NSThread isMainThread] || !installed) { if (error) *error=@"请先在主线程安装原库桥接"; return NO; }
    @try {
        id manager=object(NSClassFromString(@"FLEXManager"),@"sharedManager");
        invoke(manager,@"showExplorer");
        controller=object(manager,@"fzVC");
        if (![controller isKindOfClass:NSClassFromString(@"FZCentralViewController")]) {
            if (error) *error=@"原界面没有创建 FZCentralViewController"; return NO;
        }
        invoke(controller,@"checkOrientation");
        invoke(manager,@"doScanBluetooth");
        return YES;
    } @catch (NSException *exception) { caught(exception); if (error) *error=bridgeStatus; return NO; }
}
BOOL OPReloadOriginalConfiguration(NSString **error) {
    if (error) *error=nil;
    if (![NSThread isMainThread] || !installed || !controller || !originalReload) {
        if (error) *error=@"原配置必须在主线程且原控制器创建后加载"; return NO;
    }
    Class cls=object_getClass(controller);
    if (![controller isKindOfClass:NSClassFromString(@"FZCentralViewController")]) {
        if (error) *error=@"当前对象不是原配置控制器，拒绝加载"; return NO;
    }
    if (!signature(cls,NO,@"reloadCurrentFDG",'v',"",error)) return NO;
    SEL selector=NSSelectorFromString(@"reloadCurrentFDG");
    if (method_getImplementation(class_getInstanceMethod(cls,selector))!=(IMP)originalReload) {
        if (error) *error=@"原配置加载实现已变化，拒绝调用未验证的方法"; return NO;
    }
    @try {
        if (![configurationState()[@"valid"] boolValue]) {
            if(error)*error=@"当前手柄类型没有已应用的有效映射方案";
            return NO;
        }
        originalReload(controller,selector);
        const BOOL valid=[configurationState()[@"valid"] boolValue];
        if(!valid && error)*error=@"原引擎加载后当前方案为空";
        return valid;
    } @catch (NSException *exception) {
        caught(exception); if (error) *error=bridgeStatus; return NO;
    }
}
namespace {
static NSDictionary *configurationState(void) {
    NSMutableDictionary *state=[@{@"available":@NO,@"valid":@NO,@"deviceType":@(-1),
        @"currentPlanName":@"",@"keyCount":@0,@"joystickCount":@0,@"macroCount":@0} mutableCopy];
    if(!NSThread.isMainThread)return state;
    Class prefsClass=NSClassFromString(@"FZPreferRecordTool");
    if(!signature(prefsClass,YES,@"sharedFZPreferRecordTool",'@',"",nullptr) ||
       !signature(prefsClass,NO,@"peripheralType",'i',"",nullptr) ||
       !signature(prefsClass,NO,@"getCurrentFDG",'@',"",nullptr))return state;
    @try {
        id prefs=object(prefsClass,@"sharedFZPreferRecordTool");
        int type=((int(*)(id,SEL))objc_msgSend)(prefs,NSSelectorFromString(@"peripheralType"));
        state[@"deviceType"]=@(type);
        if(!prefs || type<0 || type>2)return state;
        id entity=object(prefs,@"getCurrentFDG");
        if(!entity)return state;
        Class entityClass=object_getClass(entity);
        for(NSString *selector in @[@"title",@"keyList",@"jsList",@"macroList"])
            if(!signature(entityClass,NO,selector,'@',"",nullptr))return state;
        id title=object(entity,@"title"),keys=object(entity,@"keyList"),joysticks=object(entity,@"jsList"),macros=object(entity,@"macroList");
        if(title && ![title isKindOfClass:NSString.class])return state;
        for(id list in @[keys ?: NSNull.null,joysticks ?: NSNull.null,macros ?: NSNull.null])
            if(list!=NSNull.null && ![list isKindOfClass:NSArray.class])return state;
        state[@"available"]=@YES;state[@"currentPlanName"]=title ?: @"";
        state[@"keyCount"]=@([keys count]);state[@"joystickCount"]=@([joysticks count]);state[@"macroCount"]=@([macros count]);
        state[@"valid"]=@([keys count]>0 || [joysticks count]>0 || [macros count]>0);
    } @catch(__unused NSException *exception) { state[@"available"]=@NO;state[@"valid"]=@NO; }
    return state;
}
}
NSDictionary *OPOriginalCurrentConfigurationState(void) { return configurationState(); }
BOOL OPDisableOriginalAutomaticCloudLoading(NSString **error) {
    if(error)*error=nil;
    Class cls=NSClassFromString(@"FZCentralViewController");
    if(!NSThread.isMainThread || !signature(cls,NO,@"loadYunCFG",'v',"",error)) {
        if(error && !*error)*error=@"自动云加载隔离必须在主线程安装";return NO;
    }
    Method method=class_getInstanceMethod(cls,NSSelectorFromString(@"loadYunCFG"));
    if(automaticCloudDisabled) {
        if(method_getImplementation(method)==(IMP)noAutomaticCloudLoad)return YES;
        if(error)*error=@"自动云加载隔离已被替换";return NO;
    }
    if(controller || object(object(NSClassFromString(@"FLEXManager"),@"sharedManager"),@"fzVC")) {
        if(error)*error=@"自动云加载隔离必须在原控制器创建前安装";return NO;
    }
    // The original viewDidLoad schedules loadYunCFG after one second and the
    // latter retries itself. Its successful response imports cloud.fdg into
    // cacheLocalCFG. Neither engine nor editor startup should silently import
    // another cloud snapshot. Explicit cloud-list/download controls use their
    // own callbacks and remain untouched, as do all mapping algorithms/timers.
    IMP previous=method_setImplementation(method,(IMP)noAutomaticCloudLoad);
    if(!previous || method_getImplementation(method)!=(IMP)noAutomaticCloudLoad) {
        if(previous)method_setImplementation(method,previous);
        if(error)*error=@"无法隔离原自动云加载";return NO;
    }
    automaticCloudDisabled=YES;return YES;
}
BOOL OPApplyOriginalConfigurationSnapshot(NSString *fdgPath,NSInteger deviceType,NSString **error) {
    if(error)*error=nil;
    if(!NSThread.isMainThread || !controller || !installed ||
       ![fdgPath isKindOfClass:NSString.class] || !fdgPath.isAbsolutePath || deviceType<0 || deviceType>2) {
        if(error)*error=@"全局方案快照参数或引擎状态无效";return NO;
    }
    Class ioClass=NSClassFromString(@"FZCFGIOCenter"),prefsClass=NSClassFromString(@"FZPreferRecordTool");
    if(!signature(ioClass,YES,@"sharedFZCFGIOCenter",'@',"",error) ||
       !signature(ioClass,NO,@"readFDGByPath:",'@',"@",error) ||
       !signature(ioClass,NO,@"setCacheLocalCFG:",'v',"@",error) ||
       !signature(prefsClass,YES,@"sharedFZPreferRecordTool",'@',"",error) ||
       !signature(prefsClass,NO,@"setPeripheralType:",'v',"i",error) ||
       !signature(object_getClass(controller),NO,@"peripheral",'@',"",error) ||
       !signature(object_getClass(controller),NO,@"applyEntity:",'v',"@",error) ||
       !signature(object_getClass(controller),NO,@"updatePeripheralType:",'v',"i",error))return NO;
    @try {
        id io=object(ioClass,@"sharedFZCFGIOCenter");
        id document=((id(*)(id,SEL,id))objc_msgSend)(io,NSSelectorFromString(@"readFDGByPath:"),fdgPath);
        if(!document){if(error)*error=@"原解析器无法读取全局方案快照";return NO;}
        OPStopOriginalTouches();
        ((void(*)(id,SEL,id))objc_msgSend)(io,NSSelectorFromString(@"setCacheLocalCFG:"),document);
        id prefs=object(prefsClass,@"sharedFZPreferRecordTool");
        if(object(controller,@"peripheral"))
            ((void(*)(id,SEL,int))objc_msgSend)(controller,NSSelectorFromString(@"updatePeripheralType:"),(int)deviceType);
        else ((void(*)(id,SEL,int))objc_msgSend)(prefs,NSSelectorFromString(@"setPeripheralType:"),(int)deviceType);
        if(![configurationState()[@"valid"] boolValue]) {
            if(error)*error=@"快照中当前手柄类型没有有效映射";return NO;
        }
        // Match the original onImportFinish path: applyEntity initializes the
        // C mapper, while reloadCurrentFDG also updates the newer fzMapping.
        // Calling only the latter leaves the legacy processData path stale.
        ((void(*)(id,SEL,id))objc_msgSend)(controller,NSSelectorFromString(@"applyEntity:"),object(prefs,@"getCurrentFDG"));
        return OPReloadOriginalConfiguration(error);
    } @catch(__unused NSException *exception) {
        if(error)*error=@"原引擎读取全局方案快照失败";return NO;
    }
}
BOOL OPApplyOriginalConfigurationSnapshotData(NSData *data,NSInteger deviceType,NSString **error) {
    if(error)*error=nil;
    if(![data isKindOfClass:NSData.class] || !data.length || data.length>16*1024*1024) {
        if(error)*error=@"全局方案快照数据无效";return NO;
    }
    NSString *templatePath=OPRuntimePath(@"skytouch-active-XXXXXX.fdg");
    if(!templatePath.length){if(error)*error=@"运行目录尚未准备好";return NO;}
    char *path=strdup(templatePath.fileSystemRepresentation);if(!path)return NO;int fd=mkstemps(path,4);
    if(fd<0){free(path);if(error)*error=@"无法创建原解析器的快照输入";return NO;}
    BOOL written=fchmod(fd,0600)==0;size_t offset=0;
    while(written && offset<data.length) {
        ssize_t count=write(fd,(const char *)data.bytes+offset,data.length-offset);
        if(count<0 && errno==EINTR)continue;
        if(count<=0){written=NO;break;}offset+=(size_t)count;
    }
    close(fd);BOOL applied=NO;
    if(written)applied=OPApplyOriginalConfigurationSnapshot(@(path),deviceType,error);
    else if(error)*error=@"无法写入原解析器的快照输入";
    unlink(path);free(path);return applied;
}
std::uint64_t OPOriginalExecuteTouchEventCount(void) {
    return originalExecuteCalls.load(std::memory_order_relaxed);
}
NSDictionary *OPOriginalBridgeDiagnostics(void) {
    const auto invalid=adapter.lastRejection();
    const auto outside=adapter.lastOutsideRange();
    auto scalar=[](float value)->id{return std::isfinite(value) ? @(value) : @"nonfinite";};
    return @{@"bleValueCounterInstalled":@(bleValueCounterInstalled),@"processDataCounterInstalled":@(processDataCounterInstalled),
        @"bleValueCalls":@(bleValueCalls.load()),@"bleValueErrors":@(bleValueErrors.load()),@"bleValueReturns":@(bleValueReturns.load()),
        @"bleValuesWhileNotifying":@(bleWhileNotifying.load()),@"processDataCalls":@(processDataCalls.load()),
        @"beginCalls":@(beginCalls.load()),@"beginReturns":@(beginReturns.load()),@"beginTouchesCreated":@(beginTouchesCreated.load()),
        @"beginTouchesRejected":@(beginTouchesRejected.load()),@"moveCalls":@(moveCalls.load()),@"endCalls":@(endCalls.load()),
        @"clearCalls":@(clearCalls.load()),@"executeCalls":@(originalExecuteCalls.load()),@"flushCalls":@(flushCalls.load()),
        @"flushSuppressed":@(flushSuppressed.load()),@"flushNonLandscape":@(flushNonLandscape.load()),
        @"emptyFrames":@(emptyFrames.load()),@"preparedFrames":@(preparedFrames.load()),
        @"pendingTouchFrames":@(adapter.pendingCount()),@"maximumPendingTouchFrames":@(adapter.maximumPendingCount()),
        @"bridgeCancelCount":@(bridgeCancelCount),@"lastCancelReason":lastCancelReason,@"lastCancelCategory":lastCancelCategory,
        @"cancelReasonCounts":cancelReasonCounts.copy ?: @{},@"originalSlotCapacity":@(originalport::TouchAdapter::slotCount),
        @"coordinateRejectCount":@(adapter.coordinateRejectCount()),@"slotRejectCount":@(adapter.slotRejectCount()),
        @"lastInvalidSlot":@(invalid.slot),@"lastInvalidHasCoordinates":@(invalid.coordinates),
        @"lastInvalidRawX":scalar(invalid.x),@"lastInvalidRawY":scalar(invalid.y),
        @"lastInvalidWidth":scalar(invalid.width),@"lastInvalidHeight":scalar(invalid.height),
        @"outsideRangeSampleCount":@(adapter.outsideRangeSampleCount()),@"lastOutsideSlot":@(outside.slot),
        @"lastOutsideRawX":scalar(outside.x),@"lastOutsideRawY":scalar(outside.y),
        @"lastOutsideWidth":scalar(outside.width),@"lastOutsideHeight":scalar(outside.height),
        @"touchQueueOverflowCount":@(adapter.overflowCount()),@"touchQueueCapacity":@(originalport::TouchAdapter::queueCapacity),
        @"boundaryTraceCapacity":@(BoundaryTrace::capacity),@"sourceBoundaryCount":@(sourceBoundaries.total),
        @"submittedBoundaryCount":@(submittedBoundaries.total),@"sourceBoundaryCoordinateUnit":@"landscape-points",
        @"submittedBoundaryCoordinateUnit":@"normalized-landscape",@"sourceBoundaries":sourceBoundaries.snapshot(),
        @"submittedBoundaries":submittedBoundaries.snapshot(),
        @"submittedFrames":@(submittedFrames.load()),@"rejectedFrames":@(rejectedFrames.load()),@"logicalOrientation":@(targetOrientation)};
}
id OPOriginalController(void) { return controller; }
void OPStopOriginalTouches(void) {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(),^{ OPStopOriginalTouches(); }); return; }
    if (controller && originalClear) clear(controller,NSSelectorFromString(@"clearTouchList"));
    else cancel(@"系统触摸已停止",@"explicit-stop");
}
NSString *OPOriginalBridgeStatus(void) { return bridgeStatus; }
BOOL OPPostOriginalPhysicalEvent(id event) {
    if (![NSThread isMainThread] || !installed || !controller || !event) return NO;
    ++physicalMirrorDepth;
    @try {
        [NSNotificationCenter.defaultCenter postNotificationName:@"HOOK_SENDEVENT"
            object:nil userInfo:@{@"HOOK_EVENT_DATA":event}];
        return YES;
    } @catch (NSException *exception) {
        caught(exception);
        return NO;
    } @finally {
        --physicalMirrorDepth;
    }
}
