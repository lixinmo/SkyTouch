#import "OPVirtualTouchService.h"
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <cstring>
#include <cstdlib>

// Apple's HIDVirtualEventService interface/implementation (copyright 2022),
// verified on this iOS 17.1 device by VirtualTouchServiceInspect. Keep the stable
// ObjC API rather than depending on the private C callback structure version.
// https://github.com/apple-oss-distributions/IOHIDFamily/blob/IOHIDFamily-1892.40.8/HID/HIDVirtualEventService.m
namespace {
bool methodABI(Class cls,NSString *name,const char *result,NSArray<NSString *> *arguments) {
    Method method=class_getInstanceMethod(cls,NSSelectorFromString(name));
    if(!method || method_getNumberOfArguments(method)!=arguments.count+2)return false;
    auto matches=[](const char *actual,const char *expected) {
        if(!actual || !expected)return false;
        while(*actual && std::strchr("rnNoORV",*actual))++actual;
        if(!std::strcmp(expected,"@"))return actual[0]=='@' && actual[1]!='?';
        return !std::strcmp(actual,expected);
    };
    char *type=method_copyReturnType(method);bool valid=matches(type,result);std::free(type);
    for(NSUInteger i=0;valid && i<arguments.count;++i) {
        type=method_copyArgumentType(method,(unsigned)i+2);
        valid=matches(type,arguments[i].UTF8String);std::free(type);
    }
    return valid;
}
Class nativeServiceClass(void) {
    static void *library=nullptr;
    if(!library) {
        for(NSString *path in @[@"/System/Library/Frameworks/HID.framework/HID",
                               @"/System/Library/PrivateFrameworks/HID.framework/HID"]) {
            library=dlopen(path.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL);
            if(library)break;
        }
    }
    // Do not dlclose a framework which can retain asynchronous service work.
    return library ? NSClassFromString(@"HIDVirtualEventService") : Nil;
}
bool serviceABI(Class cls) {
    if(!cls)return false;
    for(NSArray *item in @[@[@"init",@"@",@[]],@[@"setDelegate:",@"v",@[@"@"]],
        @[@"setDispatchQueue:",@"v",@[@"@"]],@[@"setCancelHandler:",@"v",@[@"@?"]],
        @[@"activate",@"v",@[]],@[@"cancel",@"v",@[]],
        @[@"serviceID",[NSString stringWithUTF8String:@encode(uint64_t)],@[]],
        @[@"dispatchEvent:",[NSString stringWithUTF8String:@encode(BOOL)],@[@"@"]]])
        if(!methodABI(cls,item[0],[item[1] UTF8String],item[2]))return false;
    return true;
}
enum class State { Idle,Starting,Ready,Cancelling,Cancelled,Failed };
}

@interface OPVirtualTouchService () {
    id _native;
    OPVirtualTouchService *_keepAlive;
    NSDictionary<NSString *,id> *_properties;
    State _state;
    uint64_t _serviceID;
    NSString *_status;
    BOOL _activationAttempted;
    BOOL _preserveFailureStatus;
    BOOL _terminated;
    BOOL _cancellationComplete;
    dispatch_queue_t _callbackQueue;
    NSMutableDictionary<NSString *,NSDictionary *> *_setPropertyRequests;
    uint64_t _setPropertyRejectedCount;
}
- (void)nativeCancellationFinished;
- (void)registrationTimedOut;
- (void)failAndCancel:(NSString *)reason;
@end

