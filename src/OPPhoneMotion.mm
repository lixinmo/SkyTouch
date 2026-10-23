#import "OPPhoneMotion.h"
#import "OPPhoneMotionWorker.h"
#include "OPPhoneMotionWire.hpp"
#import <CoreMotion/CoreMotion.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <sys/poll.h>
#include <grp.h>
#include <spawn.h>
#include <signal.h>
#include <fcntl.h>
#include <unistd.h>
#include <dlfcn.h>
#include <cerrno>
#include <climits>
#include <cstring>
#include <cstdlib>

extern char **environ;
namespace op_phone_motion {
using namespace op_phone_wire;
static bool configureSocket(int fd) {
    const int flags=fcntl(fd,F_GETFL,0),one=1;
    return flags>=0&&fcntl(fd,F_SETFL,flags|O_NONBLOCK)==0&&fcntl(fd,F_SETFD,FD_CLOEXEC)==0&&
        setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one))==0;
}
static bool sendPacket(int fd,const Packet &packet) {
    // A full socket means the peer stopped draining. Never block a main thread
    // or retain stale motion. A short write terminates this private session.
    ssize_t result;do{result=send(fd,&packet,sizeof(packet),0);}while(result<0&&errno==EINTR);
    return result==(ssize_t)sizeof(packet);
}
struct Reader {
    Packet packet{};size_t filled=0;
    // 1 complete packet, 0 would block, -1 EOF/error; retain one partial frame.
    int read(int fd) {
        while(filled<sizeof(packet)) {
            ssize_t n=recv(fd,(char *)&packet+filled,sizeof(packet)-filled,0);
            if(n>0){filled+=(size_t)n;continue;}
            if(n<0&&errno==EINTR)continue;
            if(n<0&&(errno==EAGAIN||errno==EWOULDBLOCK))return 0;
            return -1;
        }
        filled=0;return 1;
    }
};
static void reap(pid_t child) {
    if(child<=0)return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        for(unsigned attempt=0;;++attempt) {
            int status=0;pid_t result=waitpid(child,&status,WNOHANG);
            if(result==child||(result<0&&errno!=EINTR))return;
            if(attempt==25)kill(child,SIGTERM);
            if(attempt==100)kill(child,SIGKILL);
            if(attempt>100){do{result=waitpid(child,&status,0);}while(result<0&&errno==EINTR);return;}
            usleep(20000);
        }
    });
}
static bool ownServiceBundle() {
    return [NSBundle.mainBundle.bundleIdentifier isEqual:@"SkyTouchMapping"]&&
        [NSBundle.mainBundle.executablePath.lastPathComponent isEqual:@"SkyTouchMapping"];
}
static bool workerPeer(int fd,pid_t parent) {
    if(fd!=3||parent<=1||geteuid()!=0||!ownServiceBundle())return false;
    struct stat st{};int type=0;socklen_t length=sizeof(type);uid_t uid=(uid_t)-1;gid_t gid=(gid_t)-1;
    sockaddr_un address{};socklen_t addressLength=sizeof(address);
    if(fstat(fd,&st)||!S_ISSOCK(st.st_mode)||getsockopt(fd,SOL_SOCKET,SO_TYPE,&type,&length)||type!=SOCK_STREAM||
       getsockname(fd,(sockaddr *)&address,&addressLength)||address.sun_family!=AF_UNIX||
       getpeereid(fd,&uid,&gid)||uid!=0)return false;
    using ProcPath=int(*)(int,void *,uint32_t);
    auto path=(ProcPath)dlsym(RTLD_DEFAULT,"proc_pidpath");
    char parentPath[4096],resolvedParent[PATH_MAX],resolvedSelf[PATH_MAX];
    if(!path||path(parent,parentPath,sizeof(parentPath))<=0||
       !realpath(parentPath,resolvedParent)||!realpath(NSBundle.mainBundle.executablePath.fileSystemRepresentation,resolvedSelf))return false;
    return !std::strcmp(resolvedParent,resolvedSelf);
}
}

