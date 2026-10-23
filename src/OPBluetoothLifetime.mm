#import "OPBluetoothLifetime.h"
#import "OPRuntimeControl.h"
#import "OPStoragePaths.h"
#include <cerrno>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

namespace op_bluetooth_lifetime {
static const char *const configurationName = "com.lixinmo.skytouch.original-config.lock";
static const char *const hostName = "com.lixinmo.skytouch.original-host.lock";
struct FD {
    int value;
    explicit FD(int fd) : value(fd) {}
    ~FD() { if (value >= 0) close(value); }
    FD(const FD &) = delete;
    FD &operator=(const FD &) = delete;
};
enum class Lease { Idle, InUse, Unknown };
struct Probe {
    Lease lease;
    NSString *detail;
};
static BOOL trustedOwner(uid_t uid) {
    return uid == 0 || uid == 501;
}
static BOOL validFile(const struct stat &state) {
    return S_ISREG(state.st_mode) && state.st_nlink == 1 && trustedOwner(state.st_uid);
}
static Probe unknown(NSString *operation, int code = 0) {
    return {Lease::Unknown, code ? [NSString stringWithFormat:@"%@:errno=%d", operation, code] : operation};
}
static Probe probe(int directory, const char *name) {
    // Never create, chmod, chown, truncate or repair a consumer's lock file.
    FD input(openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC));
    if (input.value < 0) {
        const int code = errno;
        return code == ENOENT ? Probe{Lease::Idle, @"missing"} : unknown(@"open", code);
    }
    struct stat before{};
    if (fstat(input.value, &before)) return unknown(@"fstat", errno);
    if (!validFile(before)) return unknown(@"unsafe-lock-file");
    int result;
    do { result = flock(input.value, LOCK_SH | LOCK_NB); } while (result < 0 && errno == EINTR);
    const int code = result < 0 ? errno : 0;
    // The open descriptor must still refer to the named stable inode. A
    // replaced/unlinked lease cannot tell us whether its replacement is busy.
    struct stat current{};
    if (fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW)) return unknown(@"recheck", errno);
    if (!validFile(current) || before.st_dev != current.st_dev || before.st_ino != current.st_ino)
        return unknown(@"lock-file-changed");
    if (!result) return {Lease::Idle, @"unlocked"};
    if (code == EWOULDBLOCK || code == EAGAIN) return {Lease::InUse, @"exclusive-consumer"};
    return unknown(@"flock", code);
}
static NSString *name(Lease lease) {
    switch (lease) {
        case Lease::Idle: return @"idle";
        case Lease::InUse: return @"in-use";
        case Lease::Unknown: return @"unknown";
    }
}
static NSDictionary *state(BOOL enabled, Probe configuration, Probe host) {
    NSMutableArray<NSString *> *reasons = [NSMutableArray array];
    if (enabled) [reasons addObject:@"mapping-enabled"];
    if (configuration.lease == Lease::InUse) [reasons addObject:@"configuration-in-use"];
    else if (configuration.lease == Lease::Unknown)
        [reasons addObject:[@"configuration-unknown:" stringByAppendingString:configuration.detail]];
    if (host.lease == Lease::InUse) [reasons addObject:@"host-in-use"];
    else if (host.lease == Lease::Unknown)
        [reasons addObject:[@"host-unknown:" stringByAppendingString:host.detail]];
    return @{@"required": @(reasons.count != 0),
             @"reason": reasons.count ? [reasons componentsJoinedByString:@","] : @"idle",
             @"mappingEnabled": @(enabled),
             @"configurationInUse": @(configuration.lease == Lease::InUse),
             @"hostInUse": @(host.lease == Lease::InUse),
             @"configurationLockState": name(configuration.lease),
             @"hostLockState": name(host.lease)};
}
}

NSDictionary *OPBluetoothLifetimeState(void) {
    using namespace op_bluetooth_lifetime;
    const BOOL enabled = OPMappingRuntimeEnabled();
    NSString *path = OPRuntimeDirectory();
    if (!path.isAbsolutePath) return state(enabled, unknown(@"invalid-directory"), unknown(@"invalid-directory"));
    FD directory(open(path.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC));
    if (directory.value < 0) {
        const int code = errno;
        const Probe unavailable = code == ENOENT ? Probe{Lease::Idle, @"missing-directory"} : unknown(@"directory-open", code);
        return state(enabled, unavailable, unavailable);
    }
    struct stat metadata{};
    if (fstat(directory.value, &metadata)) {
        Probe failed = unknown(@"directory-fstat", errno);
        return state(enabled, failed, failed);
    }
    if (!S_ISDIR(metadata.st_mode) || !trustedOwner(metadata.st_uid) || (metadata.st_mode & 0002))
        return state(enabled, unknown(@"unsafe-directory"), unknown(@"unsafe-directory"));
    return state(enabled, probe(directory.value, configurationName), probe(directory.value, hostName));
}

BOOL OPBluetoothLifetimeRequired(void) { return [OPBluetoothLifetimeState()[@"required"] boolValue]; }
