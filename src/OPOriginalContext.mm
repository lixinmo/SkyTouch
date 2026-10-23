#import "OPStoragePaths.h"
#import "OPOriginalContext.h"
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <mach/machine.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#include <dlfcn.h>
#include <cstdint>
#include <cstring>
#include <vector>
#include <sys/stat.h>
#include <dirent.h>
#include <fcntl.h>
#include <unistd.h>
#include <cerrno>
#include <cstdarg>
#include "../vendor/fishhook/fishhook.h"

namespace {
using SearchPaths = decltype(&NSSearchPathForDirectoriesInDomains);
static SearchPaths priorSearch = nullptr;
static void *recordedImport = nullptr;
static IMP recordedBundleMethod = nullptr;
static IMP recordedHTTPBundleMethod = nullptr;
static NSString *fixedTarget;
static NSString *fixedDocuments;
static NSString *fixedDefaultsTarget;
static const mach_header *configuredImage = nullptr;
static BOOL configured = NO;
static BOOL poisoned = NO;
static NSString *profileParent(void) { return OPDataRoot().stringByDeletingLastPathComponent; }
static constexpr uid_t profileUID=501;
static constexpr gid_t profileGID=501;

static BOOL fail(NSString **error, NSString *message) {
    if (error) *error = message;
    return NO;
}
static BOOL validTarget(NSString *target) {
    return [target isKindOfClass:NSString.class] && target.length>0 && target.length<=255 &&
        [target rangeOfString:@"^[A-Za-z0-9][A-Za-z0-9._-]{0,254}$" options:NSRegularExpressionSearch].length==target.length;
}
struct OwnedFD {
    int value=-1;
    explicit OwnedFD(int descriptor=-1):value(descriptor) {}
    ~OwnedFD() { if (value>=0) close(value); }
    OwnedFD(const OwnedFD &)=delete;
    OwnedFD &operator=(const OwnedFD &)=delete;
};
static BOOL profileError(NSString **error,NSString *operation) {
    return fail(error,[NSString stringWithFormat:@"原配置目录%@失败：%s",operation,std::strerror(errno)]);
}
static BOOL applyProfileMetadata(int fd,BOOL directory,uid_t owner,gid_t group,BOOL root,NSString **error) {
    struct stat info{};
    if (fstat(fd,&info)) return profileError(error,@"检查");
    if ((directory ? !S_ISDIR(info.st_mode) : !S_ISREG(info.st_mode)) || (!directory && info.st_nlink!=1))
        return fail(error,@"原配置树包含符号链接、硬链接或特殊文件，未修改该项目以外的内容");
    if (!root && (info.st_uid!=owner || info.st_gid!=group))
        return fail(error,@"原配置仍由 root 或其他用户持有；请先完成后台退出和专属配置权限迁移");
    if (root && (info.st_uid!=owner || info.st_gid!=group) && fchown(fd,owner,group)) return profileError(error,@"所有者迁移");
    const mode_t mode=directory ? 0700 : 0600;
    if ((info.st_mode&07777)!=mode && fchmod(fd,mode)) return profileError(error,@"权限迁移");
    return YES;
}
static int openProfileDirectory(int parent,const char *name,uid_t owner,gid_t group,BOOL root,NSString **error) {
    if (mkdirat(parent,name,0700) && errno!=EEXIST) { profileError(error,@"创建"); return -1; }
    int fd=openat(parent,name,O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_DIRECTORY|O_NONBLOCK);
    if (fd<0) { profileError(error,@"打开（禁止符号链接）"); return -1; }
    if (!applyProfileMetadata(fd,YES,owner,group,root,error)) { close(fd); return -1; }
    return fd;
}
static BOOL migrateProfileTree(int directory,uid_t owner,gid_t group,BOOL root,
                               unsigned depth,std::size_t &count,NSString **error) {
    if (depth>32) return fail(error,@"原配置目录层级过深，保留文件并停止迁移");
    DIR *stream=fdopendir(dup(directory));
    if (!stream) return profileError(error,@"枚举");
    BOOL result=YES;
    while (result) {
        errno=0; dirent *entry=readdir(stream);
        if (!entry) { if (errno) result=profileError(error,@"枚举"); break; }
        if (!std::strcmp(entry->d_name,".") || !std::strcmp(entry->d_name,"..")) continue;
        if (++count>20000) { result=fail(error,@"原配置条目过多，保留文件并停止迁移"); break; }
        struct stat info{};
        if (fstatat(directory,entry->d_name,&info,AT_SYMLINK_NOFOLLOW)) { result=profileError(error,@"检查条目"); break; }
        if (!S_ISDIR(info.st_mode) && !S_ISREG(info.st_mode)) {
            result=fail(error,@"原配置树包含符号链接或特殊文件，保留文件并停止迁移"); break;
        }
        const BOOL isDirectory=S_ISDIR(info.st_mode);
        OwnedFD child(openat(directory,entry->d_name,O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK|(isDirectory ? O_DIRECTORY : 0)));
        if (child.value<0) { result=profileError(error,@"打开条目"); break; }
        result=applyProfileMetadata(child.value,isDirectory,owner,group,root,error);
        if (result && isDirectory) result=migrateProfileTree(child.value,owner,group,root,depth+1,count,error);
    }
    closedir(stream);
    return result;
}
// parent is the existing Application Support directory; only children created
// below com.lixinmo.skytouch are changed. FD-relative traversal never follows a
// profile entry to another application directory.
static BOOL prepareProfileAtParent(int parent,NSString *target,uid_t owner,gid_t group,BOOL root,NSString **error) {
    OwnedFD project(openProfileDirectory(parent,"com.lixinmo.skytouch",owner,group,root,error));
    if (project.value<0) return NO;
    OwnedFD profiles(openProfileDirectory(project.value,"Profiles",owner,group,root,error));
    if (profiles.value<0) return NO;
    OwnedFD profile(openProfileDirectory(profiles.value,target.UTF8String,owner,group,root,error));
    if (profile.value<0) return NO;
    OwnedFD documents(openProfileDirectory(profile.value,"Documents",owner,group,root,error));
    if (documents.value<0) return NO;
    OwnedFD cfg(openProfileDirectory(documents.value,"cfg",owner,group,root,error));
    if (cfg.value<0) return NO;
    OwnedFD tmp(openProfileDirectory(documents.value,"tmp",owner,group,root,error));
    if (tmp.value<0) return NO;
    std::size_t count=0;
    return migrateProfileTree(profile.value,owner,group,root,0,count,error);
}
static const char *const defaultsFile="skytouch-original-defaults.plist";
static NSArray<NSString *> *originalDefaultsKeys() {
    return @[@"changeConfiguration",@"isFirstDown",@"isUpdateDown",@"firstPointA_x",@"firstPointA_y",@"1800"];
}
// The envelope prevents accidentally treating a vendor account archive or
// another target's copied preference file as this target's mirror.
static NSDictionary *readDefaultsMirror(int documents,NSString *target,NSString **error) {
    OwnedFD input(openat(documents,defaultsFile,O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK));
    if (input.value<0) {
        if (errno==ENOENT) return @{}; // New target: explicitly clear all six keys.
        profileError(error,@"读取专属偏好"); return nil;
    }
    struct stat info{};
    if (fstat(input.value,&info) || !S_ISREG(info.st_mode) || info.st_nlink!=1 || info.st_size<=0 || info.st_size>65536) {
        fail(error,@"原偏好镜像不是合法的小型普通文件"); return nil;
    }
    NSMutableData *data=[NSMutableData dataWithLength:static_cast<NSUInteger>(info.st_size)];
    size_t offset=0;
    while (offset<data.length) {
        ssize_t size=read(input.value,static_cast<char *>(data.mutableBytes)+offset,data.length-offset);
        if (size<0 && errno==EINTR) continue;
        if (size<=0) { fail(error,@"读取原偏好镜像失败，未改动当前偏好"); return nil; }
        offset+=static_cast<size_t>(size);
    }
    id plist=[NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:nil];
    if (![plist isKindOfClass:NSDictionary.class] || ![plist[@"version"] isEqual:@1] ||
        ![plist[@"targetBundleID"] isEqual:target] || ![plist[@"values"] isKindOfClass:NSDictionary.class]) {
        fail(error,@"原偏好镜像格式或目标不匹配，未改动当前偏好"); return nil;
    }
    NSDictionary *values=plist[@"values"];
    for (id key in values) if (![originalDefaultsKeys() containsObject:key]) {
        fail(error,@"原偏好镜像包含未授权键，未改动当前偏好"); return nil;
    }
    return values;
}
static BOOL importDefaultsMirror(int documents,NSString *target,NSUserDefaults *defaults,NSString **error) {
    NSDictionary *values=readDefaultsMirror(documents,target,error);
    if (!values) return NO;
    for (NSString *key in originalDefaultsKeys()) {
        id value=values[key];
        if (value) [defaults setObject:value forKey:key];
        else [defaults removeObjectForKey:key];
    }
    return [defaults synchronize] ? YES : fail(error,@"原偏好已恢复到内存，但写入本进程偏好域失败");
}
static BOOL exportDefaultsMirror(int documents,NSString *target,NSUserDefaults *defaults,
                                uid_t owner,gid_t group,BOOL root,NSString **error) {
    NSMutableDictionary *values=[NSMutableDictionary dictionary];
    for (NSString *key in originalDefaultsKeys()) {
        id value=[defaults objectForKey:key]; if (value) values[key]=value;
    }
    NSError *serializationError=nil;
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:@{@"version":@1,@"targetBundleID":target,@"values":values}
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:&serializationError];
    if (!data.length || data.length>65536) return fail(error,@"原偏好不是合法的小型 plist，旧镜像已保留");
    struct stat existing{};
    if (fstatat(documents,defaultsFile,&existing,AT_SYMLINK_NOFOLLOW)==0) {
        if (!S_ISREG(existing.st_mode) || existing.st_nlink!=1) return fail(error,@"原偏好镜像路径是链接或特殊文件，未覆盖");
    } else if (errno!=ENOENT) return profileError(error,@"检查偏好镜像路径");
    NSString *temporary=[NSString stringWithFormat:@".skytouch-defaults-%@.tmp",NSUUID.UUID.UUIDString];
    OwnedFD output(openat(documents,temporary.UTF8String,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600));
    if (output.value<0) return profileError(error,@"创建偏好镜像临时文件");
    BOOL result=applyProfileMetadata(output.value,NO,owner,group,root,error);
    size_t offset=0;
    while (result && offset<data.length) {
        ssize_t size=write(output.value,static_cast<const char *>(data.bytes)+offset,data.length-offset);
        if (size<0 && errno==EINTR) continue;
        if (size<=0) { result=profileError(error,@"写入偏好镜像"); break; }
        offset+=static_cast<size_t>(size);
    }
    if (result && fsync(output.value)) result=profileError(error,@"同步偏好镜像");
    if (result && renameat(documents,temporary.UTF8String,documents,defaultsFile)) result=profileError(error,@"替换偏好镜像");
    if (!result) unlinkat(documents,temporary.UTF8String,0);
    return result;
}
static int openPreparedDocuments(NSString *target,NSString **error) {
    if (!OPPrepareSharedOriginalProfile(target,error)) return -1;
    OwnedFD directory(open(profileParent().fileSystemRepresentation,O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_DIRECTORY|O_NONBLOCK));
    if (directory.value<0) { profileError(error,@"打开偏好父目录"); return -1; }
    for (NSString *part in @[@"com.lixinmo.skytouch",@"Profiles",target,@"Documents"]) {
        const int next=openat(directory.value,part.fileSystemRepresentation,O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_DIRECTORY|O_NONBLOCK);
        if (next<0) { profileError(error,@"打开专属偏好目录"); return -1; }
        close(directory.value); directory.value=next;
    }
    const int result=directory.value; directory.value=-1; return result;
}

