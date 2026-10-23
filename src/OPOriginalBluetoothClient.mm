#import "OPOriginalBluetoothClient.h"
#import "OPBluetoothBroker.h"
#import "OPOriginalBridge.h"
#import "OPControllerIdentity.h"
#import <CoreBluetooth/CoreBluetooth.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <mach/mach_time.h>
#include <cstdint>
#include <cstring>
#include <climits>
#include <atomic>
#include <notify.h>
#include <algorithm>
#include <array>

@class OPBrokerPeripheralFacade,OPBrokerManagerFacade;
namespace op_original_ble {
static BOOL installed=NO,stopped=NO,attached=NO,inFlight=NO,pendingPoll=NO,baseline=NO,brokerReady=NO,wantsScan=NO;
static __weak id owner;
static OPBrokerManagerFacade *manager;
static OPBrokerPeripheralFacade *selected;
static NSMutableDictionary<NSString *,OPBrokerPeripheralFacade *> *devices;
static NSSet<NSString *> *systemConnectedDeviceIDs;
static NSMutableSet<NSString *> *announced;
static NSMutableSet<NSString *> *retrievalAttemptedDeviceIDs;
// CoreBluetooth retains each characteristic's latest value between callbacks.
// Preserve that lifetime for vendor code that reads the last report later.
static NSMutableDictionary<NSString *,NSData *> *retainedValues;
static NSString *epoch,*deviceID=@"",*deviceName=@"",*stage=@"not-installed";
static uint64_t localGeneration=0,brokerGeneration=0,cursor=0,lastResponseNs=0,delivered=0,cancelled=0;
static uint64_t lastReportNs=0,nextEnsureNs=0;
static int dataNotificationToken=-1;
static uint64_t wakeups=0,requestCount=0,requestFailures=0,packetAgeSamples=0,maxPacketAgeNs=0,maxRoundTripNs=0;
static double meanPacketAgeNs=0,meanRoundTripNs=0;
static std::array<uint64_t,9> packetAgeBuckets{};
static constexpr std::array<uint64_t,9> packetAgeBoundsUs{{1000,2000,4000,8000,16000,32000,64000,128000,250000}};
static std::atomic<uint64_t> commandGeneration{0};
static NSInteger brokerPID=0,bluetoothState=CBManagerStateUnknown;
static BOOL brokerScanning=NO;
static BOOL observedBrokerState=NO,synchronizingExistingConnection=NO;
using ToastMethod=void(*)(id,SEL,id);
static ToastMethod originalShowToast=nullptr;
using PeripheralTypeMethod=void(*)(id,SEL,int);
static PeripheralTypeMethod originalUpdatePeripheralType=nullptr;
static BOOL processingRealReport=NO;
static NSInteger knownPeripheralType=-1;
static uint64_t existingConnectionSyncs=0,suppressedConnectionToasts=0;
static NSTimer *timer;
static dispatch_queue_t requests;
static uint64_t nowNs() {
    static mach_timebase_info_data_t scale=[] {mach_timebase_info_data_t s{};mach_timebase_info(&s);return s;}();
    return static_cast<uint64_t>((long double)mach_continuous_time()*scale.numer/scale.denom);
}
static BOOL integer(id value,uint64_t &number,BOOL zero=YES) {
    if(![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value)!=CFNumberGetTypeID() ||
        CFNumberIsFloatType((__bridge CFNumberRef)value) || [value compare:@0]==NSOrderedAscending)return NO;
    number=[value unsignedLongLongValue];return zero || number!=0;
}
static BOOL boolean(id value) {return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID();}
static BOOL signature(Class cls,BOOL classMethod,NSString *name,const char *result,NSArray<NSString *> *arguments) {
    Method method=classMethod ? class_getClassMethod(cls,NSSelectorFromString(name)) : class_getInstanceMethod(cls,NSSelectorFromString(name));
    NSMethodSignature *s=method ? [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)] : nil;
    if(!s || s.numberOfArguments!=arguments.count+2 || std::strcmp(s.methodReturnType,result))return NO;
    for(NSUInteger i=0;i<arguments.count;++i)if(std::strcmp([s getArgumentTypeAtIndex:i+2],arguments[i].UTF8String))return NO;
    return YES;
}
static id get(id object,NSString *name) {
    return object && signature(object_getClass(object),NO,name,"@",@[]) ?
        ((id(*)(id,SEL))objc_msgSend)(object,NSSelectorFromString(name)) : nil;
}
static void setObject(id object,NSString *selector,id value) {
    ((void(*)(id,SEL,id))objc_msgSend)(object,NSSelectorFromString(selector),value);
}
static void showToast(id controller,SEL selector,id message) {
    // setBLEConnectMode: synchronously emits these exact original strings.
    // A new consumer observing an already-connected broker is hydrating its
    // UI, not observing a radio connection transition. Other messages and
    // later genuine connection/disconnection changes retain the original UI.
    if(NSThread.isMainThread && controller==owner && synchronizingExistingConnection) {
        BOOL connectionMessage=[message isKindOfClass:NSString.class] &&
            ([message isEqualToString:@"手柄已连接"] ||
             [message isEqualToString:[NSString stringWithFormat:@"【%@】已连接",deviceName]]);
        if(connectionMessage){++suppressedConnectionToasts;return;}
    }
    if(originalShowToast)originalShowToast(controller,selector,message);
}
static void updatePeripheralType(id controller,SEL selector,int type) {
    if(originalUpdatePeripheralType)originalUpdatePeripheralType(controller,selector,type);
    if(NSThread.isMainThread && controller==owner && processingRealReport && brokerReady &&
       OPControllerIdentityTypeIsValid(type) && deviceID.length) {
        // updatePeripheralState invokes this only after decoding a real type
        // marker. Match the vendor's sole name override (Wasp -> v1), without
        // mistaking a chosen engine snapshot or a pinned editor type for the
        // physical device. No raw report bytes or button states are persisted.
        NSInteger actual=[deviceName containsString:@"Wasp"] ? 2 : type;
        knownPeripheralType=actual;
        OPRememberControllerIdentity(deviceID,deviceName,actual);
    }
}
static void setConnectionMode(BOOL ready,BOOL existingConnection=NO) {
    id controller=owner;
    if(controller) {
        const BOOL previous=synchronizingExistingConnection;
        synchronizingExistingConnection=previous || (ready && existingConnection);
        if(ready && existingConnection)++existingConnectionSyncs;
        @try {
            if(ready) {
                id prefs=get(NSClassFromString(@"FZPreferRecordTool"),@"sharedFZPreferRecordTool");
                int type=OPControllerIdentityTypeIsValid(knownPeripheralType) ? (int)knownPeripheralType :
                    ((int(*)(id,SEL))objc_msgSend)(prefs,NSSelectorFromString(@"peripheralType"));
                if(type<0 || type>2)type=0;
                // Preserve the vendor's device-name rules (including Wasp/v1)
                // before setBLEConnectMode loads the device-specific current slot.
                ((void(*)(id,SEL,int))objc_msgSend)(controller,NSSelectorFromString(@"updatePeripheralType:"),type);
            }
            ((void(*)(id,SEL,int))objc_msgSend)(controller,NSSelectorFromString(@"setBLEConnectMode:"),ready ? 2 : 0);
            // This name rule is verified in the original updatePeripheralType:
            // implementation; an actual Wasp connection needs no input packet
            // to identify its layout. Unknown names never invent a type.
            if(ready && [deviceName containsString:@"Wasp"] && deviceID.length)
                OPRememberControllerIdentity(deviceID,deviceName,2);
        } @finally {
            synchronizingExistingConnection=previous;
        }
    }
}
static void invalidate(NSString *reason,BOOL detach) {
    // Losing this consumer's transport does not disconnect the broker or
    // reset the vendor's connection/device-type state. Freshness still gates
    // output until a new baseline has been acknowledged.
    ++localGeneration;baseline=NO;lastResponseNs=0;
    if(detach)attached=NO;
    ++cancelled;stage=reason;OPStopOriginalTouches();
}
static void attach(void);
static void poll(void);
static void operation(NSDictionary *request);
}

