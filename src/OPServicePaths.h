#pragma once
#import <Foundation/Foundation.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

NS_ASSUME_NONNULL_BEGIN
// The app and its nested services have separate executable/bundle identities.
// Locate shared read-only assets without changing NSBundle.mainBundle (which
// UIKit, preferences and system process accounting use for real identity).
static inline NSString * _Nullable OPApplicationPathForBundle(NSString *path,NSString *identifier) {
    if (![path isKindOfClass:NSString.class] || !path.isAbsolutePath) return nil;
    path=path.stringByStandardizingPath;
    if ([identifier isEqual:@"com.lixinmo.skytouch.app"] && [path.lastPathComponent isEqual:@"SkyTouch.app"]) return path;
    NSString *expected=[identifier isEqual:@"SkyTouchMapping"] ? @"SystemMapping.bundle" :
        [identifier isEqual:@"SkyTouchBLE"] ? @"SystemBluetooth.bundle" : nil;
    NSString *parent=path.stringByDeletingLastPathComponent;
    return expected && [path.lastPathComponent isEqual:expected] && [parent.lastPathComponent isEqual:@"SkyTouch.app"] ? parent : nil;
}
static inline NSString * _Nullable OPApplicationBundlePath(void) {
    NSBundle *bundle=NSBundle.mainBundle;
    NSString *path=OPApplicationPathForBundle(bundle.bundlePath,bundle.bundleIdentifier ?: @"");
    return path && [[[NSBundle bundleWithPath:path] bundleIdentifier] isEqual:@"com.lixinmo.skytouch.app"] ? path : nil;
}
static inline NSString * _Nullable OPMappingServiceExecutablePath(void) {
    return [OPApplicationBundlePath() stringByAppendingPathComponent:@"SystemMapping.bundle/SkyTouchMapping"];
}
// Foundation may return /private/var while the same app path standardizes to
// /var on RootHide. Compare the files, not those equivalent path spellings.
// Parent aliases are legitimate; the final executable must be a regular file.
static inline BOOL OPServiceExecutablePathsMatch(NSString * _Nullable actual,NSString * _Nullable expected) {
    if(!actual.length || !expected.length)return NO;
    int actualFD=open(actual.fileSystemRepresentation,O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK);
    if(actualFD<0)return NO;
    int expectedFD=open(expected.fileSystemRepresentation,O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK);
    struct stat actualInfo{},expectedInfo{};
    BOOL matches=expectedFD>=0 && fstat(actualFD,&actualInfo)==0 && fstat(expectedFD,&expectedInfo)==0 &&
        S_ISREG(actualInfo.st_mode) && S_ISREG(expectedInfo.st_mode) &&
        actualInfo.st_dev==expectedInfo.st_dev && actualInfo.st_ino==expectedInfo.st_ino;
    if(expectedFD>=0)close(expectedFD);
    close(actualFD);return matches;
}
NS_ASSUME_NONNULL_END
