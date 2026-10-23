#import "OPSystemTouch.h"
#import "OPVirtualTouchService.h"

#include "../shared/core/Coordinates.hpp"
#include <array>
#include <cstdint>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <unistd.h>

// Only ABI declarations/field values are restated here, not a vendored touch
// framework. ABI cross-check: WebKit's PAL/pal/spi/ios/IOKitSPIIOS.h and
// Tools/WebKitTestRunner/ios/HIDEventGenerator.mm (Apple, BSD-2-Clause),
// https://github.com/WebKit/WebKit/tree/main/Source/WebCore/PAL/pal/spi/ios
// Sender-ID/dispatch feasibility reference: ZXTouch Touch.xm (GPL-3.0),
// https://github.com/epic0001/zxtouchrootless/blob/709208f1e71b770f81f1e154dce2a5149aaafac5/pccontrol/Touch.xm
// No ZXTouch source, server, app hooks, or dependencies are included.
// NB: several historical headers have WRONG modern-iOS declarations:
// hand type is 3 (not 0x23), IOHIDFloat is double, integer fields use CFIndex,
// AppendEvent has an options argument, and range/touch are boolean_t (int).

namespace {
// This identifies the dedicated process; it is not an entitlement or delivery
// test. Root alone is deliberately insufficient, and SpringBoard is rejected.
BOOL OPHostAllowed(uid_t effectiveUID, NSString *bundleIdentifier) {
    return effectiveUID == 0 && ([bundleIdentifier isEqualToString:@"SkyTouchMapping"] ||
        [bundleIdentifier isEqualToString:@"com.lixinmo.skytouch.app"]);
}

using HIDEvent = const void *;

constexpr uint32_t kDigitizerEventType = 11;
constexpr uint32_t kHandTransducer = 3;
constexpr uint32_t kFieldBuiltIn = 4;
constexpr uint32_t kDigitizerBase = kDigitizerEventType << 16;
constexpr uint32_t kFieldMajorRadius = kDigitizerBase + 20;
constexpr uint32_t kFieldMinorRadius = kDigitizerBase + 21;
constexpr uint32_t kFieldDisplayIntegrated = kDigitizerBase + 25;
constexpr uint32_t kMaskRange = 1u << 0;
constexpr uint32_t kMaskTouch = 1u << 1;
constexpr uint32_t kMaskPosition = 1u << 2;
constexpr uint32_t kMaskIdentity = 1u << 5;
constexpr uint32_t kMaskCancel = 1u << 7;

// Dedicated Probe evidence on iOS 17.1: child index 257 was not delivered;
// child index 20 delivered Began/Moved/Ended with this unchanged event shape.
// Reserve 20..29 for this backend's IDs 1..10. This is not an Apple-reserved
// range: multi-touch and physical/synthetic coexistence still require QA.
// Parent index remains unchanged; only child index/identity are translated.
constexpr uint32_t kParentIndex = 0x100;
constexpr uint32_t kFingerIndexBase = 19;

struct HIDAPI {
    void (*setSender)(HIDEvent, uint64_t) = nullptr;
    void (*setInteger)(HIDEvent, uint32_t, CFIndex) = nullptr;
    void (*setFloat)(HIDEvent, uint32_t, double) = nullptr;
    void (*append)(HIDEvent, HIDEvent, uint32_t) = nullptr;
    HIDEvent (*createHand)(CFAllocatorRef, uint64_t, uint32_t, uint32_t,
        uint32_t, uint32_t, uint32_t, double, double, double, double, double,
        int, int, uint32_t) = nullptr;
    HIDEvent (*createFinger)(CFAllocatorRef, uint64_t, uint32_t, uint32_t,
        uint32_t, double, double, double, double, double, int, int, uint32_t) = nullptr;
};

template <typename T>
bool resolveSymbol(void *library, const char *name, T &target) {
    target = reinterpret_cast<T>(dlsym(library, name));
    return target != nullptr;
}

struct Contact {
    bool active = false;
    fsm::NormalizedPoint point{0, 0};
};

std::optional<fsm::DisplayOrientation> displayOrientation(UIInterfaceOrientation value) {
    switch (value) {
        case UIInterfaceOrientationPortrait: return fsm::DisplayOrientation::Portrait;
        case UIInterfaceOrientationPortraitUpsideDown: return fsm::DisplayOrientation::PortraitUpsideDown;
        case UIInterfaceOrientationLandscapeLeft: return fsm::DisplayOrientation::LandscapeLeft;
        case UIInterfaceOrientationLandscapeRight: return fsm::DisplayOrientation::LandscapeRight;
        default: return std::nullopt;
    }
}

std::optional<fsm::NormalizedPoint> originalPointToNative(float x,float y,fsm::DisplayOrientation orientation) {
    // The supplied engine can deliberately drag beyond the window while the
    // same UITouch remains captured. UIKit's original setLocationInWindow
    // neither clips that point nor cancels other fingers. Preserve its finite
    // coordinates across our affine orientation conversion as well.
    if(!std::isfinite(x)||!std::isfinite(y))return std::nullopt;
    switch(orientation) {
        case fsm::DisplayOrientation::Portrait:return fsm::NormalizedPoint{x,y};
        case fsm::DisplayOrientation::PortraitUpsideDown:return fsm::NormalizedPoint{1-x,1-y};
        case fsm::DisplayOrientation::LandscapeLeft:return fsm::NormalizedPoint{y,1-x};
        case fsm::DisplayOrientation::LandscapeRight:return fsm::NormalizedPoint{1-y,x};
    }
    return std::nullopt;
}

bool isActive(fsm::TouchPhase phase) {
    return phase == fsm::TouchPhase::Began || phase == fsm::TouchPhase::Moved ||
           phase == fsm::TouchPhase::Stationary;
}

bool isKnownPhase(fsm::TouchPhase phase) {
    return isActive(phase) || phase == fsm::TouchPhase::Ended ||
           phase == fsm::TouchPhase::Cancelled;
}

uint32_t eventMask(fsm::TouchPhase phase) {
    switch (phase) {
        case fsm::TouchPhase::Began: return kMaskRange | kMaskTouch | kMaskIdentity;
        case fsm::TouchPhase::Moved: return kMaskPosition;
        case fsm::TouchPhase::Stationary: return 0;
        case fsm::TouchPhase::Ended: return kMaskRange | kMaskTouch | kMaskIdentity;
        case fsm::TouchPhase::Cancelled: return kMaskRange | kMaskTouch | kMaskIdentity | kMaskCancel;
    }
    return 0;
}

bool anyActive(const std::array<Contact, fsm::kMaxTouches> &contacts) {
    for (const auto &contact : contacts) if (contact.active) return true;
    return false;
}
} // namespace

