#import "OPInputSettings.h"
#import "OPPhoneProfile.h"
#import "OPStoragePaths.h"
#import <notify.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>
#include <cerrno>
#include <cmath>

const char *const OPInputSettingsChangedNotification="com.lixinmo.skytouch.input-settings.changed";
namespace {
constexpr const char *settingsName="com.lixinmo.skytouch.input-settings.plist";
constexpr const char *lockName="com.lixinmo.skytouch.input-settings.lock";
constexpr NSUInteger maximumBytes=16384;
struct FD {int value;explicit FD(int fd=-1):value(fd){}~FD(){if(value>=0)close(value);}FD(const FD&)=delete;};
BOOL fail(NSString **error,NSString *message){if(error)*error=message;return NO;}
NSDictionary *defaults(NSString *revision) {
    return @{ @"version":@1,@"revision":revision,@"mode":@"controller",
        @"phoneBindings":@{@"action":@"LB",@"volumeUp":@"A",@"volumeDown":@"B",@"side":@"LT"},
        @"controllerMotion":@"controller",@"motionScaleX":@2048.0,@"motionScaleY":@2048.0 };
}
BOOL owned(const struct stat &st) {
    return st.st_uid==0 || st.st_uid==501;
}
BOOL metadata(int fd,BOOL directory,BOOL reading=NO) {
    struct stat st{};
    return fd>=0 && fstat(fd,&st)==0 && owned(st) &&
        (directory ? (S_ISDIR(st.st_mode) && !(st.st_mode&0022)) :
        (S_ISREG(st.st_mode) && (st.st_nlink==1 || (reading && st.st_nlink==0)) && !(st.st_mode&0077)));
}
int directory(BOOL runtime) {
    NSString *path=runtime ? OPRuntimeDirectory() : OPSettingsDirectory();
    if(!path.isAbsolutePath)return -1;
    int fd=open(path.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);
    if(!metadata(fd,YES)){if(fd>=0)close(fd);return -1;}return fd;
}
BOOL number(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value)==CFNumberGetTypeID() &&
        std::isfinite([value doubleValue]);
}
BOOL valid(NSDictionary *value,BOOL write,NSString **error) {
    NSSet *keys=[NSSet setWithArray:@[@"version",@"revision",@"mode",@"phoneBindings",@"controllerMotion",@"motionScaleX",@"motionScaleY"]];
    if(![value isKindOfClass:NSDictionary.class] || ![[NSSet setWithArray:value.allKeys] isEqual:keys])
        return fail(error,@"输入设置包含缺失或未知字段。");
    id revision=value[@"revision"],version=value[@"version"];
    if(!number(version) || CFNumberIsFloatType((__bridge CFNumberRef)version) || ![version isEqual:@1] ||
       ![revision isKindOfClass:NSString.class] ||
       (![[NSUUID alloc]initWithUUIDString:revision] && !(write && [@[@"legacy-default",@"invalid-settings"] containsObject:revision])))
        return fail(error,@"输入设置版本或修订号无效。");
    if(![@[@"controller",@"phone"] containsObject:value[@"mode"]] ||
       ![@[@"controller",@"phone"] containsObject:value[@"controllerMotion"]])
        return fail(error,@"请选择手柄模式或手机模式，以及有效的体感来源。");
    NSDictionary *bindings=value[@"phoneBindings"];
    if(![bindings isKindOfClass:NSDictionary.class] ||
       ![[NSSet setWithArray:bindings.allKeys] isEqual:[NSSet setWithArray:@[@"action",@"volumeUp",@"volumeDown",@"side"]]])
        return fail(error,@"请为四个手机实体键设置逻辑按键。");
    for(id key in bindings.allValues) {
        uint32_t mask=0;
        if(!OPPhoneLogicalKeyMask(key,0,&mask) && !OPPhoneLogicalKeyMask(key,2,&mask))
            return fail(error,@"手机按键绑定包含尚未支持的逻辑按键。");
    }
    for(NSString *key in @[@"motionScaleX",@"motionScaleY"]) {
        id scale=value[key];
        if(!number(scale) || [scale doubleValue]<1 || [scale doubleValue]>65536)
            return fail(error,@"手机体感定标必须是 1 至 65536 之间的有限数值。");
    }
    return YES;
}
NSDictionary *readAt(int parent) {
    FD input(openat(parent,settingsName,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK));
    if(input.value<0)return defaults(errno==ENOENT ? @"legacy-default" : @"invalid-settings");
    struct stat before{},after{};
    if(!metadata(input.value,NO,YES) || fstat(input.value,&before) || before.st_size<=0 || before.st_size>(off_t)maximumBytes)
        return defaults(@"invalid-settings");
    NSMutableData *bytes=[NSMutableData dataWithLength:(NSUInteger)before.st_size];size_t offset=0;
    while(offset<bytes.length) {
        ssize_t count=read(input.value,(uint8_t *)bytes.mutableBytes+offset,bytes.length-offset);
        if(count<0 && errno==EINTR)continue;
        if(count<=0)return defaults(@"invalid-settings");offset+=(size_t)count;
    }
    uint8_t extra;ssize_t tail;do{tail=read(input.value,&extra,1);}while(tail<0 && errno==EINTR);
    if(tail!=0 || fstat(input.value,&after) || before.st_size!=after.st_size ||
       before.st_mtimespec.tv_sec!=after.st_mtimespec.tv_sec || before.st_mtimespec.tv_nsec!=after.st_mtimespec.tv_nsec)
        return defaults(@"invalid-settings");
    id value=[NSPropertyListSerialization propertyListWithData:bytes options:NSPropertyListImmutable format:nil error:nil];
    return valid(value,NO,nullptr) ? value : defaults(@"invalid-settings");
}
BOOL normalize(int fd) {
    if(geteuid()==0 && fchown(fd,501,501))return NO;
    return fchmod(fd,0600)==0 && metadata(fd,NO);
}
}

