#pragma once
#include <array>
#include <chrono>
#include <thread>
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

// One-shot privileged maintenance only. Existing lease inodes are opened and
// held exclusively for the entire operation. Missing files are never created.
// Every retry releases partial leases, so waiting for a draining Bluetooth
// owner never fabricates a live configuration owner and keeps that owner alive.
namespace op_configuration_maintenance {
enum class GuardResult { Ready, Busy, Unsafe };
enum class GuardMode { Mapping, All };
inline bool managementOperationKnown(const char *operation) {
    if(!operation)return false;
    for(const char *name:{"list","backup","restore","clear","recover","acknowledge"})
        if(std::strcmp(operation,name)==0)return true;
    return false;
}
inline bool managementOperationTakesArgument(const char *operation) {
    return operation && (std::strcmp(operation,"restore")==0 || std::strcmp(operation,"acknowledge")==0);
}
inline bool managementRequiresAllLeases(const char *operation,bool recovery) {
    return recovery || (operation && (std::strcmp(operation,"restore")==0 || std::strcmp(operation,"clear")==0 ||
        std::strcmp(operation,"recover")==0 || std::strcmp(operation,"acknowledge")==0));
}
class RuntimeGuard {
    static constexpr std::array<const char *,3> directories={"Caches","com.lixinmo.skytouch","Runtime"};
    static constexpr std::array<const char *,5> names={
        "com.lixinmo.skytouch.original-supervisor.lock",
        "com.lixinmo.skytouch.original-host.lock",
        "com.lixinmo.skytouch.floating.lock",
        "com.lixinmo.skytouch.original-bluetooth.lock",
        "com.lixinmo.skytouch.original-config.lock"};
    int library_=-1;
    std::array<int,3> directories_={-1,-1,-1};
    std::array<int,5> leases_={-1,-1,-1,-1,-1};
    size_t count_=0;
    bool ready_=false;
    static bool owner(uid_t uid) {
        return uid==0 || uid==501;
    }
    static bool valid(const struct stat &value,bool directory) {
        return owner(value.st_uid) && !(value.st_mode&0002) &&
            (directory ? S_ISDIR(value.st_mode) : (S_ISREG(value.st_mode)&&value.st_nlink==1));
    }
    static bool same(const struct stat &a,const struct stat &b) {
        return a.st_dev==b.st_dev && a.st_ino==b.st_ino && a.st_mode==b.st_mode &&
            a.st_uid==b.st_uid && a.st_gid==b.st_gid && a.st_nlink==b.st_nlink;
    }
    static bool matches(int parent,const char *name,int fd,bool directory) {
        struct stat held{},named{};
        if(fd<0)return fstatat(parent,name,&named,AT_SYMLINK_NOFOLLOW)<0 && errno==ENOENT;
        return fstat(fd,&held)==0 && fstatat(parent,name,&named,AT_SYMLINK_NOFOLLOW)==0 &&
            valid(held,directory) && valid(named,directory) && same(held,named);
    }
    void reset() {
        ready_=false;
        for(int &fd:leases_)if(fd>=0){close(fd);fd=-1;}
        for(auto it=directories_.rbegin();it!=directories_.rend();++it)if(*it>=0){close(*it);*it=-1;}
    }
    GuardResult attempt(GuardMode mode) {
        reset();count_=mode==GuardMode::All ? names.size() : 3;
        struct stat libraryState{};
        if(library_<0 || fstat(library_,&libraryState)!=0 || !valid(libraryState,true))return GuardResult::Unsafe;
        int parent=library_;
        for(size_t i=0;i<directories.size();++i) {
            int fd=openat(parent,directories[i],O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
            if(fd<0) {
                if(errno!=ENOENT || !matches(parent,directories[i],-1,true))return GuardResult::Unsafe;
                ready_=true;return validate() ? GuardResult::Ready : GuardResult::Unsafe;
            }
            directories_[i]=fd;
            if(!matches(parent,directories[i],fd,true))return GuardResult::Unsafe;
            parent=fd;
        }
        for(size_t i=0;i<count_;++i) {
            int fd=openat(parent,names[i],O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
            if(fd<0) {
                if(errno!=ENOENT || !matches(parent,names[i],-1,false))return GuardResult::Unsafe;
                continue;
            }
            leases_[i]=fd;
            if(!matches(parent,names[i],fd,false))return GuardResult::Unsafe;
            int result;do{result=flock(fd,LOCK_EX|LOCK_NB);}while(result<0&&errno==EINTR);
            if(result<0)return errno==EWOULDBLOCK || errno==EAGAIN ? GuardResult::Busy : GuardResult::Unsafe;
            if(!matches(parent,names[i],fd,false))return GuardResult::Unsafe;
        }
        ready_=true;return validate() ? GuardResult::Ready : GuardResult::Unsafe;
    }
public:
    explicit RuntimeGuard(int library):library_(fcntl(library,F_DUPFD_CLOEXEC,3)){}
    RuntimeGuard(const RuntimeGuard&)=delete;
    RuntimeGuard &operator=(const RuntimeGuard&)=delete;
    ~RuntimeGuard(){reset();if(library_>=0)close(library_);}
    bool validate() const {
        if(!ready_)return false;
        int parent=library_;
        for(size_t i=0;i<directories.size();++i) {
            if(!matches(parent,directories[i],directories_[i],true))return false;
            if(directories_[i]<0)return true;
            parent=directories_[i];
        }
        for(size_t i=0;i<count_;++i)if(!matches(parent,names[i],leases_[i],false))return false;
        return true;
    }
    GuardResult acquire(GuardMode mode,std::chrono::milliseconds timeout=std::chrono::seconds(8)) {
        const auto until=std::chrono::steady_clock::now()+timeout;
        for(;;) {
            GuardResult result=attempt(mode);
            if(result==GuardResult::Ready)return result;
            // Do not retain an early lease while waiting for a later owner.
            reset();
            if(result!=GuardResult::Busy || std::chrono::steady_clock::now()>=until)return result;
            std::this_thread::sleep_for(std::chrono::milliseconds(40));
        }
    }
};
} // namespace op_configuration_maintenance
