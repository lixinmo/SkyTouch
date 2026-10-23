#import "OPConfigurationArchive.h"
#import "OPStoragePaths.h"
#import <CommonCrypto/CommonDigest.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <fcntl.h>
#include <dirent.h>
#include <unistd.h>
#include <cerrno>
#include <cstring>
#include <cstdio>
#include <map>
#include <set>
#include <vector>
#include <string>
#include <algorithm>
#include <stdexcept>

namespace op_archive {
constexpr const char *package="com.lixinmo.skytouch";
constexpr const char *transaction=".com.lixinmo.skytouch.configuration-transaction-v1";
constexpr const char *fixedBackup="com.lixinmo.skytouchSetting.skytouchbackup";
constexpr const char *pendingName=".com.lixinmo.skytouch.pending-mobile-defaults-v1.plist";
constexpr const char *receipt=".storage-migration-v1.plist";
constexpr size_t maxEntries=10000,maxFile=32*1024*1024,maxTotal=128*1024*1024,maxArchive=160*1024*1024;
struct FD {
    int fd;
    explicit FD(int value=-1):fd(value){}
    ~FD(){if(fd>=0)close(fd);}
    FD(const FD&)=delete;FD& operator=(const FD&)=delete;
    FD(FD&&v):fd(v.fd){v.fd=-1;}
    FD& operator=(FD&&v){if(fd>=0)close(fd);fd=v.fd;v.fd=-1;return *this;}
};
[[noreturn]] void fail(const char *message){throw std::runtime_error(message);}
[[noreturn]] void io(const char *message){throw std::runtime_error(std::string(message)+": "+strerror(errno));}
std::string utf8(NSString *s) { const char *v=s.UTF8String;if(!v || strlen(v)!=[s lengthOfBytesUsingEncoding:NSUTF8StringEncoding])fail("Invalid UTF-8 filename");return v; }
NSString *string(const std::string &s) {NSString *v=[[NSString alloc]initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding];if(!v)fail("Invalid UTF-8 filename");return v;}
bool nameOK(const std::string &name){return !name.empty() && name.size()<=255 && name!="." && name!=".." && name.find('/')==std::string::npos && name.find('\0')==std::string::npos;}
void inspect(int fd,bool directory) {
    struct stat st{};if(fstat(fd,&st))io("Cannot inspect configuration file");
    if(directory ? !S_ISDIR(st.st_mode) : (!S_ISREG(st.st_mode)||st.st_nlink!=1))fail("Links and special files are not allowed");
    if(st.st_uid!=0 && st.st_uid!=501)fail("Unexpected configuration file owner");
}
void metadata(int fd,bool directory) {
    if(fchown(fd,501,501))io("Cannot set mobile ownership");
    if(fchmod(fd,directory?0700:0600))io("Cannot set private permissions");
}
int directory(int parent,const std::string &name,bool create=false,bool optional=false) {
    if(!nameOK(name))fail("Unsafe directory name");
    bool made=false;if(create){if(mkdirat(parent,name.c_str(),0700)==0)made=true;else if(errno!=EEXIST)io("Cannot create configuration directory");}
    int fd=openat(parent,name.c_str(),O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);
    if(fd<0){if(optional&&errno==ENOENT)return -1;io("Cannot open configuration directory without following links");}
    try {inspect(fd,true);if(made)metadata(fd,true);}catch(...){close(fd);throw;}return fd;
}
int fixedDirectory(NSString *path,bool optional=false) {
    if(!path.isAbsolutePath)fail("RootHide data path is unavailable");
    int fd=open(path.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);
    if(fd<0){if(optional&&errno==ENOENT)return -1;io("Cannot open fixed storage directory");}
    try{inspect(fd,true);}catch(...){close(fd);throw;}return fd;
}
std::vector<std::string> names(int fd) {
    FD copy(openat(fd,".",O_RDONLY|O_DIRECTORY|O_CLOEXEC));if(copy.fd<0)io("Cannot enumerate configuration directory");
    DIR *stream=fdopendir(copy.fd);if(!stream)io("Cannot enumerate configuration directory");copy.fd=-1;
    std::vector<std::string> result;errno=0;
    while(dirent *entry=readdir(stream)){std::string name=entry->d_name;if(name!="."&&name!=".."){if(!nameOK(name)){closedir(stream);fail("Unsafe configuration filename");}result.push_back(name);}errno=0;}
    int saved=errno;closedir(stream);if(saved){errno=saved;io("Cannot enumerate configuration directory");}
    std::sort(result.begin(),result.end());return result;
}
bool exists(int parent,const std::string &name,struct stat *result=nullptr) {
    struct stat st{};if(fstatat(parent,name.c_str(),&st,AT_SYMLINK_NOFOLLOW)){if(errno==ENOENT)return false;io("Cannot inspect storage entry");}
    if(result)*result=st;return true;
}
int regular(int parent,const std::string &name) {
    if(!nameOK(name))fail("Unsafe configuration filename");
    int fd=openat(parent,name.c_str(),O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);if(fd<0)io("Cannot read configuration file");
    try{inspect(fd,false);}catch(...){close(fd);throw;}return fd;
}
bool same(const struct stat &a,const struct stat &b){return a.st_dev==b.st_dev&&a.st_ino==b.st_ino&&a.st_mode==b.st_mode&&a.st_uid==b.st_uid&&a.st_nlink==b.st_nlink&&a.st_size==b.st_size&&a.st_mtimespec.tv_sec==b.st_mtimespec.tv_sec&&a.st_mtimespec.tv_nsec==b.st_mtimespec.tv_nsec;}
NSData *read(int parent,const std::string &name,size_t limit=maxFile) {
    FD input(regular(parent,name));struct stat before{},after{};if(fstat(input.fd,&before))io("Cannot inspect configuration size");
    if(before.st_size<0 || (uint64_t)before.st_size>limit)fail("Configuration file exceeds the supported size limit");
    NSMutableData *bytes=[NSMutableData dataWithLength:(NSUInteger)before.st_size];size_t offset=0;
    while(offset<bytes.length){ssize_t count=::read(input.fd,(char *)bytes.mutableBytes+offset,bytes.length-offset);if(count<0&&errno==EINTR)continue;if(count<=0)fail("Configuration changed while reading");offset+=(size_t)count;}
    if(fstat(input.fd,&after)||!same(before,after))fail("Configuration changed while reading");
    struct stat linked{};if(!exists(parent,name,&linked)||!same(after,linked))fail("Configuration file was replaced while reading");return bytes;
}
NSString *hash(NSData *bytes){unsigned char value[CC_SHA256_DIGEST_LENGTH];CC_SHA256(bytes.bytes,(CC_LONG)bytes.length,value);char hex[65];for(size_t i=0;i<sizeof(value);++i)snprintf(hex+2*i,3,"%02x",value[i]);return @(hex);}
NSData *serialize(id value){NSData *bytes=[NSPropertyListSerialization dataWithPropertyList:value format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];if(!bytes)fail("Cannot encode configuration archive");return bytes;}
id parse(NSData *bytes){id result=[NSPropertyListSerialization propertyListWithData:bytes options:NSPropertyListImmutable format:nil error:nil];if(!result)fail("Configuration archive is not a valid property list");return result;}
void write(int parent,const std::string &name,NSData *bytes) {
    if(!nameOK(name))fail("Unsafe output name");
    FD file(openat(parent,name.c_str(),O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600));if(file.fd<0)io("Cannot create configuration file");metadata(file.fd,false);
    size_t offset=0;while(offset<bytes.length){ssize_t count=::write(file.fd,(const char *)bytes.bytes+offset,bytes.length-offset);if(count<0&&errno==EINTR)continue;if(count<=0)io("Cannot write configuration file");offset+=(size_t)count;}if(fsync(file.fd))io("Cannot sync configuration file");
}
void preferenceOwnership(int parent,const std::string &name,const std::string &identifier) {
    if(identifier!="root-app" && identifier!="root-mapping")return;
    FD file(regular(parent,name));if(fchown(file.fd,0,0)||fchmod(file.fd,0600)||fsync(file.fd))io("Cannot preserve root preference ownership");
}
void atomic(int parent,const std::string &name,NSData *bytes) {
    std::string temp=".com.lixinmo.skytouch.archive-write-"+utf8(NSUUID.UUID.UUIDString);
    write(parent,temp,bytes);
    if(renameat(parent,temp.c_str(),parent,name.c_str())){unlinkat(parent,temp.c_str(),0);io("Cannot commit configuration file");}
    if(fsync(parent))io("Cannot sync configuration directory");
}
void erase(int parent,const std::string &name) {
    struct stat before{};if(!exists(parent,name,&before))return;
    if(S_ISDIR(before.st_mode)) {
        FD child(directory(parent,name));struct stat opened{};if(fstat(child.fd,&opened)||before.st_dev!=opened.st_dev||before.st_ino!=opened.st_ino)fail("Directory changed while clearing configuration");
        for(const auto &entry:names(child.fd))erase(child.fd,entry);
        struct stat current{};if(!exists(parent,name,&current)||current.st_dev!=opened.st_dev||current.st_ino!=opened.st_ino)fail("Directory replaced while clearing configuration");
        if(unlinkat(parent,name.c_str(),AT_REMOVEDIR))io("Cannot remove configuration directory");
    } else {
        FD file(regular(parent,name));struct stat opened{};if(fstat(file.fd,&opened)||!same(before,opened))fail("File changed while clearing configuration");
        if(unlinkat(parent,name.c_str(),0))io("Cannot remove configuration file");
    }
    if(fsync(parent))io("Cannot sync removed configuration");
}
std::vector<std::string> components(NSString *value) {
    if(![value isKindOfClass:NSString.class] || !value.length || value.length>2048 || value.isAbsolutePath)fail("Unsafe archive path");
    NSArray *parts=[value componentsSeparatedByString:@"/"];if(parts.count>24)fail("Archive path is too deep");std::vector<std::string> result;
    for(NSString *part in parts){auto name=utf8(part);if(!nameOK(name))fail("Unsafe archive path");result.push_back(name);}return result;
}
bool allowedTop(const std::string &name){return name=="Profiles"||name=="Settings"||name=="ConfiguredTargets.plist"||name=="GlobalRevisions";}
NSArray<NSString *> *preferenceIDs(){return @[@"mobile-app",@"root-app",@"root-mapping"];}
NSString *nativeMobilePath() {
    return @"/var/mobile";
}
NSString *nativeBackupPath(NSString *name){return [[nativeMobilePath() stringByAppendingPathComponent:@"Media"] stringByAppendingPathComponent:name];}
struct Locations {
    FD library,support,media,legacyMedia,rootLibrary;
    Locations():library(fixedDirectory(OPStorageRootedPath(@"/var/mobile/Library"))),support(directory(library.fd,"Application Support")),
        media(-1),legacyMedia(-1),rootLibrary(fixedDirectory(OPStorageRootedPath(@"/var/root/Library"),true)){}
    int mediaFD(bool create){if(media.fd<0){FD mobile(fixedDirectory(nativeMobilePath()));media=FD(directory(mobile.fd,"Media",create,true));}return media.fd;}
    int legacyMediaFD(){if(legacyMedia.fd<0){FD mobile(fixedDirectory(OPStorageRootedPath(@"/var/mobile")));legacyMedia=FD(directory(mobile.fd,"Media",false,true));}return legacyMedia.fd;}
    int preferenceParent(NSString *identifier,bool create=false){
        bool mobile=[identifier isEqual:@"mobile-app"];int lib=mobile?library.fd:rootLibrary.fd;if(lib<0)return -1;
        bool absent=!exists(lib,"Preferences");int fd=directory(lib,"Preferences",create,true);
        if(fd>=0 && create && absent && !mobile && (fchown(fd,0,0)||fchmod(fd,0700))){close(fd);io("Cannot initialize root preference directory");}
        return fd;
    }
    static std::string preferenceName(NSString *identifier){return [identifier isEqual:@"root-mapping"]?"SkyTouchMapping.plist":"com.lixinmo.skytouch.app.plist";}
};
void scan(int parent,const std::string &name,NSString *path,NSMutableArray *entries,size_t &total) {
    if(entries.count>=maxEntries)fail("Too many configuration files");components(path);struct stat st{};if(!exists(parent,name,&st))fail("Configuration disappeared while reading");
    if(S_ISDIR(st.st_mode)){
        [entries addObject:@{@"path":path,@"type":@"directory"}];FD child(directory(parent,name));
        for(const auto &n:names(child.fd))scan(child.fd,n,[path stringByAppendingPathComponent:string(n)],entries,total);
    } else {NSData *bytes=read(parent,name);total+=bytes.length;if(total>maxTotal)fail("Configuration exceeds backup size limit");[entries addObject:@{@"path":path,@"type":@"file",@"bytes":bytes,@"sha256":hash(bytes)}];}
}
NSDictionary *snapshot(Locations &locations) {
    FD data(directory(locations.support.fd,package));NSMutableArray *entries=[NSMutableArray array];size_t total=0;
    for(const auto &name:names(data.fd))if(allowedTop(name))scan(data.fd,name,string(name),entries,total);
    NSMutableDictionary *preferences=[NSMutableDictionary dictionary];
    for(NSString *identifier in preferenceIDs()){
        FD parent(locations.preferenceParent(identifier));std::string name=Locations::preferenceName(identifier);
        if(parent.fd<0||!exists(parent.fd,name)){preferences[identifier]=@{@"present":@NO};continue;}
        NSData *bytes=read(parent.fd,name);if(![parse(bytes) isKindOfClass:NSDictionary.class])fail("Saved application settings are invalid");total+=bytes.length;if(total>maxTotal)fail("Configuration exceeds backup size limit");preferences[identifier]=@{@"present":@YES,@"bytes":bytes,@"sha256":hash(bytes)};
    }
    return @{@"entries":entries,@"preferences":preferences};
}
bool scratchName(const std::string &name){NSString *pattern=@"^\\.com\\.lixinmo\\.skytouch\\.archive-write-[0-9A-Fa-f-]{36}$";NSString *value=string(name);return [value rangeOfString:pattern options:NSRegularExpressionSearch].length==value.length;}
bool backupPrefix(NSString *name){return [name isKindOfClass:NSString.class] && [name hasPrefix:@"com.lixinmo.skytouchSetting."] && nameOK(utf8(name));}
bool backupName(NSString *name){if([name isEqual:@(fixedBackup)])return true;return backupPrefix(name) && [name hasSuffix:@".skytouchbackup"] && name.length>[@"com.lixinmo.skytouchSetting..skytouchbackup" length];}
bool identifierOK(NSString *value){return [value isKindOfClass:NSString.class] && [[[[NSUUID alloc]initWithUUIDString:value] UUIDString] isEqual:value];}

NSData *checkedBytes(NSDictionary *entry,size_t &total) {
    NSData *bytes=entry[@"bytes"];NSString *expected=entry[@"sha256"];
    if(![bytes isKindOfClass:NSData.class]||bytes.length>maxFile||![expected isKindOfClass:NSString.class]||![hash(bytes) isEqual:expected])fail("Backup file checksum verification failed");
    total+=bytes.length;if(total>maxTotal)fail("Backup exceeds restored size limit");return bytes;
}
void validate(NSDictionary *archive) {
    if(![archive isKindOfClass:NSDictionary.class]||![archive[@"format"] isEqual:@"com.lixinmo.skytouch.configuration"]||![archive[@"version"] isEqual:@1]||![archive[@"createdAt"] isKindOfClass:NSDate.class])fail("Unsupported SkyTouch backup format");
    NSArray *entries=archive[@"entries"];NSDictionary *preferences=archive[@"preferences"];
    if(![entries isKindOfClass:NSArray.class]||entries.count>maxEntries||![preferences isKindOfClass:NSDictionary.class]||preferences.count!=3)fail("Invalid backup contents");
    std::set<std::string> files,dirs;size_t total=0;
    for(id item in entries){if(![item isKindOfClass:NSDictionary.class])fail("Invalid backup entry");auto path=components(item[@"path"]);if(!allowedTop(path.front()))fail("Backup contains a forbidden path");std::string full=utf8(item[@"path"]);
        if(files.count(full)||dirs.count(full))fail("Duplicate backup path");for(size_t i=1;i<path.size();++i){std::string ancestor;for(size_t j=0;j<i;++j){if(j)ancestor+='/';ancestor+=path[j];}if(!dirs.count(ancestor))fail("Backup directory is missing or out of order");}
        if([item[@"type"] isEqual:@"directory"]){if(item[@"bytes"]||item[@"sha256"]||path.front()=="ConfiguredTargets.plist")fail("Invalid backup directory");dirs.insert(full);}else if([item[@"type"] isEqual:@"file"]){if(path.size()==1&&path.front()!="ConfiguredTargets.plist")fail("Invalid backup root file");checkedBytes(item,total);files.insert(full);}else fail("Invalid backup entry type");
    }
    if(!dirs.count("Settings"))fail("Backup settings directory is missing");
    for(NSString *identifier in preferenceIDs()){NSDictionary *item=preferences[identifier];if(![item isKindOfClass:NSDictionary.class]||![item[@"present"] isKindOfClass:NSNumber.class])fail("Invalid backed-up application settings");if([item[@"present"] boolValue]){if(![parse(checkedBytes(item,total)) isKindOfClass:NSDictionary.class])fail("Invalid backed-up application settings");}else if(item[@"bytes"]||item[@"sha256"])fail("Invalid absent application settings");}
}
void materialize(int root,NSArray *entries) {
    for(NSDictionary *item in entries){auto path=components(item[@"path"]);FD parent(dup(root));if(parent.fd<0)io("Cannot open staged data");for(size_t i=0;i+1<path.size();++i)parent=FD(directory(parent.fd,path[i]));
        if([item[@"type"] isEqual:@"directory"]){FD made(directory(parent.fd,path.back(),true));if(fsync(made.fd))io("Cannot sync staged directory");}else write(parent.fd,path.back(),item[@"bytes"]);if(fsync(parent.fd))io("Cannot sync staged data");}
}
void emptyReceipt(int data){write(data,receipt,serialize(@{@"schema":@1,@"complete":@YES,@"createdAt":@(NSDate.date.timeIntervalSince1970),@"legacyData":@[],@"legacyPreferences":@[],@"previousDestination":@[]}));}
void disableMapping(int data) {
    FD settings(directory(data,"Settings",true));atomic(settings.fd,"com.lixinmo.skytouch.runtime-intent.plist",serialize(@{@"version":@1,@"enabled":@NO,@"generation":NSUUID.UUID.UUIDString,@"updatedAt":@(NSDate.date.timeIntervalSince1970)}));
}
void cleanRuntime(Locations &locations){FD caches(directory(locations.library.fd,"Caches",false,true));if(caches.fd>=0)erase(caches.fd,package);}
bool ownPreference(const std::string &name){return name.rfind("com.lixinmo.skytouch.",0)==0||name.rfind(".com.lixinmo.skytouch.",0)==0;}
void preflightTree(int parent,const std::string &name);
void cleanPreferences(int library,bool mapping=false,bool dryRun=false){if(library<0)return;FD parent(directory(library,"Preferences",false,true));if(parent.fd<0)return;for(const auto &name:names(parent.fd))if(ownPreference(name)||(mapping&&name=="SkyTouchMapping.plist")){if(dryRun)preflightTree(parent.fd,name);else erase(parent.fd,name);}}
// UIKit/CFNetwork use the executable's bundle identity, which is different
// from our own Runtime directory. Clear only these exact, owned identities;
// never remove a shared framework directory or another application's cache.
const std::vector<std::string> &frameworkIdentities() {
    static const std::vector<std::string> identities={"com.lixinmo.skytouch.app","SkyTouchMapping",
        "SkyTouchBLE","com.lixinmo.skytouch.probe"};
    return identities;
}
bool ownByHostPreference(const std::string &name) {
    for(const auto &identity:frameworkIdentities()) {
        if(name==identity+".plist")return true;
        const std::string prefix=identity+".",suffix=".plist";
        if(name.size()!=prefix.size()+36+suffix.size() || name.rfind(prefix,0)!=0 ||
            name.compare(name.size()-suffix.size(),suffix.size(),suffix)!=0)continue;
        NSString *host=string(name.substr(prefix.size(),36));
        if([[NSUUID alloc]initWithUUIDString:host])return true;
    }
    return false;
}
int optionalPath(int parent,std::initializer_list<const char *> path) {
    FD current(dup(parent));if(current.fd<0)io("Cannot inspect framework directory");
    for(const char *component:path) {
        current=FD(directory(current.fd,component,false,true));
        if(current.fd<0)return -1;
    }
    int result=current.fd;current.fd=-1;return result;
}
void clearFrameworkLibrary(int library,bool dryRun) {
    auto handle=[&](int parent,const std::string &name){if(dryRun)preflightTree(parent,name);else erase(parent,name);};
    for(const char *parentName:{"Caches","HTTPStorages","WebKit","Saved Application State","Cookies","Preferences"}) {
        FD parent(optionalPath(library,{parentName}));if(parent.fd<0)continue;
        const std::string component=parentName;
        for(const auto &identity:frameworkIdentities()) {
            std::string name=identity;
            if(component=="Saved Application State")name+=".savedState";
            else if(component=="Cookies")name+=".binarycookies";
            else if(component=="Preferences")name+=".plist";
            handle(parent.fd,name);
        }
        if(component=="Preferences") {
            FD byHost(optionalPath(parent.fd,{"ByHost"}));
            if(byHost.fd>=0)for(const auto &name:names(byHost.fd))if(ownByHostPreference(name))handle(byHost.fd,name);
        }
    }
    FD snapshots(optionalPath(library,{"SplashBoard","Snapshots"}));
    if(snapshots.fd>=0)for(const auto &identity:frameworkIdentities())handle(snapshots.fd,identity);
}
void clearFrameworkFiles(bool dryRun) {
    // /var itself is a trusted OS/RootHide link. Resolve only that anchor;
    // every component below it is opened separately with O_NOFOLLOW. In
    // particular a Library, SplashBoard or ByHost link must fail preflight.
    NSString *rootedVar=OPStorageRootedPath(@"/var");
    if(!rootedVar.length)fail("RootHide framework storage is unavailable");
    rootedVar=rootedVar.stringByResolvingSymlinksInPath;
    NSString *nativeVar=@"/private/var";
    for(NSString *anchor in @[rootedVar,nativeVar]) {
        FD var(fixedDirectory(anchor,true));if(var.fd<0)continue;
        for(const char *user:{"mobile","root"}) {
            FD library(optionalPath(var.fd,{user,"Library"}));
            if(library.fd>=0)clearFrameworkLibrary(library.fd,dryRun);
        }
    }
}
void clearExtras(Locations &locations,bool dryRun=false) {
    auto handle=[&](int parent,const std::string &name){if(dryRun)preflightTree(parent,name);else erase(parent,name);};
    // Also revalidate on committed-transaction recovery and acknowledgement:
    // a framework can write new state while the App displays its exit alert.
    if(!dryRun)clearFrameworkFiles(true);
    clearFrameworkFiles(dryRun);
    if(dryRun){FD caches(directory(locations.library.fd,"Caches",false,true));if(caches.fd>=0)preflightTree(caches.fd,package);}else cleanRuntime(locations);
    cleanPreferences(locations.library.fd,false,dryRun);cleanPreferences(locations.rootLibrary.fd,true,dryRun);
    NSString *legacy=@"/var/mobile/Library";
    FD library(fixedDirectory(legacy,true));if(library.fd>=0){struct stat a{},b{};if(fstat(library.fd,&a)||fstat(locations.library.fd,&b))io("Cannot compare storage roots");if(a.st_dev==b.st_dev&&a.st_ino==b.st_ino)fail("Legacy and RootHide roots must be distinct");FD support(directory(library.fd,"Application Support",false,true));if(support.fd>=0)handle(support.fd,"SkyTouchOriginal");cleanPreferences(library.fd,false,dryRun);}
    handle(locations.support.fd,".com.lixinmo.skytouch.migration-stage-v1");
    for(int media:{locations.mediaFD(false),locations.legacyMediaFD()})if(media>=0)for(const auto &name:names(media))if(backupPrefix(string(name))||scratchName(name)){struct stat st{};if(!exists(media,name,&st)||!S_ISREG(st.st_mode)||st.st_nlink!=1)fail("Backup cleanup encountered a link or non-file");handle(media,name);}
}
struct Target {std::string id,name;FD parent;Target(std::string value,std::string n,int p):id(value),name(n),parent(p){}};
std::vector<Target> targets(Locations &locations) {
    std::vector<Target> result;result.emplace_back("data",package,dup(locations.support.fd));
    for(NSString *identifier in preferenceIDs()){int parent=locations.preferenceParent(identifier,true);if(parent<0)fail("Application preference directory is unavailable");result.emplace_back(utf8(identifier),Locations::preferenceName(identifier),parent);}
    result.emplace_back("pending",pendingName,dup(locations.support.fd));return result;
}
void move(int from,const std::string &source,int to,const std::string &destination) {
    if(renameatx_np(from,source.c_str(),to,destination.c_str(),RENAME_EXCL))io("Cannot move configuration transaction entry");
    if(fsync(from)||fsync(to))io("Cannot sync configuration transaction move");
}
NSDictionary *journal(int tx){id value=parse(read(tx,"journal.plist",1024*1024));if(![value isKindOfClass:NSDictionary.class]||![value[@"version"] isEqual:@1]||![@[@"restore",@"clear"] containsObject:value[@"operation"]]||![@[@"prepared",@"committed"] containsObject:value[@"phase"]]||![value[@"slots"] isKindOfClass:NSArray.class]||[value[@"slots"] count]!=5)fail("Invalid configuration transaction record");return value;}
void syncRootPreferences(Locations &locations) {
    for(NSString *identifier in @[@"root-app",@"root-mapping"]) {
        FD parent(locations.preferenceParent(identifier,true));if(parent.fd<0)fail("Root preference directory is unavailable");
        auto name=Locations::preferenceName(identifier);bool present=exists(parent.fd,name);
        if(present)preferenceOwnership(parent.fd,name,utf8(identifier));
        NSDictionary *expected=present ? parse(read(parent.fd,name)) : @{};
        if(![expected isKindOfClass:NSDictionary.class])fail("Invalid root preference dictionary");
        NSString *domain=[identifier isEqual:@"root-app"]?@"com.lixinmo.skytouch.app":@"SkyTouchMapping";
        CFStringRef appID=(__bridge CFStringRef)domain;
        CFArrayRef previous=CFPreferencesCopyKeyList(appID,kCFPreferencesCurrentUser,kCFPreferencesAnyHost);
        NSMutableArray *removed=[NSMutableArray array];
        for(NSString *key in (__bridge NSArray *)previous)if(!expected[key])[removed addObject:key];
        CFPreferencesSetMultiple((__bridge CFDictionaryRef)expected,(__bridge CFArrayRef)removed,appID,kCFPreferencesCurrentUser,kCFPreferencesAnyHost);
        if(previous)CFRelease(previous);
        if(!CFPreferencesSynchronize(appID,kCFPreferencesCurrentUser,kCFPreferencesAnyHost))fail("Cannot synchronize root application settings");
        if(present) {
            if(!exists(parent.fd,name)||![parse(read(parent.fd,name)) isEqual:expected])fail("Root application settings did not synchronize to RootHide storage");
        } else {
            if(exists(parent.fd,name)) {
                if(![parse(read(parent.fd,name)) isEqual:@{}])fail("Root application settings were recreated with stale values");
                erase(parent.fd,name);
            }
        }
    }
}
void initializeEmpty(Locations &locations) {
    if(exists(locations.support.fd,package))return;
    FD data(directory(locations.support.fd,package,true));
    FD settings(directory(data.fd,"Settings",true)),profiles(directory(data.fd,"Profiles",true));
    if(fsync(data.fd)||fsync(locations.support.fd))io("Cannot sync empty configuration directories");
}
void recover(Locations &locations) {
    FD tx(directory(locations.support.fd,transaction,false,true));if(tx.fd<0)return;
    if(!exists(tx.fd,"journal.plist")){erase(locations.support.fd,transaction);return;}
    NSDictionary *record=journal(tx.fd);auto items=targets(locations);NSArray *slots=record[@"slots"];
    for(size_t i=0;i<items.size();++i){NSDictionary *slot=slots[i];if(![slot isKindOfClass:NSDictionary.class]||![slot[@"id"] isEqual:string(items[i].id)]||![slot[@"hadOld"] isKindOfClass:NSNumber.class]||![slot[@"hasNew"] isKindOfClass:NSNumber.class])fail("Invalid configuration transaction target");}
    if([record[@"phase"] isEqual:@"prepared"]){FD old(directory(tx.fd,"old"));
        for(size_t i=0;i<items.size();++i){auto &target=items[i];NSDictionary *slot=slots[i];if(exists(old.fd,target.id)){
            erase(target.parent.fd,target.name);
            if(target.id=="data")move(old.fd,target.id,target.parent.fd,target.name);
            else {write(target.parent.fd,target.name,read(old.fd,target.id));preferenceOwnership(target.parent.fd,target.name,target.id);if(fsync(target.parent.fd))io("Cannot sync restored preference");}
        }else if(![slot[@"hadOld"] boolValue])erase(target.parent.fd,target.name);else if(!exists(target.parent.fd,target.name))fail("Original configuration is missing from interrupted transaction");}
        syncRootPreferences(locations);
        // A preference daemon may have observed a replaced mobile plist even
        // when the transaction did not reach commit. Keep the original bytes
        // authoritative until the App synchronizes its own domain and acks.
        // The old/mobile-app slot remains immutable throughout rollback; if
        // that move never happened, the live file is still the original.
        NSDictionary *mobileSlot=slots[1];BOOL present=[mobileSlot[@"hadOld"] boolValue];
        NSData *original=serialize(@{});
        if(present) {
            original=exists(old.fd,"mobile-app") ? read(old.fd,"mobile-app") : read(items[1].parent.fd,items[1].name);
            if(![parse(original) isKindOfClass:NSDictionary.class])fail("Original application settings need manual recovery");
        }
        NSDictionary *pending=@{@"version":@1,@"operation":@"restore",@"id":NSUUID.UUID.UUIDString,
            @"present":@(present),@"defaultsData":original,@"sha256":hash(original)};
        atomic(tx.fd,"rollback-pending.plist",serialize(pending));
        move(tx.fd,"rollback-pending.plist",locations.support.fd,pendingName);

    } else if([record[@"operation"] isEqual:@"clear"])clearExtras(locations);
    erase(locations.support.fd,transaction);
}
void preflightTree(int parent,const std::string &name) {
    struct stat st{};if(!exists(parent,name,&st))return;
    if(S_ISDIR(st.st_mode)){FD child(directory(parent,name));for(const auto &n:names(child.fd))preflightTree(child.fd,n);}
    else {FD file(regular(parent,name));}
}
void commit(Locations &locations,NSDictionary *archive,bool clear) {
    if(clear)clearExtras(locations,true);
    FD tx(directory(locations.support.fd,transaction,true));FD staged(directory(tx.fd,"new",true)),old(directory(tx.fd,"old",true));
    FD data(directory(staged.fd,"data",true));
    if(clear){FD settings(directory(data.fd,"Settings",true));(void)settings;}else materialize(data.fd,archive[@"entries"]);
    emptyReceipt(data.fd);disableMapping(data.fd);if(fsync(data.fd))io("Cannot sync replacement configuration");
    auto items=targets(locations);for(auto &target:items)preflightTree(target.parent.fd,target.name);NSMutableArray *slots=[NSMutableArray array];
    for(auto &target:items){bool hasNew=target.id=="pending" || (!clear && target.id=="data");if(!clear&&target.id!="data"&&target.id!="pending"){NSDictionary *pref=archive[@"preferences"][string(target.id)];hasNew=[pref[@"present"] boolValue];if(hasNew){write(staged.fd,target.id,pref[@"bytes"]);preferenceOwnership(staged.fd,target.id,target.id);}}
        [slots addObject:@{@"id":string(target.id),@"hadOld":@(exists(target.parent.fd,target.name)),@"hasNew":@(hasNew)}];}
    NSDictionary *mobile=clear ? @{@"present":@NO} : archive[@"preferences"][@"mobile-app"];
    NSData *defaults=[mobile[@"present"] boolValue]?mobile[@"bytes"]:serialize(@{});
    NSDictionary *pending=@{@"version":@1,@"operation":clear?@"clear":@"restore",@"id":NSUUID.UUID.UUIDString,@"present":mobile[@"present"],@"defaultsData":defaults,@"sha256":hash(defaults)};
    write(staged.fd,"pending",serialize(pending));
    if(fsync(staged.fd)||fsync(old.fd)||fsync(tx.fd)||fsync(locations.support.fd))io("Cannot sync prepared configuration");
    NSMutableDictionary *record=[@{@"version":@1,@"operation":clear?@"clear":@"restore",@"phase":@"prepared",@"slots":slots} mutableCopy];atomic(tx.fd,"journal.plist",serialize(record));

    for(size_t i=0;i<items.size();++i){auto &target=items[i];NSDictionary *slot=slots[i];if([slot[@"hadOld"] boolValue])move(target.parent.fd,target.name,old.fd,target.id);if([slot[@"hasNew"] boolValue])move(staged.fd,target.id,target.parent.fd,target.name);}
    syncRootPreferences(locations);cleanRuntime(locations);record[@"phase"]=@"committed";atomic(tx.fd,"journal.plist",serialize(record));
    if(clear)clearExtras(locations);erase(locations.support.fd,transaction);
}
NSDictionary *pendingRecord(Locations &locations) {
    if(!exists(locations.support.fd,pendingName))return nil;
    NSDictionary *value=parse(read(locations.support.fd,pendingName,maxFile+1024*1024));
    if(![value isKindOfClass:NSDictionary.class]||![value[@"version"] isEqual:@1]||![@[@"restore",@"clear"] containsObject:value[@"operation"]]||!identifierOK(value[@"id"])||![value[@"present"] isKindOfClass:NSNumber.class])fail("Invalid pending application settings");
    NSData *bytes=value[@"defaultsData"];
    if(![bytes isKindOfClass:NSData.class]||bytes.length>maxFile||![value[@"sha256"] isEqual:hash(bytes)]||![parse(bytes) isKindOfClass:NSDictionary.class])fail("Pending application settings checksum failed");
    if([value[@"operation"] isEqual:@"clear"] && ([value[@"present"] boolValue]||[parse(bytes) count]!=0))fail("Invalid pending clear operation");
    return value;
}
NSDictionary *pendingResult(NSDictionary *record) {
    return @{@"mobileDefaults":parse(record[@"defaultsData"]),@"pendingID":record[@"id"],@"pendingOperation":record[@"operation"],@"mobileDefaultsPresent":record[@"present"]};
}
NSDictionary *replayPending(Locations &locations,NSDictionary *record) {
    FD parent(locations.preferenceParent(@"mobile-app",true));if(parent.fd<0)fail("Mobile preference directory is unavailable");
    const auto name=Locations::preferenceName(@"mobile-app");
    if([record[@"present"] boolValue])atomic(parent.fd,name,record[@"defaultsData"]);
    else erase(parent.fd,name);
    return pendingResult(record);
}
NSDictionary *acknowledge(Locations &locations,NSString *identifier,NSDictionary *record) {
    if(!record||![record[@"id"] isEqual:identifier])fail("Application settings acknowledgement is stale");
    FD parent(locations.preferenceParent(@"mobile-app",true));if(parent.fd<0)fail("Mobile preference directory is unavailable");
    auto name=Locations::preferenceName(@"mobile-app");NSDictionary *expected=parse(record[@"defaultsData"]);
    NSDictionary *actual=exists(parent.fd,name)?parse(read(parent.fd,name)):@{};
    if(![actual isKindOfClass:NSDictionary.class]||![actual isEqual:expected])fail("Application settings have not synchronized yet");
    if([record[@"operation"] isEqual:@"clear"])clearExtras(locations);
    else if(![record[@"present"] boolValue])erase(parent.fd,name);
    erase(locations.support.fd,pendingName);return @{@"acknowledged":@YES};
}
// Transfer the v43 backup location without assuming that a rename can cross
// filesystems. Every source remains until its complete destination is durable
// and verified. Equal-name equal-content files make interrupted runs retryable.
void migrateLegacyBackups(Locations &locations) {
    int legacy=locations.legacyMediaFD();if(legacy<0)return;
    std::vector<std::string> selected;
    for(const auto &name:names(legacy))if(backupPrefix(string(name)))selected.push_back(name);
    if(selected.empty())return;
    if(selected.size()>maxEntries)fail("Too many legacy backup files");
    int destination=locations.mediaFD(true);struct stat sourceRoot{},destinationRoot{};
    if(fstat(legacy,&sourceRoot)||fstat(destination,&destinationRoot))io("Cannot compare backup directories");
    if(sourceRoot.st_dev==destinationRoot.st_dev && sourceRoot.st_ino==destinationRoot.st_ino)return;
    struct Expected {struct stat state;std::string digest;};std::map<std::string,Expected> expected;std::set<std::string> retained;
    // Preflight all names before copying or deleting any legacy backup.
    for(const auto &name:selected) {@autoreleasepool{
        struct stat state{};if(!exists(legacy,name,&state))fail("Legacy backup disappeared during migration");
        NSData *bytes=read(legacy,name,maxArchive);std::string digest=utf8(hash(bytes));
        if(exists(destination,name) && ![read(destination,name,maxArchive) isEqual:bytes]) {
            if(name==fixedBackup){retained.insert(name);continue;}
            fail("A different backup with the same filename already exists in Media");
        }
        expected.emplace(name,Expected{state,digest});
    }}
    selected.erase(std::remove_if(selected.begin(),selected.end(),[&](const std::string &name){return retained.count(name)>0;}),selected.end());

    for(const auto &name:selected) {@autoreleasepool{
        const Expected &entry=expected.at(name);struct stat current{};
        if(!exists(legacy,name,&current)||!same(entry.state,current))fail("Legacy backup changed before copying");
        NSData *bytes=read(legacy,name,maxArchive);if(utf8(hash(bytes))!=entry.digest)fail("Legacy backup changed before copying");
        if(exists(destination,name)){if(![read(destination,name,maxArchive) isEqual:bytes])fail("Backup destination changed during migration");continue;}
        std::string temp=".com.lixinmo.skytouch.archive-write-"+utf8(NSUUID.UUID.UUIDString);
        try {write(destination,temp,bytes);if(![read(destination,temp,maxArchive) isEqual:bytes])fail("Migrated backup checksum failed");move(destination,temp,destination,name);}
        catch(...){if(exists(destination,temp))erase(destination,temp);throw;}
    }}

    // Verify the complete set again before the first source unlink.
    for(const auto &name:selected) {@autoreleasepool{
        if(utf8(hash(read(legacy,name,maxArchive)))!=expected.at(name).digest || utf8(hash(read(destination,name,maxArchive)))!=expected.at(name).digest)fail("Backup migration verification failed; original files retained");
    }}

    for(const auto &name:selected) {@autoreleasepool{
        FD original(regular(legacy,name));struct stat opened{},current{};
        if(fstat(original.fd,&opened)||!same(opened,expected.at(name).state)||utf8(hash(read(legacy,name,maxArchive)))!=expected.at(name).digest||utf8(hash(read(destination,name,maxArchive)))!=expected.at(name).digest||!exists(legacy,name,&current)||!same(opened,current))fail("Legacy backup changed before removal; original retained");
        if(unlinkat(legacy,name.c_str(),0)||fsync(legacy))io("Cannot remove verified legacy backup");
    }}
}
NSDictionary *list(Locations &locations) {
    NSMutableArray *backups=[NSMutableArray array];int media=locations.mediaFD(false);BOOL hasFixed=media>=0&&exists(media,fixedBackup);
    if(media>=0)for(const auto &name:names(media)){NSString *filename=string(name);if(!backupName(filename)||(hasFixed&&name!=fixedBackup))continue;struct stat st{};if(!exists(media,name,&st)||!S_ISREG(st.st_mode)||st.st_nlink!=1||st.st_size<0||(uint64_t)st.st_size>maxArchive)continue;
        [backups addObject:@{@"filename":filename,@"path":nativeBackupPath(filename),@"size":@(st.st_size),@"createdAt":@(st.st_mtimespec.tv_sec)}];}
    [backups sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [b[@"filename"] compare:a[@"filename"]];}];return @{@"backups":backups};
}
bool generatedHistoricalBackup(NSString *name) {
    NSString *pattern=@"^com\\.lixinmo\\.skytouchSetting\\.[0-9]{8}T[0-9]{6}Z\\.[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\.skytouchbackup$";
    return [name rangeOfString:pattern options:NSRegularExpressionSearch].length==name.length;
}
void backupHistory(Locations &locations,bool dryRun) {
    for(int directoryFD:{locations.mediaFD(false),locations.legacyMediaFD()}) {
        if(directoryFD<0)continue;
        bool normal=directoryFD==locations.media.fd;
        for(const auto &name:names(directoryFD)) {
            if((normal&&name==fixedBackup) || (!generatedHistoricalBackup(string(name)) && !(name==fixedBackup&&!normal)))continue;
            struct stat state{};
            if(!exists(directoryFD,name,&state)||!S_ISREG(state.st_mode)||state.st_nlink!=1)fail("Old backup cleanup encountered a link or non-file");
            if(dryRun){FD input(regular(directoryFD,name));}else erase(directoryFD,name);
        }
    }
}
NSDictionary *backup(Locations &locations) {
    int media=locations.mediaFD(true);struct stat previousState{};BOOL previous=exists(media,fixedBackup,&previousState);
    // Explicit backup replaces even a damaged ordinary current file. Links
    // and special objects are refused; the swap retains its original bytes
    // until the replacement has been validated and committed.
    if(previous){FD old(regular(media,fixedBackup));struct stat opened{};if(fstat(old.fd,&opened)||!same(previousState,opened))fail("Current backup changed before replacement");}
    backupHistory(locations,true);
    NSDictionary *first=snapshot(locations);NSDictionary *second=snapshot(locations);if(![first isEqual:second])fail("Configuration changed during backup; please try again");
    NSMutableDictionary *archive=[first mutableCopy];archive[@"format"]=@"com.lixinmo.skytouch.configuration";archive[@"version"]=@1;archive[@"createdAt"]=NSDate.date;validate(archive);NSData *bytes=serialize(archive);if(bytes.length>maxArchive)fail("Backup exceeds supported size limit");
    NSString *filename=@(fixedBackup);std::string temp=".com.lixinmo.skytouch.archive-write-"+utf8(NSUUID.UUID.UUIDString);bool published=false;
    try {
        write(media,temp,bytes);NSData *verified=read(media,temp,maxArchive);validate(parse(verified));
        if(![verified isEqual:bytes])fail("Written backup verification failed");
        struct stat current{};bool stillPresent=exists(media,fixedBackup,&current);
        if(stillPresent!=(bool)previous || (previous&&!same(previousState,current)))fail("Current backup changed before replacement");

        // Swap keeps the previous backup in the private temporary slot until
        // the new fixed file is verified and its directory entry is durable.
        unsigned flags=previous?RENAME_SWAP:RENAME_EXCL;
        if(renameatx_np(media,temp.c_str(),media,fixedBackup,flags))io("Cannot atomically replace current backup");
        published=true;
        if(fsync(media)||![read(media,fixedBackup,maxArchive) isEqual:bytes])fail("Current backup could not be verified after replacement");
    }catch(...) {
        if(published) {
            int rollback=previous?renameatx_np(media,temp.c_str(),media,fixedBackup,RENAME_SWAP):renameatx_np(media,fixedBackup,media,temp.c_str(),RENAME_EXCL);
            if(rollback||fsync(media))fail("Backup replacement needs attention; the previous copy was retained in Media");
        }
        if(exists(media,temp))erase(media,temp);throw;
    }
    if(exists(media,temp))erase(media,temp);
    // The newly completed current-configuration backup is now authoritative.
    // Only at this point retire this feature's historical backup files.
    backupHistory(locations,false);
    return @{@"backupFilename":filename,@"backupPath":nativeBackupPath(filename),@"bytes":@(bytes.length),@"fileCount":@([archive[@"entries"] count])};
}

} // namespace

