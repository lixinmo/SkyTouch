#import "OPForegroundContext.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#include <cstring>
#include <cstdlib>
#include <cstdint>
#include <cstdio>
#include <mach/mach_time.h>

// Exact iOS-17 runtime declarations, independently checked before invocation:
// https://github.com/MTACS/iOS-17-Runtime-Headers/tree/main/PrivateFrameworks/FrontBoardServices.framework
// FBSDisplayLayoutMonitorConfiguration.configurationForDefaultMainDisplayMonitor
// FBSDisplayLayoutMonitor.monitorWithConfiguration:/currentLayout
// Modern transition callback ABI was verified from the target iOS 17.1
// framework wrapper and its block descriptor (validation/evidence/layout-block.json):
// void (^)(FBSDisplayLayoutMonitor *, FBSDisplayLayout *, FBSDisplayLayoutTransitionContext *).
// Do not use addObserver or the deprecated initializer on the immutable factory result.

namespace {
static id monitor;
static id systemService;
static NSString *lastError=@"display-layout monitor not started";
static NSTimeInterval lastCallbackUnix=0;
static NSUInteger callbackCount=0;
static NSUInteger sessionGeneration=0;
static void (^changeHandler)(NSDictionary *);
static void trace(const char *stage) {
    (void)stage;
}

static bool typeIs(const char *type,char expected) {
    if (!type) return false;
    while (*type && std::strchr("rnNoORV",*type)) ++type;
    if (expected=='k') return type[0]=='@' && type[1]=='?' && type[2]=='\0';
    if (expected=='b') return (*type=='B' || *type=='c') && type[1]=='\0';
    if (*type!=expected) return false;
    return expected=='@' ? (type[1]=='\0' || type[1]=='"') : type[1]=='\0';
}
static bool compatible(id object,NSString *name,char result,const char *arguments) {
    if (!object) return false;
    Method method=class_getInstanceMethod(object_getClass(object),NSSelectorFromString(name));
    if (!method || method_getNumberOfArguments(method)!=2+std::strlen(arguments)) return false;
    char *type=method_copyReturnType(method); bool valid=typeIs(type,result); std::free(type);
    for (unsigned i=0;valid && i<method_getNumberOfArguments(method);++i) {
        type=method_copyArgumentType(method,i);
        valid=typeIs(type,i==0 ? '@' : i==1 ? ':' : arguments[i-2]); std::free(type);
    }
    return valid;
}
static id objectValue(id object,NSString *name) {
    return compatible(object,name,'@',"") ? ((id(*)(id,SEL))objc_msgSend)(object,NSSelectorFromString(name)) : nil;
}
static NSNumber *boolValue(id object,NSString *name) {
    if (!compatible(object,name,'b',"")) return nil;
    return @(((BOOL(*)(id,SEL))objc_msgSend)(object,NSSelectorFromString(name)));
}
static NSNumber *longValue(id object,NSString *name) {
    if (!compatible(object,name,'q',"")) return nil;
    return @(((long long(*)(id,SEL))objc_msgSend)(object,NSSelectorFromString(name)));
}
static void noArg(id object,NSString *name) {
    if (compatible(object,name,'v',"")) ((void(*)(id,SEL))objc_msgSend)(object,NSSelectorFromString(name));
}
static BOOL bundleValid(id value) {
    return [value isKindOfClass:NSString.class] && [value length]<=255 &&
        [value rangeOfString:@"^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$" options:NSRegularExpressionSearch].length==[value length] && [value length]>0;
}
static NSString *selectBundle(NSArray<NSDictionary *> *elements,NSNumber *locked,NSNumber *backlight,NSString **reason) {
    if (!locked) { *reason=@"lock state unavailable"; return nil; }
    if (locked.boolValue) { *reason=@"device locked or blocked"; return nil; }
    if (!backlight || backlight.longLongValue<=0) { *reason=@"display not confirmed lit"; return nil; }
    NSMutableSet *focusedApps=[NSMutableSet set];
    for (NSDictionary *item in elements) {
        if (![item[@"flagsKnown"] boolValue]) { *reason=@"layout element ABI incomplete"; return nil; }
        if ([item[@"transitioning"] boolValue]) { *reason=@"display layout transitioning"; return nil; }
        if (![item[@"application"] boolValue] || ![item[@"keyboardFocus"] boolValue]) continue;
        NSString *bundle=item[@"bundleIdentifier"];
        if (!bundleValid(bundle)) { *reason=@"application element has no valid bundle identifier"; return nil; }
        if ([bundle isEqualToString:@"com.apple.springboard"]) {
            *reason=@"SpringBoard has application focus"; return nil;
        }
        [focusedApps addObject:bundle];
    }
    // Device evidence: a focused Probe app has fillsDisplayBounds=NO and
    // isSpringBoardElement=YES. Neither property identifies app visibility or
    // the SpringBoard bundle; do not use them as rejection predicates.
    if (focusedApps.count==1) { *reason=@"unique focused UIApplication element"; return focusedApps.anyObject; }
    *reason=focusedApps.count ? @"ambiguous focused application elements" : @"no focused application";
    return nil;
}
} // namespace