@interface OPPhoneMotion ()
- (void)drain;
- (BOOL)sendKind:(std::uint32_t)kind;
- (void)fail:(NSString *)error;
@end
@implementation OPPhoneMotion {
    op_phone::MotionAccumulator _accumulator;
    op_phone_motion::Reader _reader;
    double _scaleX,_scaleY;
    BOOL _started,_active,_available;
    UIInterfaceOrientation _orientation;
    NSUInteger _samples,_rejected;
    std::uint64_t _session,_generation,_sequence;
    pid_t _child;
    int _socket;
    NSTimer *_poll;
    NSString *_error;
}
- (instancetype)init {if((self=[super init]))_socket=-1;return self;}
- (BOOL)startWithScaleX:(double)x scaleY:(double)y error:(NSString **)error {
    using namespace op_phone_motion;
    if(error)*error=nil;
    if(!NSThread.isMainThread||geteuid()!=0||!ownServiceBundle()||!std::isfinite(x)||!std::isfinite(y)||x<1||y<1||x>65536||y>65536) {
        if(error)*error=@"手机体感需要专用映射宿主及有效定标参数";return NO;
    }
    [self stop];_scaleX=x;_scaleY=y;_error=nil;_reader={};_sequence=0;_generation=1;
    do{arc4random_buf(&_session,sizeof(_session));}while(!_session);
    int pair[2]={-1,-1};
    if(socketpair(AF_UNIX,SOCK_STREAM,0,pair)||!configureSocket(pair[0])||!configureSocket(pair[1])) {
        if(pair[0]>=0)close(pair[0]);if(pair[1]>=0)close(pair[1]);
        if(error)*error=@"无法创建手机体感专用通道";return NO;
    }
    posix_spawn_file_actions_t actions;posix_spawnattr_t attributes;
    int code=posix_spawn_file_actions_init(&actions);BOOL actionsReady=!code,attrsReady=NO;
    if(!code){code=posix_spawnattr_init(&attributes);attrsReady=!code;}
    if(!code)code=posix_spawnattr_setflags(&attributes,POSIX_SPAWN_CLOEXEC_DEFAULT);
    if(!code)code=posix_spawn_file_actions_addclose(&actions,pair[0]);
    if(!code)code=posix_spawn_file_actions_adddup2(&actions,pair[1],3);
    if(!code&&pair[1]!=3)code=posix_spawn_file_actions_addclose(&actions,pair[1]);
    NSString *path=NSBundle.mainBundle.executablePath;
    char *args[]={const_cast<char *>(path.fileSystemRepresentation),const_cast<char *>("--phone-motion-fd"),const_cast<char *>("3"),nullptr};
    pid_t child=0;if(!code)code=posix_spawn(&child,args[0],&actions,&attributes,args,environ);
    if(actionsReady)posix_spawn_file_actions_destroy(&actions);if(attrsReady)posix_spawnattr_destroy(&attributes);
    close(pair[1]);
    if(code){close(pair[0]);if(error)*error=@"无法启动手机体感采样子进程";return NO;}
    _socket=pair[0];_child=child;_started=YES;_available=NO;
    if(![self sendKind:Hello]){if(error)*error=_error;return NO;}
    __weak OPPhoneMotion *weakSelf=self;
    _poll=[NSTimer timerWithTimeInterval:.01 repeats:YES block:^(__unused NSTimer *timer){[weakSelf drain];}];
    [NSRunLoop.mainRunLoop addTimer:_poll forMode:NSRunLoopCommonModes];return YES;
}
- (BOOL)sendKind:(std::uint32_t)kind {
    op_phone_wire::Packet packet;packet.kind=kind;packet.session=_session;packet.generation=_generation;
    if(_socket<0||!op_phone_motion::sendPacket(_socket,packet)){[self fail:@"手机体感采样通道中断"];return NO;}
    return YES;
}
- (void)drain {
    using namespace op_phone_wire;
    if(!_started||_socket<0)return;
    for(unsigned count=0;count<64;++count) {
        const int result=_reader.read(_socket);
        if(result<0){[self fail:@"手机体感采样进程已退出"];return;}if(!result)break;
        const Packet p=_reader.packet;
        if(!header(p,_session)||p.sequence!=_sequence+1||p.generation>_generation||
           (p.kind!=Sample&&p.kind!=Status)) {[self fail:@"手机体感采样协议无效"];return;}
        _sequence=p.sequence;
        if(p.generation!=_generation)continue;
        if(p.kind==Status) {
            if(p.flags<Available||p.flags>SampleError||p.timestamp!=0||p.x!=0||p.y!=0||p.z!=0) {
                [self fail:@"手机体感状态消息无效"];return;
            }
            if(p.flags==Available){_available=YES;continue;}
            _accumulator.reset();_error=p.flags==Unavailable ? @"采样进程无法取得手机体感" : @"手机体感采样中断";continue;
        }
        if(p.flags){[self fail:@"手机体感样本标志无效"];return;}
        if(!_active)continue;
        if(_accumulator.sample(p.timestamp,NSProcessInfo.processInfo.systemUptime,p.x,p.y,p.z,_scaleX,_scaleY)) {
            ++_samples;_available=YES;_error=nil;
        } else ++_rejected;
    }
}
- (void)setActive:(BOOL)active {
    if(!NSThread.isMainThread||!_started||_active==active)return;
    ++_generation;_active=active;_accumulator.reset();
    [self sendKind:active ? op_phone_wire::Active : op_phone_wire::Inactive];
}
- (void)setOrientation:(UIInterfaceOrientation)orientation {
    if(!NSThread.isMainThread||_orientation==orientation)return;
    _orientation=orientation;_accumulator.orient((int)orientation);
    if(_started&&_active){++_generation;[self sendKind:op_phone_wire::Active];}
}
- (op_phone::Delta)consume {return NSThread.isMainThread&&_active ? _accumulator.consume(NSProcessInfo.processInfo.systemUptime) : op_phone::Delta{};}
- (void)discardPending {if(NSThread.isMainThread)_accumulator.discardPending();}
- (void)clear {if(NSThread.isMainThread)_accumulator.reset();}
- (BOOL)fresh {return NSThread.isMainThread&&_started&&_active&&_accumulator.fresh(NSProcessInfo.processInfo.systemUptime);}
- (void)fail:(NSString *)error {_error=error;[self stop];}
- (void)stop {
    if(!NSThread.isMainThread)return;
    _active=NO;_started=NO;_available=NO;[_poll invalidate];_poll=nil;
    if(_socket>=0){close(_socket);_socket=-1;}
    pid_t child=_child;_child=0;op_phone_motion::reap(child);_accumulator.reset();
}
- (void)dealloc {
    [_poll invalidate];if(_socket>=0)close(_socket);op_phone_motion::reap(_child);
}
- (NSDictionary *)status {return @{@"started":@(_started),@"active":@(_active),@"fresh":@(self.fresh),
    @"workerAvailable":@(_available),@"samplingUID":@501,@"transport":@"inherited-socketpair",
    @"samples":@(_samples),@"rejectedSamples":@(_rejected),@"scaleX":@(_scaleX),@"scaleY":@(_scaleY),
    @"scaleUnit":@"vendor-counts-per-radian",@"experimental":@YES,@"error":_error ?: @""};}
