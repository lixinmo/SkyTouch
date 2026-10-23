#import "OPGlobalProfile.h"
#import "OPOriginalContext.h"
#import "OPStoragePaths.h"
#import <CommonCrypto/CommonDigest.h>
#include <fcntl.h>
#include <dirent.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
#include <cerrno>
#include <cstring>

namespace op_global_profile {
static constexpr NSUInteger maximumFDG=16*1024*1024;
static constexpr NSUInteger maximumManifest=256*1024;
static const char *const controlName="ConfiguredTargets.plist";
static const char *const defaultsName="skytouch-original-defaults.plist";
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
    return fail(error,[NSString stringWithFormat:@"全局方案%@失败：%s",operation,std::strerror(errno)]);
}
static NSString *projectRoot(void) {
    return OPDataRoot();
}
static BOOL validTarget(id target) {
    return [target isKindOfClass:NSString.class] && [target length]>0 && [target length]<=255 &&
        [target rangeOfString:@"^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$" options:NSRegularExpressionSearch].length==[target length];
}
static BOOL integer(id value,NSInteger *result) {
    if(![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value)!=CFNumberGetTypeID() ||
       CFNumberIsFloatType((__bridge CFNumberRef)value))return NO;
    long long number=[value longLongValue];
    if([value compare:@(number)]!=NSOrderedSame || number<NSIntegerMin || number>NSIntegerMax)return NO;
    if(result)*result=(NSInteger)number;return YES;
}
static BOOL owned(const struct stat &state) {
    return state.st_uid==0 || state.st_uid==501;
}
static BOOL metadata(int descriptor,BOOL directory,NSString **error) {
    struct stat state{};
    if(fstat(descriptor,&state))return ioError(error,@"检查文件");
    if((directory ? !S_ISDIR(state.st_mode) : (!S_ISREG(state.st_mode)||state.st_nlink!=1)) ||
       !owned(state) || (state.st_mode&0022))
        return fail(error,@"全局方案包含链接、特殊文件或不安全的所有者/写入权限");
    return YES;
}
static BOOL newMetadata(int descriptor,BOOL directory,NSString **error) {
    if(geteuid()==0 && fchown(descriptor,501,501))return ioError(error,@"设置文件所有者");
    if(fchmod(descriptor,directory ? 0700 : 0600))return ioError(error,@"设置文件权限");
    return metadata(descriptor,directory,error);
}
static int directoryAt(int parent,const char *name,BOOL create,NSString **error) {
    BOOL created=NO;
    if(create) {
        if(mkdirat(parent,name,0700)==0)created=YES;
        else if(errno!=EEXIST){ioError(error,@"创建目录");return -1;}
    }
    int descriptor=openat(parent,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);
    if(descriptor<0){ioError(error,@"打开目录（禁止链接）");return -1;}
    if(!(created ? newMetadata(descriptor,YES,error) : metadata(descriptor,YES,error))) {
        close(descriptor);return -1;
    }
    return descriptor;
}
static int openProject(BOOL create,NSString **error) {
    NSString *root=projectRoot();
    if(!root.length || !root.isAbsolutePath) {fail(error,@"全局方案固定目录未配置");return -1;}
    // /var is an OS-owned link on iOS. Open the fixed system parent once, then
    // traverse every project-controlled component with openat + O_NOFOLLOW.
    FD parent(open(root.stringByDeletingLastPathComponent.fileSystemRepresentation,
                   O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK));
    if(parent.value<0){ioError(error,@"打开固定父目录");return -1;}
    return directoryAt(parent.value,root.lastPathComponent.fileSystemRepresentation,create,error);
}
static NSData *readFile(int parent,const char *name,NSUInteger limit,BOOL missingOK,
                        BOOL *missing,NSString **error) {
    if(missing)*missing=NO;
    FD input(openat(parent,name,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK));
    if(input.value<0) {
        if(missingOK && errno==ENOENT){if(missing)*missing=YES;return nil;}
        ioError(error,@"读取文件");return nil;
    }
    if(!metadata(input.value,NO,error))return nil;
    struct stat before{},after{};
    if(fstat(input.value,&before)){ioError(error,@"检查文件长度");return nil;}
    if(before.st_size<=0 || (uint64_t)before.st_size>limit) {
        fail(error,@"全局方案文件为空或超过大小限制");return nil;
    }
    NSMutableData *data=[NSMutableData dataWithLength:(NSUInteger)before.st_size];
    size_t offset=0;
    while(offset<data.length) {
        ssize_t count=read(input.value,(uint8_t *)data.mutableBytes+offset,data.length-offset);
        if(count<0 && errno==EINTR)continue;
        if(count<=0){fail(error,@"全局方案文件读取不完整");return nil;}
        offset+=(size_t)count;
    }
    uint8_t extra=0;ssize_t trailing;
    do{trailing=read(input.value,&extra,1);}while(trailing<0&&errno==EINTR);
    if(trailing!=0 || fstat(input.value,&after) || before.st_dev!=after.st_dev || before.st_ino!=after.st_ino ||
       before.st_size!=after.st_size || before.st_nlink!=after.st_nlink || before.st_uid!=after.st_uid ||
       before.st_mode!=after.st_mode || before.st_mtimespec.tv_sec!=after.st_mtimespec.tv_sec ||
       before.st_mtimespec.tv_nsec!=after.st_mtimespec.tv_nsec) {
        fail(error,@"读取期间全局方案文件发生变化，请重新应用");return nil;
    }
    return [data copy];
}
static NSDictionary *plist(NSData *data,NSString **error) {
    id result=data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:nil] : nil;
    if(![result isKindOfClass:NSDictionary.class]){fail(error,@"全局方案索引格式无效");return nil;}
    return result;
}
static NSData *encode(NSDictionary *value,NSString **error) {
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:value format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    if(!data.length || data.length>maximumManifest){fail(error,@"全局方案索引过大或不能保存");return nil;}
    return data;
}
static NSString *digest(NSData *data) {
    unsigned char result[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes,(CC_LONG)data.length,result);
    char hex[CC_SHA256_DIGEST_LENGTH*2+1];
    for(NSUInteger i=0;i<sizeof(result);++i)snprintf(hex+i*2,3,"%02x",result[i]);
    return @(hex);
}
static NSArray<NSString *> *defaultKeys(void) {
    return @[@"changeConfiguration",@"isFirstDown",@"isUpdateDown",@"firstPointA_x",@"firstPointA_y",@"1800"];
}
static BOOL validDefaults(id values,NSString **error) {
    if(![values isKindOfClass:NSDictionary.class])return fail(error,@"映射偏好格式无效");
    for(id key in values)if(![defaultKeys() containsObject:key])return fail(error,@"映射偏好包含非映射字段");
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:values format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    return data.length>0 && data.length<=65536 ? YES : fail(error,@"映射偏好不是合法的小型 plist");
}
static NSDictionary *readDefaults(int documents,NSString *target,NSString **error) {
    BOOL missing=NO;
    NSData *data=readFile(documents,defaultsName,65536,YES,&missing,error);
    if(missing)return @{};
    if(!data)return nil;
    NSDictionary *mirror=plist(data,error);NSInteger version=0;
    if(!mirror || !integer(mirror[@"version"],&version) || version!=1 ||
       ![mirror[@"targetBundleID"] isEqual:target]) {
        fail(error,@"映射偏好镜像版本或来源不匹配");return nil;
    }
    NSDictionary *values=mirror[@"values"];
    return validDefaults(values,error) ? values : nil;
}
static NSDictionary *selectedPlan(NSData *fdg,NSInteger type,NSString **error) {
    if(type<0 || type>2){fail(error,@"请选择受支持的手柄方案类型");return nil;}
    id document=[NSJSONSerialization JSONObjectWithData:fdg options:0 error:nil];
    if(![document isKindOfClass:NSDictionary.class]){fail(error,@"本地方案不是有效的原版 FDG 文件");return nil;}
    NSString *key=@[@"gamepad_list",@"keyboard_mouse_list",@"v1_list"][(NSUInteger)type];
    id rows=document[key];
    if(![rows isKindOfClass:NSArray.class] || ![rows count] || ![rows[0] isKindOfClass:NSDictionary.class]) {
        fail(error,@"当前手柄类型没有已应用的本地方案；请先在原版界面选择并应用方案");return nil;
    }
    NSDictionary *plan=rows[0];NSUInteger count=0;
    // FZCFGIOCenter's recovered decoder (0x1cfdf4) and encoder (0x1d4148)
    // both use "macros" for the entity's macroList. A macro-only plan is valid.
    for(NSString *field in @[@"keys",@"joysticks",@"macros"]) {
        id mappings=plan[field];if(!mappings)continue;
        if(![mappings isKindOfClass:NSArray.class]){fail(error,@"当前方案的按键、摇杆或宏列表格式无效");return nil;}
        for(id mapping in mappings) {
            // Preserve the original's macro/gesture fields and value types.
            // Validate only the recovered outer shape, not a guessed subtype
            // schema that would discard legitimate vendor configurations.
            if(![mapping isKindOfClass:NSDictionary.class] || ![mapping count]) {
                fail(error,@"当前方案包含空的按键、摇杆或宏映射");return nil;
            }
            ++count;
        }
    }
    if(!count){fail(error,@"当前方案没有按键、摇杆或宏映射；下载到其他列表不等于已应用");return nil;}
    if(plan[@"title"] && ![plan[@"title"] isKindOfClass:NSString.class]) {
        fail(error,@"当前方案名称格式无效");return nil;
    }
    return plan;
}
static BOOL validManifest(NSDictionary *manifest,NSString **error) {
    NSInteger schema=0,type=-1;
    if(integer(manifest[@"schema"],&schema) && schema==2)
        return fail(error,@"旧记录只选择了游戏来源，尚未固定具体方案；请进入编辑并重新应用为全局方案");
    if(!integer(manifest[@"schema"],&schema) || schema!=3)
        return fail(error,@"尚未应用有效的全局方案");
    NSArray *keys=@[@"schema",@"activeProfileTarget",@"activeProfileDisplayName",@"deviceType",@"planName",@"revision",@"fdgSHA256",@"defaults"];
    if(manifest.count!=keys.count)return fail(error,@"全局方案索引含有未识别字段");
    for(id key in manifest)if(![keys containsObject:key])return fail(error,@"全局方案索引含有未识别字段");
    NSString *revision=manifest[@"revision"],*hash=manifest[@"fdgSHA256"];
    if(!validTarget(manifest[@"activeProfileTarget"]) ||
       ![manifest[@"activeProfileDisplayName"] isKindOfClass:NSString.class] ||
       ![manifest[@"planName"] isKindOfClass:NSString.class] ||
       !integer(manifest[@"deviceType"],&type) || type<0 || type>2 ||
       ![revision isKindOfClass:NSString.class] || revision.length!=36 ||
       ![[[NSUUID alloc]initWithUUIDString:revision].UUIDString isEqual:revision] ||
       ![hash isKindOfClass:NSString.class] || hash.length!=64 ||
       [hash rangeOfString:@"^[0-9a-f]{64}$" options:NSRegularExpressionSearch].length!=64)
        return fail(error,@"全局方案索引字段无效");
    return validDefaults(manifest[@"defaults"],error);
}
static BOOL existingDestination(int directory,const char *name,NSString **error) {
    struct stat state{};
    if(fstatat(directory,name,&state,AT_SYMLINK_NOFOLLOW)==0) {
        if(!S_ISREG(state.st_mode)||state.st_nlink!=1||!owned(state)||(state.st_mode&0022))
            return fail(error,@"全局方案保存位置包含链接或不安全文件，旧选择已保留");
        return YES;
    }
    return errno==ENOENT ? YES : ioError(error,@"检查保存位置");
}
static BOOL atomicWrite(int directory,const char *name,NSData *data,NSString *stage,NSString **error) {
    if(!existingDestination(directory,name,error))return NO;
    (void)stage;
    NSString *temporary=[@".global-" stringByAppendingString:NSUUID.UUID.UUIDString];
    FD output(openat(directory,temporary.UTF8String,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600));
    if(output.value<0)return ioError(error,@"创建临时文件");
    BOOL success=newMetadata(output.value,NO,error);size_t offset=0;
    while(success && offset<data.length) {
        ssize_t count=write(output.value,(const uint8_t *)data.bytes+offset,data.length-offset);
        if(count<0&&errno==EINTR)continue;
        if(count<=0){success=ioError(error,@"写入临时文件");break;}
        offset+=(size_t)count;
    }
    if(success && fsync(output.value))success=ioError(error,@"同步临时文件");
    if(success && !existingDestination(directory,name,error))success=NO;
    if(success && renameat(directory,temporary.UTF8String,directory,name))success=ioError(error,@"原子替换索引");
    if(!success)unlinkat(directory,temporary.UTF8String,0);
    // Commit is the atomic rename. Nothing after a successful control rename
    // can return failure and imply that the previous selection still exists.
    return success;
}
static int documentsAt(int root,NSString *target,NSString **error) {
    NSString *expected=[projectRoot() stringByAppendingPathComponent:[NSString stringWithFormat:@"Profiles/%@/Documents",target]];
    if(![OPOriginalDocumentsForTarget(target) isEqual:expected]) {
        fail(error,@"原版配置路径与固定项目目录不匹配");return -1;
    }
    FD profiles(directoryAt(root,"Profiles",NO,error));if(profiles.value<0)return -1;
    FD profile(directoryAt(profiles.value,target.UTF8String,NO,error));if(profile.value<0)return -1;
    return directoryAt(profile.value,"Documents",NO,error);
}
static int publicationLock(int root,BOOL exclusive,NSString **error) {
    (void)root;
    NSString *path=OPRuntimePath(@"global-publish.lock");
    if(!path.isAbsolutePath){fail(error,@"全局方案运行目录不可用");return -1;}
    FD runtime(open(path.stringByDeletingLastPathComponent.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK));
    if(runtime.value<0 || !metadata(runtime.value,YES,error)){if(runtime.value<0)ioError(error,@"打开运行目录");return -1;}
    FD lock(openat(runtime.value,path.lastPathComponent.fileSystemRepresentation,O_RDWR|O_CREAT|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK,0600));
    if(lock.value<0){ioError(error,@"打开发布锁");return -1;}
    if(!metadata(lock.value,NO,error))return -1;
    if(geteuid()==0 && !newMetadata(lock.value,NO,error))return -1;
    int result;
    // Readers wait through the bounded commit/cleanup operation rather than
    // momentarily reporting a missing mapping and stopping an active engine.
    do{result=flock(lock.value,exclusive ? LOCK_EX|LOCK_NB : LOCK_SH);}while(result && errno==EINTR);
    if(result){fail(error,@"另一次全局方案发布尚未结束，请稍后重试");return -1;}
    int descriptor=lock.value;lock.value=-1;return descriptor;
}
static BOOL revisionName(NSString *name) {
    return name.length==36 && [[[NSUUID alloc]initWithUUIDString:name].UUIDString isEqual:name];
}
static NSArray<NSString *> *directoryNames(int directory) {
    // A fresh open description avoids sharing a directory enumeration offset.
    int copy=openat(directory,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);
    if(copy<0)return nil;
    DIR *stream=fdopendir(copy);if(!stream){close(copy);return nil;}
    NSMutableArray *names=[NSMutableArray array];BOOL success=YES;
    for(;;) {
        errno=0;struct dirent *entry=readdir(stream);
        if(!entry){success=errno==0;break;}
        if(!strcmp(entry->d_name,".") || !strcmp(entry->d_name,".."))continue;
        NSString *name=[NSString stringWithUTF8String:entry->d_name];
        if(!name){success=NO;break;}[names addObject:name];
    }
    closedir(stream);return success ? names : nil;
}
static BOOL snapshotForRemoval(int directory,NSString *revision,struct stat *state) {
    if(!metadata(directory,YES,nil) || fstat(directory,state))return NO;
    NSArray *names=directoryNames(directory);
    if(names.count!=2 || ![names containsObject:@"mapping.fdg"] || ![names containsObject:@"manifest.plist"])return NO;
    NSDictionary *manifest=plist(readFile(directory,"manifest.plist",maximumManifest,NO,nullptr,nil),nil);
    if(!manifest || !validManifest(manifest,nil) || ![manifest[@"revision"] isEqual:revision])return NO;
    FD mapping(openat(directory,"mapping.fdg",O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK));
    struct stat mappingState{};
    return mapping.value>=0 && metadata(mapping.value,NO,nil) && !fstat(mapping.value,&mappingState) &&
        mappingState.st_size>0 && (uint64_t)mappingState.st_size<=maximumFDG;
}
static BOOL pruneHistory(int revisions,NSString *active,NSString **error) {
    NSArray *names=directoryNames(revisions);
    if(!names)return fail(error,@"无法枚举历史方案快照");
    NSMutableArray<NSDictionary *> *candidates=[NSMutableArray array];
    for(NSString *name in names) {
        if([name isEqual:active] || !revisionName(name))continue;
        FD directory(directoryAt(revisions,name.UTF8String,NO,nil));struct stat state{};
        if(directory.value<0 || !snapshotForRemoval(directory.value,name,&state))continue;
        [candidates addObject:@{@"revision":name,@"seconds":@(state.st_mtimespec.tv_sec),
            @"nanoseconds":@(state.st_mtimespec.tv_nsec),@"device":@(state.st_dev),@"inode":@(state.st_ino)}];
    }
    [candidates sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b) {
        NSComparisonResult result=[b[@"seconds"] compare:a[@"seconds"]];
        if(result==NSOrderedSame)result=[b[@"nanoseconds"] compare:a[@"nanoseconds"]];
        return result==NSOrderedSame ? [a[@"revision"] compare:b[@"revision"]] : result;
    }];
    BOOL success=YES;
    for(NSUInteger index=4;index<candidates.count;++index) {
        NSDictionary *candidate=candidates[index];NSString *name=candidate[@"revision"];
        FD directory(directoryAt(revisions,name.UTF8String,NO,nil));struct stat state{},named{};
        // Validate again immediately before unlinking. Never recursively erase
        // unexpected files, follow links, or touch a replaced directory.
        if(directory.value<0 || !snapshotForRemoval(directory.value,name,&state) ||
           state.st_dev!=[candidate[@"device"] longLongValue] || state.st_ino!=[candidate[@"inode"] unsignedLongLongValue] ||
           fstatat(revisions,name.UTF8String,&named,AT_SYMLINK_NOFOLLOW) || !S_ISDIR(named.st_mode) ||
           named.st_dev!=state.st_dev || named.st_ino!=state.st_ino)continue;
        if(unlinkat(directory.value,"mapping.fdg",0) || unlinkat(directory.value,"manifest.plist",0) ||
           unlinkat(revisions,name.UTF8String,AT_REMOVEDIR))success=NO;
    }
    if(success && fsync(revisions))success=NO;
    return success ? YES : fail(error,@"部分旧方案快照暂时无法回收");
}
static NSDictionary *readGlobalProfileAt(int root,NSString **error) {
    NSData *index=readFile(root,controlName,maximumManifest,NO,nullptr,error);if(!index)return nil;
    NSDictionary *manifest=plist(index,error);if(!manifest || !validManifest(manifest,error))return nil;
    FD revisions(directoryAt(root,"GlobalRevisions",NO,error));if(revisions.value<0)return nil;
    NSString *revision=manifest[@"revision"];
    FD selected(directoryAt(revisions.value,revision.UTF8String,NO,error));if(selected.value<0)return nil;
    NSDictionary *sidecar=plist(readFile(selected.value,"manifest.plist",maximumManifest,NO,nullptr,error),error);
    if(![sidecar isEqual:manifest]){fail(error,@"全局方案索引与快照描述不一致，请重新应用方案");return nil;}
    NSData *fdg=readFile(selected.value,"mapping.fdg",maximumFDG,NO,nullptr,error);if(!fdg)return nil;
    if(![digest(fdg) isEqual:manifest[@"fdgSHA256"]]){fail(error,@"全局方案快照 SHA-256 不匹配，请重新应用方案");return nil;}
    NSDictionary *plan=selectedPlan(fdg,[manifest[@"deviceType"] integerValue],error);
    if(!plan || ![(plan[@"title"] ?: @"") isEqual:manifest[@"planName"]]) {
        fail(error,@"全局方案的选中配置与快照不一致，请重新应用方案");return nil;
    }
    NSMutableDictionary *result=[manifest mutableCopy];
    result[@"snapshotPath"]=[projectRoot() stringByAppendingPathComponent:[NSString stringWithFormat:@"GlobalRevisions/%@/mapping.fdg",revision]];
    result[@"snapshotData"]=fdg;
    return result;
}
}