NSDictionary *OPReadInputSettings(void) {
    FD parent(directory(NO));return parent.value<0 ? defaults(@"invalid-settings") : readAt(parent.value);
}
BOOL OPPhoneModeSelected(void){return [OPReadInputSettings()[@"mode"] isEqual:@"phone"];}
NSString *OPInputSettingsRevision(void){return OPReadInputSettings()[@"revision"];}
BOOL OPWriteInputSettings(NSDictionary *settings,NSString **error) {
    if(error)*error=nil;
    if(!valid(settings,YES,error))return NO;
    FD parent(directory(NO)),locks(directory(YES));
    if(parent.value<0 || locks.value<0)return fail(error,@"输入设置目录不可用，请重新打开凌触。");
    FD lock(openat(locks.value,lockName,O_RDWR|O_CREAT|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK,0600));
    if(!metadata(lock.value,NO) || !normalize(lock.value))return fail(error,@"输入设置锁不可用。");
    int result;do{result=flock(lock.value,LOCK_EX);}while(result<0 && errno==EINTR);
    if(result<0)return fail(error,@"无法锁定输入设置。");
    struct stat locked{},named{};
    if(fstat(lock.value,&locked) || fstatat(locks.value,lockName,&named,AT_SYMLINK_NOFOLLOW) ||
       locked.st_dev!=named.st_dev || locked.st_ino!=named.st_ino)return fail(error,@"输入设置锁已变化，请重试。");
    if(![readAt(parent.value)[@"revision"] isEqual:settings[@"revision"]])
        return fail(error,@"输入设置已在其他位置更新，请返回后重新修改。");
    struct stat previous{};BOOL exists=fstatat(parent.value,settingsName,&previous,AT_SYMLINK_NOFOLLOW)==0;
    if(!exists && errno!=ENOENT)return fail(error,@"无法检查现有输入设置。");
    if(exists && (!S_ISREG(previous.st_mode) || previous.st_nlink!=1 || !owned(previous) || (previous.st_mode&0077)))
        return fail(error,@"现有输入设置不是安全的普通文件。");
    NSMutableDictionary *record=[settings mutableCopy];record[@"revision"]=NSUUID.UUID.UUIDString;
    NSData *bytes=[NSPropertyListSerialization dataWithPropertyList:record format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    if(!bytes.length || bytes.length>maximumBytes)return fail(error,@"输入设置无法编码。");
    NSString *temporary=[NSString stringWithFormat:@".%s.%@.tmp",settingsName,NSUUID.UUID.UUIDString];
    FD output(openat(parent.value,temporary.UTF8String,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600));
    BOOL written=output.value>=0 && normalize(output.value);size_t offset=0;
    while(written && offset<bytes.length) {
        ssize_t count=write(output.value,(const uint8_t *)bytes.bytes+offset,bytes.length-offset);
        if(count<0 && errno==EINTR)continue;
        if(count<=0){written=NO;break;}offset+=(size_t)count;
    }
    if(written)written=fsync(output.value)==0;
    if(written) {
        struct stat current{};int found=fstatat(parent.value,settingsName,&current,AT_SYMLINK_NOFOLLOW);
        written=exists ? found==0 && previous.st_dev==current.st_dev && previous.st_ino==current.st_ino : found<0 && errno==ENOENT;
    }
    if(written)written=renameat(parent.value,temporary.UTF8String,parent.value,settingsName)==0;
    if(!written){unlinkat(parent.value,temporary.UTF8String,0);return fail(error,@"输入设置写入失败，原设置已保留。");}
    (void)fsync(parent.value);notify_post(OPInputSettingsChangedNotification);return YES;
}