@interface OPSystemTouch () {
    HIDAPI _api;
    void *_hidLibrary;
    OPVirtualTouchService *_virtualService;
    uint64_t _submittedFrameCount;
    uint64_t _lastFrameTime;
    uint64_t _cancelGeneration;
    NSUInteger _cancelRetryCount;
    BOOL _cancellationPending;
    BOOL _cancelRetryScheduled;
    BOOL _shutdownRequested;
    std::array<Contact, fsm::kMaxTouches> _contacts;
    UIInterfaceOrientation _activeOrientation;
    NSString *_status;
}
- (BOOL)permittedHost;
- (BOOL)loadHIDAPI;
- (BOOL)prepareOutputService:(NSString **)error;
- (BOOL)outputServiceReady;
- (BOOL)outputServiceRemoved;
- (uint64_t)outputServiceIdentifier;
- (BOOL)dispatchOutputEvent:(HIDEvent)event;
- (void)cancelOutputService;
- (BOOL)submitNativeFrame:(const fsm::TouchFrame &)frame;
- (BOOL)rejectFrameWithReason:(NSString *)reason;
- (void)retryCancellationIfNeeded;
- (void)completeShutdown;
@end

@implementation OPSystemTouch

- (instancetype)init {
    if ((self = [super init])) {
        _status = @"系统触屏后端未准备";
        _activeOrientation = UIInterfaceOrientationUnknown;
    }
    return self;
}

- (BOOL)permittedHost {
    return OPHostAllowed(geteuid(), [NSBundle mainBundle].bundleIdentifier);
}