void OPStopForegroundContext(void) {
    if (![NSThread isMainThread]) return;
    @try {
        trace("stop: monitor invalidate before");
        noArg(monitor,@"invalidate");
        trace("stop: monitor invalidate after");
    } @catch (__unused NSException *exception) {}
    ++sessionGeneration; monitor=nil; systemService=nil;
    lastCallbackUnix=0; callbackCount=0; lastError=@"display-layout monitor stopped";
}

BOOL OPStartForegroundContext(NSString **error) {
    if (error) *error=nil;
    if (![NSThread isMainThread]) { if (error) *error=@"foreground observer must start on main thread"; return NO; }
    if (monitor) return YES;
    trace("start: load frameworks");
    for (NSString *name in @[@"FrontBoardServices",@"SpringBoardServices"]) {
        NSString *path=[NSString stringWithFormat:@"/System/Library/PrivateFrameworks/%@.framework/%@",name,name];
        if (!dlopen(path.fileSystemRepresentation,RTLD_NOW|RTLD_GLOBAL)) {
            lastError=[@"framework unavailable: " stringByAppendingString:name]; if (error) *error=lastError; return NO;
        }
    }
    trace("start: validate factory ABI");
    Class configurationClass=NSClassFromString(@"FBSDisplayLayoutMonitorConfiguration");
    Class monitorClass=NSClassFromString(@"FBSDisplayLayoutMonitor");
    if (!compatible(configurationClass,@"configurationForDefaultMainDisplayMonitor",'@',"") ||
        !compatible(monitorClass,@"monitorWithConfiguration:",'@',"@")) {
        lastError=@"iOS-17 main-display monitor factory ABI unavailable"; if (error) *error=lastError; return NO;
    }
    @try {
        trace("start: main-display configuration factory before");
        id configuration=objectValue(configurationClass,@"configurationForDefaultMainDisplayMonitor");
        trace("start: main-display configuration factory after");
        if (!configuration) { lastError=@"main-display monitor configuration unavailable"; if (error) *error=lastError; return NO; }
        if (!compatible(configuration,@"setTransitionHandler:",'v',"k")) {
            lastError=@"modern transition-handler setter ABI unavailable"; if (error) *error=lastError; return NO;
        }
        const NSUInteger generation=++sessionGeneration;
        void (^transitionHandler)(id,id,id)=^(id source,id layout,id context) {
            (void)layout; (void)context;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation!=sessionGeneration || source!=monitor) return;
                lastCallbackUnix=NSDate.date.timeIntervalSince1970; ++callbackCount;
                if (changeHandler) changeHandler(OPForegroundContextSnapshot());
            });
        };
        trace("start: setTransitionHandler before");
        ((void(*)(id,SEL,id))objc_msgSend)(configuration,NSSelectorFromString(@"setTransitionHandler:"),transitionHandler);
        trace("start: setTransitionHandler after; monitor factory before");
        monitor=((id(*)(id,SEL,id))objc_msgSend)(monitorClass,NSSelectorFromString(@"monitorWithConfiguration:"),configuration);
        trace("start: monitor factory after");
        if (!compatible(monitor,@"currentLayout",'@',"") || !compatible(monitor,@"invalidate",'v',"")) {
            OPStopForegroundContext(); lastError=@"display-layout monitor read/invalidate ABI unavailable"; if (error) *error=lastError; return NO;
        }
        lastError=@"monitor created; waiting for actual display layout";
        return YES;
    } @catch (NSException *exception) {
        NSString *failure=exception.reason ?: exception.name;
        OPStopForegroundContext(); lastError=[@"display-layout observer failed: " stringByAppendingString:failure];
        if (error) *error=lastError; return NO;
    }
}

