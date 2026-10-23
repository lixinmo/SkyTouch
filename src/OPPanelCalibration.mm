#import "OPStoragePaths.h"
#import "OPPanelCalibration.h"
#import <objc/message.h>
#include <dlfcn.h>
#include <sys/sysctl.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <cmath>
#include <cerrno>

namespace {

constexpr const char *filename="com.lixinmo.skytouch.original-panel.plist";
bool bootTime(timeval &value) {
    size_t size=sizeof(value);
    return sysctlbyname("kern.boottime",&value,&size,nullptr,0)==0 && size==sizeof(value) &&
        value.tv_sec>0 && value.tv_usec>=0 && value.tv_usec<1000000;
}
bool number(id object) {
    return [object isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)object)==CFNumberGetTypeID();
}
bool integerNumber(id object) {
    return number(object) && !CFNumberIsFloatType((__bridge CFNumberRef)object);
}
bool senderNumber(id object,std::uint64_t &sender) {
    if (!number(object) || CFNumberIsFloatType((__bridge CFNumberRef)object) || [object compare:@0]!=NSOrderedDescending) return false;
    sender=[object unsignedLongLongValue]; return sender!=0;
}
NSDictionary *readRecord(void) {
    int parent=open(OPSettingsDirectory().fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_CLOEXEC);
    if (parent<0) return nil;
    int fd=openat(parent,filename,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);
    close(parent);
    if (fd<0) return nil;
    struct stat status{};
    if (fstat(fd,&status) || !S_ISREG(status.st_mode) || status.st_nlink!=1 ||
        (status.st_uid!=0 && status.st_uid!=501) || (status.st_mode&0022) ||
        status.st_size<=0 || status.st_size>4096) { close(fd); return nil; }
    NSMutableData *data=[NSMutableData dataWithLength:(NSUInteger)status.st_size];
    size_t offset=0;
    while (offset<data.length) {
        ssize_t amount=read(fd,(char *)data.mutableBytes+offset,data.length-offset);
        if (amount<0 && errno==EINTR) continue;
        if (amount<=0) { close(fd); return nil; }
        offset+=(size_t)amount;
    }
    close(fd);
    id record=[NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:nil];
    return [record isKindOfClass:NSDictionary.class] ? record : nil;
}
void storeRecord(std::uint64_t sender) {
    timeval boot{}; if (!bootTime(boot)) return;
    NSDictionary *record=@{@"schema":@1,@"senderID":@(sender),@"bootSeconds":@(boot.tv_sec),
        @"bootMicroseconds":@(boot.tv_usec),@"recordedAtUnix":@(NSDate.date.timeIntervalSince1970),
        @"source":@"configuration-application-direct-touch"};
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:record format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    if (!data.length || data.length>4096) return;
    int parent=open(OPSettingsDirectory().fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_CLOEXEC);
    if (parent<0) return;
    NSString *temporary=[@".com.lixinmo.skytouch.panel-" stringByAppendingString:NSUUID.UUID.UUIDString];
    int fd=openat(parent,temporary.UTF8String,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    if (fd<0) { close(parent); return; }
    bool good=geteuid()!=0 || fchown(fd,501,501)==0;
    size_t offset=0;
    while (good && offset<data.length) {
        ssize_t amount=write(fd,(const char *)data.bytes+offset,data.length-offset);
        if (amount<0 && errno==EINTR) continue;
        if (amount<=0) { good=false; break; }
        offset+=(size_t)amount;
    }
    if (good) good=fsync(fd)==0;
    if (close(fd)) good=false;
    if (good) good=renameat(parent,temporary.UTF8String,parent,filename)==0;
    if (!good) unlinkat(parent,temporary.UTF8String,0);
    close(parent);
}
}

BOOL OPReadPanelCalibration(std::uint64_t *senderID) {
    if (!senderID) return NO;
    *senderID=0;
    NSDictionary *record=readRecord(); timeval boot{};
    if (!record || !bootTime(boot) || !integerNumber(record[@"schema"]) || [record[@"schema"] integerValue]!=1 ||
        !integerNumber(record[@"bootSeconds"]) || [record[@"bootSeconds"] longLongValue]!=boot.tv_sec ||
        !integerNumber(record[@"bootMicroseconds"]) || [record[@"bootMicroseconds"] longLongValue]!=boot.tv_usec ||
        ![record[@"source"] isEqual:@"configuration-application-direct-touch"] || !number(record[@"recordedAtUnix"])) return NO;
    const double recorded=[record[@"recordedAtUnix"] doubleValue], now=NSDate.date.timeIntervalSince1970;
    const double bootUnix=(double)boot.tv_sec+(double)boot.tv_usec/1000000.0;
    if (!std::isfinite(recorded) || recorded<bootUnix || recorded>now) return NO;
    std::uint64_t candidate=0;
    if (!senderNumber(record[@"senderID"],candidate)) return NO;
    *senderID=candidate; return YES;
}

void OPRecordPanelFromConfigurationEvent(UIEvent *event) {
    if (!NSThread.isMainThread || geteuid()!=501 ||
        ![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.lixinmo.skytouch.app"] ||
        UIApplication.sharedApplication.applicationState!=UIApplicationStateActive || event.type!=UIEventTypeTouches) return;
    BOOL began=NO;
    for (UITouch *touch in event.allTouches)
        if (touch.type==UITouchTypeDirect && touch.phase==UITouchPhaseBegan) { began=YES; break; }
    if (!began) return;
    SEL selector=NSSelectorFromString(@"_hidEvent");
    NSMethodSignature *signature=[event methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments!=2 || signature.methodReturnLength!=sizeof(void *) || signature.methodReturnType[0]!='^') return;
    static void *library=dlopen("/System/Library/Frameworks/IOKit.framework/IOKit",RTLD_NOW|RTLD_LOCAL);
    if (!library) return;
    using Event=const void *;
    static auto type=(uint32_t(*)(Event))dlsym(library,"IOHIDEventGetType");
    static auto integer=(CFIndex(*)(Event,uint32_t))dlsym(library,"IOHIDEventGetIntegerValue");
    static auto sender=(uint64_t(*)(Event))dlsym(library,"IOHIDEventGetSenderID");
    if (!type || !integer || !sender) return;
    @try {
        Event raw=((Event(*)(id,SEL))objc_msgSend)(event,selector);
        if (!raw || type(raw)!=11 || !integer(raw,4) || !integer(raw,(11U<<16)+25) || !integer(raw,(11U<<16)+9)) return;
        const std::uint64_t candidate=sender(raw);
        if (!candidate) return;
        std::uint64_t previous=0;
        if (OPReadPanelCalibration(&previous) && previous==candidate) return;
        storeRecord(candidate);
    } @catch (__unused NSException *exception) { /* Normal UIKit delivery continues. */ }
}