- (BOOL)ready {
    return [self permittedHost] && [self outputServiceReady] && [self outputServiceIdentifier] != 0 &&
           _api.createHand && _api.createFinger &&
           !_cancellationPending && !_shutdownRequested;
}
- (BOOL)cancellationPending { return _cancellationPending; }
- (NSString *)status {
    return _virtualService && !_shutdownRequested &&
        (!_virtualService.ready || [_status hasPrefix:@"独立虚拟触屏服务注册中"]) ? _virtualService.status : _status;
}
- (uint64_t)serviceIdentifier { return [self outputServiceIdentifier]; }
- (NSDictionary *)sourceDiagnostics { return _virtualService.diagnostics ?: @{}; }
- (uint64_t)submittedFrameCount { return _submittedFrameCount; }

- (BOOL)prepare {
    if (![NSThread isMainThread]) return NO;
    if (![self permittedHost]) {
        _status = @"已拒绝：触屏后端仅供 UID 0 的凌触专用 HUD 使用";
        return NO;
    }
    if (_cancellationPending || _shutdownRequested) {
        [self reset];
        if (_cancellationPending) return NO;
    }
    if (self.ready) return YES;
    if (![self loadHIDAPI]) return NO;
    NSString *error=nil;
    if(![self prepareOutputService:&error]) {
        _status=error ?: @"无法注册独立虚拟触屏服务";return NO;
    }
    _status=@"独立虚拟触屏服务注册中，等待系统枚举";
    return YES;
}

- (BOOL)prepareOutputService:(NSString **)error {
    if(!_virtualService)_virtualService=[OPVirtualTouchService new];
    return [_virtualService start:error];
}
- (BOOL)outputServiceReady {return _virtualService.ready;}
- (BOOL)outputServiceRemoved {return _virtualService && (_virtualService.terminated || _virtualService.cancellationComplete);}
- (uint64_t)outputServiceIdentifier {return _virtualService.serviceID;}
- (BOOL)dispatchOutputEvent:(HIDEvent)event {return [_virtualService dispatchEvent:(CFTypeRef)event];}
- (void)cancelOutputService {[_virtualService cancel];_virtualService=nil;}

- (BOOL)loadHIDAPI {
    if (!_hidLibrary) {
        _hidLibrary = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_LOCAL);
        if (!_hidLibrary) {
            _hidLibrary = dlopen("/System/Library/PrivateFrameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_LOCAL);
        }
    }
    if (!_hidLibrary) {
        _status = @"不可用：当前系统无法加载 IOKit";
        return NO;
    }

    // Fail closed: no offset scanning, patching, or speculative fallback ABI.
#define OP_REQUIRE(member, symbol) \
    if (!resolveSymbol(_hidLibrary, symbol, _api.member)) { \
        _status = [@"不可用：缺少系统符号 " stringByAppendingString:@symbol]; \
        return NO; \
    }
    OP_REQUIRE(setSender, "IOHIDEventSetSenderID")
    OP_REQUIRE(setInteger, "IOHIDEventSetIntegerValue")
    OP_REQUIRE(setFloat, "IOHIDEventSetFloatValue")
    OP_REQUIRE(append, "IOHIDEventAppendEvent")
    OP_REQUIRE(createHand, "IOHIDEventCreateDigitizerEvent")
    OP_REQUIRE(createFinger, "IOHIDEventCreateDigitizerFingerEvent")
#undef OP_REQUIRE

    return YES;
}