BOOL OPConfigurationArchiveNeedsRecovery(void) {
    @try {try {op_archive::Locations locations;return op_archive::exists(locations.support.fd,op_archive::transaction)||op_archive::exists(locations.support.fd,op_archive::pendingName)||!op_archive::exists(locations.support.fd,op_archive::package);}catch(...){return YES;}}@catch(NSException *exception){(void)exception;return YES;}
}
NSDictionary *OPConfigurationArchivePerformWithLockedLibrary(NSString *operation,NSString *basename,int lockedLibrary,NSString **error) {
    if(error)*error=nil;
    @try {
        try {
            if(geteuid()!=0)op_archive::fail("Configuration management requires the storage helper");
            if(![@[@"list",@"backup",@"restore",@"clear",@"recover",@"acknowledge"] containsObject:operation])op_archive::fail("Unknown configuration operation");
            if([operation isEqual:@"restore"] ? !op_archive::backupName(basename) : ([operation isEqual:@"acknowledge"] ? !op_archive::identifierOK(basename) : basename.length>0))op_archive::fail("Invalid configuration operation argument");
            op_archive::Locations locations;
            // The helper also holds its lifecycle guard. This library flock
            // serializes archives with installer migration without new files.
            if(lockedLibrary>=0) {
                struct stat supplied{},expected{};
                if(fstat(lockedLibrary,&supplied)||fstat(locations.library.fd,&expected)||!S_ISDIR(supplied.st_mode)||supplied.st_dev!=expected.st_dev||supplied.st_ino!=expected.st_ino)
                    op_archive::fail("Invalid storage helper lock descriptor");
                if(flock(lockedLibrary,LOCK_EX|LOCK_NB))op_archive::fail("Configuration management is already running");
            }else if(flock(locations.library.fd,LOCK_EX|LOCK_NB))op_archive::fail("Configuration management is already running");
            op_archive::recover(locations);
            NSDictionary *pending=op_archive::pendingRecord(locations);
            if([operation isEqual:@"recover"]){if(pending)return op_archive::replayPending(locations,pending);op_archive::migrateLegacyBackups(locations);op_archive::initializeEmpty(locations);return @{@"recovered":@YES};}
            if([operation isEqual:@"acknowledge"])return op_archive::acknowledge(locations,basename,pending);
            if(pending)op_archive::fail("Application settings need synchronization; reopen SkyTouch first");
            if(![operation isEqual:@"clear"]&&![operation isEqual:@"backup"])op_archive::migrateLegacyBackups(locations);
            if([operation isEqual:@"list"])return op_archive::list(locations);
            if([operation isEqual:@"backup"])return op_archive::backup(locations);
            NSDictionary *archive=nil;if([operation isEqual:@"restore"]){int media=locations.mediaFD(false);if(media<0)op_archive::fail("No configuration backup exists");archive=op_archive::parse(op_archive::read(media,op_archive::utf8(basename),op_archive::maxArchive));op_archive::validate(archive);}
            try {op_archive::commit(locations,archive,[operation isEqual:@"clear"]);}catch(...){try{op_archive::recover(locations);}catch(...){op_archive::fail("Configuration transaction needs recovery; reopen SkyTouch before using it");}throw;}
            return op_archive::pendingResult(op_archive::pendingRecord(locations));
        }catch(const std::exception &failure){if(error)*error=[NSString stringWithUTF8String:failure.what()];return nil;}
    }@catch(NSException *exception){(void)exception;if(error)*error=@"配置备份格式无效或资源不足，未完成操作。";return nil;}
}
NSDictionary *OPConfigurationArchivePerform(NSString *operation,NSString *basename,NSString **error) {return OPConfigurationArchivePerformWithLockedLibrary(operation,basename,-1,error);}