// Only selectors recovered from the original's scan/retrieve/connect and raw
// value callback are provided. These objects are NOT CoreBluetooth instances,
// do not implement coding/forwarding, and cannot discover/write hardware.
@interface OPBrokerPeripheralFacade:NSObject
@property(nonatomic,copy) NSString *name;
@property(nonatomic,strong) NSUUID *identifier;
@property(nonatomic,weak) id delegate;
@property(nonatomic) CBPeripheralState state;
@end
@implementation OPBrokerPeripheralFacade @end

@interface OPBrokerCharacteristicFacade:NSObject
@property(nonatomic,copy) NSData *value;
@property(nonatomic,strong) CBUUID *UUID;
@property(nonatomic,getter=isNotifying) BOOL notifying;
@end
@implementation OPBrokerCharacteristicFacade @end

@interface OPBrokerManagerFacade:NSObject
@property(nonatomic,weak) id delegate;
@property(nonatomic,readonly) CBManagerState state;
@property(nonatomic,readonly,getter=isScanning) BOOL scanning;
- (void)scanForPeripheralsWithServices:(id)services options:(id)options;
- (void)stopScan;
- (NSArray *)retrieveConnectedPeripheralsWithServices:(id)services;
- (NSArray *)retrievePeripheralsWithIdentifiers:(NSArray *)identifiers;
- (void)connectPeripheral:(id)peripheral options:(id)options;
- (void)cancelPeripheralConnection:(id)peripheral;
@end
@implementation OPBrokerManagerFacade
- (CBManagerState)state {return (CBManagerState)op_original_ble::bluetoothState;}
- (BOOL)isScanning {return op_original_ble::brokerScanning;}
- (void)scanForPeripheralsWithServices:(id)services options:(id)options {
    (void)services;(void)options;
    if(!NSThread.isMainThread || op_original_ble::stopped)return;
    ++op_original_ble::commandGeneration;
    op_original_ble::wantsScan=YES;[op_original_ble::announced removeAllObjects];
    [op_original_ble::retrievalAttemptedDeviceIDs removeAllObjects];
    op_original_ble::attach();op_original_ble::operation(@{@"op":@"scan"});
}
- (void)stopScan {
    if(!NSThread.isMainThread || op_original_ble::stopped)return;
    // CoreBluetooth stopScan does not stop a connected peripheral's stream.
    // Only suppress this consumer's discovery announcements; the shared broker
    // and this subscription keep running.
    op_original_ble::wantsScan=NO;
}
- (NSArray *)retrieveConnectedPeripheralsWithServices:(id)services {
    if(!NSThread.isMainThread || op_original_ble::stopped || ![services isKindOfClass:NSArray.class])return @[];
    // The original asks for Generic Access (1800); the broker verifies its
    // candidates with the controller UART service. Do not claim arbitrary
    // services for these facades or turn advertisement/cache rows into links.
    BOOL supported=NO;
    for(id service in services)if([service isKindOfClass:CBUUID.class] &&
        ([service isEqual:[CBUUID UUIDWithString:@"1800"]] ||
         [service isEqual:[CBUUID UUIDWithString:@"6E400001-B5A3-F393-E0A9-E50E24DCCA9E"]]))supported=YES;
    if(!supported)return @[];
    op_original_ble::attach();
    if(op_original_ble::selected.state==CBPeripheralStateConnected)return @[op_original_ble::selected];
    NSMutableArray *result=[NSMutableArray array];
    for(NSString *identifier in [op_original_ble::systemConnectedDeviceIDs.allObjects sortedArrayUsingSelector:@selector(compare:)]) {
        OPBrokerPeripheralFacade *peripheral=op_original_ble::devices[identifier];
        if(peripheral)[result addObject:peripheral];
    }
    return result;
}
- (NSArray *)retrievePeripheralsWithIdentifiers:(NSArray *)identifiers {
    if(!NSThread.isMainThread || op_original_ble::stopped || ![identifiers isKindOfClass:NSArray.class])return @[];
    op_original_ble::attach();NSMutableArray *result=[NSMutableArray array];
    for(id identifier in identifiers)if([identifier isKindOfClass:NSUUID.class]) {
        id peripheral=op_original_ble::devices[((NSUUID *)identifier).UUIDString];if(peripheral)[result addObject:peripheral];
    }
    return result;
}
- (void)connectPeripheral:(id)peripheral options:(id)options {
    (void)options;
    if(!NSThread.isMainThread || op_original_ble::stopped || ![peripheral isKindOfClass:OPBrokerPeripheralFacade.class])return;
    NSString *identifier=((OPBrokerPeripheralFacade *)peripheral).identifier.UUIDString;
    if(op_original_ble::devices[identifier]!=peripheral)return;
    if(peripheral==op_original_ble::selected && OPOriginalBluetoothClientReady())return;
    ++op_original_ble::commandGeneration;
    op_original_ble::invalidate(@"selecting-broker-device",NO);op_original_ble::attach();
    op_original_ble::operation(@{@"op":@"select",@"id":identifier});
}
- (void)cancelPeripheralConnection:(id)peripheral {
    if(!NSThread.isMainThread || op_original_ble::stopped || ![peripheral isKindOfClass:OPBrokerPeripheralFacade.class])return;
    ++op_original_ble::commandGeneration;
    op_original_ble::invalidate(@"consumer-detached-by-cancel",YES);
}
@end

