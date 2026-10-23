#import "OPPhoneButtonClient.h"
#import "OPStoragePaths.h"
#import "OPServicePaths.h"
#import "../springboard/OPPhoneButtonTransport.hpp"
#import <notify.h>
#include <atomic>
#include <sys/file.h>

using namespace op_phone_buttons;
@interface OPPhoneButtonsConnection : NSObject {
@public
    std::atomic<bool> stopped;
    std::atomic<bool> desiredArmed;
    std::atomic<uint64_t> command;
    std::atomic<uint64_t> epoch,mainHeartbeat;
    std::atomic<bool> heartbeatPending;
    std::atomic<uint32_t> pendingCallbacks;
    dispatch_queue_t queue;
    dispatch_source_t timer;
    Stream stream;
    int listener,lockFD,directoryFD;
    struct stat socketIdentity;
    Packet session;
    Sequence incoming;
    uint64_t outgoing,lastSeen,lastLease;
    bool hello;
}
@property(nonatomic,copy) NSString *socketPath;
@property(nonatomic,copy) NSString *directoryPath;
@property(nonatomic,copy) NSString *stage;
@property(nonatomic,copy) void (^onState)(uint32_t);
@property(nonatomic,copy) dispatch_block_t invalidated;
@property(nonatomic) BOOL ready;
@property(nonatomic) uint32_t capabilities;
@property(nonatomic) uint32_t lastMask;
@property(nonatomic) uint32_t physicalMask;
@property(nonatomic) uint64_t responseTime;
@property(nonatomic) uint64_t readyEpoch;
@property(nonatomic) uint64_t deliveredCommand;
- (void)start;
- (void)stop;
- (void)sendLease;
@end

