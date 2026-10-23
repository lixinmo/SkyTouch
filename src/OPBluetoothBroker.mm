#import "OPStoragePaths.h"
#import "OPBluetoothBroker.h"
#import "OPControllerIdentity.h"
#import "OPBluetoothLifetime.h"
#import "OPRuntimeControl.h"
#import "OPServicePaths.h"
#import "../shared/src/SMBluetooth.h"
#import <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <mach/mach_time.h>
#include <notify.h>
#include <spawn.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <cmath>

extern char **environ;
NSString *const OPBluetoothBrokerPortName=@"com.lixinmo.skytouch.original.bluetooth.broker";
NSString *const OPBluetoothBrokerStatusPath=OPRuntimePath(@"com.lixinmo.skytouch.original-bluetooth-status.plist");
NSString *const OPBluetoothBrokerSelectionPath=OPSettingPath(@"com.lixinmo.skytouch.original-bluetooth-selection.plist");
const char *const OPBluetoothBrokerStopNotification="com.lixinmo.skytouch.original.bluetooth.stop";
const char *const OPBluetoothBrokerDataNotification="com.lixinmo.skytouch.original.bluetooth.data-available";
static NSString *const OPBrokerTokenPath=OPRuntimePath(@"com.lixinmo.skytouch.original-bluetooth-token");
static NSString *const OPBrokerLockPath=OPRuntimePath(@"com.lixinmo.skytouch.original-bluetooth.lock");
static constexpr NSUInteger OPBrokerMaxReplyBytes=128*1024;

static uint64_t OPBrokerNow(void) {
    static mach_timebase_info_data_t base;
    static dispatch_once_t once;
    dispatch_once(&once,^{ mach_timebase_info(&base); });
    return (uint64_t)(((__uint128_t)mach_continuous_time()*base.numer)/base.denom);
}
static BOOL OPBrokerFail(NSString **error, NSString *reason) { if(error)*error=reason; return NO; }
static BOOL OPBrokerUInt(id value,uint64_t *out) {
    if(![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID())return NO;
    const char *type=[value objCType];
    if(!type || strchr("cCsSiIlLqQ",type[0])==nullptr || [value compare:@0]==NSOrderedAscending)return NO;
    *out=[value unsignedLongLongValue]; return YES;
}
static NSString *OPBrokerUUID(id value) {
    if(![value isKindOfClass:NSString.class] || [value length]!=36)return nil;
    return [[NSUUID alloc]initWithUUIDString:value].UUIDString;
}
static NSData *OPBrokerReadFile(NSString *path,NSUInteger limit,BOOL token) {
    int fd=open(path.fileSystemRepresentation,O_RDONLY|O_CLOEXEC|O_NOFOLLOW);
    if(fd<0)return nil;
    struct stat before{},after{};
    BOOL valid=fstat(fd,&before)==0 && S_ISREG(before.st_mode) && before.st_nlink==1 &&
        (before.st_uid==0 || before.st_uid==501) && before.st_size>=0 && (uint64_t)before.st_size<=limit;
    if(token)valid=valid && before.st_uid==501 && (before.st_mode&0777)==0600 && before.st_size==32;
    NSMutableData *data=valid ? [NSMutableData dataWithLength:(NSUInteger)before.st_size] : nil;
    size_t offset=0;
    while(valid && offset<data.length) {
        ssize_t count=read(fd,(uint8_t *)data.mutableBytes+offset,data.length-offset);
        if(count<0 && errno==EINTR)continue;
        if(count<=0){valid=NO;break;} offset+=(size_t)count;
    }
    valid=valid && fstat(fd,&after)==0 && before.st_dev==after.st_dev && before.st_ino==after.st_ino &&
        before.st_size==after.st_size && after.st_nlink==1 && after.st_uid==before.st_uid && after.st_mode==before.st_mode;
    close(fd); return valid ? data : nil;
}
static NSDictionary *OPBrokerReadPlist(NSString *path,NSUInteger limit) {
    NSData *data=OPBrokerReadFile(path,limit,NO);
    id result=data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:nil] : nil;
    return [result isKindOfClass:NSDictionary.class] ? result : nil;
}
static BOOL OPBrokerWrite(NSString *path,NSData *data) {
    struct stat existing{};
    if(lstat(path.fileSystemRepresentation,&existing)==0 &&
       (!S_ISREG(existing.st_mode)||existing.st_nlink!=1||(existing.st_uid!=0&&existing.st_uid!=501)))return NO;
    NSString *pattern=[path stringByAppendingString:@".XXXXXX"];
    char *temporary=strdup(pattern.fileSystemRepresentation);
    int fd=mkstemp(temporary);
    if(fd<0){free(temporary);return NO;}
    BOOL valid=fchmod(fd,0600)==0 && (geteuid()!=0 || fchown(fd,501,501)==0);
    size_t offset=0;
    while(valid && offset<data.length) {
        ssize_t count=write(fd,(const uint8_t *)data.bytes+offset,data.length-offset);
        if(count<0 && errno==EINTR)continue;
        if(count<=0){valid=NO;break;}offset+=(size_t)count;
    }
    if(valid)valid=fsync(fd)==0;
    close(fd);
    if(valid)valid=rename(temporary,path.fileSystemRepresentation)==0;
    if(!valid)unlink(temporary);
    free(temporary);return valid;
}
static BOOL OPBrokerWritePlist(NSString *path,NSDictionary *value) {
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:value format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    return data && OPBrokerWrite(path,data);
}
static BOOL OPBrokerTokenEqual(NSData *a,id b) {
    if(![b isKindOfClass:NSData.class]||a.length!=32||[b length]!=32)return NO;
    const uint8_t *x=(const uint8_t *)a.bytes,*y=(const uint8_t *)[b bytes];
    uint8_t difference=0;for(NSUInteger i=0;i<32;++i)difference|=x[i]^y[i];return difference==0;
}