NSDictionary *OPForegroundContextSnapshot(void) {
    if (![NSThread isMainThread]) return @{@"available":@NO,@"valid":@NO,@"reason":@"foreground snapshot requires main thread"};
    static const mach_timebase_info_data_t scale=[] {mach_timebase_info_data_t value{};mach_timebase_info(&value);return value;}();
    const uint64_t readStarted=(uint64_t)(((__uint128_t)mach_continuous_time()*scale.numer)/scale.denom);
    NSMutableDictionary *result=[@{@"source":@"FBSDisplayLayoutMonitor",@"available":@(monitor!=nil),@"valid":@NO,
        @"readStartedMonotonicNs":@(readStarted),
        @"bundleIdentifier":@"",@"reason":lastError ?: @"",@"readAtUnix":@(NSDate.date.timeIntervalSince1970),
        @"lastCallbackUnix":@(lastCallbackUnix),@"callbackCount":@(callbackCount),@"acceptedOnDevice":@NO} mutableCopy];
    if (!monitor) return result;
    @try {
        trace("snapshot: system service factory before");
        if (!systemService) systemService=objectValue(NSClassFromString(@"FBSSystemService"),@"sharedService");
        trace("snapshot: system service factory after; lock query before");
        NSNumber *locked=boolValue(systemService,@"isPasscodeLockedOrBlocked");
        trace("snapshot: lock query after");
        result[@"lockKnown"]=@(locked!=nil); result[@"locked"]=locked ?: NSNull.null;
        trace("snapshot: currentLayout before");
        id layout=objectValue(monitor,@"currentLayout");
        trace("snapshot: currentLayout after");
        result[@"hasLayout"]=@(layout!=nil);
        if (!layout) { result[@"reason"]=@"layout server returned no current layout"; return result; }
        NSNumber *backlight=longValue(layout,@"displayBacklightLevel");
        result[@"backlightLevel"]=backlight ?: NSNull.null;
        result[@"orientation"]=longValue(layout,@"interfaceOrientation") ?: @0;
        id timestamp=objectValue(layout,@"timestamp");
        if ([timestamp isKindOfClass:NSDate.class]) result[@"layoutTimestampUnix"]=@([timestamp timeIntervalSince1970]);
        // timestamp is the last layout change, not a freshness heartbeat. Do
        // not reject a stable visible application merely because it is old.
        id rawElements=objectValue(layout,@"elements");
        trace("snapshot: elements after");
        if (![rawElements isKindOfClass:NSArray.class] || [rawElements count]>64) {
            result[@"reason"]=@"layout elements unavailable or oversized"; return result;
        }
        NSMutableArray *elements=[NSMutableArray array];
        for (id element in rawElements) {
            id bundle=objectValue(element,@"bundleIdentifier");
            NSNumber *app=boolValue(element,@"isUIApplicationElement"), *springboard=boolValue(element,@"isSpringBoardElement");
            NSNumber *fills=boolValue(element,@"fillsDisplayBounds"), *focus=boolValue(element,@"hasKeyboardFocus");
            [elements addObject:@{@"bundleIdentifier":bundleValid(bundle) ? bundle : @"",
                @"flagsKnown":@(app && focus),@"application":app ?: @NO,
                @"springboard":springboard ?: @NO,@"fillsDisplay":fills ?: @NO,@"keyboardFocus":focus ?: @NO,
                @"transitioning":boolValue(element,@"sb_isTransitioning") ?: @NO,
                @"layoutRole":longValue(element,@"layoutRole") ?: NSNull.null}];
        }
        NSString *reason=nil;
        NSString *bundle=selectBundle(elements,locked,backlight,&reason);
        result[@"elements"]=elements; result[@"reason"]=reason; result[@"valid"]=@(bundle!=nil);
        if (bundle) result[@"bundleIdentifier"]=bundle;
        return result;
    } @catch (NSException *exception) {
        result[@"reason"]=[@"layout query failed: " stringByAppendingString:exception.reason ?: exception.name];
        return result;
    }
}

NSString *OPForegroundBundleIdentifier(void) {
    NSDictionary *snapshot=OPForegroundContextSnapshot();
    return [snapshot[@"valid"] boolValue] ? snapshot[@"bundleIdentifier"] : nil;
}

BOOL OPGlobalOutputContextAllowed(NSDictionary *snapshot,NSString **reason) {
    auto reject=[&](NSString *message) { if (reason) *reason=message; return NO; };
    if (reason) *reason=nil;
    if (![snapshot isKindOfClass:NSDictionary.class] || ![snapshot[@"available"] boolValue] ||
        ![snapshot[@"hasLayout"] boolValue]) return reject(@"等待可读取的显示状态");
    if (![snapshot[@"lockKnown"] boolValue] || ![snapshot[@"locked"] isKindOfClass:NSNumber.class])
        return reject(@"锁屏状态未知，系统触屏暂停");
    if ([snapshot[@"locked"] boolValue]) return reject(@"屏幕已锁定，系统触屏暂停");
    if (![snapshot[@"backlightLevel"] isKindOfClass:NSNumber.class] || [snapshot[@"backlightLevel"] doubleValue]<=0)
        return reject(@"屏幕未点亮，系统触屏暂停");
    if (![snapshot[@"orientation"] isKindOfClass:NSNumber.class] ||
        [snapshot[@"orientation"] integerValue]<1 || [snapshot[@"orientation"] integerValue]>4)
        return reject(@"显示方向未知，系统触屏暂停");
    NSArray *elements=snapshot[@"elements"];
    if (![elements isKindOfClass:NSArray.class]) return reject(@"显示元素不可读取，系统触屏暂停");
    for (id item in elements) {
        if (![item isKindOfClass:NSDictionary.class]) return reject(@"显示元素不可读取，系统触屏暂停");
    }
    // Do not require a unique focused application. SpringBoard has no ordinary
    // app focus, and normal app transitions must keep the same global profile.
    // The launcher is an ordinary output surface. Actual editing is guarded
    // separately by the configuration session lease, never by app identity.
    return YES;
}

void OPSetForegroundContextChangeHandler(void (^handler)(NSDictionary *)) {
    if (![NSThread isMainThread]) return;
    changeHandler=[handler copy];
    if (changeHandler && monitor) changeHandler(OPForegroundContextSnapshot());
}
