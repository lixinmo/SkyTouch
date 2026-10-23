#import "OPLocalConfiguration.h"
#import "OPGlobalProfile.h"
#import "OPSessionSupervisor.h"
#import <CommonCrypto/CommonDigest.h>
#include <notify.h>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
#include <cerrno>

namespace op_local_configuration {
struct FD {int value=-1;~FD(){if(value>=0)close(value);}};
BOOL fail(NSString **error,NSString *message) {if(error)*error=message;return NO;}
NSArray<NSString *> *listKeys(void) {return @[@"gamepad_list",@"keyboard_mouse_list",@"v1_list"];}
NSArray<NSString *> *typeNames(void) {return @[@"手柄",@"键鼠",@"半柄"] ;}
NSString *lockPath(void) {
    return OPSupervisorConfigurationLockPath;
}
BOOL lockLibrary(FD &lease,NSString **error) {
    NSString *path=lockPath();
    if(!path.isAbsolutePath)return fail(error,@"本地方案锁路径未配置");
    BOOL created=NO;
    lease.value=open(path.fileSystemRepresentation,O_RDWR|O_CREAT|O_EXCL|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK,0600);
    if(lease.value>=0)created=YES;
    else if(errno==EEXIST)lease.value=open(path.fileSystemRepresentation,O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK);
    if(lease.value<0)return fail(error,@"无法读取本地方案会话锁");
    struct stat metadata{};
    if(fstat(lease.value,&metadata)!=0 || !S_ISREG(metadata.st_mode) || metadata.st_nlink!=1 || (metadata.st_mode&0022))
        return fail(error,@"本地方案会话锁格式或权限无效");
    if(metadata.st_uid!=0 && metadata.st_uid!=501)return fail(error,@"本地方案会话锁所有者无效");
    if(created && geteuid()==0 && fchown(lease.value,501,501)!=0)return fail(error,@"无法设置本地方案锁所有者");
    if(flock(lease.value,LOCK_SH|LOCK_NB)!=0)
        return fail(error,@"凌触正在编辑方案，请先保存并退出编辑后再切换");
    return YES;
}
NSString *fingerprint(NSString *target,NSInteger type,NSDictionary *plan) {
    NSData *JSON=[NSJSONSerialization dataWithJSONObject:plan options:NSJSONWritingSortedKeys error:nil];
    if(!JSON)return nil;
    NSMutableData *bytes=[[[NSString stringWithFormat:@"%@\n%ld\n",target,(long)type] dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [bytes appendData:JSON];unsigned char result[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes.bytes,(CC_LONG)bytes.length,result);
    char output[CC_SHA256_DIGEST_LENGTH*2+1];
    for(NSUInteger i=0;i<sizeof(result);++i)snprintf(output+i*2,3,"%02x",result[i]);
    return @(output);
}
// Empty current slots are normal before the first apply. Malformed mapping
// containers are rejected; legitimate unknown vendor fields are preserved.
BOOL mappingCount(NSDictionary *plan,NSUInteger *count,NSString **error) {
    *count=0;
    if(plan[@"title"] && ![plan[@"title"] isKindOfClass:NSString.class])return fail(error,@"本地方案名称格式无效");
    for(NSString *key in @[@"keys",@"joysticks",@"macros"]) {
        id list=plan[key];if(!list)continue;
        if(![list isKindOfClass:NSArray.class])return fail(error,@"本地方案映射列表格式无效");
        for(id mapping in list) {
            if(![mapping isKindOfClass:NSDictionary.class] || ![mapping count])return fail(error,@"本地方案含有空或无效映射");
            ++*count;
        }
    }
    return YES;
}
NSArray<NSDictionary *> *catalog(NSString *target,NSData *bytes,NSDictionary **document,NSString **error) {
    id decoded=[NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil];
    if(![decoded isKindOfClass:NSDictionary.class]){fail(error,@"本地方案库不是有效的 FDG 文件");return nil;}
    if(document)*document=decoded;
    NSDictionary *active=OPReadGlobalProfile(nil);NSString *activeID=nil;
    NSInteger activeType=[active[@"deviceType"] integerValue];
    if([active[@"activeProfileTarget"] isEqual:target] && activeType>=0 && activeType<3) {
        id snapshot=[NSJSONSerialization JSONObjectWithData:active[@"snapshotData"] options:0 error:nil];
        id rows=[snapshot isKindOfClass:NSDictionary.class] ? snapshot[listKeys()[activeType]] : nil;
        if([rows isKindOfClass:NSArray.class] && [rows count] && [rows[0] isKindOfClass:NSDictionary.class])
            activeID=fingerprint(target,activeType,rows[0]);
    }
    NSMutableArray *output=[NSMutableArray array];NSMutableSet *seen=[NSMutableSet set];
    for(NSInteger type=0;type<3;++type) {
        id rows=decoded[listKeys()[type]];if(!rows)continue;
        if(![rows isKindOfClass:NSArray.class]){fail(error,@"本地方案库列表格式无效");return nil;}
        for(NSUInteger index=0;index<[rows count];++index) {
            id plan=rows[index];NSUInteger count=0;
            if(![plan isKindOfClass:NSDictionary.class]){fail(error,@"本地方案库包含无效条目");return nil;}
            if(!mappingCount(plan,&count,error))return nil;
            if(!count)continue;
            NSString *identifier=fingerprint(target,type,plan);
            if(!identifier){fail(error,@"无法识别本地方案内容");return nil;}
            if([seen containsObject:identifier])continue;
            [seen addObject:identifier];
            NSString *name=[plan[@"title"] length] ? plan[@"title"] : @"未命名方案";
            [output addObject:@{@"id":identifier,@"target":target,@"name":name,@"deviceType":@(type),
                @"deviceTypeName":typeNames()[type],@"sourceIndex":@(index),@"isCurrent":@([identifier isEqual:activeID]),
                @"isSourceCurrent":@(index==0),@"mappingCount":@(count)}];
        }
    }
    return output;
}
}

NSArray<NSDictionary *> *OPLocalConfigurationsForTarget(NSString *target,NSString **error) {
    using namespace op_local_configuration;if(error)*error=nil;
    FD lease;if(!lockLibrary(lease,error))return nil;
    NSData *bytes=OPReadLocalProfileLibrary(target,error);if(!bytes)return nil;
    return catalog(target,bytes,nullptr,error);
}
BOOL OPApplyLocalConfiguration(NSString *target,NSString *identifier,NSString *sourceDisplayName,NSString **error) {
    using namespace op_local_configuration;if(error)*error=nil;
    if(![identifier isKindOfClass:NSString.class] || identifier.length!=64 ||
       ![sourceDisplayName isKindOfClass:NSString.class])return fail(error,@"请选择有效的本地方案");
    FD lease;if(!lockLibrary(lease,error))return NO;
    NSData *bytes=OPReadLocalProfileLibrary(target,error);if(!bytes)return NO;
    NSDictionary *document=nil;NSArray *rows=catalog(target,bytes,&document,error);if(!rows)return NO;
    NSDictionary *selected=nil;
    for(NSDictionary *row in rows)if([row[@"id"] isEqual:identifier]){selected=row;break;}
    if(!selected)return fail(error,@"该方案已修改或删除，请刷新列表后重新选择");
    NSInteger type=[selected[@"deviceType"] integerValue];NSUInteger index=[selected[@"sourceIndex"] unsignedIntegerValue];
    NSString *key=listKeys()[type];NSMutableDictionary *snapshot=[document mutableCopy];
    NSMutableArray *plans=[document[key] mutableCopy];
    plans[0]=plans[index];snapshot[key]=plans;
    NSData *snapshotBytes=[NSJSONSerialization dataWithJSONObject:snapshot options:NSJSONWritingSortedKeys error:nil];
    if(!snapshotBytes)return fail(error,@"无法创建所选方案快照");
    if(!OPPublishGlobalProfileSnapshot(target,sourceDisplayName,type,snapshotBytes,error))return NO;
    notify_post(OPSupervisorProfileUpdatedNotification);
    return YES;
}