static NSArray<NSString *> *searchPaths(NSSearchPathDirectory directory,
                                       NSSearchPathDomainMask domains, BOOL expandTilde) {
    if (directory == NSDocumentDirectory && domains == NSUserDomainMask && fixedDocuments)
        return @[fixedDocuments];
    return priorSearch ? priorSearch(directory, domains, expandTilde) : @[];
}

static NSString *bundleIdentifier(id, SEL) { return fixedTarget; }
// No forwarding, formatting, vararg inspection or secondary logging. These
// replace imports only in the verified original image, never in the host.
static void silentOriginalLog(NSString *, ...) {}
static void silentOriginalLogv(NSString *, va_list) {}

static bool inRange(std::uint64_t offset, std::uint64_t size,
                    std::uint64_t start, std::uint64_t length) {
    return offset >= start && offset - start <= length && size <= length - (offset - start);
}

static bool named(const char value[16], const char *name) {
    return std::strncmp(value, name, 16) == 0;
}

// Inspection only: fishhook performs every import-slot write. Enumerating the
// exact slots is necessary because its return value does not report vm_protect
// failure and its `replaced` output is assigned BEFORE a successful slot write.
static BOOL importSlots(const mach_header *header, intptr_t slide,
                        std::vector<void **> &slots, NSString **error,
                        const char *symbolName="_NSSearchPathForDirectoriesInDomains",BOOL required=YES) {
    const auto *mh = reinterpret_cast<const mach_header_64 *>(header);
    if (mh->magic != MH_MAGIC_64 || mh->filetype != MH_DYLIB)
        return fail(error, @"原库不是预期的 64 位动态库");
    const bool matchingCPU = mh->cputype == CPU_TYPE_ARM64 && mh->cpusubtype == CPU_SUBTYPE_ARM64_ALL;
    if (!matchingCPU) return fail(error, @"原库 context 仅支持已验证的 arm64 原始镜像");
    if (mh->sizeofcmds > 1024 * 1024 || mh->ncmds > mh->sizeofcmds / sizeof(load_command))
        return fail(error, @"原库 load commands 不合法");
    const auto *commands = reinterpret_cast<const std::uint8_t *>(mh) + sizeof(*mh);
    std::size_t position = 0;
    const segment_command_64 *linkedit = nullptr;
    const symtab_command *symbols = nullptr;
    const dysymtab_command *indirect = nullptr;
    std::vector<const segment_command_64 *> segments;
    for (std::uint32_t i = 0; i < mh->ncmds; ++i) {
        if (!inRange(position, sizeof(load_command), 0, mh->sizeofcmds))
            return fail(error, @"原库 load-command 表越界");
        const auto *command = reinterpret_cast<const load_command *>(commands + position);
        if (command->cmdsize < sizeof(load_command) || command->cmdsize % 8 ||
            !inRange(position, command->cmdsize, 0, mh->sizeofcmds))
            return fail(error, @"原库 load-command 长度无效");
        if (command->cmd == LC_SEGMENT_64) {
            if (command->cmdsize < sizeof(segment_command_64)) return fail(error, @"原库 segment 缺失");
            const auto *segment = reinterpret_cast<const segment_command_64 *>(command);
            if (sizeof(*segment) + static_cast<std::uint64_t>(segment->nsects) * sizeof(section_64) != command->cmdsize)
                return fail(error, @"原库 section 表长度无效");
            segments.push_back(segment);
            if (named(segment->segname, SEG_LINKEDIT)) {
                if (linkedit) return fail(error, @"原库存在重复 __LINKEDIT");
                linkedit = segment;
            }
        } else if (command->cmd == LC_SYMTAB) {
            if (symbols || command->cmdsize != sizeof(symtab_command)) return fail(error, @"原库符号表无效");
            symbols = reinterpret_cast<const symtab_command *>(command);
        } else if (command->cmd == LC_DYSYMTAB) {
            if (indirect || command->cmdsize != sizeof(dysymtab_command)) return fail(error, @"原库间接符号表无效");
            indirect = reinterpret_cast<const dysymtab_command *>(command);
        }
        position += command->cmdsize;
    }
    if (position != mh->sizeofcmds || !linkedit || !symbols || !indirect || !indirect->nindirectsyms)
        return fail(error, @"原库缺少可检查的传统导入表，未尝试其他补丁方式");
    if (!inRange(symbols->symoff, static_cast<std::uint64_t>(symbols->nsyms) * sizeof(nlist_64), linkedit->fileoff, linkedit->filesize) ||
        !inRange(symbols->stroff, symbols->strsize, linkedit->fileoff, linkedit->filesize) ||
        !inRange(indirect->indirectsymoff, static_cast<std::uint64_t>(indirect->nindirectsyms) * sizeof(std::uint32_t), linkedit->fileoff, linkedit->filesize))
        return fail(error, @"原库导入表超出 __LINKEDIT");
    const auto base = static_cast<std::uintptr_t>(slide) + linkedit->vmaddr - linkedit->fileoff;
    const auto *symtab = reinterpret_cast<const nlist_64 *>(base + symbols->symoff);
    const auto *strings = reinterpret_cast<const char *>(base + symbols->stroff);
    const auto *indices = reinterpret_cast<const std::uint32_t *>(base + indirect->indirectsymoff);
    for (const auto *segment : segments) {
        if (!named(segment->segname, SEG_DATA) && !named(segment->segname, "__DATA_CONST")) continue;
        const auto *sections = reinterpret_cast<const section_64 *>(segment + 1);
        for (std::uint32_t i = 0; i < segment->nsects; ++i) {
            const auto &section = sections[i];
            const auto type = section.flags & SECTION_TYPE;
            if (type != S_LAZY_SYMBOL_POINTERS && type != S_NON_LAZY_SYMBOL_POINTERS) continue;
            if (section.size % sizeof(void *) || !inRange(section.addr, section.size, segment->vmaddr, segment->vmsize))
                return fail(error, @"原库导入槽位 section 不合法");
            const auto count = section.size / sizeof(void *);
            if (!inRange(section.reserved1, count, 0, indirect->nindirectsyms))
                return fail(error, @"原库导入槽位索引越界");
            auto **bindings = reinterpret_cast<void **>(static_cast<std::uintptr_t>(slide) + section.addr);
            for (std::uint64_t index = 0; index < count; ++index) {
                const std::uint32_t symbolIndex = indices[section.reserved1 + index];
                if (symbolIndex & (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) continue;
                if (symbolIndex >= symbols->nsyms) return fail(error, @"原库导入符号索引越界");
                const auto stringIndex = symtab[symbolIndex].n_un.n_strx;
                if (stringIndex >= symbols->strsize || !std::memchr(strings + stringIndex, 0, symbols->strsize - stringIndex))
                    return fail(error, @"原库符号字符串越界");
                if (std::strcmp(strings + stringIndex, symbolName) == 0)
                    slots.push_back(&bindings[index]);
            }
        }
    }
    if (required && slots.empty()) return fail(error, @"原库没有预期的函数导入");
    return YES;
}


static BOOL slotsMatch(const std::vector<void **> &slots, void *expected) {
    for (void **slot : slots) if (*slot != expected) return NO;
    return YES;
}

static BOOL executableAddress(void *pointer) {
    vm_address_t address = reinterpret_cast<std::uintptr_t>(pointer);
    const vm_address_t requested = address;
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t info{};
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    const kern_return_t result = vm_region_64(mach_task_self(), &address, &size,
        VM_REGION_BASIC_INFO_64, reinterpret_cast<vm_region_info_t>(&info), &count, &object);
    if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
    if (result != KERN_SUCCESS || requested < address || requested - address >= size) return NO;
    if (info.protection & VM_PROT_EXECUTE) return YES;
    // A dyld shared-cache parent submap can report READ even when the leaf
    // containing the function is executable. Query the actual leaf before
    // rejecting a legitimate Foundation/RootHide function address.
    natural_t depth = 0;
    for (unsigned attempt = 0; attempt < 16; ++attempt) {
        address = requested;
        size = 0;
        vm_region_submap_info_data_64_t leaf{};
        count = VM_REGION_SUBMAP_INFO_COUNT_64;
        const kern_return_t leafResult = vm_region_recurse_64(mach_task_self(), &address, &size, &depth,
            reinterpret_cast<vm_region_recurse_info_t>(&leaf), &count);
        if (leafResult != KERN_SUCCESS || requested < address || requested - address >= size) return NO;
        if (!leaf.is_submap) return (leaf.protection & VM_PROT_EXECUTE) != 0;
        ++depth;
    }
    return NO;
}
} // namespace