namespace op_original_ble {
static void attach(void) {
    if(stopped || !owner)return;
    if(!attached){attached=YES;invalidate(@"waiting-for-new-subscription-baseline",NO);}
}
static OPBrokerPeripheralFacade *device(NSString *identifier,NSString *name) {
    NSUUID *uuid=[[NSUUID alloc] initWithUUIDString:identifier];if(!uuid)return nil;
    NSString *key=uuid.UUIDString;
    OPBrokerPeripheralFacade *value=devices[key];
    if(!value){value=[OPBrokerPeripheralFacade new];value.identifier=uuid;devices[key]=value;}
    value.name=name;return value;
}
static BOOL applyState(NSDictionary *reply,BOOL newGeneration=NO,BOOL includesDeviceList=YES) {
    uint64_t state=0;
    if(!integer(reply[@"bluetoothState"],state) || state>CBManagerStatePoweredOn ||
        !boolean(reply[@"connected"]) || !boolean(reply[@"scanning"]) ||
        ![reply[@"deviceID"] isKindOfClass:NSString.class] || ![reply[@"deviceName"] isKindOfClass:NSString.class])return NO;
    NSString *identifier=reply[@"deviceID"],*name=reply[@"deviceName"];
    if(identifier.length>64 || name.length>256)return NO;
    const BOOL ready=[reply[@"connected"] boolValue];
    if(ready && (!identifier.length || ![[NSUUID alloc] initWithUUIDString:identifier]))return NO;
    NSArray *rows=reply[@"devices"];
    if(![rows isKindOfClass:NSArray.class] || rows.count>128)return NO;
    for(id row in rows) {
        if(![row isKindOfClass:NSDictionary.class] || ![row[@"id"] isKindOfClass:NSString.class] ||
            ![row[@"name"] isKindOfClass:NSString.class] || [row[@"name"] length]>256 ||
            ![[NSUUID alloc] initWithUUIDString:row[@"id"]] ||
            (row[@"systemConnected"] && !boolean(row[@"systemConnected"])))return NO;
    }
    const NSInteger oldState=bluetoothState;const BOOL previouslyReady=brokerReady;
    const BOOL existingConnection=!observedBrokerState && ready;
    observedBrokerState=YES;
    const BOOL nameChanged=![deviceName isEqualToString:name];
    const BOOL deviceChanged=![deviceID isEqualToString:identifier];
    if(newGeneration || !previouslyReady || deviceChanged || nameChanged) {
        knownPeripheralType=-1;
        uint64_t reported=0;
        if(ready && integer(reply[@"currentPeripheralType"],reported) && reported<=2)knownPeripheralType=(NSInteger)reported;
        else if(ready) {
            NSDictionary *remembered=OPLastKnownControllerIdentity();
            if([remembered[@"identifier"] caseInsensitiveCompare:identifier]==NSOrderedSame &&
               OPControllerIdentityTypeIsValid([remembered[@"peripheralType"] integerValue]) && remembered[@"peripheralType"])
                knownPeripheralType=[remembered[@"peripheralType"] integerValue];
        }
    }
    bluetoothState=(NSInteger)state;brokerScanning=[reply[@"scanning"] boolValue];brokerReady=ready;
    deviceID=[identifier copy];deviceName=[name copy];
    for(OPBrokerPeripheralFacade *value in devices.allValues)value.state=CBPeripheralStateDisconnected;
    for(NSDictionary *row in rows)device(row[@"id"],row[@"name"]);
    if(includesDeviceList || newGeneration) {
        NSMutableSet<NSString *> *systemConnected=[NSMutableSet set];
        if(includesDeviceList)for(NSDictionary *row in rows)if([row[@"systemConnected"] boolValue])
            [systemConnected addObject:[[NSUUID alloc] initWithUUIDString:row[@"id"]].UUIDString];
        systemConnectedDeviceIDs=[systemConnected copy];
    }
    selected=identifier.length ? device(identifier,name) : nil;
    if(selected){selected.state=ready ? CBPeripheralStateConnected : CBPeripheralStateDisconnected;selected.delegate=owner;}
    id controller=owner;
    if(controller) {
        setObject(controller,@"setPeripheral:",ready ? selected : nil);
        if(ready && (newGeneration || !previouslyReady || nameChanged)) {
            id prefs=get(NSClassFromString(@"FZPreferRecordTool"),@"sharedFZPreferRecordTool");
            setObject(prefs,@"setLastDeviceName:",name);
        }
        if(existingConnection || ready!=previouslyReady || (ready && (newGeneration || nameChanged || deviceChanged)))setConnectionMode(ready,existingConnection);
        if(oldState!=bluetoothState)((void(*)(id,SEL,id))objc_msgSend)(controller,NSSelectorFromString(@"centralManagerDidUpdateState:"),manager);
    }
    if(previouslyReady && !ready){++cancelled;OPStopOriginalTouches();}
    return YES;
}
static void announceDevices(NSDictionary *reply,uint64_t token) {
    if(!wantsScan || brokerReady)return;
    if(!deviceID.length && systemConnectedDeviceIDs.count) {
        NSMutableSet<NSString *> *newCandidates=[systemConnectedDeviceIDs mutableCopy];
        [newCandidates minusSet:retrievalAttemptedDeviceIDs];
        if(newCandidates.count) {
            [retrievalAttemptedDeviceIDs unionSet:systemConnectedDeviceIDs];
            // A system connection may have stopped advertising. Preserve the
            // original retrieval/name-selection flow, including when its first
            // query ran before the asynchronous broker status arrived. A fake
            // advertisement would stop the old scan without selecting a device.
            ((bool(*)(id,SEL))objc_msgSend)(owner,NSSelectorFromString(@"retrieveConnectedPeripheralWithServices"));
        }
    }
    if(localGeneration!=token || !attached || stopped || !wantsScan || !brokerScanning)return;
    for(NSDictionary *row in reply[@"devices"]) {
        if(localGeneration!=token || !attached || stopped || !wantsScan)break;
        NSUUID *uuid=[[NSUUID alloc] initWithUUIDString:row[@"id"]];NSString *key=uuid.UUIDString;
        if([systemConnectedDeviceIDs containsObject:key])continue;
        if([announced containsObject:key])continue;[announced addObject:key];
        NSNumber *RSSI=[row[@"RSSI"] isKindOfClass:NSNumber.class] ? row[@"RSSI"] : @0;
        ((void(*)(id,SEL,id,id,id,id))objc_msgSend)(owner,NSSelectorFromString(@"centralManager:didDiscoverPeripheral:advertisementData:RSSI:"),manager,devices[key],@{},RSSI);
    }
}
static void applyReply(NSDictionary *reply,uint64_t expectedLocal,BOOL includesDeviceList=YES) {
    if(stopped || !attached || localGeneration!=expectedLocal || !owner)return;
    uint64_t generation=0,sequence=0,pid=0,time=0;
    if(![reply isKindOfClass:NSDictionary.class]){invalidate(@"invalid-broker-reply",NO);return;}
    NSString *responseEpoch=reply[@"epoch"];
    const uint64_t now=nowNs();
    if(![reply isKindOfClass:NSDictionary.class] || ![responseEpoch isKindOfClass:NSString.class] ||
        ![[NSUUID alloc] initWithUUIDString:responseEpoch] || !integer(reply[@"generation"],generation) ||
        !integer(reply[@"sequence"],sequence) || !integer(reply[@"pid"],pid,NO) || pid>INT_MAX ||
        !integer(reply[@"monotonicNs"],time,NO) || time>now || now-time>250000000ULL ||
        !boolean(reply[@"overflow"]) || ![reply[@"packets"] isKindOfClass:NSArray.class] || [reply[@"packets"] count]>64) {
        invalidate(@"invalid-or-stale-broker-status",NO);return;
    }
    if(baseline && [epoch isEqual:responseEpoch] && (brokerPID!=(NSInteger)pid || generation<brokerGeneration || sequence<cursor)) {
        invalidate(@"broker-identity-or-sequence-regressed",NO);return;
    }
    const BOOL identityChanged=![epoch isEqual:responseEpoch] || brokerGeneration!=generation || brokerPID!=(NSInteger)pid;
    const BOOL changed=!baseline || identityChanged;
    if(changed || [reply[@"overflow"] boolValue]) {
        invalidate(changed ? @"new-broker-generation-baseline" : @"broker-overflow-baseline",NO);
        epoch=[responseEpoch copy];brokerGeneration=generation;brokerPID=(NSInteger)pid;cursor=sequence;baseline=YES;lastReportNs=0;
        const uint64_t stateToken=localGeneration;
        if(!applyState(reply,identityChanged,includesDeviceList)){invalidate(@"invalid-broker-device-state",NO);return;}
        if(stopped || !attached || localGeneration!=stateToken)return;
        lastResponseNs=time;announceDevices(reply,localGeneration);return; // Never replay a previous subscriber's packets.
    }
    const uint64_t stateToken=localGeneration;
    if(!applyState(reply,NO,includesDeviceList)){invalidate(@"invalid-broker-device-state",NO);return;}
    if(stopped || !attached || localGeneration!=stateToken)return;
    lastResponseNs=time;
    if(!brokerReady){cursor=sequence;stage=@"broker-not-ready";announceDevices(reply,localGeneration);return;}
    const uint64_t deliveryGeneration=localGeneration;
    if(sequence>cursor && ![reply[@"packets"] count]){invalidate(@"missing-broker-packets",NO);cursor=sequence;return;}
    for(id packet in reply[@"packets"]) {
        uint64_t seq=0,stamp=0;
        const uint64_t current=nowNs();
        id value=[packet isKindOfClass:NSDictionary.class] ? packet[@"value"] : nil;
        id uuid=[packet isKindOfClass:NSDictionary.class] ? packet[@"uuid"] : nil;
        if(![packet isKindOfClass:NSDictionary.class] || !integer(packet[@"seq"],seq,NO) || cursor==UINT64_MAX || seq!=cursor+1 || seq>sequence ||
            !integer(packet[@"timeNs"],stamp,NO) || stamp<lastReportNs || stamp>current || current-stamp>250000000ULL ||
            ![value isKindOfClass:NSData.class] || ![value length] || [value length]>512 ||
            ![uuid isKindOfClass:NSString.class] || !([uuid caseInsensitiveCompare:@"6E400003-B5A3-F393-E0A9-E50E24DCCA9E"]==NSOrderedSame || [uuid caseInsensitiveCompare:@"2A26"]==NSOrderedSame)) {
            invalidate(@"packet-gap-or-stale-report",NO);cursor=sequence;return;
        }
        if(stopped || !attached || localGeneration!=deliveryGeneration || !brokerReady)return;
        OPBrokerCharacteristicFacade *characteristic=[OPBrokerCharacteristicFacade new];
        NSData *retained=[value copy];retainedValues[[uuid uppercaseString]]=retained;
        characteristic.UUID=[CBUUID UUIDWithString:uuid];characteristic.value=retained;characteristic.notifying=YES;
        id controller=owner;SEL selector=NSSelectorFromString(@"peripheral:didUpdateValueForCharacteristic:error:");
        // Fetch the CURRENT implementation, including the root bridge's
        // observation wrapper. The original parser owns every raw byte.
        IMP implementation=class_getMethodImplementation(object_getClass(controller),selector);
        const uint64_t age=nowNs()-stamp;
        if(age>250000000ULL){invalidate(@"packet-stale-before-delivery",NO);cursor=sequence;return;}
        cursor=seq;lastReportNs=stamp;maxPacketAgeNs=std::max(maxPacketAgeNs,age);
        meanPacketAgeNs+=(static_cast<double>(age)-meanPacketAgeNs)/static_cast<double>(++packetAgeSamples);
        for(size_t bucket=0;bucket<packetAgeBoundsUs.size();++bucket) {
            if(age<=packetAgeBoundsUs[bucket]*1000ULL){++packetAgeBuckets[bucket];break;}
        }
        const BOOL previousReportScope=processingRealReport;
        @try {
            processingRealReport=YES;
            ((void(*)(id,SEL,id,id,id))implementation)(controller,selector,selected,characteristic,nil);++delivered;
        }
        @catch(__unused NSException *exception){invalidate(@"original-raw-callback-exception",NO);return;}
        @finally {processingRealReport=previousReportScope;}
    }
    if(localGeneration==deliveryGeneration) {
        stage=@"consuming-new-raw-reports";
        // A bounded reply may contain only the first 64 retained reports. Drain
        // the rest immediately, not at the next heartbeat or another wakeup.
        if(cursor<sequence)pendingPoll=YES;
    }
}
static void poll(void) {
    if(stopped || !attached || !owner)return;
    if(lastResponseNs && nowNs()-lastResponseNs>250000000ULL)invalidate(@"broker-heartbeat-expired",NO);
    if(inFlight){pendingPoll=YES;return;}
    pendingPoll=NO;inFlight=YES;
    const uint64_t token=localGeneration,requestedCursor=cursor;
    const uint64_t commandToken=commandGeneration.load();
    const BOOL needsDiscovery=!baseline || (wantsScan && !brokerReady);
    const BOOL mayEnsure=!lastResponseNs;
    dispatch_async(requests,^{
        const uint64_t began=nowNs();
        NSString *error=nil;NSDictionary *reply=nil;
        NSDictionary *request=@{@"op":needsDiscovery ? @"status" : @"input",@"cursor":@(requestedCursor)};
        if(commandGeneration.load()==commandToken)reply=OPBluetoothBrokerRequest(request,.1,&error);
        if(commandGeneration.load()==commandToken && !reply && mayEnsure && nowNs()>=nextEnsureNs) {
            nextEnsureNs=nowNs()+3*NSEC_PER_SEC;
            if(OPEnsureBluetoothBrokerRunning(&error) && commandGeneration.load()==commandToken)
                reply=OPBluetoothBrokerRequest(request,.1,&error);
        }
        const uint64_t elapsed=nowNs()-began;
        const BOOL protocolFailure=[error isEqualToString:@"蓝牙服务响应格式无效"];
        dispatch_async(dispatch_get_main_queue(),^{
            inFlight=NO;
            ++requestCount;maxRoundTripNs=std::max(maxRoundTripNs,elapsed);
            meanRoundTripNs+=(static_cast<double>(elapsed)-meanRoundTripNs)/static_cast<double>(requestCount);
            if(stopped || !attached)return;
            if(localGeneration==token && commandGeneration.load()==commandToken) {
                if(!reply) {
                    ++requestFailures;
                    // A transient IPC failure is not a new subscription. Keep
                    // the FIFO cursor and held mapping until the real heartbeat
                    // lease expires. Identity/protocol faults still fail closed.
                    if(protocolFailure)invalidate(@"invalid-broker-reply",NO);
                    else if(lastResponseNs && nowNs()-lastResponseNs<=250000000ULL)stage=@"broker-IPC-retrying";
                    else if(baseline || lastResponseNs)invalidate(@"broker-heartbeat-expired",NO);
                    else stage=@"broker-IPC-unavailable";
                } else applyReply(reply,token,needsDiscovery);
            }
            if(pendingPoll)poll();
        });
    });
}

static void operation(NSDictionary *request) {
    if(stopped)return;
    const uint64_t token=commandGeneration.load();
    dispatch_async(requests,^{
        if(commandGeneration.load()!=token)return;
        NSString *error=nil;NSDictionary *reply=nil;
        if(OPEnsureBluetoothBrokerRunning(&error) && commandGeneration.load()==token)reply=OPBluetoothBrokerRequest(request,.1,&error);
        dispatch_async(dispatch_get_main_queue(),^{
            if(stopped || commandGeneration.load()!=token)return;
            if(!reply)invalidate(@"broker-command-unavailable",NO);
        });
    });
}
static void initBLE(id controller,SEL) {
    if(!NSThread.isMainThread || stopped)return;
    if(owner==controller && manager){attach();return;}
    [timer invalidate];timer=nil;
    owner=controller;manager=[OPBrokerManagerFacade new];manager.delegate=controller;
    observedBrokerState=NO;
    setObject(controller,@"setManager:",manager);setObject(controller,@"setPeripheral:",nil);
    devices=[NSMutableDictionary dictionary];announced=[NSMutableSet set];
    systemConnectedDeviceIDs=[NSSet set];
    retrievalAttemptedDeviceIDs=[NSMutableSet set];
    retainedValues=[NSMutableDictionary dictionary];
    attach();
    timer=[NSTimer timerWithTimeInterval:.1 repeats:YES block:^(__unused NSTimer *value){poll();}];
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];poll();
}
}

