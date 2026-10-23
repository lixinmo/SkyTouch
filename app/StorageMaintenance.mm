#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import "../src/OPStoragePaths.h"
#import "../src/OPConfigurationArchive.h"
#include "../src/OPConfigurationMaintenanceGuard.hpp"
#include <sys/stat.h>
#include <sys/file.h>
#include <fcntl.h>
#include <dirent.h>
#include <unistd.h>
#include <cstdio>
#include <cstring>
#include <cerrno>
#include <string>
#include <vector>
#include <map>
#include <algorithm>
#include <stdexcept>

// A one-shot package maintenance executable, never a resident service. The
// installer first stops our own processes. All project-controlled components
// are traversed with openat/O_NOFOLLOW; source files are never followed or
// modified while constructing the replacement tree.
namespace {
constexpr const char *dataName="com.lixinmo.skytouch";
constexpr const char *legacyName="SkyTouchOriginal";
constexpr const char *stageName=".com.lixinmo.skytouch.migration-stage-v1";
constexpr const char *receiptName=".storage-migration-v1.plist";
constexpr const char *legacyPublishLock=".global-publish.lock";
constexpr const char *prefix="com.lixinmo.skytouch.";
struct FD {
    int fd;
    explicit FD(int value=-1):fd(value){}
    ~FD(){if(fd>=0)close(fd);}
    FD(const FD&)=delete;
    FD& operator=(const FD&)=delete;
    FD(FD&&other):fd(other.fd){other.fd=-1;}
};
struct Entry {
    std::string path;
    bool directory;
    off_t size;
    std::string sha256;
};
void removeVerifiedTree(int source,int copiedRoot,const std::string &parentPath,const std::map<std::string,Entry> &expected);
[[noreturn]] void fail(const std::string &what){throw std::runtime_error(what);}
[[noreturn]] void io(const char *what){fail(std::string(what)+": "+strerror(errno));}
bool validName(const std::string &name) {
    return !name.empty() && name!="." && name!=".." && name.find('/')==std::string::npos && name.find('\0')==std::string::npos;
}
void state(int fd,bool directory) {
    struct stat st{};
    if(fstat(fd,&st))io("inspect file");
    if(directory ? !S_ISDIR(st.st_mode) : (!S_ISREG(st.st_mode)||st.st_nlink!=1))
        fail("Refusing symbolic/hard links or special files");
    if(st.st_uid!=0 && st.st_uid!=501)fail("Unexpected owner");
}
void privateMetadata(int fd,bool directory) {
    if(fchown(fd,501,501))io("set mobile ownership");
    if(fchmod(fd,directory?0700:0600))io("set private permissions");
    state(fd,directory);
}
int dirAt(int parent,const std::string &name,bool create=false,bool optional=false) {
    if(!validName(name))fail("Unsafe directory name");
    bool made=false;
    if(create) {
        if(mkdirat(parent,name.c_str(),0700)==0)made=true;
        else if(errno!=EEXIST)io("create directory");
    }
    int fd=openat(parent,name.c_str(),O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);
    if(fd<0) {
        if(optional && errno==ENOENT)return -1;
        io("open directory without following links");
    }
    try {state(fd,true);if(made)privateMetadata(fd,true);} catch(...) {close(fd);throw;}
    return fd;
}
int openLibrary(NSString *path) {
    if(!path.isAbsolutePath)fail("Library path is not absolute");
    int fd=open(path.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);
    if(fd<0)io("open fixed Library directory");
    try {state(fd,true);} catch(...) {close(fd);throw;}
    return fd;
}
std::vector<std::string> names(int directory) {
    // dup shares its directory offset. A fresh openat(".") avoids skipped
    // entries when re-verifying a tree that was already enumerated.
    int copy=openat(directory,".",O_RDONLY|O_DIRECTORY|O_CLOEXEC);
    if(copy<0)io("enumerate directory");
    DIR *stream=fdopendir(copy);
    if(!stream){close(copy);io("enumerate directory");}
    std::vector<std::string> result;
    errno=0;
    while(dirent *entry=readdir(stream)) {
        std::string name=entry->d_name;
        if(name!="." && name!="..") {
            if(!validName(name)){closedir(stream);fail("Unsafe filename");}
            result.push_back(name);
        }
        errno=0;
    }
    int saved=errno;closedir(stream);
    if(saved){errno=saved;io("read directory");}
    std::sort(result.begin(),result.end());return result;
}
bool sameStat(const struct stat &a,const struct stat &b) {
    return a.st_dev==b.st_dev && a.st_ino==b.st_ino && a.st_mode==b.st_mode && a.st_uid==b.st_uid &&
        a.st_nlink==b.st_nlink && a.st_size==b.st_size &&
        a.st_mtimespec.tv_sec==b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec==b.st_mtimespec.tv_nsec;
}
std::string digest(int fd,int output=-1) {
    state(fd,false);struct stat before{},after{};
    if(fstat(fd,&before) || lseek(fd,0,SEEK_SET)<0)io("inspect input");
    CC_SHA256_CTX context;CC_SHA256_Init(&context);
    unsigned char buffer[65536];off_t total=0;
    for(;;) {
        ssize_t count=read(fd,buffer,sizeof(buffer));
        if(count<0&&errno==EINTR)continue;
        if(count<0)io("read input");
        if(!count)break;
        total+=count;CC_SHA256_Update(&context,buffer,(CC_LONG)count);
        for(ssize_t offset=0;output>=0 && offset<count;) {
            ssize_t written=write(output,buffer+offset,(size_t)(count-offset));
            if(written<0&&errno==EINTR)continue;
            if(written<=0)io("write staged copy");
            offset+=written;
        }
    }
    if(fstat(fd,&after) || !sameStat(before,after) || total!=before.st_size)
        fail("Source changed while it was being read");
    unsigned char bytes[CC_SHA256_DIGEST_LENGTH];CC_SHA256_Final(bytes,&context);
    char hex[CC_SHA256_DIGEST_LENGTH*2+1];
    for(size_t i=0;i<sizeof(bytes);++i)snprintf(hex+i*2,3,"%02x",bytes[i]);
    return hex;
}
int fileAt(int parent,const std::string &name) {
    if(!validName(name))fail("Unsafe filename");
    int fd=openat(parent,name.c_str(),O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);
    if(fd<0)io("open regular file without following links");
    try{state(fd,false);}catch(...){close(fd);throw;}return fd;
}
struct stat entryState(int parent,const std::string &name) {
    struct stat st{};
    if(fstatat(parent,name.c_str(),&st,AT_SYMLINK_NOFOLLOW))io("inspect directory entry");
    if(!S_ISDIR(st.st_mode) && (!S_ISREG(st.st_mode)||st.st_nlink!=1))fail("Refusing symbolic/hard links or special files");
    return st;
}
void scan(int directory,const std::string &relative,std::vector<Entry> &entries) {
    for(const auto &name:names(directory)) {
        struct stat st=entryState(directory,name);
        std::string path=relative.empty()?name:relative+"/"+name;
        bool isDir=S_ISDIR(st.st_mode);
        if(isDir) {
            FD child(dirAt(directory,name));entries.push_back({path,true,0,""});scan(child.fd,path,entries);
        } else {
            FD file(fileAt(directory,name));entries.push_back({path,false,st.st_size,digest(file.fd)});
        }
    }
}
void verifySameEntries(const std::vector<Entry> &left,const std::vector<Entry> &right) {
    if(left.size()!=right.size())fail("Source tree changed during migration");
    for(size_t i=0;i<left.size();++i)
        if(left[i].path!=right[i].path || left[i].directory!=right[i].directory ||
           left[i].size!=right[i].size || left[i].sha256!=right[i].sha256)
            fail("Source tree changed during migration");
}
void copyFile(int source,const std::string &name,int destination) {
    FD input(fileAt(source,name));std::string expected=digest(input.fd);struct stat sourceState{};
    if(fstat(input.fd,&sourceState))io("inspect source timestamps");
    struct stat existing{};
    if(fstatat(destination,name.c_str(),&existing,AT_SYMLINK_NOFOLLOW)==0) {
        if(!S_ISREG(existing.st_mode) || existing.st_nlink!=1)fail("Destination type conflict; no data was replaced");
        FD previous(fileAt(destination,name));
        if(digest(previous.fd)!=expected)fail("Destination content conflict; no data was replaced: "+name);
        return;
    }
    if(errno!=ENOENT)io("inspect destination");
    FD output(openat(destination,name.c_str(),O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600));
    if(output.fd<0)io("create staged file");
    privateMetadata(output.fd,false);
    if(digest(input.fd,output.fd)!=expected)fail("Source changed before copying");
    if(fsync(output.fd))io("sync staged file");
    if(digest(output.fd)!=expected)fail("Staged file verification failed");
    struct timespec times[2]={sourceState.st_atimespec,sourceState.st_mtimespec};
    if(futimens(output.fd,times) || fsync(output.fd))io("preserve source timestamps");
}
void copyTree(int source,int destination,const char *skipRootFile=nullptr) {
    for(const auto &name:names(source)) {
        if(skipRootFile && name==skipRootFile)continue;
        struct stat st=entryState(source,name);
        if(S_ISDIR(st.st_mode)) {
            FD in(dirAt(source,name)),out(dirAt(destination,name,true));
            copyTree(in.fd,out.fd);
            struct timespec times[2]={st.st_atimespec,st.st_mtimespec};
            if(futimens(out.fd,times))io("preserve source directory timestamps");
            if(fsync(out.fd))io("sync staged directory");
        } else copyFile(source,name,destination);
    }
}
Entry migratedDataEntry(const Entry &entry) {
    Entry result=entry;
    if(result.path==legacyPublishLock)result.path=std::string("MigrationArchive/LegacyData/")+legacyPublishLock;
    return result;
}
// Used only on our controlled staging/cache trees, or the validated legacy
// snapshot after an explicit finalize-legacy operation. Never follows links.
void removeTree(int directory) {
    for(const auto &name:names(directory)) {
        struct stat st=entryState(directory,name);
        if(S_ISDIR(st.st_mode)) {
            FD child(dirAt(directory,name));removeTree(child.fd);
            if(unlinkat(directory,name.c_str(),AT_REMOVEDIR))io("remove private directory");
        } else {
            FD file(fileAt(directory,name));struct stat opened{};
            if(fstat(file.fd,&opened) || !sameStat(st,opened))fail("Entry changed before removal");
            if(unlinkat(directory,name.c_str(),0))io("remove private file");
        }
    }
    if(fsync(directory))io("sync removed directory entries");
}
bool persistent(const std::string &name) {
    for(const char *suffix:{"runtime-intent.plist","controller-identity.plist","editor-selection.plist",
        "floating-position.plist","original-bluetooth-selection.plist","original-panel.plist"})
        if(name==std::string(prefix)+suffix)return true;
    return false;
}
std::vector<Entry> preferenceEntries(int preferences) {
    std::vector<Entry> result;
    if(preferences<0)return result;
    for(const auto &name:names(preferences)) {
        if(name.compare(0,strlen(prefix),prefix)!=0 && name.compare(0,strlen(prefix)+1,std::string(".")+prefix)!=0)continue;
        auto st=entryState(preferences,name);
        if(!S_ISREG(st.st_mode))fail("Legacy preference is not a regular file");
        FD input(fileAt(preferences,name));result.push_back({name,false,st.st_size,digest(input.fd)});
    }
    return result;
}
NSArray *encodeEntries(const std::vector<Entry> &entries) {
    NSMutableArray *result=[NSMutableArray array];
    for(const auto &entry:entries) {
        NSString *path=[[NSString alloc] initWithBytes:entry.path.data() length:entry.path.size() encoding:NSUTF8StringEncoding];
        if(!path)fail("Legacy filename is not valid UTF-8");
        [result addObject:@{@"path":path,@"directory":@(entry.directory),@"size":@(entry.size),@"sha256":@(entry.sha256.c_str())}];
    }
    return result;
}
NSData *readSmall(int directory,const char *name) {
    FD file(fileAt(directory,name));struct stat st{};
    if(fstat(file.fd,&st) || st.st_size<0 || st.st_size>32*1024*1024)fail("Invalid migration receipt size");
    NSMutableData *data=[NSMutableData dataWithLength:(NSUInteger)st.st_size];size_t offset=0;
    while(offset<data.length) {
        ssize_t count=read(file.fd,(char *)data.mutableBytes+offset,data.length-offset);
        if(count<0&&errno==EINTR)continue;
        if(count<=0)fail("Incomplete migration receipt");offset+=(size_t)count;
    }
    return data;
}
NSDictionary *receipt(int directory) {
    struct stat st{};
    if(fstatat(directory,receiptName,&st,AT_SYMLINK_NOFOLLOW)) {
        if(errno==ENOENT)return nil;io("inspect migration receipt");
    }
    id value=[NSPropertyListSerialization propertyListWithData:readSmall(directory,receiptName) options:NSPropertyListImmutable format:nil error:nil];
    if(![value isKindOfClass:NSDictionary.class] || ![value[@"schema"] isEqual:@1] ||
       ![value[@"complete"] isEqual:@YES] || ![value[@"legacyData"] isKindOfClass:NSArray.class] ||
       ![value[@"legacyPreferences"] isKindOfClass:NSArray.class] ||
       ![value[@"previousDestination"] isKindOfClass:NSArray.class])fail("Invalid migration receipt");
    return value;
}
void writeReceipt(int directory,const std::vector<Entry> &data,const std::vector<Entry> &preferences,const std::vector<Entry> &previous) {
    NSDictionary *value=@{@"schema":@1,@"complete":@YES,@"createdAt":@(NSDate.date.timeIntervalSince1970),
        @"legacyData":encodeEntries(data),@"legacyPreferences":encodeEntries(preferences),@"previousDestination":encodeEntries(previous)};
    NSData *bytes=[NSPropertyListSerialization dataWithPropertyList:value format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    if(!bytes)fail("Cannot serialize migration receipt");
    FD out(openat(directory,receiptName,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600));
    if(out.fd<0)io("create migration receipt");privateMetadata(out.fd,false);
    size_t offset=0;
    while(offset<bytes.length) {
        ssize_t count=write(out.fd,(const char *)bytes.bytes+offset,bytes.length-offset);
        if(count<0&&errno==EINTR)continue;
        if(count<=0)io("write migration receipt");offset+=(size_t)count;
    }
    if(fsync(out.fd))io("sync migration receipt");
}
void removeStage(int support) {
    FD previous(dirAt(support,stageName,false,true));
    if(previous.fd<0)return;
    removeTree(previous.fd);
    if(unlinkat(support,stageName,AT_REMOVEDIR))io("remove old staging tree");
    if(fsync(support))io("sync removed staging tree");
}
void removeCommittedStage(int support,NSDictionary *record) {
    FD previous(dirAt(support,stageName,false,true));if(previous.fd<0)return;
    std::vector<Entry> entries;scan(previous.fd,"",entries);
    NSMutableDictionary *index=[NSMutableDictionary dictionary];
    for(NSDictionary *item in record[@"previousDestination"]) {
        if(![item isKindOfClass:NSDictionary.class] || ![item[@"path"] isKindOfClass:NSString.class])fail("Invalid previous destination receipt entry");
        index[item[@"path"]]=item;
    }
    for(NSDictionary *item in encodeEntries(entries))
        if(![item isEqual:index[item[@"path"]]])fail("Previous destination changed after commit; staging backup retained");
    std::map<std::string,Entry> expected;for(const auto &entry:entries)expected.emplace(entry.path,entry);
    FD active(dirAt(support,dataName));
    removeVerifiedTree(previous.fd,active.fd,"",expected);
    if(unlinkat(support,stageName,AT_REMOVEDIR) || fsync(support))io("remove verified previous destination");
}
void verifyMigratedEntry(int destination,const Entry &entry) {
    FD current(dup(destination));if(current.fd<0)io("open migrated root");
    size_t start=0;
    for(;;) {
        size_t slash=entry.path.find('/',start);
        std::string component=entry.path.substr(start,slash==std::string::npos?std::string::npos:slash-start);
        if(!validName(component))fail("Unsafe migration receipt path");
        if(slash!=std::string::npos) {
            int next=dirAt(current.fd,component);close(current.fd);current.fd=next;start=slash+1;continue;
        }
        if(entry.directory) {FD child(dirAt(current.fd,component));return;}
        FD file(fileAt(current.fd,component));struct stat st{};
        if(fstat(file.fd,&st) || st.st_size!=entry.size || digest(file.fd)!=entry.sha256)
            fail("Migrated file changed or is missing; refusing legacy cleanup");
        return;
    }
}
void migrate(int oldLibrary,int newLibrary) {
    FD support(dirAt(newLibrary,"Application Support",true));
    FD oldSupport(dirAt(oldLibrary,"Application Support",false,true));
    FD original(oldSupport.fd>=0?dirAt(oldSupport.fd,legacyName,false,true):-1);
    FD preferences(dirAt(oldLibrary,"Preferences",false,true));
    FD existing(dirAt(support.fd,dataName,false,true));
    NSDictionary *completed=existing.fd>=0 ? receipt(existing.fd) : nil;
    if(completed) {
        removeCommittedStage(support.fd,completed);puts("Migration already committed; legacy data was not re-imported.");return;
    }
    std::vector<Entry> dataEntries;if(original.fd>=0)scan(original.fd,"",dataEntries);
    std::vector<Entry> existingEntries;if(existing.fd>=0)scan(existing.fd,"",existingEntries);
    auto prefs=preferenceEntries(preferences.fd);
    for(const auto &entry:dataEntries)
        if(entry.path==receiptName || entry.path=="MigrationArchive")fail("Legacy data uses a reserved migration path");
    // Stage names belong exclusively to this package and are never active.
    // A failed or interrupted run can be safely reconstructed from unchanged
    // sources. The active destination is untouched until the single rename.
    removeStage(support.fd);FD staged(dirAt(support.fd,stageName,true));
    if(existing.fd>=0)copyTree(existing.fd,staged.fd,legacyPublishLock);
    if(original.fd>=0)copyTree(original.fd,staged.fd,legacyPublishLock);
    FD settings(dirAt(staged.fd,"Settings",true));
    FD archive(dirAt(staged.fd,"MigrationArchive",true));
    FD archivedPreferences(dirAt(archive.fd,"Preferences",true));
    FD archivedData(dirAt(archive.fd,"LegacyData",true));
    for(int source:{existing.fd,original.fd}) {
        if(source<0)continue;
        struct stat st{};
        if(fstatat(source,legacyPublishLock,&st,AT_SYMLINK_NOFOLLOW)==0)copyFile(source,legacyPublishLock,archivedData.fd);
        else if(errno!=ENOENT)io("inspect old publication lock");
    }
    for(const auto &entry:prefs)copyFile(preferences.fd,entry.path,persistent(entry.path)?settings.fd:archivedPreferences.fd);
    std::vector<Entry> dataAgain;if(original.fd>=0)scan(original.fd,"",dataAgain);
    verifySameEntries(dataEntries,dataAgain);verifySameEntries(prefs,preferenceEntries(preferences.fd));
    std::vector<Entry> existingAgain;if(existing.fd>=0)scan(existing.fd,"",existingAgain);
    verifySameEntries(existingEntries,existingAgain);
    if(fsync(archivedPreferences.fd) || fsync(archivedData.fd) || fsync(archive.fd) || fsync(settings.fd))io("sync preference directories");
    writeReceipt(staged.fd,dataEntries,prefs,existingEntries);
    if(fsync(staged.fd))io("sync completed staging tree");
    // RENAME_SWAP keeps an existing destination available atomically, even
    // across a crash. RENAME_EXCL prevents accidental replacement on a fresh
    // migration. Both are supported by the iOS 15/macOS deployment baseline.
    unsigned flags=existing.fd>=0?RENAME_SWAP:RENAME_EXCL;
    if(renameatx_np(support.fd,stageName,support.fd,dataName,flags))io("atomically commit migrated data");
    if(fsync(support.fd))io("sync committed directory");
    removeCommittedStage(support.fd,receipt(staged.fd));
    printf("Migration committed: %zu data entries, %zu preference files; originals retained for verification.\n",dataEntries.size(),prefs.size());
}
void removeVerifiedTree(int source,int copiedRoot,const std::string &parentPath,const std::map<std::string,Entry> &expected) {
    auto children=names(source);
    // Never delete an entry just because it appeared in a fresh enumeration.
    // It must be present in the validated receipt and have its verified copy.
    for(const auto &name:children) {
        std::string path=parentPath.empty()?name:parentPath+"/"+name;
        if(!expected.count(path))fail("New legacy data appeared during cleanup; retained");
    }
    for(const auto &name:children) {
        std::string path=parentPath.empty()?name:parentPath+"/"+name;
        const Entry &entry=expected.at(path);auto before=entryState(source,name);
        if(S_ISDIR(before.st_mode)!=entry.directory)fail("Legacy entry changed type during cleanup");
        if(entry.directory) {
            FD directory(dirAt(source,name));struct stat opened{};
            if(fstat(directory.fd,&opened) || before.st_dev!=opened.st_dev || before.st_ino!=opened.st_ino)
                fail("Legacy directory changed during cleanup");
            removeVerifiedTree(directory.fd,copiedRoot,path,expected);
            struct stat current{};
            if(fstatat(source,name.c_str(),&current,AT_SYMLINK_NOFOLLOW) ||
               current.st_dev!=opened.st_dev || current.st_ino!=opened.st_ino)
                fail("Legacy directory was replaced during cleanup");
            if(unlinkat(source,name.c_str(),AT_REMOVEDIR))io("remove verified legacy directory");
        } else {
            FD file(fileAt(source,name));
            if(digest(file.fd)!=entry.sha256)fail("Legacy data changed during cleanup; retained");
            verifyMigratedEntry(copiedRoot,migratedDataEntry(entry));
            struct stat opened{},current{};
            if(fstat(file.fd,&opened) || fstatat(source,name.c_str(),&current,AT_SYMLINK_NOFOLLOW) ||
               !sameStat(before,opened) || !sameStat(opened,current))fail("Legacy file changed before unlink; retained");
            if(unlinkat(source,name.c_str(),0))io("remove verified legacy file");
        }
    }
    if(fsync(source))io("sync verified legacy removals");
}
void finalizeLegacy(int oldLibrary,int newLibrary) {
    FD support(dirAt(newLibrary,"Application Support"));FD data(dirAt(support.fd,dataName));
    NSDictionary *record=receipt(data.fd);if(!record)fail("No committed migration receipt");
    FD oldSupport(dirAt(oldLibrary,"Application Support",false,true));
    FD original(oldSupport.fd>=0?dirAt(oldSupport.fd,legacyName,false,true):-1);
    FD preferences(dirAt(oldLibrary,"Preferences",false,true));
    std::vector<Entry> oldData;if(original.fd>=0)scan(original.fd,"",oldData);
    auto oldPrefs=preferenceEntries(preferences.fd);
    // A cleanup interrupted after deleting some entries is retryable. Every
    // remaining entry must still match the receipt; newly created or changed
    // legacy data makes cleanup fail without deleting any of those entries.
    auto subset=[](NSArray *expected,const std::vector<Entry> &actual) {
        NSMutableDictionary *index=[NSMutableDictionary dictionary];
        for(NSDictionary *item in expected) {
            if(![item isKindOfClass:NSDictionary.class] || ![item[@"path"] isKindOfClass:NSString.class])fail("Invalid receipt entry");
            index[item[@"path"]]=item;
        }
        for(NSDictionary *item in encodeEntries(actual))
            if(![item isEqual:index[item[@"path"]]])fail("Legacy data changed after migration; refusing cleanup");
    };
    subset(record[@"legacyData"],oldData);subset(record[@"legacyPreferences"],oldPrefs);
    for(const auto &entry:oldData)verifyMigratedEntry(data.fd,migratedDataEntry(entry));
    // A restored backup has a committed receipt but no migration archive.
    // Require a destination directory only when a remaining legacy preference
    // needs its verified copy there. Missing copies must still stop cleanup.
    bool needsSettings=std::any_of(oldPrefs.begin(),oldPrefs.end(),[](const Entry &entry){return persistent(entry.path);});
    bool needsArchive=std::any_of(oldPrefs.begin(),oldPrefs.end(),[](const Entry &entry){return !persistent(entry.path);});
    FD settings(needsSettings?dirAt(data.fd,"Settings"):-1);
    FD archive(needsArchive?dirAt(data.fd,"MigrationArchive"):-1);
    FD archivedPreferences(needsArchive?dirAt(archive.fd,"Preferences"):-1);
    for(const auto &entry:oldPrefs)verifyMigratedEntry(persistent(entry.path)?settings.fd:archivedPreferences.fd,entry);
    if(original.fd>=0) {
        std::map<std::string,Entry> expected;
        for(const auto &entry:oldData)expected.emplace(entry.path,entry);
        removeVerifiedTree(original.fd,data.fd,"",expected);
        struct stat opened{},current{};
        if(fstat(original.fd,&opened) || fstatat(oldSupport.fd,legacyName,&current,AT_SYMLINK_NOFOLLOW) ||
           current.st_dev!=opened.st_dev || current.st_ino!=opened.st_ino)
            fail("Legacy root was replaced during cleanup; retained");
        if(unlinkat(oldSupport.fd,legacyName,AT_REMOVEDIR))io("remove verified legacy root");
        if(fsync(oldSupport.fd))io("sync removed legacy root");
    }
    for(const auto &entry:oldPrefs) {
        FD file(fileAt(preferences.fd,entry.path));
        struct stat before{};if(fstat(file.fd,&before))io("inspect legacy preference before cleanup");
        if(digest(file.fd)!=entry.sha256)fail("Legacy preference changed during cleanup");
        verifyMigratedEntry(persistent(entry.path)?settings.fd:archivedPreferences.fd,entry);
        struct stat opened{},current{};
        if(fstat(file.fd,&opened) || fstatat(preferences.fd,entry.path.c_str(),&current,AT_SYMLINK_NOFOLLOW) ||
           !sameStat(before,opened) || !sameStat(opened,current))fail("Legacy preference was replaced during cleanup");
        if(unlinkat(preferences.fd,entry.path.c_str(),0))io("remove verified legacy preference");
    }
    if(preferences.fd>=0 && fsync(preferences.fd))io("sync removed legacy preferences");
    if(!preferenceEntries(preferences.fd).empty())fail("New legacy preferences appeared during cleanup; retained");
    puts("Verified legacy sources removed; migrated data and archived runtime records retained.");
}
void cleanRuntime(int library) {
    FD caches(dirAt(library,"Caches",false,true));if(caches.fd<0)return;
    FD package(dirAt(caches.fd,dataName,false,true));if(package.fd<0)return;
    FD runtime(dirAt(package.fd,"Runtime",false,true));if(runtime.fd<0)return;
    removeTree(runtime.fd);
    if(unlinkat(package.fd,"Runtime",AT_REMOVEDIR))io("remove runtime directory");
    if(fsync(package.fd))io("sync removed runtime directory");
    puts("Runtime files removed; saved configurations and settings retained.");
}
int managementReply(NSDictionary *result,NSString *error) {
    NSDictionary *response=result ? @{@"ok":@YES,@"result":result} :
        @{@"ok":@NO,@"error":error.length ? error : @"配置管理未完成，请稍后重试。"};
    NSData *encoded=[NSPropertyListSerialization dataWithPropertyList:response
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    if(!encoded){std::fputs("SkyTouch configuration management failed.\n",stderr);return 1;}
    const char *bytes=static_cast<const char *>(encoded.bytes);size_t remaining=encoded.length;
    while(remaining) {
        ssize_t written=write(STDOUT_FILENO,bytes,remaining);
        if(written<0 && errno==EINTR)continue;
        if(written<=0){std::fputs("SkyTouch configuration reply unavailable.\n",stderr);return 1;}
        bytes+=written;remaining-=static_cast<size_t>(written);
    }
    if(!result)std::fputs("SkyTouch configuration management failed.\n",stderr);
    return result ? 0 : 1;
}
int manageConfiguration(int argc,char **argv) {
    @try {try {
        if(geteuid()!=0)return managementReply(nil,@"配置管理需要凌触的系统辅助程序。");
        if(argc<3 || argc>4)return managementReply(nil,@"配置管理参数无效。");
        NSString *operation=[NSString stringWithUTF8String:argv[2]];
        NSString *basename=argc==4 ? [NSString stringWithUTF8String:argv[3]] : nil;
        if(!operation || !op_configuration_maintenance::managementOperationKnown(argv[2]) ||
            (op_configuration_maintenance::managementOperationTakesArgument(argv[2]) ? (argc!=4 || !basename.length ||
                [basename rangeOfString:@"/"].location!=NSNotFound || [basename isEqual:@"."] || [basename isEqual:@".."]) : argc!=3))
            return managementReply(nil,@"配置管理操作或备份文件名无效。");
        NSString *library=OPStorageRootedPath(@"/var/mobile/Library");
        if(!library)return managementReply(nil,@"无法访问本次安装的 RootHide 数据目录。");
        FD destination(openLibrary(library));
        if(flock(destination.fd,LOCK_EX|LOCK_NB)!=0)
            return managementReply(nil,@"有其他配置维护任务正在运行，请稍后重试。");
        const BOOL recovery=OPConfigurationArchiveNeedsRecovery();
        const BOOL full=op_configuration_maintenance::managementRequiresAllLeases(argv[2],recovery);
        const BOOL guardNeeded=full || [operation isEqual:@"backup"];
        op_configuration_maintenance::RuntimeGuard guard(destination.fd);
        if(guardNeeded) {
            using namespace op_configuration_maintenance;
            GuardResult result=guard.acquire(full ? GuardMode::All : GuardMode::Mapping);
            if(result==GuardResult::Busy)return managementReply(nil,@"当前配置或映射会话尚未退出，请先返回首页并关闭映射后重试。");
            if(result!=GuardResult::Ready)return managementReply(nil,@"运行文件状态异常，已保留现有配置，请重新打开凌触后重试。");
            if(!guard.validate())return managementReply(nil,@"配置会话状态发生变化，请稍后重试。");
        }
        NSString *error=nil;
        NSDictionary *result=OPConfigurationArchivePerformWithLockedLibrary(operation,basename,destination.fd,&error);
        return managementReply(result,error);
    }catch(const std::exception &exception){(void)exception;return managementReply(nil,@"无法安全访问配置数据，现有配置已保留。");}}
    @catch(NSException *exception){(void)exception;return managementReply(nil,@"配置管理未完成，请重新打开凌触后重试。");}
}
} // namespace

int main(int argc,char **argv) {
    @autoreleasepool {
        if(argc>=2 && !strcmp(argv[1],"manage"))return manageConfiguration(argc,argv);
        try {
            if(argc<2)fail("Usage: SkyTouchStorage migrate|finalize-legacy|clean-runtime");
            NSString *legacyLibrary=@"/var/mobile/Library";
            NSString *newLibrary=nil;
            if(argc!=2 || geteuid()!=0)fail("Package maintenance requires root and no path arguments");
            NSString *root=OPJailbreakRoot();
            if(!root.length)fail("Cannot resolve this installed application's RootHide root");
            newLibrary=[root stringByAppendingPathComponent:@"var/mobile/Library"];
            FD destination(openLibrary(newLibrary));
            // Package manager serializes maintainer scripts. This extra flock
            // also protects manual verification runs without creating a lock
            // file in the user's persistent settings.
            if(flock(destination.fd,LOCK_EX|LOCK_NB))fail("Storage maintenance already running");
            if(!strcmp(argv[1],"clean-runtime"))cleanRuntime(destination.fd);
            else {
                FD source(openLibrary(legacyLibrary));
                struct stat a{},b{};if(fstat(source.fd,&a)||fstat(destination.fd,&b))io("inspect Library roots");
                if(a.st_dev==b.st_dev && a.st_ino==b.st_ino)fail("Legacy and RootHide Library roots must differ");
                if(!strcmp(argv[1],"migrate"))migrate(source.fd,destination.fd);
                else if(!strcmp(argv[1],"finalize-legacy"))finalizeLegacy(source.fd,destination.fd);
                else fail("Unknown maintenance operation");
            }
            return 0;
        } catch(const std::exception &error) {
            fprintf(stderr,"SkyTouch storage maintenance: %s\n",error.what());return 1;
        }
    }
}