@implementation OPPhoneButtonsConnection
- (instancetype)init {
    if((self=[super init])) {
        stopped=false;desiredArmed=false;command=1;epoch=1;mainHeartbeat=nowNs();heartbeatPending=false;pendingCallbacks=0;
        listener=lockFD=directoryFD=-1;socketIdentity={};session={};incoming={};
        outgoing=lastSeen=lastLease=0;hello=false;_stage=@"starting";
        static dispatch_queue_t sharedQueue;
        static dispatch_once_t once;
        dispatch_once(&once,^{sharedQueue=dispatch_queue_create("com.lixinmo.skytouch.phone-buttons",DISPATCH_QUEUE_SERIAL);});
        // A stopped instance retires its listener before a replacement creates
        // the same endpoint, including an immediate input-mode round trip.
        queue=sharedQueue;
    }
    return self;
}
- (void)reportFailure:(NSString *)reason {
    desiredArmed=false;
    const uint64_t current=epoch.load();
    dispatch_async(dispatch_get_main_queue(),^{
        if(self->stopped.load() || self->epoch.load()!=current)return;
        self.ready=NO;self.stage=reason;self.lastMask=0;self.responseTime=0;
        self.onState(0);self.invalidated();
    });
}
- (void)drop:(NSString *)reason {
    stream.close();hello=false;incoming={};outgoing=lastSeen=lastLease=0;
    epoch.fetch_add(1);command.fetch_add(1);[self reportFailure:reason];
}
- (BOOL)openListener {
    NSString *parent=self.directoryPath.stringByDeletingLastPathComponent;
    int parentFD=open(parent.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_CLOEXEC);
    struct stat parentInfo{};
    if(parentFD<0 || fstat(parentFD,&parentInfo) || !S_ISDIR(parentInfo.st_mode) || parentInfo.st_uid!=0) {
        if(parentFD>=0)close(parentFD);return NO;
    }
    const char *leaf=self.directoryPath.lastPathComponent.fileSystemRepresentation;
    if(mkdirat(parentFD,leaf,0755) && errno!=EEXIST){close(parentFD);return NO;}
    directoryFD=openat(parentFD,leaf,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);close(parentFD);
    struct stat dir{};
    if(directoryFD<0 || fstat(directoryFD,&dir) || dir.st_uid!=0 || (dir.st_mode&0777)!=0755)return NO;
    lockFD=openat(directoryFD,"lock",O_RDWR|O_CREAT|O_NOFOLLOW|O_CLOEXEC,0600);
    struct stat lock{};
    if(lockFD<0 || fstat(lockFD,&lock) || !S_ISREG(lock.st_mode) || lock.st_nlink!=1 ||
       lock.st_uid!=0 || (lock.st_mode&0777)!=0600 || flock(lockFD,LOCK_EX|LOCK_NB))return NO;
    struct stat old{};
    if(!fstatat(directoryFD,socketName,&old,AT_SYMLINK_NOFOLLOW)) {
        if(!S_ISSOCK(old.st_mode) || old.st_uid!=501 || (old.st_mode&0777)!=0600 || unlinkat(directoryFD,socketName,0))return NO;
    } else if(errno!=ENOENT)return NO;
    sockaddr_un destination{};
    if(!address(self.socketPath.fileSystemRepresentation,destination))return NO;
    listener=socket(AF_UNIX,SOCK_STREAM,0);
    if(listener<0 || !configureSocket(listener) || bind(listener,(sockaddr *)&destination,sizeof(destination)))return NO;
    // Record ownership before later setup can fail so cleanup removes only the
    // socket this listener actually created, including a failed chown/listen.
    if(fstatat(directoryFD,socketName,&socketIdentity,AT_SYMLINK_NOFOLLOW) ||
       fchownat(directoryFD,socketName,501,501,AT_SYMLINK_NOFOLLOW) ||
       fchmodat(directoryFD,socketName,0600,0) || listen(listener,1))return NO;
    return YES;
}
- (void)closeListener {
    if(listener>=0){close(listener);listener=-1;}
    struct stat current{};
    if(directoryFD>=0 && socketIdentity.st_ino && !fstatat(directoryFD,socketName,&current,AT_SYMLINK_NOFOLLOW) &&
       S_ISSOCK(current.st_mode) && current.st_ino==socketIdentity.st_ino && current.st_dev==socketIdentity.st_dev)
        (void)unlinkat(directoryFD,socketName,0);
    socketIdentity={};
    if(lockFD>=0){close(lockFD);lockFD=-1;}
    if(directoryFD>=0){close(directoryFD);directoryFD=-1;}
}
- (BOOL)sendKind:(Kind)kind {
    if(stream.fd<0)return NO;
    const uint64_t mainTime=mainHeartbeat.load();
    Packet packet=session;packet.kind=kind;packet.sequence=++outgoing;packet.timestamp=nowNs();
    packet.command=command.load();packet.flags=(kind==Kind::Lease && hello && desiredArmed.load() &&
        mainTime && packet.timestamp-mainTime<leaseNs) ? 1 : 0;
    packet.capabilities=0;packet.physical=packet.mapped=0;
    return stream.queue(packet) && stream.flush();
}
- (void)sendLease {
    if(!hello || stream.fd<0)return;
    if(!heartbeatPending.exchange(true)) {
        dispatch_async(dispatch_get_main_queue(),^{
            self->mainHeartbeat=nowNs();self->heartbeatPending=false;
        });
    }
    if(![self sendKind:Kind::Lease]){[self drop:@"button-transport-write-failed"];return;}
    lastLease=nowNs();
}
- (BOOL)receive:(const Packet &)packet {
    const uint64_t now=nowNs();
    if(!valid(packet,now) || !sameGeneration(packet,session) || !incoming.accept(packet.sequence))return NO;
    if(!hello) {
        if(packet.kind!=Kind::Hello || packet.mapped || packet.flags || packet.command)return NO;
        hello=true;lastSeen=now;
        const uint32_t caps=packet.capabilities,physical=packet.physical;const uint64_t current=epoch.load();
        dispatch_async(dispatch_get_main_queue(),^{
            if(self->stopped.load() || self->epoch.load()!=current)return;
            self.capabilities=caps;self.physicalMask=physical;self.lastMask=0;self.responseTime=now;
            self.readyEpoch=current;self.deliveredCommand=0;
            self.ready=caps==all;self.stage=self.ready ? @"ready-disarmed" : @"unsupported-button-abi";
            self.onState(0);
            if(!self.ready)self.invalidated();
        });
        [self sendLease];return YES;
    }
    if(packet.kind!=Kind::State || packet.command>command.load())return NO;
    lastSeen=now;
    if(pendingCallbacks.fetch_add(1)>=maximumPending){pendingCallbacks.fetch_sub(1);return NO;}
    const Packet copy=packet;const uint64_t currentEpoch=epoch.load();
    dispatch_async(dispatch_get_main_queue(),^{
        self->pendingCallbacks.fetch_sub(1);
        if(self->stopped.load() || self->epoch.load()!=currentEpoch)return;
        const BOOL wasReady=self.ready;
        self.responseTime=copy.timestamp;self.capabilities=copy.capabilities;self.physicalMask=copy.physical;
        self.ready=copy.capabilities==all;self.readyEpoch=currentEpoch;
        const BOOL current=self->desiredArmed.load() && copy.command==self->command.load() &&
            (copy.flags&1) && self.ready && nowNs()-copy.timestamp<=staleNs;
        const uint32_t mask=current ? copy.mapped : 0;
        self.stage=!self.ready ? @"unsupported-button-abi" : (copy.flags&2) ? @"waiting-for-release" :
            current ? @"armed" : @"ready-disarmed";
        if(mask!=self.lastMask || (current && self.deliveredCommand!=copy.command)) {
            self.lastMask=mask;self.deliveredCommand=copy.command;self.onState(mask);
        }
        if(wasReady && !self.ready)self.invalidated();
    });
    return YES;
}
- (void)tick {
    if(stopped.load())return;
    if(listener<0)return;
    if(stream.fd<0) {
        int accepted=accept(listener,nullptr,nullptr);
        if(accepted>=0) {
            if(!configureSocket(accepted) || !peerIs(accepted,501,"/System/Library/CoreServices/SpringBoard.app/SpringBoard")) {
                close(accepted);return;
            }
            stream.fd=accepted;session={};arc4random_buf(session.generation,sizeof(session.generation));
            if(!session.generation[0] && !session.generation[1])session.generation[0]=1;
            hello=false;incoming={};outgoing=0;lastSeen=nowNs();lastLease=0;
            desiredArmed=false;command.fetch_add(1);epoch.fetch_add(1);
            if(![self sendKind:Kind::Welcome]){[self drop:@"button-handshake-write-failed"];return;}
        }
    }
    if(stream.fd<0)return;
    if(!stream.read([self](const Packet &packet){return (bool)[self receive:packet];}) || !stream.flush()) {
        [self drop:@"button-bridge-disconnected"];return;
    }
    const uint64_t now=nowNs();
    if(!lastSeen || now-lastSeen>staleNs){[self drop:@"button-bridge-lease-expired"];return;}
    if(hello && now-lastLease>=heartbeatNs)[self sendLease];
}
- (void)start {
    dispatch_async(queue,^{
        if(self->stopped.load())return;
        if(![self openListener]){[self closeListener];[self reportFailure:@"button-endpoint-unavailable"];return;}
        dispatch_async(dispatch_get_main_queue(),^{if(!self->stopped.load())self.stage=@"waiting-for-SpringBoard";});
        self->timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,self->queue);
        __weak OPPhoneButtonsConnection *weak=self;
        dispatch_source_set_event_handler(self->timer,^{@autoreleasepool {[weak tick];}});
        dispatch_source_set_timer(self->timer,DISPATCH_TIME_NOW,4*NSEC_PER_MSEC,NSEC_PER_MSEC);
        dispatch_resume(self->timer);
    });
}
- (void)stop {
    stopped=true;desiredArmed=false;command.fetch_add(1);epoch.fetch_add(1);self.ready=NO;self.lastMask=0;
    dispatch_async(queue,^{
        if(self->stream.fd>=0)(void)[self sendKind:Kind::Goodbye];
        self->stream.close();[self closeListener];
        if(self->timer){dispatch_source_cancel(self->timer);self->timer=nil;}
    });
}
@end