- (BOOL)dispatchFrame:(const fsm::TouchFrame &)frame
           orientation:(UIInterfaceOrientation)orientation {
    if (![NSThread isMainThread]) return NO;
    if (![self permittedHost]) {
        _status = @"未发送：当前进程不是 UID 0 的凌触专用 HUD";
        return NO;
    }
    if (_cancellationPending) {
        [self reset];
        if (_cancellationPending) return NO;
    }
    if (!self.ready) {
        _status = @"未发送：独立虚拟触屏服务尚未就绪";
        return NO;
    }
    const auto direction = displayOrientation(orientation);
    if (!direction) {
        return [self rejectFrameWithReason:@"无法确认前台界面方向"];
    }
    if (anyActive(_contacts) && orientation != _activeOrientation) {
        return [self rejectFrameWithReason:@"界面旋转，需要重新开始触点"];
    }
    if (frame.count > fsm::kMaxTouches ||
        (_lastFrameTime != 0 && frame.timestampNs != 0 && frame.timestampNs < _lastFrameTime)) {
        return [self rejectFrameWithReason:@"触点数量或时间戳非法"];
    }

    std::array<bool, fsm::kMaxTouches> seen{};
    auto next = _contacts;
    auto native = frame;
    for (std::size_t i = 0; i < frame.count; ++i) {
        const auto &touch = frame.touches[i];
        if (touch.id == 0 || touch.id > fsm::kMaxTouches || !isKnownPhase(touch.phase)) {
            return [self rejectFrameWithReason:@"触点 ID 或阶段非法"];
        }
        const std::size_t index = touch.id - 1;
        const auto point = originalPointToNative(touch.x, touch.y, *direction);
        const bool began = touch.phase == fsm::TouchPhase::Began;
        if (!point || seen[index] || (began == _contacts[index].active)) {
            // Began requires an idle ID; all other phases require a live ID.
            return [self rejectFrameWithReason:@"触点坐标、重复 ID 或阶段序列非法"];
        }
        seen[index] = true;
        native.touches[i].x = point->x;
        native.touches[i].y = point->y;
        next[index] = Contact{isActive(touch.phase), *point};
    }
    for (std::size_t i = 0; i < fsm::kMaxTouches; ++i) {
        if (_contacts[i].active && !seen[i]) {
            return [self rejectFrameWithReason:@"触点快照遗漏仍按住的手指"];
        }
    }

    if (![self submitNativeFrame:native]) {
        return [self rejectFrameWithReason:@"HID 事件分配失败或独立虚拟服务未接受事件"];
    }
    _contacts = next;
    _activeOrientation = anyActive(_contacts) ? orientation : UIInterfaceOrientationUnknown;
    _lastFrameTime = frame.timestampNs;
    if (frame.count) _status = @"已提交系统触点；实际送达请以测试面板为准";
    return YES;
}

- (BOOL)submitNativeFrame:(const fsm::TouchFrame &)frame {
    // Cancellation retries must remain possible while ready==NO. Normal
    // gestures enter only through dispatchFrame's ready gate.
    if (![self permittedHost] || ![self outputServiceReady] || ![self outputServiceIdentifier]) return NO;
    if (frame.count == 0) return YES;
    uint32_t mask = 0;
    bool touching = false;
    for (std::size_t i = 0; i < frame.count; ++i) {
        mask |= eventMask(frame.touches[i].phase);
        touching = touching || isActive(frame.touches[i].phase);
    }
    // frame.timestampNs is solely for stale-frame rejection; HID expects
    // mach_absolute_time ticks, NOT nanoseconds or wall-clock timestamps.
    const uint64_t ticks = mach_absolute_time();
    // A hand is a collection, not another finger. Its x/y/pressure remain 0;
    // each child owns the position. Touch/range reflect any surviving child.
    // Zero tipPressure is intentional (no force-touch simulation). Began uses
    // touch/range/identity masks: position is supplied on the new child without
    // a position-change mask, matching WebKit's initial-contact convention.
    HIDEvent parent = _api.createHand(kCFAllocatorDefault, ticks, kHandTransducer,
        kParentIndex, 1, mask, 0, 0, 0, 0, 0, 0, touching, touching, 0);
    if (!parent) return NO;
    _api.setInteger(parent, kFieldDisplayIntegrated, 1);
    // A main-display virtual digitizer is built-in in BackBoard's routing
    // model. Its independent service ID still separates it from real fingers.
    _api.setInteger(parent, kFieldBuiltIn, 1);
    _api.setSender(parent, [self outputServiceIdentifier]);
    for (std::size_t i = 0; i < frame.count; ++i) {
        const auto &touch = frame.touches[i];
        const bool down = isActive(touch.phase);
        const uint32_t identity = kFingerIndexBase + touch.id;
        HIDEvent finger = _api.createFinger(kCFAllocatorDefault, ticks,
            identity, identity, eventMask(touch.phase), touch.x, touch.y,
            0, 0, 0, down, down, 0);
        if (!finger) {
            CFRelease(parent);
            return NO;
        }
        _api.setFloat(finger, kFieldMajorRadius, down ? 0.04 : 0);
        _api.setFloat(finger, kFieldMinorRadius, down ? 0.04 : 0);
        _api.append(parent, finger, 0);
        CFRelease(finger); // parent retains appended children
    }
    const BOOL sent=[self dispatchOutputEvent:parent];
    CFRelease(parent);
    if(!sent)return NO;
    ++_submittedFrameCount;
    return YES;
}

