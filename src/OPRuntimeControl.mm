#import "OPRuntimeControl.h"
#import "OPStoragePaths.h"
#import <notify.h>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
#include <cerrno>
#include <cmath>
#include <cstring>

const char *const OPRuntimeIntentChangedNotification="com.lixinmo.skytouch.runtime-intent.changed";

namespace op_runtime_control {
static const char *const intentName="com.lixinmo.skytouch.runtime-intent.plist";
static const char *const lockName="com.lixinmo.skytouch.runtime-intent.lock";
static constexpr NSUInteger maximumBytes=16384;
struct FD {
    int value;
    explicit FD(int descriptor=-1):value(descriptor) {}
    ~FD(){if(value>=0)close(value);}
    FD(const FD &)=delete;
    FD &operator=(const FD &)=delete;
};
static BOOL fail(NSString **error,NSString *message) {
    if(error)*error=message;return NO;
}
static BOOL ioError(NSString **error,NSString *operation) {
    return fail(error,[NSString stringWithFormat:@"映射开关%@失败：%s",operation,std::strerror(errno)]);
}
static BOOL owned(const struct stat &state) {
    return state.st_uid==0 || state.st_uid==501;
}
static BOOL metadata(const struct stat &state,BOOL directory,NSString **error) {
    if(!owned(state) || (directory ? (!S_ISDIR(state.st_mode) || (state.st_mode&0002)) :
       (!S_ISREG(state.st_mode) || state.st_nlink!=1 || (state.st_mode&0077))))
        return fail(error,@"映射开关包含链接、特殊文件或不安全的所有者/权限");
    return YES;
}
static BOOL metadata(int descriptor,BOOL directory,struct stat *result,NSString **error) {
    struct stat state{};
    if(fstat(descriptor,&state))return ioError(error,@"检查文件");
    if(result)*result=state;
    return metadata(state,directory,error);
}
static BOOL normalize(int descriptor,NSString **error) {
    // Both the ordinary App (mobile) and the root floating process must be
    // able to update this one record and its stable lock inode.
    if(geteuid()==0 && fchown(descriptor,501,501))return ioError(error,@"设置所有者");
    if(fchmod(descriptor,0600))return ioError(error,@"设置权限");
    return metadata(descriptor,NO,nullptr,error);
}
static int openDirectory(NSString **error) {
    NSString *path=OPSettingsDirectory();
    if(!path.isAbsolutePath){fail(error,@"映射开关固定目录不可用");return -1;}
    // /var is an OS-owned symlink on iOS; the fixed Preferences directory and
    // every file opened relative to it must not themselves be symlinks.
    int descriptor=open(path.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);
    if(descriptor<0){ioError(error,@"打开目录");return -1;}
    if(!metadata(descriptor,YES,nullptr,error)){close(descriptor);return -1;}
    return descriptor;
}
static int openLockDirectory(int settings,NSString **error) {
    (void)settings;
    NSString *path=OPRuntimeDirectory();
    if(!path.isAbsolutePath){fail(error,@"映射运行目录不可用");return -1;}
    int descriptor=open(path.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);
    if(descriptor<0){ioError(error,@"打开运行目录");return -1;}
    if(!metadata(descriptor,YES,nullptr,error)){close(descriptor);return -1;}
    return descriptor;
}
static BOOL sameEntry(int directory,const char *name,const struct stat &expected,NSString **error) {
    struct stat actual{};
    if(fstatat(directory,name,&actual,AT_SYMLINK_NOFOLLOW))return ioError(error,@"复核文件");
    if(!metadata(actual,NO,error))return NO;
    return actual.st_dev==expected.st_dev && actual.st_ino==expected.st_ino ? YES :
        fail(error,@"映射开关文件已变化，请重试");
}
static NSDictionary *disabled(void) {return @{@"version":@1,@"enabled":@NO};}
static NSDictionary *readIntent(int directory) {
    // Share the writer's stable inode while inspecting the record. Without
    // this, a reader can open the old record just before rename, then see its
    // now-zero link count and incorrectly report a transient disabled state.
    // Reads never create the lock or migrate a legacy service record.
    FD locks(openLockDirectory(directory,nullptr));
    if(locks.value<0)return disabled();
    FD lock(openat(locks.value,lockName,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK));
    struct stat lockState{};
    if(lock.value<0 || !metadata(lock.value,NO,nullptr,nullptr))return disabled();
    int locked;do{locked=flock(lock.value,LOCK_SH);}while(locked<0&&errno==EINTR);
    if(locked<0 || !metadata(lock.value,NO,&lockState,nullptr) || !sameEntry(locks.value,lockName,lockState,nullptr))return disabled();
    FD input(openat(directory,intentName,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK));
    struct stat before{},after{};
    if(input.value<0 || !metadata(input.value,NO,&before,nullptr) || before.st_size<=0 ||
       (uint64_t)before.st_size>maximumBytes)return disabled();
    NSMutableData *data=[NSMutableData dataWithLength:(NSUInteger)before.st_size];
    size_t offset=0;
    while(offset<data.length) {
        ssize_t count=read(input.value,(uint8_t *)data.mutableBytes+offset,data.length-offset);
        if(count<0 && errno==EINTR)continue;
        if(count<=0)return disabled();
        offset+=(size_t)count;
    }
    uint8_t extra;ssize_t tail;
    do{tail=read(input.value,&extra,1);}while(tail<0&&errno==EINTR);
    if(tail!=0 || fstat(input.value,&after) || before.st_size!=after.st_size ||
       before.st_mtimespec.tv_sec!=after.st_mtimespec.tv_sec || before.st_mtimespec.tv_nsec!=after.st_mtimespec.tv_nsec)
        return disabled();
    id value=[NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:nil];
    if(![value isKindOfClass:NSDictionary.class])return disabled();
    id version=value[@"version"],enabled=value[@"enabled"],generation=value[@"generation"],updated=value[@"updatedAt"];
    if(![version isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)version)!=CFNumberGetTypeID() ||
       ![version isEqual:@1] || ![enabled isKindOfClass:NSNumber.class] ||
       CFGetTypeID((__bridge CFTypeRef)enabled)!=CFBooleanGetTypeID() ||
       ![generation isKindOfClass:NSString.class] || ![[NSUUID alloc] initWithUUIDString:generation] ||
       ![updated isKindOfClass:NSNumber.class] || !std::isfinite([updated doubleValue]) || [updated doubleValue]<=0)
        return disabled();
    return @{@"version":@1,@"enabled":enabled,@"generation":generation,@"updatedAt":updated};
}
static BOOL writeIntent(BOOL enabled,NSString **error) {
    if(error)*error=nil;
    FD directory(openDirectory(error));if(directory.value<0)return NO;
    FD locks(openLockDirectory(directory.value,error));if(locks.value<0)return NO;
    FD lock(openat(locks.value,lockName,O_RDWR|O_CREAT|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK,0600));
    struct stat lockState{};
    if(lock.value<0)return ioError(error,@"打开写入锁");
    if(!metadata(lock.value,NO,nullptr,error) || !normalize(lock.value,error))return NO;
    int result;do{result=flock(lock.value,LOCK_EX);}while(result<0&&errno==EINTR);
    if(result<0)return ioError(error,@"取得写入锁");
    if(!metadata(lock.value,NO,&lockState,error) || !sameEntry(locks.value,lockName,lockState,error))return NO;

    // Reject symlinks, hard links and special files even though atomic rename
    // would replace them, so an invalid destination is never silently repaired.
    FD previous(openat(directory.value,intentName,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK));
    struct stat previousState{};BOOL absent=NO;
    if(previous.value<0) {
        if(errno!=ENOENT)return ioError(error,@"检查现有状态");
        absent=YES;
    } else if(!metadata(previous.value,NO,&previousState,error))return NO;

    NSDictionary *record=@{@"version":@1,@"enabled":@(enabled),@"generation":NSUUID.UUID.UUIDString,
                           @"updatedAt":@(NSDate.date.timeIntervalSince1970)};
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:record format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    if(!data.length || data.length>maximumBytes)return fail(error,@"映射开关状态无法编码");
    NSString *temporary=[NSString stringWithFormat:@".%s.%@.tmp",intentName,NSUUID.UUID.UUIDString];
    FD output(openat(directory.value,temporary.UTF8String,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600));
    if(output.value<0)return ioError(error,@"创建新状态");
    auto removeTemporary=[&](){unlinkat(directory.value,temporary.UTF8String,0);};
    if(!normalize(output.value,error)){removeTemporary();return NO;}
    size_t offset=0;
    while(offset<data.length) {
        ssize_t count=write(output.value,(const uint8_t *)data.bytes+offset,data.length-offset);
        if(count<0&&errno==EINTR)continue;
        if(count<=0){ioError(error,@"写入新状态");removeTemporary();return NO;}
        offset+=(size_t)count;
    }
    if(fsync(output.value)){ioError(error,@"同步新状态");removeTemporary();return NO;}
    if(absent) {
        struct stat appeared{};
        if(fstatat(directory.value,intentName,&appeared,AT_SYMLINK_NOFOLLOW)==0 || errno!=ENOENT) {
            removeTemporary();return fail(error,@"映射开关状态已变化，请重试");
        }
    } else if(!sameEntry(directory.value,intentName,previousState,error)){removeTemporary();return NO;}
    if(renameat(directory.value,temporary.UTF8String,directory.value,intentName)) {
        ioError(error,@"提交新状态");removeTemporary();return NO;
    }
    // The commit has happened. Directory fsync is unsupported on some iOS
    // filesystems; its result must not report a false failure after commit.
    (void)fsync(directory.value);
    return YES;
}
static void post(const char *name) {
    (void)notify_post(name);
}
}

NSDictionary *OPMappingRuntimeIntent(void) {
    op_runtime_control::FD directory(op_runtime_control::openDirectory(nullptr));
    return directory.value<0 ? op_runtime_control::disabled() : op_runtime_control::readIntent(directory.value);
}
BOOL OPMappingRuntimeEnabled(void) {return [OPMappingRuntimeIntent()[@"enabled"] boolValue];}
BOOL OPSetMappingRuntimeEnabled(BOOL enabled,NSString **error) {
    if(!op_runtime_control::writeIntent(enabled,error))return NO;
    op_runtime_control::post(OPRuntimeIntentChangedNotification);return YES;
}
BOOL OPStopMappingRuntime(NSString **error) {
    if(!op_runtime_control::writeIntent(NO,error))return NO;
    op_runtime_control::post(OPRuntimeIntentChangedNotification);
    op_runtime_control::post("com.lixinmo.skytouch.original.supervisor.stop");
    op_runtime_control::post("com.lixinmo.skytouch.floating.stop");
    return YES;
}
