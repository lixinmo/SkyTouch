#pragma once
#include <sys/file.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <cerrno>
#include <climits>
#include <cstdlib>

namespace op_floating_lease {
struct Result {
    int descriptor=-1;
    int status=77;
    int error=0;
    bool inherited=false;
};

inline bool regularOwned(const struct stat &value,uid_t expectedOwner) {
    return S_ISREG(value.st_mode) && value.st_nlink==1 && value.st_uid==expectedOwner;
}

// Adopt only the same root-owned regular file, including an older host's
// legitimate descriptor 0/1/2. A fresh acquisition and an adopted descriptor
// are both normalized above the stdio range before the caller can exec again.
// F_DUPFD_CLOEXEC shares the same open-file description, preserving flock
// continuously while the low descriptor is closed.
inline Result acquire(const char *path,uid_t expectedOwner,const char *inheritedText) {
    int descriptor=open(path,O_CREAT|O_RDWR|O_CLOEXEC|O_NOFOLLOW,0644);
    if(descriptor<0)return {-1,77,errno,false};
    struct stat expected{};
    if(fstat(descriptor,&expected)!=0 || !regularOwned(expected,expectedOwner)) {
        const int error=errno ? errno : EINVAL;close(descriptor);return {-1,77,error,false};
    }
    bool adopted=false;
    if(inheritedText && *inheritedText) {
        bool digits=true;
        for(const char *p=inheritedText;*p;++p)if(*p<'0' || *p>'9'){digits=false;break;}
        char *end=nullptr;errno=0;
        const long candidate=digits ? strtol(inheritedText,&end,10) : -1;
        struct stat inherited{};
        if(digits && !errno && end && *end=='\0' && candidate>=0 && candidate<INT_MAX && candidate!=descriptor &&
           fstat(static_cast<int>(candidate),&inherited)==0 && regularOwned(inherited,expectedOwner) &&
           inherited.st_dev==expected.st_dev && inherited.st_ino==expected.st_ino &&
           flock(static_cast<int>(candidate),LOCK_EX|LOCK_NB)==0) {
            close(descriptor);descriptor=static_cast<int>(candidate);adopted=true;
        }
    }
    if(descriptor<3) {
        const int normalized=fcntl(descriptor,F_DUPFD_CLOEXEC,3);
        if(normalized<0) {
            const int error=errno;close(descriptor);return {-1,77,error,adopted};
        }
        close(descriptor);descriptor=normalized;
    }
    if(flock(descriptor,LOCK_EX|LOCK_NB)!=0) {
        const int error=errno;close(descriptor);return {-1,75,error,adopted};
    }
    if(fchmod(descriptor,0644)!=0 || fcntl(descriptor,F_SETFD,FD_CLOEXEC)!=0) {
        const int error=errno;close(descriptor);return {-1,77,error,adopted};
    }
    return {descriptor,0,0,adopted};
}
}