BOOL OPInstallOriginalBluetoothClient(NSString **error) {
    using namespace op_original_ble;if(error)*error=nil;
    if(!NSThread.isMainThread){if(error)*error=@"原蓝牙消费者必须在主线程安装";return NO;}
    if(op_original_ble::installed)return !stopped;
    Class cls=NSClassFromString(@"FZCentralViewController"),prefs=NSClassFromString(@"FZPreferRecordTool");
    BOOL valid=signature(cls,NO,@"initBLE","v",@[]) &&
        signature(cls,NO,@"setManager:","v",@[@"@"]) && signature(cls,NO,@"setPeripheral:","v",@[@"@"]) &&
        signature(cls,NO,@"setBLEConnectMode:","v",@[@"i"]) &&
        signature(cls,NO,@"showToast:","v",@[@"@"]) &&
        signature(cls,NO,@"updatePeripheralType:","v",@[@"i"]) &&
        signature(cls,NO,@"peripheral:didUpdateValueForCharacteristic:error:","v",@[@"@",@"@",@"@"]) &&
        signature(cls,NO,@"centralManagerDidUpdateState:","v",@[@"@"]) &&
        signature(cls,NO,@"retrieveConnectedPeripheralWithServices","B",@[]) &&
        signature(cls,NO,@"centralManager:didDiscoverPeripheral:advertisementData:RSSI:","v",@[@"@",@"@",@"@",@"@"]) &&
        signature(prefs,YES,@"sharedFZPreferRecordTool","@",@[]) && signature(prefs,NO,@"setLastDeviceName:","v",@[@"@"]) &&
        signature(prefs,NO,@"peripheralType","i",@[]);
    if(!valid || OPOriginalController()){if(error)*error=@"原蓝牙接口ABI不符或控制器已创建，拒绝创建第二个蓝牙所有者";return NO;}
    Method method=class_getInstanceMethod(cls,NSSelectorFromString(@"initBLE"));
    IMP previous=method_setImplementation(method,(IMP)initBLE);
    if(!previous || method_getImplementation(method)!=(IMP)initBLE){if(previous)method_setImplementation(method,previous);if(error)*error=@"原initBLE替换未生效";return NO;}
    Method toastMethod=class_getInstanceMethod(cls,NSSelectorFromString(@"showToast:"));
    originalShowToast=(ToastMethod)method_setImplementation(toastMethod,(IMP)showToast);
    if(!originalShowToast || method_getImplementation(toastMethod)!=(IMP)showToast) {
        if(originalShowToast)method_setImplementation(toastMethod,(IMP)originalShowToast);
        originalShowToast=nullptr;method_setImplementation(method,previous);
        if(error)*error=@"原连接状态提示隔离未生效";return NO;
    }
    Method typeMethod=class_getInstanceMethod(cls,NSSelectorFromString(@"updatePeripheralType:"));
    originalUpdatePeripheralType=(PeripheralTypeMethod)method_setImplementation(typeMethod,(IMP)updatePeripheralType);
    if(!originalUpdatePeripheralType || method_getImplementation(typeMethod)!=(IMP)updatePeripheralType) {
        if(originalUpdatePeripheralType)method_setImplementation(typeMethod,(IMP)originalUpdatePeripheralType);
        method_setImplementation(toastMethod,(IMP)originalShowToast);originalShowToast=nullptr;
        method_setImplementation(method,previous);if(error)*error=@"原手柄类型观察接口安装失败";return NO;
    }
    requests=dispatch_queue_create("com.lixinmo.skytouch.original-raw-consumer",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INTERACTIVE,0));
    // Notifications carry no data or authority. They only wake an authenticated
    // cursor read; coalescing is handled by pendingPoll and sequence draining.
    if(notify_register_dispatch(OPBluetoothBrokerDataNotification,&dataNotificationToken,dispatch_get_main_queue(),^(__unused int value){
        ++wakeups;poll();
    })!=NOTIFY_STATUS_OK) {
        method_setImplementation(method,previous);
        method_setImplementation(toastMethod,(IMP)originalShowToast);originalShowToast=nullptr;
        method_setImplementation(typeMethod,(IMP)originalUpdatePeripheralType);originalUpdatePeripheralType=nullptr;
        if(error)*error=@"无法注册蓝牙输入唤醒通知";return NO;
    }
    op_original_ble::installed=YES;stage=@"installed-no-hardware-central";return YES;
}
void OPStopOriginalBluetoothClient(void) {
    using namespace op_original_ble;
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{OPStopOriginalBluetoothClient();});return;}
    stopped=YES;++commandGeneration;invalidate(@"consumer-stopped-broker-retained",YES);[timer invalidate];timer=nil;
    pendingPoll=NO;if(dataNotificationToken>=0){notify_cancel(dataNotificationToken);dataNotificationToken=-1;}
    manager.delegate=nil;selected.delegate=nil;
}
BOOL OPOriginalBluetoothClientReady(void) {
    using namespace op_original_ble;
    return NSThread.isMainThread && op_original_ble::installed && !stopped && attached && brokerReady && lastResponseNs && op_original_ble::nowNs()-lastResponseNs<=250000000ULL;
}
BOOL OPOriginalBluetoothClientWrapsPeripheralType(IMP implementation) {
    using namespace op_original_ble;
    return NSThread.isMainThread && op_original_ble::installed && originalUpdatePeripheralType==(PeripheralTypeMethod)implementation &&
        class_getMethodImplementation(NSClassFromString(@"FZCentralViewController"),NSSelectorFromString(@"updatePeripheralType:"))==(IMP)updatePeripheralType;
}
NSDictionary *OPOriginalBluetoothClientStatus(void) {
    using namespace op_original_ble;
    if(!NSThread.isMainThread)return @{@"ready":@NO,@"stage":@"main-thread-required"};
    NSMutableArray *ageBounds=[NSMutableArray arrayWithCapacity:9],*ageCounts=[NSMutableArray arrayWithCapacity:9];
    for(size_t bucket=0;bucket<packetAgeBoundsUs.size();++bucket){
        [ageBounds addObject:@(packetAgeBoundsUs[bucket])];[ageCounts addObject:@(packetAgeBuckets[bucket])];
    }
    return @{@"installed":@(op_original_ble::installed),@"ready":@(OPOriginalBluetoothClientReady()),@"attached":@(attached),@"stage":stage,
        @"epoch":epoch ?: @"",@"generation":@(brokerGeneration),@"localGeneration":@(localGeneration),@"brokerPID":@(brokerPID),
        @"bluetoothState":@(bluetoothState),@"scanning":@(brokerScanning),@"brokerReady":@(brokerReady),
        @"connected":@(OPOriginalBluetoothClientReady()),@"managerPresent":@(manager!=nil),@"peripheralPresent":@(selected!=nil),
        @"connectionStateName":OPOriginalBluetoothClientReady() ? @"connected" : @"not-ready-or-detached",
        @"stateName":@[@"unknown",@"resetting",@"unsupported",@"unauthorized",@"poweredOff",@"poweredOn"][(NSUInteger)bluetoothState],
        @"deviceName":deviceName,@"deviceID":deviceID,@"cursor":@(cursor),@"deliveredRawPackets":@(delivered),
        @"hasDeliveredRawReport":@(lastReportNs!=0),@"cancelCount":@(cancelled),
        @"existingConnectionSyncs":@(existingConnectionSyncs),@"suppressedConnectionToasts":@(suppressedConnectionToasts),
        @"inputWakeups":@(wakeups),@"inputRequestCount":@(requestCount),@"inputRequestFailures":@(requestFailures),
        @"packetAgeSamples":@(packetAgeSamples),@"inputAgeUsUpperBounds":ageBounds,@"inputAgeBucketCounts":ageCounts,@"packetAgeMeanMs":@(meanPacketAgeNs/1e6),@"packetAgeMaxMs":@(maxPacketAgeNs/1e6),
        @"inputRoundTripMeanMs":@(meanRoundTripNs/1e6),@"inputRoundTripMaxMs":@(maxRoundTripNs/1e6)};
}