BOOL OPPublishGlobalProfile(NSString *sourceBundleID,NSString *sourceDisplayName,NSInteger deviceType,NSString **error) {
    using namespace op_global_profile;
    if(error)*error=nil;
    if(!validTarget(sourceBundleID) || ![sourceDisplayName isKindOfClass:NSString.class])return fail(error,@"方案来源无效");
    NSData *fdg=OPReadLocalProfileLibrary(sourceBundleID,error);
    return fdg && OPPublishGlobalProfileSnapshot(sourceBundleID,sourceDisplayName,deviceType,fdg,error);
}

NSData *OPReadLocalProfileLibrary(NSString *sourceBundleID,NSString **error) {
    using namespace op_global_profile;
    if(error)*error=nil;
    if(!validTarget(sourceBundleID)){fail(error,@"方案来源无效");return nil;}
    FD root(openProject(NO,error));if(root.value<0)return nil;
    FD documents(documentsAt(root.value,sourceBundleID,error));if(documents.value<0)return nil;
    FD cfg(directoryAt(documents.value,"cfg",NO,error));if(cfg.value<0)return nil;
    return readFile(cfg.value,"local.fdg",maximumFDG,NO,nullptr,error);
}

BOOL OPPublishGlobalProfileSnapshot(NSString *sourceBundleID,NSString *sourceDisplayName,NSInteger deviceType,NSData *snapshotData,NSString **error) {
    using namespace op_global_profile;
    if(error)*error=nil;
    if(!validTarget(sourceBundleID) || ![sourceDisplayName isKindOfClass:NSString.class])return fail(error,@"方案来源无效");
    if(![snapshotData isKindOfClass:NSData.class] || !snapshotData.length || snapshotData.length>maximumFDG)
        return fail(error,@"全局方案快照为空或超过大小限制");
    NSData *fdg=[snapshotData copy];
    FD root(openProject(NO,error));if(root.value<0)return NO;
    FD documents(documentsAt(root.value,sourceBundleID,error));if(documents.value<0)return NO;
    NSDictionary *plan=selectedPlan(fdg,deviceType,error);if(!plan)return NO;
    NSDictionary *defaults=readDefaults(documents.value,sourceBundleID,error);if(!defaults)return NO;
    if(!existingDestination(root.value,controlName,error))return NO;
    FD lock(publicationLock(root.value,YES,error));if(lock.value<0)return NO;
    FD revisions(directoryAt(root.value,"GlobalRevisions",YES,error));if(revisions.value<0)return NO;
    NSString *revision=NSUUID.UUID.UUIDString;
    if(mkdirat(revisions.value,revision.UTF8String,0700))return ioError(error,@"创建方案修订");
    FD destination(openat(revisions.value,revision.UTF8String,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK));
    if(destination.value<0)return ioError(error,@"打开新方案修订");
    BOOL success=newMetadata(destination.value,YES,error);
    NSString *hash=digest(fdg);
    NSDictionary *manifest=@{@"schema":@3,@"activeProfileTarget":sourceBundleID,@"activeProfileDisplayName":sourceDisplayName,
        @"deviceType":@(deviceType),@"planName":plan[@"title"] ?: @"",@"revision":revision,@"fdgSHA256":hash,@"defaults":defaults};
    NSData *encoded=encode(manifest,error);
    success=success && encoded && validManifest(manifest,error);
    if(success)success=atomicWrite(destination.value,"mapping.fdg",fdg,@"snapshot",error);
    if(success) {
        NSData *readback=readFile(destination.value,"mapping.fdg",maximumFDG,NO,nullptr,error);
        success=readback && [digest(readback) isEqual:hash] && [readback isEqual:fdg];
        if(!success)fail(error,@"全局方案快照回读校验失败，旧选择已保留");
    }
    if(success)success=atomicWrite(destination.value,"manifest.plist",encoded,@"manifest",error);
    if(success) {
        NSDictionary *readback=plist(readFile(destination.value,"manifest.plist",maximumManifest,NO,nullptr,error),error);
        success=[readback isEqual:manifest];
        if(!success)fail(error,@"全局方案描述回读校验失败，旧选择已保留");
    }
    if(success && (fsync(destination.value)||fsync(revisions.value)))success=ioError(error,@"同步方案修订目录");
    if(success)success=atomicWrite(root.value,controlName,encoded,@"control",error);
    if(!success) {
        // Only this unpublished UUID is removed; no source, older revision or
        // active control file is changed on a failed publication.
        unlinkat(destination.value,"mapping.fdg",0);unlinkat(destination.value,"manifest.plist",0);
        unlinkat(revisions.value,revision.UTF8String,AT_REMOVEDIR);
    }else {
        // Make the new index durable before removing any older revision it
        // supersedes. A failed directory sync leaves extra history intact.
        BOOL durable=fsync(root.value)==0;
        // The control rename has committed. Cleanup is best effort and cannot
        // report a failed apply after the new selection is already active.
        if(durable)(void)pruneHistory(revisions.value,revision,nil);
    }
    return success;
}

NSDictionary *OPReadGlobalProfile(NSString **error) {
    using namespace op_global_profile;
    if(error)*error=nil;
    FD root(openProject(NO,error));if(root.value<0)return nil;
    FD lock(publicationLock(root.value,NO,error));if(lock.value<0)return nil;
    return readGlobalProfileAt(root.value,error);
}

BOOL OPPruneGlobalProfileHistory(NSString **error) {
    using namespace op_global_profile;
    if(error)*error=nil;
    FD root(openProject(NO,error));if(root.value<0)return NO;
    FD lock(publicationLock(root.value,YES,error));if(lock.value<0)return NO;
    NSDictionary *active=readGlobalProfileAt(root.value,error);if(!active)return NO;
    FD revisions(directoryAt(root.value,"GlobalRevisions",NO,error));if(revisions.value<0)return NO;
    if(fsync(root.value))return ioError(error,@"同步当前方案索引目录");
    return pruneHistory(revisions.value,active[@"revision"],error);
}