static OPPhoneButtonsConnection *OPPhoneButtons;
BOOL OPStartPhoneButtonClient(void (^onState)(uint32_t),dispatch_block_t invalidated,NSString **error) {
    if(error)*error=nil;
    if(!NSThread.isMainThread || !onState || !invalidated || OPPhoneButtons) {
        if(error)*error=@"手机按键输入必须从主线程启动一次";return NO;
    }
    if(geteuid()!=0 || ![NSBundle.mainBundle.bundleIdentifier isEqual:@"SkyTouchMapping"] ||
       !OPServiceExecutablePathsMatch(NSBundle.mainBundle.executablePath,OPMappingServiceExecutablePath())) {
        if(error)*error=@"手机按键输入必须由凌触独立映射服务运行";return NO;
    }
    NSString *directory=OPStorageRootedPath(@(socketDirectory));
    NSString *path=[directory stringByAppendingPathComponent:@(socketName)];sockaddr_un check{};
    if(!path.length || !address(path.fileSystemRepresentation,check)) {
        if(error)*error=@"手机按键通信路径不可用或超出系统长度限制";return NO;
    }
    OPPhoneButtons=[OPPhoneButtonsConnection new];OPPhoneButtons.directoryPath=directory;OPPhoneButtons.socketPath=path;
    OPPhoneButtons.onState=onState;OPPhoneButtons.invalidated=invalidated;[OPPhoneButtons start];return YES;
}
BOOL OPPhoneButtonClientReady(void) {
    return NSThread.isMainThread && OPPhoneButtons && OPPhoneButtons.ready &&
        OPPhoneButtons.readyEpoch==OPPhoneButtons->epoch.load() &&
        OPPhoneButtons.responseTime && nowNs()-OPPhoneButtons.responseTime<=staleNs;
}
void OPSetPhoneButtonClientArmed(BOOL armed) {
    if(!NSThread.isMainThread || !OPPhoneButtons)return;
    OPPhoneButtonsConnection *client=OPPhoneButtons;
    const bool value=armed && OPPhoneButtonClientReady();
    if(client->desiredArmed.exchange(value)==value)return;
    client->command.fetch_add(1);
    if(!value){client.lastMask=0;client.onState(0);}
    dispatch_async(client->queue,^{if(!client->stopped.load())[client sendLease];});
}
void OPStopPhoneButtonClient(void) {
    if(!NSThread.isMainThread || !OPPhoneButtons)return;
    OPPhoneButtonsConnection *client=OPPhoneButtons;OPPhoneButtons=nil;
    [client stop];client.onState(0);
}
NSDictionary *OPPhoneButtonClientStatus(void) {
    if(!NSThread.isMainThread)return @{@"ready":@NO,@"stage":@"wrong-thread"};
    OPPhoneButtonsConnection *client=OPPhoneButtons;
    static int diagnosticToken=-1;
    static int suppressionToken=-1;
    static dispatch_once_t once;
    dispatch_once(&once,^{
        if(notify_register_check(diagnosticNotification,&diagnosticToken)!=NOTIFY_STATUS_OK)diagnosticToken=-1;
        if(notify_register_check(suppressionNotification,&suppressionToken)!=NOTIFY_STATUS_OK)suppressionToken=-1;
    });
    uint64_t diagnostic=0;
    if(diagnosticToken>=0 && notify_get_state(diagnosticToken,&diagnostic)!=NOTIFY_STATUS_OK)diagnostic=0;
    uint64_t counts=0;if(suppressionToken>=0 && notify_get_state(suppressionToken,&counts)!=NOTIFY_STATUS_OK)counts=0;
    const uint32_t observed=(uint32_t)(diagnostic>>32),now=(uint32_t)(nowNs()/NSEC_PER_SEC);
    const bool fresh=observed && now>=observed && now-observed<=15;
    NSDictionary *bridge=@{@"stage":@(diagnosticName((Diagnostic)(diagnostic&255))),
        @"detail":@((diagnostic>>8)&255),@"capabilities":@((diagnostic>>16)&255),
        @"protocolVersion":@((diagnostic>>24)&255),@"fresh":@(fresh),@"authorizesInput":@NO};
    return @{@"ready":@(OPPhoneButtonClientReady()),@"armed":@(client && client->desiredArmed.load()),
        @"capabilities":@(client.capabilities),@"physicalMask":@(client.physicalMask),
        @"stage":client.stage ?: @"not-started",@"protocolVersion":@(version),@"deviceVerified":@NO,
        @"bridgeDiagnostic":bridge,@"suppressedHardwareCallbacks":@((uint32_t)counts),
        @"suppressedNativeActions":@((uint32_t)(counts>>32))};
}