// Diagnostic disk I/O must never block the Bluetooth/IPC run loop. At most one
// snapshot is being written and one (the latest) is waiting; older diagnostics
// can be coalesced because no input packet is persisted here.
@interface OPBrokerStatusWriter : NSObject
- (instancetype)initWithWrite:(void (^)(NSDictionary *))write;
- (void)submit:(NSDictionary *)snapshot;
- (void)finish:(NSDictionary *)snapshot;
@end
@implementation OPBrokerStatusWriter {
    dispatch_queue_t _queue;
    void (^_write)(NSDictionary *);
    NSDictionary *_pending;
    BOOL _scheduled;
}
- (instancetype)initWithWrite:(void (^)(NSDictionary *))write {
    if((self=[super init])) {
        _write=[write copy];
        _queue=dispatch_queue_create("com.lixinmo.skytouch.bluetooth.status-writer",
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_UTILITY,0));
    }
    return self;
}
- (void)submit:(NSDictionary *)snapshot {
    @synchronized(self) {
        _pending=[snapshot copy];
        if(_scheduled)return;
        _scheduled=YES;
        dispatch_async(_queue,^{
            for(;;) {
                @autoreleasepool {
                    NSDictionary *next=nil;
                    @synchronized(self) {
                        next=self->_pending;self->_pending=nil;
                        if(!next){self->_scheduled=NO;return;}
                    }
                    self->_write(next);
                }
            }
        });
    }
}
- (void)finish:(NSDictionary *)snapshot {
    [self submit:snapshot];
    dispatch_sync(_queue,^{}); // Main shutdown only; the final stopped state wins.
}
@end

@interface OPBluetoothBrokerOwner : NSObject
@property(nonatomic,strong) SMBluetooth *bluetooth;
@property(nonatomic,strong) OPBrokerStatusWriter *statusWriter;
@property(nonatomic,copy) NSData *token;
@property(nonatomic,copy) NSString *epoch;
@property(nonatomic,copy) NSString *selectionID;
@property(nonatomic,copy) NSString *selectionName;
@property(nonatomic,copy) NSDictionary *lastControllerIdentity;
@property(nonatomic,strong) NSMutableArray<NSDictionary *> *packets;
@property(nonatomic) uint64_t generation;
@property(nonatomic) uint64_t sequence;
@property(nonatomic) uint64_t lostThrough;
@property(nonatomic) uint64_t receivedThisConnection;
@property(nonatomic) uint64_t lastAttemptNs;
@property(nonatomic) uint64_t lastKnownRefreshNs;
@property(nonatomic) BOOL stopping;
@property(nonatomic) BOOL selectionQueued;
@property(nonatomic) BOOL shouldCheckLifetime;
@property(nonatomic) uint64_t idleSinceNs;
@property(nonatomic,copy) NSDictionary *keepAliveState;
- (BOOL)retireIfUnusedAt:(uint64_t)now;
- (void)syncGeneration;
- (void)considerSelection;
- (void)tick;
- (NSDictionary *)snapshot;
- (NSDictionary *)diskSnapshot;
- (NSDictionary *)request:(NSDictionary *)request;
- (void)appendControllerIdentityTo:(NSMutableDictionary *)state;
@end

