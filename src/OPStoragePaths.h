#pragma once
#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#include <dlfcn.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <limits.h>
#include <cstdlib>
#include <cstring>
#include <cerrno>
#include <initializer_list>

// All writable paths belong to this installation's RootHide root. Production
// never accepts environment variables, falls back to native /var, or migrates
// user data on application/service startup. The installer owns migration.
NS_ASSUME_NONNULL_BEGIN
static inline NSString * _Nullable OPStorageRootFromExecutable(NSString *executable) {
    if(![executable isKindOfClass:NSString.class] || !executable.isAbsolutePath)return nil;
    NSArray<NSString *> *parts=executable.stringByStandardizingPath.pathComponents;
    NSUInteger appIndex=[parts indexOfObject:@"SkyTouch.app"];
    if(appIndex==NSNotFound || appIndex<3 || ![parts[appIndex-1] isEqual:@"Applications"])return nil;
    NSString *rootName=parts[appIndex-2];
    if([rootName rangeOfString:@"^\\.jbroot-[0-9A-Fa-f]+$" options:NSRegularExpressionSearch].length!=rootName.length)return nil;
    NSString *tail=[NSString pathWithComponents:[parts subarrayWithRange:NSMakeRange(appIndex+1,parts.count-appIndex-1)]];
    if(![@[@"SkyTouch",@"SkyTouchStorage",@"SystemMapping.bundle/SkyTouchMapping",@"SystemBluetooth.bundle/SkyTouchBLE"] containsObject:tail])return nil;
    return [NSString pathWithComponents:[parts subarrayWithRange:NSMakeRange(0,appIndex-1)]];
}
using OPStorageJBRootFunction=const char * _Nullable (* _Nullable)(const char * _Nonnull);
static inline OPStorageJBRootFunction OPStorageRootFunction(void) {
    static OPStorageJBRootFunction function=nullptr;
    static dispatch_once_t once;
    dispatch_once(&once,^{
        @autoreleasepool {
            char executable[PATH_MAX],resolved[PATH_MAX];uint32_t size=sizeof(executable);
            if(_NSGetExecutablePath(executable,&size)!=0 || !realpath(executable,resolved))return;
            NSString *root=OPStorageRootFromExecutable(@(resolved));if(!root)return;
            NSString *library=[root stringByAppendingPathComponent:@"usr/lib/libroothide.dylib"];
            // Keep the handle alive: RootHide owns the returned path cache.
            void *handle=dlopen(library.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL);
            if(!handle)return;
            auto candidate=(OPStorageJBRootFunction)dlsym(handle,"jbroot");
            const char *converted=candidate ? candidate("/") : nullptr;
            char convertedRoot[PATH_MAX],expectedRoot[PATH_MAX];
            if(!converted || !realpath(converted,convertedRoot) || !realpath(root.fileSystemRepresentation,expectedRoot) ||
                std::strcmp(convertedRoot,expectedRoot)!=0)return;
            function=candidate;
        }
    });
    return function;
}
static inline NSString * _Nullable OPJailbreakRoot(void) {
    OPStorageJBRootFunction function=OPStorageRootFunction();
    const char *path=function ? function("/") : nullptr;
    return path ? [@(path) stringByStandardizingPath] : nil;
}
// Backups belong to the ordinary iOS Media directory. Keep file links within
// the application's backup namespace; never accept a rooted or arbitrary path.
static inline BOOL OPStorageNativeBackupPathIsSafe(NSString *path) {
    if(![path isKindOfClass:NSString.class] || ![path.stringByDeletingLastPathComponent isEqual:@"/var/mobile/Media"] ||
       ![path isEqual:path.stringByStandardizingPath] || [path rangeOfString:@"\0"].location!=NSNotFound)return NO;
    NSString *name=path.lastPathComponent;
    return name.length<=160 && [name hasPrefix:@"com.lixinmo.skytouchSetting."] &&
        [name hasSuffix:@".skytouchbackup"];
}
static inline NSString * _Nullable OPStorageRootedPath(NSString *nativePath) {
    NSString *root=OPJailbreakRoot();if(!root.length || !nativePath.isAbsolutePath)return nil;
    NSString *expected=[root stringByAppendingPathComponent:[nativePath substringFromIndex:1]];
    static NSMutableDictionary<NSString *,NSString *> *verifiedPaths;
    static dispatch_once_t once;
    dispatch_once(&once,^{verifiedPaths=[NSMutableDictionary dictionary];});
    @synchronized(verifiedPaths) {
        NSString *cached=verifiedPaths[nativePath];if(cached)return cached;
        OPStorageJBRootFunction function=OPStorageRootFunction();
        const char *raw=function ? function(nativePath.fileSystemRepresentation) : nullptr;
        if(!raw)return nil;
        NSString *converted=@(raw);
        // RootHide /var legitimately links into its AppGroup; resolve both
        // through that same trusted link once. The installation root is fixed
        // for this process; high-frequency status reads reuse this result.
        if(!converted.isAbsolutePath || ![converted.stringByResolvingSymlinksInPath isEqual:expected.stringByResolvingSymlinksInPath])return nil;
        verifiedPaths[nativePath]=converted;
        return converted;
    }
}
static inline NSString * _Nullable OPDataRoot(void) {
    return OPStorageRootedPath(@"/var/mobile/Library/Application Support/com.lixinmo.skytouch");
}
static inline NSString * _Nullable OPSettingsDirectory(void) {return [OPDataRoot() stringByAppendingPathComponent:@"Settings"];}
static inline BOOL OPStorageFilenameIsSafe(NSString *name) {
    return [name isKindOfClass:NSString.class] && name.length && name.length<=255 &&
        ![name isEqual:@"."] && ![name isEqual:@".."] && [name rangeOfString:@"/"].location==NSNotFound &&
        [name rangeOfString:@"\0"].location==NSNotFound;
}
static inline NSString * _Nullable OPSettingPath(NSString *filename) {
    return OPStorageFilenameIsSafe(filename) ? [OPSettingsDirectory() stringByAppendingPathComponent:filename] : nil;
}
static inline NSString * _Nullable OPRuntimeDirectory(void) {
    return OPStorageRootedPath(@"/var/mobile/Library/Caches/com.lixinmo.skytouch/Runtime");
}
static inline NSString * _Nullable OPRuntimePath(NSString *filename) {
    return OPStorageFilenameIsSafe(filename) ? [OPRuntimeDirectory() stringByAppendingPathComponent:filename] : nil;
}
static inline BOOL OPStorageDirectoryIsOwned(int fd) {
    struct stat info{};
    const uid_t owner=501;const gid_t group=501;
    return fd>=0 && fstat(fd,&info)==0 && S_ISDIR(info.st_mode) && info.st_uid==owner && info.st_gid==group &&
        (info.st_mode&07777)==0700;
}
static inline int OPStorageOpenDirectory(NSString * _Nullable path) {
    return path.length ? open(path.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK) : -1;
}
static inline BOOL OPStorageDirectoriesReady(NSString * _Nullable * _Nullable error) {
    if(error)*error=nil;
    int data=OPStorageOpenDirectory(OPDataRoot());
    int settings=data>=0 ? openat(data,"Settings",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK) : -1;
    BOOL valid=OPStorageDirectoryIsOwned(data) && OPStorageDirectoryIsOwned(settings);
    if(settings>=0)close(settings);if(data>=0)close(data);
    if(!valid){if(error)*error=@"RootHide 数据尚未迁移或目录权限不正确，请重新安装完整包。";return NO;}
    // Caches may be purged by the OS. Recreate only our two owned components,
    // never chmod/chown a shared Library/Caches or another application's path.
    NSString *cache=OPStorageRootedPath(@"/var/mobile/Library/Caches");
    int parent=OPStorageOpenDirectory(cache);
    if(parent<0){if(error)*error=@"RootHide 缓存父目录不可用。";return NO;}
    for(const char *name : {"com.lixinmo.skytouch","Runtime"}) {
        BOOL created=mkdirat(parent,name,0700)==0;
        int child=openat(parent,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);
        if(created && child>=0 && geteuid()==0 && fchown(child,501,501)!=0){close(child);child=-1;}
        valid=OPStorageDirectoryIsOwned(child);
        close(parent);parent=child;
        if(!valid)break;
    }
    if(parent>=0)close(parent);
    if(!valid && error)*error=@"凌触运行目录不可用或权限不正确。";
    return valid;
}
NS_ASSUME_NONNULL_END
