#import "../src/OPStoragePaths.h"
#import <Foundation/Foundation.h>
#import "../src/OPHUDHost.h"
#import "../src/OPSessionSupervisor.h"
#import "../src/OPServicePaths.h"
#import "../src/OPPhoneMotionWorker.h"
#include <unistd.h>
#include <cstdio>
#include <cstring>

enum class OPMappingMode { Invalid, Supervisor, Engine, FloatingConfiguration };
static OPMappingMode OPMappingServiceArguments(int argc,const char *const *argv,NSString **session,NSString **target,NSString **launchAttempt) {
    if(session)*session=nil;if(target)*target=nil;
    if(launchAttempt)*launchAttempt=nil;
    if(argc==2 && !std::strcmp(argv[1],"--original-supervisor"))return OPMappingMode::Supervisor;
    if(argc==4 && !std::strcmp(argv[1],"--original-supervisor") && !std::strcmp(argv[2],"--launch-attempt")) {
        NSString *attempt=[NSString stringWithUTF8String:argv[3]];
        if(!OPManagedSessionIdentifierIsValid(attempt))return OPMappingMode::Invalid;
        if(launchAttempt)*launchAttempt=attempt;return OPMappingMode::Supervisor;
    }
    if(argc==4 && !std::strcmp(argv[1],"--floating-configuration") && !std::strcmp(argv[2],"--session-target")) {
        NSString *bundle=[NSString stringWithUTF8String:argv[3]];
        if(!OPManagedTargetIsValid(bundle))return OPMappingMode::Invalid;
        if(target)*target=bundle;return OPMappingMode::FloatingConfiguration;
    }
    if(argc!=7 || std::strcmp(argv[1],"--original-hud") || std::strcmp(argv[2],"--engine-session") ||
        std::strcmp(argv[3],"--managed-session") || std::strcmp(argv[5],"--session-target"))return OPMappingMode::Invalid;
    NSString *identifier=[NSString stringWithUTF8String:argv[4]],*bundle=[NSString stringWithUTF8String:argv[6]];
    if(!OPManagedSessionIdentifierIsValid(identifier) || !OPManagedTargetIsValid(bundle))return OPMappingMode::Invalid;
    if(session)*session=identifier;if(target)*target=bundle;
    return OPMappingMode::Engine;
}
static BOOL OPMappingServiceIdentityAllowed(uid_t effectiveUID,NSString *bundleID,NSString *executableName) {
    return effectiveUID==0 && [bundleID isEqual:@"SkyTouchMapping"] && [executableName isEqual:@"SkyTouchMapping"];
}

int main(int argc,char **argv) { @autoreleasepool {
    // Private child role, before storage or root HID initialization. Its helper
    // validates the inherited socket and same-executable root parent first.
    if(argc==3&&!std::strcmp(argv[1],"--phone-motion-fd")&&!std::strcmp(argv[2],"3"))
        return OPRunPhoneMotionWorker(3);
    NSString *storageError=nil;
    if(!OPStorageDirectoriesReady(&storageError)) {
        NSLog(@"[SkyTouch] Storage unavailable: %@",storageError);return 74;
    }
    if(!OPMappingServiceIdentityAllowed(geteuid(),NSBundle.mainBundle.bundleIdentifier,NSBundle.mainBundle.executablePath.lastPathComponent) ||
        !OPApplicationBundlePath()) {
        std::fputs("mapping service requires its own root service bundle\n",stderr);return 77;
    }
    NSString *session=nil,*target=nil,*launchAttempt=nil;
    switch(OPMappingServiceArguments(argc,argv,&session,&target,&launchAttempt)) {
        case OPMappingMode::Supervisor:return OPRunSessionSupervisor(launchAttempt);
        case OPMappingMode::Engine:return OPRunManagedHUD(session,target);
        case OPMappingMode::FloatingConfiguration:return OPRunFloatingConfiguration(target);
        case OPMappingMode::Invalid:
            std::fputs("mapping service requires supervisor, managed engine or floating configuration mode\n",stderr);return 64;
    }
} }