NSString *OPOriginalDocumentsForTarget(NSString *targetBundleID) {
    if (!validTarget(targetBundleID)) return nil;
    NSString *profiles=[OPDataRoot() stringByAppendingPathComponent:@"Profiles"];
    return [[profiles stringByAppendingPathComponent:targetBundleID] stringByAppendingPathComponent:@"Documents"];
}

BOOL OPPrepareSharedOriginalProfile(NSString *targetBundleID,NSString **error) {
    if (error) *error=nil;
    if (!validTarget(targetBundleID)) return fail(error,@"目标 bundle ID 不合法");
    const uid_t caller=geteuid();
    if (caller!=0 && caller!=profileUID) return fail(error,@"只有 root 后台或 mobile 配置 App 可以准备原配置");
    OwnedFD parent(open(profileParent().fileSystemRepresentation,O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_DIRECTORY|O_NONBLOCK));
    if (parent.value<0) return profileError(error,@"打开专属树的现有父目录");
    return prepareProfileAtParent(parent.value,targetBundleID,profileUID,profileGID,caller==0,error);
}

BOOL OPImportOriginalProfileDefaults(NSString *targetBundleID,NSString **error) {
    if (error) *error=nil;
    if (![NSThread isMainThread] || !validTarget(targetBundleID)) return fail(error,@"原偏好必须在主线程为合法目标恢复");
    if ((configured && ![fixedTarget isEqual:targetBundleID]) ||
        (fixedDefaultsTarget && ![fixedDefaultsTarget isEqual:targetBundleID]))
        return fail(error,@"原偏好会话已固定，切换目标必须重启配置或引擎进程");
    if (fixedDefaultsTarget) return YES; // Do not overwrite this session's unsaved changes.
    OwnedFD documents(openPreparedDocuments(targetBundleID,error));
    if (documents.value<0) return NO;
    if (!importDefaultsMirror(documents.value,targetBundleID,NSUserDefaults.standardUserDefaults,error)) return NO;
    fixedDefaultsTarget=[targetBundleID copy];
    return YES;
}