@end

int OPRunPhoneMotionWorker(int fd) { @autoreleasepool {
    using namespace op_phone_motion;using namespace op_phone_wire;
    const pid_t parent=getppid();
    if(!workerPeer(fd,parent)||!configureSocket(fd))return 77;
    Reader reader;const double deadline=NSProcessInfo.processInfo.systemUptime+2;
    int result=0;
    while(!(result=reader.read(fd))&&NSProcessInfo.processInfo.systemUptime<deadline) {
        pollfd wait{fd,POLLIN,0};poll(&wait,1,20);
    }
    Packet hello=reader.packet;
    if(result!=1||hello.kind!=Hello||hello.generation!=1||!command(hello,hello.session))return 64;
    // iOS 17.1 device validation: UID 0 aborts here even with UIKit bootstrap;
    // UID 501 works without UIKit. Only this isolated child drops privileges.
    if(setgroups(0,nullptr)||setgid(501)||setuid(501)||geteuid()!=501||getegid()!=501)return 77;
    CMMotionManager *manager=[CMMotionManager new];
    __block BOOL alive=YES,active=NO;
    __block std::uint64_t generation=1,sequence=0;
    const std::uint64_t session=hello.session;
    void(^status)(StatusCode)=^(StatusCode code){Packet p;p.kind=Status;p.flags=code;p.session=session;p.generation=generation;p.sequence=++sequence;
        if(!sendPacket(fd,p))alive=NO;};
    if(!manager.deviceMotionAvailable){status(Unavailable);close(fd);return 69;}
    status(Available);
    while(alive&&getppid()==parent) { @autoreleasepool {
        for(unsigned i=0;i<16;++i) {
            int state=reader.read(fd);if(state<0){alive=NO;break;}if(!state)break;
            Packet p=reader.packet;
            if(!command(p,session)||p.kind==Hello||p.generation<=generation){alive=NO;break;}
            generation=p.generation;[manager stopDeviceMotionUpdates];active=p.kind==Active;
            if(p.kind==Stop){alive=NO;break;}
            if(active) {
                const auto sampleGeneration=generation;
                manager.deviceMotionUpdateInterval=.01;
                [manager startDeviceMotionUpdatesUsingReferenceFrame:CMAttitudeReferenceFrameXArbitraryZVertical
                    toQueue:NSOperationQueue.mainQueue withHandler:^(CMDeviceMotion *sample,NSError *error){
                    if(!alive||!active||generation!=sampleGeneration)return;
                    if(error||!sample){status(SampleError);return;}
                    Packet out;out.kind=Sample;out.session=session;out.generation=generation;out.sequence=++sequence;
                    out.timestamp=sample.timestamp;out.x=sample.rotationRate.x;out.y=sample.rotationRate.y;out.z=sample.rotationRate.z;
                    if(!sendPacket(fd,out))alive=NO;
                }];
            }
        }
        if(alive)[NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    }}
    active=NO;[manager stopDeviceMotionUpdates];close(fd);return 0;
} }