- (BOOL)rejectFrameWithReason:(NSString *)reason {
    [self reset];
    NSString *suffix = _cancellationPending
        ? @"；取消请求尚未提交，新输出已锁定，请查看 HID 诊断"
        : @"；旧触点取消请求已提交（若有），实际释放需真机确认";
    _status = [[@"未发送：" stringByAppendingString:reason] stringByAppendingString:suffix];
    return NO;
}

- (void)reset {
    if (![NSThread isMainThread]) return;
    if([self outputServiceRemoved]) {
        // The event source itself was withdrawn. Do not wait forever for that
        // absent source to acknowledge a cancellation frame, and never count
        // this local retirement as a successfully dispatched HID event.
        _contacts={};_activeOrientation=UIInterfaceOrientationUnknown;_lastFrameTime=0;
        _cancellationPending=NO;_cancelRetryScheduled=NO;_cancelRetryCount=0;++_cancelGeneration;
        _status=@"独立触屏服务已撤销，旧触点状态已退休；未发送额外取消帧";
        if(_shutdownRequested)[self completeShutdown];
        return;
    }
    fsm::TouchFrame cancelled{};
    for (std::size_t i = 0; i < _contacts.size(); ++i) {
        if (!_contacts[i].active) continue;
        cancelled.touches[cancelled.count++] = fsm::Touch{
            static_cast<uint32_t>(i + 1), _contacts[i].point.x,
            _contacts[i].point.y, fsm::TouchPhase::Cancelled};
    }
    if (cancelled.count && ![self submitNativeFrame:cancelled]) {
        if (!_cancellationPending) {
            _cancellationPending = YES;
            _cancelRetryCount = 0;
            ++_cancelGeneration;
        }
        // Never forget a possibly live contact just because an allocation or
        // client failed. Retain its last native position for a bounded retry.
        _status = @"取消请求未提交：系统事件分配/客户端失败；新输出已锁定";
        [self retryCancellationIfNeeded];
        return;
    }
    _contacts = {};
    _activeOrientation = UIInterfaceOrientationUnknown;
    _lastFrameTime = 0;
    _cancellationPending = NO;
    _cancelRetryScheduled = NO;
    _cancelRetryCount = 0;
    ++_cancelGeneration;
    if (cancelled.count) _status = @"取消请求已提交；实际释放请以测试面板为准";
    if (_shutdownRequested) [self completeShutdown];
}

- (void)retryCancellationIfNeeded {
    if (!_cancellationPending || _cancelRetryScheduled || _cancelRetryCount >= 3) return;
    _cancelRetryScheduled = YES;
    ++_cancelRetryCount;
    const uint64_t generation = _cancelGeneration;
    __weak OPSystemTouch *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        OPSystemTouch *strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_cancelGeneration != generation) return;
        strongSelf->_cancelRetryScheduled = NO;
        [strongSelf reset];
    });
}

- (void)shutdown {
    if (![NSThread isMainThread]) return;
    _shutdownRequested = YES;
    [self reset]; // completes shutdown once cancellation has been submitted
}

- (void)completeShutdown {
    [self cancelOutputService];
    _shutdownRequested = NO;
    _status = @"系统触屏后端已停止";
    // Keep the system image open: other already-resolved function pointers
    // remain valid, and prepare may safely be called again later.
}

- (void)dealloc {
    // The wrapper retains its native service through its cancellation handler.
    // No physical-screen sender or event-monitor client is owned here.
    [_virtualService cancel];
}

@end
