#import "OPStoragePaths.h"
#import "OPControllerIdentity.h"
#import <CoreFoundation/CoreFoundation.h>
#include <fcntl.h>
#include <notify.h>
#include <sys/stat.h>
#include <unistd.h>

NSString *const OPControllerIdentityPath=OPSettingPath(@"com.lixinmo.skytouch.controller-identity.plist");
const char *const OPControllerIdentityChangedNotification="com.lixinmo.skytouch.controller-identity.changed";

BOOL OPControllerIdentityTypeIsValid(NSInteger type) {return type>=0 && type<=2;}
static BOOL OPIdentityInteger(id value,NSInteger *result) {
    if(![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value)!=CFNumberGetTypeID() ||
       CFNumberIsFloatType((__bridge CFNumberRef)value) || [value compare:@0]==NSOrderedAscending ||
       [value compare:@(NSIntegerMax)]==NSOrderedDescending)return NO;
    *result=[value integerValue];return YES;
}
static NSDictionary *OPIdentitySanitize(id value) {
    if(![value isKindOfClass:NSDictionary.class])return nil;
    NSInteger version=0,type=-1;
    id identifier=value[@"identifier"],name=value[@"name"];
    if(!OPIdentityInteger(value[@"version"],&version)||version!=1 ||
       !OPIdentityInteger(value[@"peripheralType"],&type)||!OPControllerIdentityTypeIsValid(type) ||
       ![identifier isKindOfClass:NSString.class]||[identifier length]!=36 ||
       ![name isKindOfClass:NSString.class]||[name length]>256)return nil;
    NSString *uuid=[[NSUUID alloc]initWithUUIDString:identifier].UUIDString;
    if(!uuid)return nil;
    // Whitelist the four fields. Extra contents never cross the API boundary.
    return @{@"version":@1,@"identifier":uuid,@"name":name,@"peripheralType":@(type)};
}
static BOOL OPIdentityFileInfoValid(const struct stat &info) {
    return S_ISREG(info.st_mode) && info.st_nlink==1 &&
        (info.st_uid==0||info.st_uid==501) && (info.st_mode&0777)==0600 &&
        info.st_size>=0 && info.st_size<=4096;
}
static NSDictionary *OPReadControllerIdentityAtPath(NSString *path) {
    int fd=open(path.fileSystemRepresentation,O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK);
    if(fd<0)return nil;
    struct stat before{},after{};
    BOOL valid=fstat(fd,&before)==0 && OPIdentityFileInfoValid(before);
    NSMutableData *data=valid ? [NSMutableData dataWithLength:(NSUInteger)before.st_size] : nil;
    size_t offset=0;
    while(valid && offset<data.length) {
        ssize_t count=read(fd,(uint8_t *)data.mutableBytes+offset,data.length-offset);
        if(count<0 && errno==EINTR)continue;
        if(count<=0){valid=NO;break;}offset+=(size_t)count;
    }
    valid=valid && fstat(fd,&after)==0 && OPIdentityFileInfoValid(after) &&
        before.st_dev==after.st_dev && before.st_ino==after.st_ino && before.st_size==after.st_size &&
        before.st_mtimespec.tv_sec==after.st_mtimespec.tv_sec && before.st_mtimespec.tv_nsec==after.st_mtimespec.tv_nsec;
    close(fd);
    id result=valid ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:nil] : nil;
    return OPIdentitySanitize(result);
}
static BOOL OPWriteControllerIdentityAtPath(NSString *path,NSDictionary *identity) {
    NSDictionary *sanitized=OPIdentitySanitize(identity);if(!sanitized)return NO;
    struct stat existing{};
    if(lstat(path.fileSystemRepresentation,&existing)==0) {
        if(!OPIdentityFileInfoValid(existing))return NO;
    } else if(errno!=ENOENT)return NO;
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:sanitized format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    if(!data || data.length>4096)return NO;
    NSString *pattern=[path stringByAppendingString:@".XXXXXX"];
    char *temporary=strdup(pattern.fileSystemRepresentation);
    if(!temporary)return NO;
    int fd=mkstemp(temporary);
    if(fd<0){free(temporary);return NO;}
    BOOL valid=fchmod(fd,0600)==0 && (geteuid()!=0 || fchown(fd,501,501)==0);
    size_t offset=0;
    while(valid && offset<data.length) {
        ssize_t count=write(fd,(const uint8_t *)data.bytes+offset,data.length-offset);
        if(count<0 && errno==EINTR)continue;
        if(count<=0){valid=NO;break;}offset+=(size_t)count;
    }
    if(valid)valid=fsync(fd)==0;
    close(fd);
    if(valid)valid=rename(temporary,path.fileSystemRepresentation)==0;
    if(!valid)unlink(temporary);
    free(temporary);return valid;
}
NSDictionary *OPLastKnownControllerIdentity(void) {return OPReadControllerIdentityAtPath(OPControllerIdentityPath);}
BOOL OPRememberControllerIdentity(NSString *identifier,NSString *name,NSInteger type) {
    if(!identifier||!name||!OPControllerIdentityTypeIsValid(type))return NO;
    NSDictionary *identity=OPIdentitySanitize(@{@"version":@1,@"identifier":identifier,@"name":name,@"peripheralType":@(type)});
    if(!identity)return NO;
    static NSObject *lock;static NSDictionary *remembered;static int changeToken=-1;
    static dispatch_once_t once;dispatch_once(&once,^{
        lock=[NSObject new];
        // A check token uses Darwin's change state instead of disk I/O on
        // every input frame. Another consumer may have remembered a different
        // device while this App was suspended, invalidating our local cache.
        if(notify_register_check(OPControllerIdentityChangedNotification,&changeToken)!=NOTIFY_STATUS_OK)changeToken=-1;
    });
    @synchronized(lock) {
        int changed=1;
        if([remembered isEqual:identity] && changeToken>=0 &&
           notify_check(changeToken,&changed)==NOTIFY_STATUS_OK && !changed)return YES;
        remembered=nil;
        NSDictionary *saved=OPLastKnownControllerIdentity();
        const BOOL needsWrite=![saved isEqual:identity];
        if(needsWrite && !OPWriteControllerIdentityAtPath(OPControllerIdentityPath,identity))return NO;
        remembered=identity;
        if(needsWrite)notify_post(OPControllerIdentityChangedNotification);
        return YES;
    }
}