BOOL OPExportOriginalProfileDefaults(NSString *targetBundleID,NSString **error) {
    if (error) *error=nil;
    if (![NSThread isMainThread] || !validTarget(targetBundleID) || ![fixedDefaultsTarget isEqual:targetBundleID] ||
        (configured && ![fixedTarget isEqual:targetBundleID]))
        return fail(error,@"只能导出本进程已恢复且固定目标的原偏好");
    OwnedFD documents(openPreparedDocuments(targetBundleID,error));
    if (documents.value<0) return NO;
    return exportDefaultsMirror(documents.value,targetBundleID,NSUserDefaults.standardUserDefaults,
                                profileUID,profileGID,geteuid()==0,error);
}

BOOL OPConfigureOriginalContext(void *handle, NSString *targetBundleID,
                                NSString *documentsDirectory, NSString **error) {
    if (error) *error = nil;
    if (![NSThread isMainThread] || !handle)
        return fail(error, @"原库 context 必须在主线程使用有效 dlopen handle 配置");
    if (poisoned) return fail(error, @"此前 context 安装未能完整回退；禁止启动原界面，请结束此宿主进程");
    if (!validTarget(targetBundleID))
        return fail(error, @"目标 bundle ID 不合法");
    if (fixedDefaultsTarget && ![fixedDefaultsTarget isEqual:targetBundleID])
        return fail(error,@"原库目标与本进程已恢复的原偏好目标不一致");
    if (![documentsDirectory isKindOfClass:NSString.class] || !documentsDirectory.isAbsolutePath ||
        [documentsDirectory rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound ||
        [documentsDirectory.pathComponents containsObject:@".."])
        return fail(error, @"原配置目录必须是明确的绝对路径");
    NSString *documents = documentsDirectory.stringByStandardizingPath;
    if ([documents isEqual:@"/"]) return fail(error, @"不能把根目录作为原配置 Documents");
    if (![documents isEqualToString:OPOriginalDocumentsForTarget(targetBundleID)])
        return fail(error,@"原配置 Documents 必须是本项目对应目标的专属目录");

    void *classSymbol = dlsym(handle, "OBJC_CLASS_$_FLEXUtility");
    Class utility = NSClassFromString(@"FLEXUtility");
    Dl_info imageInfo{}, methodInfo{};
    if (!classSymbol || (__bridge void *)utility != classSymbol || !dladdr(classSymbol, &imageInfo) || !imageInfo.dli_fbase)
        return fail(error, @"FLEXUtility 不属于提供的原库 handle，拒绝替换其他镜像");
    void *httpClassSymbol=dlsym(handle,"OBJC_CLASS_$_FZHttpTool");
    Class httpTool=NSClassFromString(@"FZHttpTool");
    Dl_info httpClassInfo{},httpMethodInfo{};
    if (!httpClassSymbol || (__bridge void *)httpTool!=httpClassSymbol ||
        !dladdr(httpClassSymbol,&httpClassInfo) || httpClassInfo.dli_fbase!=imageInfo.dli_fbase)
        return fail(error,@"FZHttpTool 不属于同一原库 handle，拒绝替换其他镜像");
    const auto *header = static_cast<const mach_header *>(imageInfo.dli_fbase);
    if (configured) {
        if (configuredImage == header && [fixedTarget isEqual:targetBundleID] && [fixedDocuments isEqual:documents]) return YES;
        return fail(error, @"原配置会话已固定，不能在运行中切换目标或 Documents");
    }
    const SEL selector = sel_registerName("getLocalBundleID");
    Method method = class_getClassMethod(utility, selector);
    // Exact original 64-bit Objective-C ABI: object return, self and SEL only.
    if (!method || method_getNumberOfArguments(method) != 2 ||
        !method_getTypeEncoding(method) || std::strcmp(method_getTypeEncoding(method), "@16@0:8") != 0 ||
        !dladdr(reinterpret_cast<void *>(method_getImplementation(method)), &methodInfo) || methodInfo.dli_fbase != imageInfo.dli_fbase)
        return fail(error, @"原 +[FLEXUtility getLocalBundleID] ABI 或实现归属不符");
    Method httpMethod=class_getClassMethod(httpTool,sel_registerName("getBundleId"));
    if (!httpMethod || method_getNumberOfArguments(httpMethod)!=2 ||
        !method_getTypeEncoding(httpMethod) || std::strcmp(method_getTypeEncoding(httpMethod),"@16@0:8")!=0 ||
        !dladdr(reinterpret_cast<void *>(method_getImplementation(httpMethod)),&httpMethodInfo) ||
        httpMethodInfo.dli_fbase!=imageInfo.dli_fbase)
        return fail(error,@"原 +[FZHttpTool getBundleId] ABI 或实现归属不符");
    intptr_t slide = 0;
    BOOL found = NO;
    for (std::uint32_t i = 0; i < _dyld_image_count(); ++i) {
        if (_dyld_get_image_header(i) == header) { slide = _dyld_get_image_vmaddr_slide(i); found = YES; break; }
    }
    if (!found) return fail(error, @"无法定位原库的已加载 Mach-O 镜像");
    std::vector<void **> slots,logSlots,logvSlots;
    if (!importSlots(header, slide, slots, error) ||
        !importSlots(header,slide,logSlots,error,"_NSLog",NO) ||
        !importSlots(header,slide,logvSlots,error,"_NSLogv",NO)) return NO;
    // Preserve the original image's already-bound implementation. RootHide may
    // legitimately wrap Foundation for its virtual filesystem; bypassing that
    // wrapper for unrelated directories would change the original host's ABI.
    void *realSearch = *slots.front();
    Dl_info priorInfo{};
    const BOOL hasPriorImage = realSearch && dladdr(realSearch, &priorInfo);
    const BOOL sameImport = realSearch && slotsMatch(slots, realSearch);
    const BOOL ownStub = hasPriorImage && priorInfo.dli_fbase == imageInfo.dli_fbase;
    const BOOL executable = realSearch && executableAddress(realSearch);
    if (!realSearch || !slotsMatch(slots, realSearch) || realSearch == reinterpret_cast<void *>(searchPaths) ||
        ownStub || !executable)
        return fail(error, [NSString stringWithFormat:@"原 Documents 导入不可用（统一=%d，自身stub=%d，可执行=%d）；请使用 RTLD_NOW 加载原库", sameImport, ownStub, executable]);
    void *realLog=logSlots.empty() ? nullptr : *logSlots.front();
    void *realLogv=logvSlots.empty() ? nullptr : *logvSlots.front();
    auto validLogImport=[&](const std::vector<void **> &entries,void *previous) {
        if (entries.empty()) return true;
        Dl_info owner{};
        return previous && slotsMatch(entries,previous) && executableAddress(previous) &&
            previous!=reinterpret_cast<void *>(silentOriginalLog) && previous!=reinterpret_cast<void *>(silentOriginalLogv) &&
            (!dladdr(previous,&owner) || owner.dli_fbase!=imageInfo.dli_fbase);
    };
    if (!validLogImport(logSlots,realLog) || !validLogImport(logvSlots,realLogv))
        return fail(error,@"原库日志导入不可验证，未启用登录或原界面");
    @try {
        if (!OPPrepareSharedOriginalProfile(targetBundleID,error)) return NO;
    } @catch (NSException *exception) {
        return fail(error, [NSString stringWithFormat:@"准备原配置目录失败：%@", exception.reason ?: exception.name]);
    }
    fixedTarget = [targetBundleID copy];
    fixedDocuments = [documents copy];
    priorSearch = reinterpret_cast<SearchPaths>(realSearch);
    const IMP expectedMethod = method_getImplementation(method);
    const IMP expectedHTTPMethod=method_getImplementation(httpMethod);
    void *recordedLog=nullptr,*recordedLogv=nullptr;
    std::vector<rebinding> requests={{"NSSearchPathForDirectoriesInDomains",reinterpret_cast<void *>(searchPaths),&recordedImport}};
    if (!logSlots.empty()) requests.push_back({"NSLog",reinterpret_cast<void *>(silentOriginalLog),&recordedLog});
    if (!logvSlots.empty()) requests.push_back({"NSLogv",reinterpret_cast<void *>(silentOriginalLogv),&recordedLogv});
    auto restoreImports=[&]() {
        std::vector<rebinding> undo={{"NSSearchPathForDirectoriesInDomains",realSearch,nullptr}};
        if (!logSlots.empty()) undo.push_back({"NSLog",realLog,nullptr});
        if (!logvSlots.empty()) undo.push_back({"NSLogv",realLogv,nullptr});
        rebind_symbols_image(const_cast<mach_header *>(header),slide,undo.data(),undo.size());
        return slotsMatch(slots,realSearch) && slotsMatch(logSlots,realLog) && slotsMatch(logvSlots,realLogv);
    };
    const int result=rebind_symbols_image(const_cast<mach_header *>(header),slide,requests.data(),requests.size());
    if (result != 0 || recordedImport != realSearch || !slotsMatch(slots, reinterpret_cast<void *>(searchPaths)) ||
        (!logSlots.empty() && (recordedLog!=realLog || !slotsMatch(logSlots,reinterpret_cast<void *>(silentOriginalLog)))) ||
        (!logvSlots.empty() && (recordedLogv!=realLogv || !slotsMatch(logvSlots,reinterpret_cast<void *>(silentOriginalLogv))))) {
        // Use the same image-only API to restore imports; never hand-write a
        // Mach-O pointer or report success merely because fishhook returned 0.
        poisoned = !restoreImports();
        if (!poisoned) { fixedTarget = nil; fixedDocuments = nil; recordedImport = nullptr; }
        return fail(error, poisoned ? @"原 Documents/日志导入重绑或回退失败，禁止启动原界面" : @"原 Documents/日志隔离未生效，已回退");
    }
    recordedBundleMethod = method_setImplementation(method, reinterpret_cast<IMP>(bundleIdentifier));
    if (recordedBundleMethod != expectedMethod || method_getImplementation(method) != reinterpret_cast<IMP>(bundleIdentifier)) {
        method_setImplementation(method, recordedBundleMethod ?: expectedMethod);
        poisoned = !restoreImports() || method_getImplementation(method) != (recordedBundleMethod ?: expectedMethod);
        if (!poisoned) { fixedTarget = nil; fixedDocuments = nil; recordedImport = nullptr; }
        return fail(error, @"原 bundle ID 方法替换失败，context 未完成；禁止启动原界面");
    }
    // The original helper (0x686418..0x6864ec) only reads this process's main
    // bundle ID. Cloud-sync callers use it instead of FLEXUtility. Return the
    // same fixed target here; their own game-prefix normalization stays intact.
    recordedHTTPBundleMethod=method_setImplementation(httpMethod,reinterpret_cast<IMP>(bundleIdentifier));
    if (recordedHTTPBundleMethod!=expectedHTTPMethod ||
        method_getImplementation(httpMethod)!=reinterpret_cast<IMP>(bundleIdentifier)) {
        method_setImplementation(httpMethod,recordedHTTPBundleMethod ?: expectedHTTPMethod);
        method_setImplementation(method,recordedBundleMethod ?: expectedMethod);
        poisoned=!restoreImports() || method_getImplementation(method)!=(recordedBundleMethod ?: expectedMethod) ||
            method_getImplementation(httpMethod)!=(recordedHTTPBundleMethod ?: expectedHTTPMethod);
        if (!poisoned) { fixedTarget=nil;fixedDocuments=nil;recordedImport=nullptr; }
        return fail(error,@"原云同步 bundle ID 方法替换失败，context 未完成；禁止启动原界面");
    }
    configuredImage = header;
    configured = YES;
    NSLog(@"[OriginalPort] fixed original context target=%@ docs=%@ image=%s importSlots=%lu originalSearch=%p originalSearchImage=%s originalBundleMethod=%p",
        fixedTarget, fixedDocuments, imageInfo.dli_fname ?: "(unknown)", static_cast<unsigned long>(slots.size()),
        recordedImport, hasPriorImage ? priorInfo.dli_fname : "(executable trampoline)", reinterpret_cast<void *>(recordedBundleMethod));
    return YES;
}