@implementation OPBluetoothBrokerOwner
- (BOOL)retireIfUnusedAt:(uint64_t)now {
    if(self.stopping)return YES;
    self.keepAliveState=OPBluetoothLifetimeState();
    if([self.keepAliveState[@"required"] boolValue]) {self.idleSinceNs=0;return NO;}
    if(!self.idleSinceNs || now<self.idleSinceNs) {self.idleSinceNs=now;return NO;}
    // A short grace period covers the handoff between editor and engine. It
    // is never extended by ordinary status reads or a disconnected radio.
    if(now-self.idleSinceNs<NSEC_PER_SEC)return NO;
    self.stopping=YES;return YES;
}
- (void)appendControllerIdentityTo:(NSMutableDictionary *)state {
    NSDictionary *identity=self.lastControllerIdentity;
    if(!identity)return;
    state[@"lastKnownPeripheralType"]=identity[@"peripheralType"];
    state[@"lastKnownDeviceID"]=identity[@"identifier"];
    state[@"lastKnownDeviceName"]=identity[@"name"];
    // A remembered type is useful for editing offline, but describes the
    // current link only when the connected UUID matches. Never reuse another
    // controller's type or turn this metadata into input readiness.
    if(!self.stopping && self.bluetooth.connected && self.bluetooth.currentDeviceIdentifier.length &&
       [self.bluetooth.currentDeviceIdentifier caseInsensitiveCompare:identity[@"identifier"]]==NSOrderedSame)
        state[@"currentPeripheralType"]=identity[@"peripheralType"];
}
- (void)syncGeneration {
    uint64_t current=self.bluetooth.connectionGeneration;
    if(current!=self.generation) {
        self.generation=current;self.receivedThisConnection=0;
        [self.packets removeAllObjects];self.lostThrough=self.sequence;
    }
}
- (void)considerSelection {
    if(self.stopping||self.selectionQueued||self.bluetooth.currentDeviceIdentifier.length)return;
    self.selectionQueued=YES;
    __weak OPBluetoothBrokerOwner *weakSelf=self;
    // SMBluetooth publishes retrieved peripherals in the middle of starting a
    // scan. Connect on the next main turn so it cannot resume scanning afterward.
    dispatch_async(dispatch_get_main_queue(),^{
        OPBluetoothBrokerOwner *owner=weakSelf;if(!owner)return;
        owner.selectionQueued=NO;
        if(owner.stopping||owner.bluetooth.currentDeviceIdentifier.length)return;
        if(OPBrokerNow()-owner.lastAttemptNs<3*NSEC_PER_SEC)return;
        SMBluetoothDevice *match=nil;
        for(SMBluetoothDevice *device in owner.bluetooth.devices) {
            if(owner.selectionID.length) {
                if([device.identifier caseInsensitiveCompare:owner.selectionID]==NSOrderedSame){match=device;break;}
            } else if(owner.selectionName.length && [device.name isEqualToString:owner.selectionName]) {
                if(match)return; // A name shared by two discoveries is ambiguous.
                match=device;
            }
        }
        if(match) { owner.lastAttemptNs=OPBrokerNow();[owner.bluetooth connectDeviceID:match.identifier];[owner syncGeneration]; }
    });
}
- (NSDictionary *)snapshot {
    [self syncGeneration];
    NSMutableArray *devices=[NSMutableArray array];
    for(SMBluetoothDevice *device in self.bluetooth.devices) {
        if(devices.count==64)break;
        [devices addObject:@{@"id":device.identifier,@"identifier":device.identifier,@"name":device.name,@"RSSI":@(device.RSSI),
            @"systemConnected":@([self.bluetooth.systemConnectedDeviceIdentifiers containsObject:device.identifier])}];
    }
    NSMutableDictionary *state=[@{@"version":@1,@"epoch":self.epoch,@"generation":@(self.generation),
        @"pid":@(getpid()),@"time":@([NSDate date].timeIntervalSince1970),@"monotonicNs":@(OPBrokerNow()),
        @"connected":@(!self.stopping&&self.bluetooth.connected),@"scanning":@(!self.stopping&&self.bluetooth.scanning),
        @"bluetoothState":@(self.bluetooth.bluetoothState),@"deviceID":self.bluetooth.currentDeviceIdentifier?:@"",
        @"deviceName":self.bluetooth.currentDeviceName?:@"",@"devices":devices,@"sequence":@(self.sequence),
        @"receivedThisConnection":@(self.receivedThisConnection),@"running":@(!self.stopping),
        @"lifetime":self.keepAliveState ?: @{},@"idleShutdownPending":@(self.idleSinceNs!=0),
        @"serviceBundleID":NSBundle.mainBundle.bundleIdentifier ?: @"",@"UIApplicationClassPresent":@(NSClassFromString(@"UIApplication")!=Nil),
        @"status":self.stopping ? @"蓝牙服务已停止" : self.bluetooth.status} mutableCopy];
    [self appendControllerIdentityTo:state];return state;
}
- (void)tick {
    if(self.stopping)return;
    if(self.shouldCheckLifetime && [self retireIfUnusedAt:OPBrokerNow()]) {
        CFRunLoopStop(CFRunLoopGetMain());return;
    }
    [self syncGeneration];
    if(self.bluetooth.connected) {
        NSString *identifier=self.bluetooth.currentDeviceIdentifier,*name=self.bluetooth.currentDeviceName;
        if(identifier.length && (![identifier isEqualToString:self.selectionID]||![name isEqualToString:self.selectionName])) {
            self.selectionID=identifier;self.selectionName=name?:@"";
            self.bluetooth.preferredPeripheralIdentifier=identifier;
            OPBrokerWritePlist(OPBluetoothBrokerSelectionPath,@{@"version":@1,@"identifier":identifier,@"name":self.selectionName});
        }
    } else if(!self.bluetooth.currentDeviceIdentifier.length && OPBrokerNow()-self.lastKnownRefreshNs>=3*NSEC_PER_SEC) {
        self.lastKnownRefreshNs=OPBrokerNow();
        [self.bluetooth refreshKnownDevices];[self considerSelection];
    }
    [self.statusWriter submit:[self diskSnapshot]];
}
- (NSDictionary *)diskSnapshot {
    NSMutableDictionary *state=[[self snapshot] mutableCopy];
    [state removeObjectForKey:@"devices"];
    // Add only scalar link diagnostics, without lastPacketHex or raw values.
    // The raw counters cover this SMBluetooth instance's complete lifetime;
    // receivedPacketCount/lastPacketLength retain their existing reset scope.
    state[@"rawValueCallbackCount"]=@(self.bluetooth.rawValueCallbackCount);
    state[@"rawValueIdentityMatchCount"]=@(self.bluetooth.rawValueIdentityMatchCount);
    state[@"rawValueMatchedErrorCount"]=@(self.bluetooth.rawValueMatchedErrorCount);
    state[@"rawValueNotifyingCount"]=@(self.bluetooth.rawValueNotifyingCount);
    state[@"rawForwardedCount"]=@(self.bluetooth.rawForwardedCount);
    state[@"notifySubscriptionConfirmationCount"]=@(self.bluetooth.notifySubscriptionConfirmationCount);
    state[@"notifySubscriptionErrorCount"]=@(self.bluetooth.notifySubscriptionErrorCount);
    state[@"initializationWriteACKCount"]=@(self.bluetooth.initializationWriteACKCount);
    state[@"initializationWriteErrorCount"]=@(self.bluetooth.initializationWriteErrorCount);
    state[@"notifyCharacteristicPresent"]=@(self.bluetooth.notifyCharacteristicPresent);
    state[@"notifyCharacteristicNotifying"]=@(self.bluetooth.notifyCharacteristicNotifying);
    state[@"receivedPacketCount"]=@(self.bluetooth.receivedPacketCount);
    state[@"lastPacketLength"]=@(self.bluetooth.lastPacketLength);
    return state;
}
- (NSDictionary *)request:(NSDictionary *)request {
    if(self.stopping)return @{@"error":@"broker-stopping"};
    uint64_t version=0;
    if(!OPBrokerUInt(request[@"version"],&version)||version!=1||!OPBrokerTokenEqual(self.token,request[@"token"]))return nil;
    NSString *operation=request[@"op"];
    if(![operation isKindOfClass:NSString.class])return @{@"error":@"invalid-operation"};
    uint64_t cursor=0;
    const BOOL inputOnly=[operation isEqualToString:@"input"];
    if(inputOnly || [operation isEqualToString:@"status"]) {
        if(request[@"cursor"]&&!OPBrokerUInt(request[@"cursor"],&cursor))return @{@"error":@"invalid-cursor"};
    } else if([operation isEqualToString:@"scan"]) {
        // An explicit scan does not interrupt an existing connection.
        if(!self.bluetooth.currentDeviceIdentifier.length)[self.bluetooth scan];
        [self considerSelection];cursor=self.sequence;
    } else if([operation isEqualToString:@"select"]) {
        NSString *identifier=OPBrokerUUID(request[@"id"]);SMBluetoothDevice *selected=nil;
        for(SMBluetoothDevice *device in self.bluetooth.devices)
            if([device.identifier isEqualToString:identifier]){selected=device;break;}
        if(!selected)return @{@"error":@"device-not-in-discovery-list"};
        if(!OPBrokerWritePlist(OPBluetoothBrokerSelectionPath,@{@"version":@1,@"identifier":identifier,@"name":selected.name}))
            return @{@"error":@"selection-persistence-failed"};
        self.selectionID=identifier;self.selectionName=selected.name;
        self.bluetooth.preferredPeripheralIdentifier=identifier;
        if(![self.bluetooth.currentDeviceIdentifier isEqualToString:identifier]) {
            [self.bluetooth disconnect];self.lastAttemptNs=0;
            [self.bluetooth connectDeviceID:selected.identifier];self.lastAttemptNs=OPBrokerNow();
        }
        cursor=self.sequence;
    } else return @{@"error":@"unknown-operation"};
    NSMutableDictionary *response=nil;
    if(inputOnly) {
        [self syncGeneration];
        response=[@{@"version":@1,@"epoch":self.epoch,@"generation":@(self.generation),
            @"pid":@(getpid()),@"monotonicNs":@(OPBrokerNow()),
            @"connected":@(!self.stopping&&self.bluetooth.connected),@"scanning":@(!self.stopping&&self.bluetooth.scanning),
            @"bluetoothState":@(self.bluetooth.bluetoothState),@"deviceID":self.bluetooth.currentDeviceIdentifier?:@"",
            @"deviceName":self.bluetooth.currentDeviceName?:@"",@"devices":@[],@"sequence":@(self.sequence)} mutableCopy];
    } else response=[[self snapshot]mutableCopy];
    if(inputOnly)[self appendControllerIdentityTo:response];
    NSMutableArray *packets=[NSMutableArray array];
    for(NSDictionary *packet in self.packets) {
        if([packet[@"seq"]unsignedLongLongValue]>cursor)[packets addObject:packet];
        if(packets.count==64)break;
    }
    response[@"overflow"]=@(cursor<self.lostThrough||cursor>self.sequence);
    response[@"packets"]=packets;return response;
}
@end

