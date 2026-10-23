#pragma once
#include "../src/OPPhoneButtonProtocol.hpp"
#include <cerrno>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <unistd.h>
#include <dlfcn.h>
#include <limits.h>
#include <mach/mach_time.h>
#include <string>

namespace op_phone_buttons {
inline uint64_t nowNs() {
    static const mach_timebase_info_data_t base=[] {mach_timebase_info_data_t b{};mach_timebase_info(&b);return b;}();
    return (uint64_t)(((__uint128_t)mach_continuous_time()*base.numer)/base.denom);
}
inline bool configureSocket(int fd) {
    int flags=fcntl(fd,F_GETFL),noSignal=1;
    return flags>=0 && !fcntl(fd,F_SETFL,flags|O_NONBLOCK) && !fcntl(fd,F_SETFD,FD_CLOEXEC) &&
        !setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&noSignal,sizeof(noSignal));
}
inline bool address(const std::string &path,sockaddr_un &result) {
    if(path.empty() || path.front()!='/' || path.size()>=sizeof(result.sun_path))return false;
    result={};result.sun_family=AF_UNIX;result.sun_len=sizeof(result);
    memcpy(result.sun_path,path.c_str(),path.size()+1);return true;
}
inline bool regularRootFile(const char *path,struct stat *output=nullptr) {
    int fd=open(path,O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK);struct stat s{};
    const bool ok=fd>=0 && !fstat(fd,&s) && S_ISREG(s.st_mode) && s.st_uid==0 && !(s.st_mode&0022);
    if(fd>=0)close(fd);if(ok && output)*output=s;return ok;
}
enum class PeerFailure:uint8_t { None=0, Credentials, PeerPID, ProcAPI, ProcPath, PathMismatch, ExecutableMetadata };
inline bool peerIs(int fd,uid_t requiredUID,const std::string &executable,PeerFailure *failure=nullptr) {
    auto reject=[failure](PeerFailure reason){if(failure)*failure=reason;return false;};
    if(failure)*failure=PeerFailure::None;
    uid_t uid=0;gid_t gid=0;pid_t pid=0;socklen_t size=sizeof(pid);
    if(getpeereid(fd,&uid,&gid) || uid!=requiredUID)return reject(PeerFailure::Credentials);
    if(getsockopt(fd,SOL_LOCAL,LOCAL_PEERPID,&pid,&size) || size!=sizeof(pid) || pid<=1)return reject(PeerFailure::PeerPID);
    using ProcPath=int(*)(int,void *,uint32_t);
    static const ProcPath processPath=[] {
        auto fn=(ProcPath)dlsym(RTLD_DEFAULT,"proc_pidpath");
        if(!fn){void *lib=dlopen("/usr/lib/libproc.dylib",RTLD_NOW|RTLD_LOCAL);if(lib)fn=(ProcPath)dlsym(lib,"proc_pidpath");}
        return fn;
    }();
    char actual[4096]{},resolved[PATH_MAX]{},expected[PATH_MAX]{};
    if(!processPath)return reject(PeerFailure::ProcAPI);
    if(processPath(pid,actual,sizeof(actual))<=0)return reject(PeerFailure::ProcPath);
    if(!realpath(actual,resolved) || !realpath(executable.c_str(),expected) || strcmp(resolved,expected))return reject(PeerFailure::PathMismatch);
    return regularRootFile(resolved) ? true : reject(PeerFailure::ExecutableMetadata);
}
// Nonblocking, ordered stream. A full queue/sequence gap is a failed session,
// never a silently dropped button edge. Call only on the owning serial queue.
struct Stream {
    int fd=-1;
    std::deque<Packet> pending;
    size_t sent=0,received=0;
    std::array<unsigned char,sizeof(Packet)> incoming{};
    Stream()=default;Stream(const Stream &)=delete;Stream &operator=(const Stream &)=delete;
    ~Stream(){close();}
    void close(){if(fd>=0)::close(fd);fd=-1;pending.clear();sent=received=0;}
    bool queue(const Packet &packet) {
        if(fd<0 || pending.size()>=maximumPending)return false;
        pending.push_back(packet);return true;
    }
    bool flush() {
        for(unsigned n=0;n<maximumPending && !pending.empty();++n) {
            const auto *bytes=reinterpret_cast<const unsigned char *>(&pending.front());
            ssize_t count=send(fd,bytes+sent,sizeof(Packet)-sent,0);
            if(count<0 && errno==EINTR)continue;
            if(count<0 && (errno==EAGAIN || errno==EWOULDBLOCK))return true;
            if(count<=0)return false;
            sent+=(size_t)count;if(sent==sizeof(Packet)){pending.pop_front();sent=0;}
        }
        return true;
    }
    template<typename F> bool read(F handler) {
        for(unsigned n=0;n<maximumPending;++n) {
            ssize_t count=recv(fd,incoming.data()+received,sizeof(Packet)-received,0);
            if(count<0 && errno==EINTR)continue;
            if(count<0 && (errno==EAGAIN || errno==EWOULDBLOCK))return true;
            if(count<=0)return false;
            received+=(size_t)count;
            if(received==sizeof(Packet)) {
                Packet packet{};memcpy(&packet,incoming.data(),sizeof(packet));received=0;
                if(!handler(packet))return false;
            }
        }
        return true;
    }
};
}