@implementation OPVirtualTouchService
- (instancetype)init {
    if((self=[super init])) {
        _state=State::Idle;_status=@"虚拟触屏服务尚未启动";
        _setPropertyRequests=[NSMutableDictionary dictionary];
        // Own virtual identity; no Apple vendor/authentication/panel sender.
        // iOS 17.1 BKHIDDirectTouchEventProcessor requires Built-In for the
        // main-display route with no displayUUID (verified 0x100043e84).
        _properties=@{@"PrimaryUsagePage":@13,@"PrimaryUsage":@4,
            @"DeviceUsagePairs":@[@{@"DeviceUsagePage":@13,@"DeviceUsage":@4}],
            @"Transport":@"Virtual",@"Product":@"SkyTouch Virtual Touch Inspection",
            @"Manufacturer":@"SkyTouch",@"VendorID":@0,@"ProductID":@0,@"VersionNumber":@1,
            @"Built-In":@YES,@"DisplayIntegrated":@YES};
    }
    return self;
}
- (BOOL)ready { return _state==State::Ready && _native && _serviceID!=0; }
- (uint64_t)serviceID { return _serviceID; }
- (NSString *)status { return _status; }
- (BOOL)cancellationPending { return _state==State::Cancelling; }
- (BOOL)terminated { return _terminated; }
- (BOOL)cancellationComplete { return _cancellationComplete; }
- (NSDictionary *)diagnostics {
    @synchronized(self) {
        return @{@"callbackQueue":@"dedicated-serial-user-interactive",
            @"setPropertyRejectedCount":@(_setPropertyRejectedCount),@"setPropertyRequests":_setPropertyRequests.copy};
    }
}
- (BOOL)start:(NSString **)error {
    if(error)*error=nil;
    if(!NSThread.isMainThread) { if(error)*error=@"虚拟触屏服务必须在主线程启动";return NO; }
    if(_state==State::Starting || _state==State::Ready)return YES;
    if(_state!=State::Idle) { if(error)*error=@"该虚拟触屏会话已结束，需创建新服务";return NO; }
    Class cls=nativeServiceClass();
    if(!serviceABI(cls)) {
        _state=State::Failed;_status=@"虚拟触屏服务接口不可用或 ABI 不匹配";
        if(error)*error=_status;return NO;
    }
    @try {
        Protocol *protocol=NSProtocolFromString(@"HIDVirtualEventServiceDelegate");
        if(protocol)class_addProtocol(OPVirtualTouchService.class,protocol);
        _native=[[cls alloc] init];
        if(!_native) {
            _state=State::Failed;_status=@"虚拟触屏服务创建失败";if(error)*error=_status;return NO;
        }
        dispatch_queue_attr_t attributes=dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INTERACTIVE,0);
        _callbackQueue=dispatch_queue_create("com.lixinmo.skytouch.virtual-touch.callbacks",attributes);
        ((void(*)(id,SEL,id))objc_msgSend)(_native,NSSelectorFromString(@"setDelegate:"),self);
        // BackBoard property requests must complete while the main thread is
        // loading the original UI/engine. Delegate properties are immutable;
        // readiness/termination and cancellation completion still land on main.
        ((void(*)(id,SEL,dispatch_queue_t))objc_msgSend)(_native,NSSelectorFromString(@"setDispatchQueue:"),_callbackQueue);
        __weak OPVirtualTouchService *weakSelf=self;
        dispatch_queue_t callbackQueue=_callbackQueue;
        dispatch_block_t handler=^{
            // First leave the serial native callback stack, then release on
            // main. A direct hop to main can run concurrently with this stack.
            dispatch_async(callbackQueue,^{
                dispatch_async(dispatch_get_main_queue(),^{[weakSelf nativeCancellationFinished];});
            });
        };
        ((void(*)(id,SEL,id))objc_msgSend)(_native,NSSelectorFromString(@"setCancelHandler:"),handler);
        _keepAlive=self;_state=State::Starting;_status=@"等待独立虚拟触屏服务注册";
        _activationAttempted=YES;
        ((void(*)(id,SEL))objc_msgSend)(_native,NSSelectorFromString(@"activate"));
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC),dispatch_get_main_queue(),^{[weakSelf registrationTimedOut];});
        BOOL requested=_state==State::Starting || _state==State::Ready;
        if(!requested && error)*error=_status;
        return requested;
    } @catch(NSException *exception) {
        NSString *reason=[@"虚拟触屏服务启动异常：" stringByAppendingString:exception.name ?: @"unknown"];
        if(_activationAttempted)[self failAndCancel:reason];
        else {_native=nil;_callbackQueue=nil;_state=State::Failed;_status=reason;}
        if(error)*error=reason;return NO;
    }
}
- (BOOL)dispatchEvent:(CFTypeRef)event {
    if(!NSThread.isMainThread || !event || !self.ready)return NO;
    @try {
        BOOL sent=((BOOL(*)(id,SEL,id))objc_msgSend)(_native,NSSelectorFromString(@"dispatchEvent:"),(__bridge id)event);
        if(!sent)_status=@"虚拟触屏服务未接受此次事件";
        return sent;
    } @catch(NSException *exception) {
        _status=[@"虚拟触屏事件提交异常：" stringByAppendingString:exception.name ?: @"unknown"];
        return NO;
    }
}
- (void)cancel {
    if(!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(),^{[self cancel];});return; }
    if(_state==State::Cancelling || _state==State::Cancelled)return;
    if(!_activationAttempted || !_native) {
        _state=State::Cancelled;_serviceID=0;_native=nil;_callbackQueue=nil;_keepAlive=nil;_cancellationComplete=YES;
        if(!_preserveFailureStatus)_status=@"虚拟触屏服务已关闭";return;
    }
    _state=State::Cancelling;_serviceID=0;
    if(!_preserveFailureStatus)_status=@"正在关闭虚拟触屏服务";
    @try { ((void(*)(id,SEL))objc_msgSend)(_native,NSSelectorFromString(@"cancel")); }
    @catch(NSException *exception) {
        // Keep the delegate/native object retained if no completion arrives.
        _preserveFailureStatus=YES;
        _status=[@"虚拟触屏服务关闭异常：" stringByAppendingString:exception.name ?: @"unknown"];
    }
}
- (void)nativeCancellationFinished {
    if(!NSThread.isMainThread) {dispatch_async(dispatch_get_main_queue(),^{[self nativeCancellationFinished];});return;}
    _state=State::Cancelled;_serviceID=0;_native=nil;_callbackQueue=nil;_cancellationComplete=YES;
    if(!_preserveFailureStatus)_status=@"虚拟触屏服务已关闭";
    _keepAlive=nil;
}
- (void)failAndCancel:(NSString *)reason {
    _preserveFailureStatus=YES;_status=[reason copy];
    // Invalidate readiness before leaving a native notification callback; call
    // native cancellation on the next queue turn, outside that callback stack.
    if(_state!=State::Cancelling && _state!=State::Cancelled)_state=State::Failed;
    _serviceID=0;
    dispatch_async(dispatch_get_main_queue(),^{[self cancel];});
}
- (void)registrationTimedOut {
    if(_state==State::Starting)[self failAndCancel:@"虚拟触屏服务注册超时，未启用触屏输出"];
}
// The native framework invokes these selectors through its delegate protocol.
- (BOOL)setProperty:(id)value forKey:(NSString *)key forService:(id)service {
    (void)service;
    NSString *type=!value || value==NSNull.null ? @"null" :
        [value isKindOfClass:NSString.class] ? @"string" :
        [value isKindOfClass:NSNumber.class] ? (CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID() ? @"boolean" : @"number") :
        [value isKindOfClass:NSArray.class] ? @"array" :
        [value isKindOfClass:NSDictionary.class] ? @"dictionary" :
        [value isKindOfClass:NSData.class] ? @"data" : @"other";
    @synchronized(self) {
        ++_setPropertyRejectedCount;
        if([key isKindOfClass:NSString.class] && key.length<=128 && (_setPropertyRequests.count<64 || _setPropertyRequests[key]))
            _setPropertyRequests[key]=@{@"valueType":type,@"count":@([_setPropertyRequests[key][@"count"] unsignedLongLongValue]+1)};
    }
    return NO;
}
- (id)propertyForKey:(NSString *)key forService:(id)service {
    (void)service;return [key isKindOfClass:NSString.class] ? _properties[key] : nil;
}
- (id)copyEventMatching:(NSDictionary *)matching forService:(id)service {
    (void)matching;(void)service;return nil;
}
- (BOOL)setOutputEvent:(id)event forService:(id)service {
    (void)event;(void)service;return NO;
}
- (void)notification:(NSInteger)type withProperty:(NSDictionary *)property forService:(id)service {
    (void)property;
    if(!NSThread.isMainThread) {dispatch_async(dispatch_get_main_queue(),^{[self notification:type withProperty:nil forService:service];});return;}
    if(service!=_native)return;
    if(type==11)_terminated=YES;
    if(_state==State::Cancelling || _state==State::Cancelled)return;
    if(type==10 && (_state==State::Starting || _state==State::Ready)) {
        @try {
            _serviceID=((uint64_t(*)(id,SEL))objc_msgSend)(_native,NSSelectorFromString(@"serviceID"));
            if(_serviceID){_state=State::Ready;_status=@"独立虚拟触屏服务已注册";}
            else [self failAndCancel:@"虚拟触屏服务未返回独立标识，未启用输出"];
        } @catch(__unused NSException *exception) {[self failAndCancel:@"虚拟触屏服务标识读取失败，未启用输出"];}
    } else if(type==11)[self failAndCancel:@"虚拟触屏服务已终止，触屏输出停止"];
}
@end