static CFDataRef OPBrokerReceive(CFMessagePortRef port,SInt32 message,CFDataRef data,void *info) {
    (void)port;
    @autoreleasepool {
        if(message!=1||!data||CFDataGetLength(data)<=0||CFDataGetLength(data)>4096)return nullptr;
        id request=[NSPropertyListSerialization propertyListWithData:(__bridge NSData *)data options:NSPropertyListImmutable format:nil error:nil];
        if(![request isKindOfClass:NSDictionary.class])return nullptr;
        NSDictionary *response=[(__bridge OPBluetoothBrokerOwner *)info request:request];
        if(!response)return nullptr;
        NSData *encoded=[NSPropertyListSerialization dataWithPropertyList:response format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
        return encoded.length<=OPBrokerMaxReplyBytes ? (__bridge_retained CFDataRef)encoded : nullptr;
    }
}

int OPRunBluetoothBroker(void) {
    @autoreleasepool {
        // iOS 17.1 bluetoothd treats unregistered, dotted non-Apple names as
        // Apps and drops their indications as "suspended session". This
        // standalone process registers with its own actual daemon name,
        // SkyTouchBLE, never an App's or another system service's identity.
        if(geteuid()!=0||![NSThread isMainThread] || NSClassFromString(@"UIApplication") ||
           ![NSBundle.mainBundle.bundleIdentifier isEqual:@"SkyTouchBLE"] ||
           ![NSBundle.mainBundle.executablePath.lastPathComponent isEqual:@"SkyTouchBLE"])return 64;
        if(!OPBluetoothLifetimeRequired())return 0;
        int lock=open(OPBrokerLockPath.fileSystemRepresentation,O_CREAT|O_RDWR|O_CLOEXEC|O_NOFOLLOW,0600);
        struct stat state{};
        if(lock<0)return 70;
        if(fstat(lock,&state)!=0||!S_ISREG(state.st_mode)||state.st_nlink!=1||state.st_uid!=0){close(lock);return 73;}
        // A preceding broker may already have closed IPC while it flushes its
        // final status. Wait briefly for that instance's lock instead of losing
        // a legitimate rapid off/on request to an immediate exit(73).
        const uint64_t deadline=OPBrokerNow()+2*NSEC_PER_SEC;
        while(flock(lock,LOCK_EX|LOCK_NB)!=0) {
            if((errno!=EWOULDBLOCK && errno!=EAGAIN) || OPBrokerNow()>=deadline){close(lock);return 73;}
            if(!OPBluetoothLifetimeRequired()){close(lock);return 0;}
            usleep(50000);
        }
        if(!OPBluetoothLifetimeRequired()){close(lock);return 0;}
        NSMutableData *token=[NSMutableData dataWithLength:32];arc4random_buf(token.mutableBytes,token.length);
        if(!OPBrokerWrite(OPBrokerTokenPath,token)){close(lock);return 74;}
        OPBluetoothBrokerOwner *owner=[OPBluetoothBrokerOwner new];
        owner.bluetooth=[SMBluetooth new];owner.token=token;owner.epoch=NSUUID.UUID.UUIDString;
        owner.shouldCheckLifetime=YES;
        owner.lastControllerIdentity=OPLastKnownControllerIdentity();
        owner.statusWriter=[[OPBrokerStatusWriter alloc]initWithWrite:^(NSDictionary *snapshot){
            OPBrokerWritePlist(OPBluetoothBrokerStatusPath,snapshot);
        }];
        owner.bluetooth.scanServiceUUIDs=@[@"6E400001-B5A3-F393-E0A9-E50E24DCCA9E"];
        owner.packets=[NSMutableArray array];
        NSDictionary *selection=OPBrokerReadPlist(OPBluetoothBrokerSelectionPath,4096);
        uint64_t version=0;
        if(OPBrokerUInt(selection[@"version"],&version)&&version==1) {
            owner.selectionID=OPBrokerUUID(selection[@"identifier"]);
            id name=selection[@"name"];
            if([name isKindOfClass:NSString.class]&&[name length]>0&&[name length]<=256)owner.selectionName=name;
        }
        owner.bluetooth.preferredPeripheralIdentifier=owner.selectionID;
        __weak OPBluetoothBrokerOwner *weakOwner=owner;
        owner.bluetooth.onDevicesChanged=^(__unused NSArray *devices){[weakOwner considerSelection];};
        owner.bluetooth.onStatusChanged=^(__unused NSString *status){
            [weakOwner syncGeneration];notify_post(OPBluetoothBrokerDataNotification);
        };
        owner.bluetooth.onRawNotification=^(NSData *value,NSString *uuid){
            OPBluetoothBrokerOwner *strongOwner=weakOwner;if(!strongOwner||strongOwner.stopping)return;
            [strongOwner syncGeneration];++strongOwner.sequence;++strongOwner.receivedThisConnection;
            if(value.length==0||value.length>512) { strongOwner.lostThrough=strongOwner.sequence;return; }
            [strongOwner.packets addObject:@{@"seq":@(strongOwner.sequence),@"timeNs":@(OPBrokerNow()),@"value":[value copy],@"uuid":uuid}];
            if(strongOwner.packets.count>128) {
                strongOwner.lostThrough=MAX(strongOwner.lostThrough,[strongOwner.packets.firstObject[@"seq"]unsignedLongLongValue]);
                [strongOwner.packets removeObjectAtIndex:0];
            }
            notify_post(OPBluetoothBrokerDataNotification);
        };
        CFMessagePortContext context={0,(__bridge void *)owner,nullptr,nullptr,nullptr};
        Boolean shouldFree=false;
        CFMessagePortRef port=CFMessagePortCreateLocal(kCFAllocatorDefault,(__bridge CFStringRef)OPBluetoothBrokerPortName,OPBrokerReceive,&context,&shouldFree);
        CFRunLoopSourceRef source=port ? CFMessagePortCreateRunLoopSource(kCFAllocatorDefault,port,0) : nullptr;
        if(!source){if(port)CFRelease(port);close(lock);return 75;}
        CFRunLoopAddSource(CFRunLoopGetMain(),source,kCFRunLoopCommonModes);
        int stopToken=-1;
        if(notify_register_dispatch(OPBluetoothBrokerStopNotification,&stopToken,dispatch_get_main_queue(),^(__unused int tokenValue){
            owner.stopping=YES;CFRunLoopStop(CFRunLoopGetMain());
        })!=NOTIFY_STATUS_OK) {
            CFMessagePortInvalidate(port);CFRelease(source);CFRelease(port);close(lock);return 76;
        }
        int identityToken=-1;
        if(notify_register_dispatch(OPControllerIdentityChangedNotification,&identityToken,dispatch_get_main_queue(),^(__unused int tokenValue){
            OPBluetoothBrokerOwner *strongOwner=weakOwner;if(!strongOwner||strongOwner.stopping)return;
            strongOwner.lastControllerIdentity=OPLastKnownControllerIdentity();
            notify_post(OPBluetoothBrokerDataNotification);
        })!=NOTIFY_STATUS_OK) {
            notify_cancel(stopToken);CFMessagePortInvalidate(port);CFRelease(source);CFRelease(port);close(lock);return 76;
        }
        // Close the registration race if a UI consumer saved a type between
        // broker construction and notification subscription.
        owner.lastControllerIdentity=OPLastKnownControllerIdentity();
        int lifetimeToken=-1;
        notify_register_dispatch(OPRuntimeIntentChangedNotification,&lifetimeToken,dispatch_get_main_queue(),^(__unused int tokenValue){
            [weakOwner tick];
        });
        [owner.bluetooth scan];[owner tick];
        NSTimer *timer=[NSTimer timerWithTimeInterval:0.5 repeats:YES block:^(__unused NSTimer *fired){[weakOwner tick];}];
        [[NSRunLoop mainRunLoop]addTimer:timer forMode:NSRunLoopCommonModes];
        CFRunLoopRun();
        owner.stopping=YES;[timer invalidate];notify_cancel(stopToken);notify_cancel(identityToken);
        if(lifetimeToken>=0)notify_cancel(lifetimeToken);
        // Refuse new requests before teardown; callers that are enabling a
        // new session can start a successor once the singleton is released.
        CFMessagePortInvalidate(port);
        owner.bluetooth.onRawNotification=nil;owner.bluetooth.onDevicesChanged=nil;owner.bluetooth.onStatusChanged=nil;
        [owner.bluetooth disconnect];[owner.statusWriter finish:[owner diskSnapshot]];
        CFMessagePortInvalidate(port);CFRunLoopRemoveSource(CFRunLoopGetMain(),source,kCFRunLoopCommonModes);
        CFRelease(source);CFRelease(port);owner.bluetooth=nil;flock(lock,LOCK_UN);close(lock);return 0;
    }
}

// Cache on the calling worker thread. Every request remains authenticated by
// the broker; no token is logged. A dead port or rejected reply discards both
// values so the next request securely rereads the replacement broker's token.
@interface OPBrokerRemoteConnection : NSObject
@property(nonatomic,strong) NSData *token;
@property(nonatomic,assign) CFMessagePortRef port;
@end
@implementation OPBrokerRemoteConnection
- (void)dealloc {if(_port)CFRelease(_port);}
@end

NSDictionary *OPBluetoothBrokerRequest(NSDictionary *request,NSTimeInterval timeout,NSString **error) {
    if(error)*error=nil;
    if(![request isKindOfClass:NSDictionary.class]||!std::isfinite(timeout)||timeout<=0||timeout>5) {
        OPBrokerFail(error,@"无效的蓝牙服务请求");return nil;
    }
    static NSString *const cacheKey=@"com.lixinmo.skytouch.original.bluetooth.remote";
    NSMutableDictionary *threadState=NSThread.currentThread.threadDictionary;
    OPBrokerRemoteConnection *connection=threadState[cacheKey];
    if(connection && !CFMessagePortIsValid(connection.port)) {
        [threadState removeObjectForKey:cacheKey];connection=nil;
    }
    if(!connection) {
        NSData *token=OPBrokerReadFile(OPBrokerTokenPath,32,YES);
        if(!token){OPBrokerFail(error,@"蓝牙服务尚未准备好");return nil;}
        CFMessagePortRef port=CFMessagePortCreateRemote(kCFAllocatorDefault,(__bridge CFStringRef)OPBluetoothBrokerPortName);
        if(!port){OPBrokerFail(error,@"蓝牙服务暂未运行");return nil;}
        connection=[OPBrokerRemoteConnection new];connection.token=token;connection.port=port;
        threadState[cacheKey]=connection;
    }
    NSMutableDictionary *authenticated=[request mutableCopy];authenticated[@"version"]=@1;authenticated[@"token"]=connection.token;
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:authenticated format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    if(!data||data.length>4096){OPBrokerFail(error,@"蓝牙请求超出大小限制");return nil;}
    CFDataRef response=nullptr;
    SInt32 result=CFMessagePortSendRequest(connection.port,1,(__bridge CFDataRef)data,timeout,timeout,kCFRunLoopDefaultMode,&response);
    if(result!=kCFMessagePortSuccess||!response){
        if(response)CFRelease(response);[threadState removeObjectForKey:cacheKey];
        OPBrokerFail(error,@"蓝牙服务响应超时或验证失败");return nil;
    }
    NSData *reply=CFBridgingRelease(response);
    id decoded=reply.length<=OPBrokerMaxReplyBytes ? [NSPropertyListSerialization propertyListWithData:reply options:NSPropertyListImmutable format:nil error:nil] : nil;
    if(![decoded isKindOfClass:NSDictionary.class]){
        [threadState removeObjectForKey:cacheKey];OPBrokerFail(error,@"蓝牙服务响应格式无效");return nil;
    }
    if([decoded[@"error"]isKindOfClass:NSString.class]){OPBrokerFail(error,decoded[@"error"]);return nil;}
    return decoded;
}

NSDictionary *OPBluetoothBrokerStatus(void) {
    NSDictionary *source=OPBrokerReadPlist(OPBluetoothBrokerStatusPath,64*1024);
    if(!source)return nil;
    NSMutableDictionary *safe=[NSMutableDictionary dictionary];
    for(NSString *key in @[@"version",@"epoch",@"generation",@"pid",@"time",@"monotonicNs",@"connected",@"scanning",@"bluetoothState",@"deviceID",@"deviceName",@"sequence",@"receivedThisConnection",@"running",@"status",
        @"currentPeripheralType",@"lastKnownPeripheralType",@"lastKnownDeviceID",@"lastKnownDeviceName"])
        if([source[key]isKindOfClass:NSNumber.class]||[source[key]isKindOfClass:NSString.class])safe[key]=source[key];
    return safe;
}

BOOL OPEnsureBluetoothBrokerRunning(NSString **error) {
    if(error)*error=nil;
    if(!OPBluetoothLifetimeRequired())return OPBrokerFail(error,@"蓝牙服务已无人使用");
    NSDictionary *current=OPBluetoothBrokerRequest(@{@"op":@"status",@"cursor":@0},0.15,nullptr);
    if([current[@"running"] boolValue])return YES;
    NSString *executable=[OPApplicationBundlePath() stringByAppendingPathComponent:@"SystemBluetooth.bundle/SkyTouchBLE"];
    if(!executable.length)return OPBrokerFail(error,@"无法定位本 App 的蓝牙服务程序");
    posix_spawnattr_t attributes;int code=posix_spawnattr_init(&attributes);
    if(code)return OPBrokerFail(error,@"无法初始化蓝牙服务启动参数");
    code=posix_spawnattr_setflags(&attributes,POSIX_SPAWN_CLOEXEC_DEFAULT);
    if(!code&&geteuid()!=0) {
        typedef int (*Persona)(const posix_spawnattr_t *,uid_t,uint32_t);
        typedef int (*PersonaID)(const posix_spawnattr_t *,uid_t);
        Persona persona=(Persona)dlsym(RTLD_DEFAULT,"posix_spawnattr_set_persona_np");
        PersonaID uid=(PersonaID)dlsym(RTLD_DEFAULT,"posix_spawnattr_set_persona_uid_np");
        PersonaID gid=(PersonaID)dlsym(RTLD_DEFAULT,"posix_spawnattr_set_persona_gid_np");
        if(!persona||!uid||!gid)code=ENOSYS;
        else {code=persona(&attributes,99,1);if(!code)code=uid(&attributes,0);if(!code)code=gid(&attributes,0);}
    }
    pid_t pid=0;char *arguments[]={(char *)executable.fileSystemRepresentation,nullptr};
    if(!code && !OPBluetoothLifetimeRequired())code=ECANCELED;
    if(!code)code=posix_spawn(&pid,executable.fileSystemRepresentation,nullptr,&attributes,arguments,environ);
    posix_spawnattr_destroy(&attributes);
    if(code)return OPBrokerFail(error,[NSString stringWithFormat:@"蓝牙服务启动失败（%d）",code]);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{int status=0;while(waitpid(pid,&status,0)<0&&errno==EINTR){};});
    for(NSUInteger attempt=0;attempt<30;++attempt) {
        if(!OPBluetoothLifetimeRequired())return OPBrokerFail(error,@"蓝牙服务已无人使用");
        NSDictionary *reply=OPBluetoothBrokerRequest(@{@"op":@"status",@"cursor":@0},0.1,nullptr);
        if([reply[@"running"] boolValue])return YES;
        usleep(100000);
    }
    return OPBrokerFail(error,@"蓝牙服务已请求启动，尚未返回可用状态");
}
