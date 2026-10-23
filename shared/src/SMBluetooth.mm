#import "SMBluetooth.h"

#import <CoreBluetooth/CoreBluetooth.h>
#include "../core/FlydigiChannels.hpp"

namespace {
NSString *const SMServiceUUID = @"6E400001-B5A3-F393-E0A9-E50E24DCCA9E";
NSString *const SMWriteUUID = @"6E400002-B5A3-F393-E0A9-E50E24DCCA9E";
NSString *const SMNotifyUUID = @"6E400003-B5A3-F393-E0A9-E50E24DCCA9E";

fsm::BLEChannelCapabilities SMChannelCapabilities(CBCharacteristic *characteristic) {
    const CBCharacteristicProperties properties = characteristic.properties;
    return {characteristic != nil,
        (properties & (CBCharacteristicPropertyWrite | CBCharacteristicPropertyWriteWithoutResponse)) != 0,
        (properties & (CBCharacteristicPropertyNotify | CBCharacteristicPropertyIndicate)) != 0};
}

NSString *SMCharacteristicSummary(NSArray<CBCharacteristic *> *characteristics) {
    NSMutableArray<NSString *> *entries = [NSMutableArray array];
    for (CBCharacteristic *characteristic in characteristics) {
        if (entries.count == 12) { [entries addObject:@"…"]; break; }
        // The final UUID components are identical across these channels. Show
        // the suffix of the first component (0002/0003), plus advertised bits.
        NSString *first = [characteristic.UUID.UUIDString componentsSeparatedByString:@"-"].firstObject;
        NSString *suffix = first.length > 4 ? [first substringFromIndex:first.length - 4] : first;
        [entries addObject:[NSString stringWithFormat:@"%@/0x%lX", suffix,
            static_cast<unsigned long>(characteristic.properties)]];
    }
    return entries.count ? [entries componentsJoinedByString:@", "] : @"无特征";
}

void SMOnMain(dispatch_block_t action) {
    if ([NSThread isMainThread]) action();
    else dispatch_async(dispatch_get_main_queue(), action);
}

NSString *SMInputHex(NSData *data) {
    // Call only after successful report validation. Never turn device metadata
    // or arbitrary data into diagnostic strings.
    if (data.length != 14 && data.length != 20) return @"";
    const auto *bytes = static_cast<const std::uint8_t *>(data.bytes);
    NSMutableString *text = [NSMutableString stringWithCapacity:data.length * 3];
    for (NSUInteger index = 0; index < data.length; ++index) {
        if (index) [text appendString:@" "];
        [text appendFormat:@"%02X", static_cast<unsigned>(bytes[index])];
    }
    return text;
}
} // namespace

@interface SMBluetooth () <CBCentralManagerDelegate, CBPeripheralDelegate>
@property(nonatomic, copy, readwrite) NSArray<SMBluetoothDevice *> *devices;
@property(nonatomic, copy, readwrite) NSSet<NSString *> *systemConnectedDeviceIdentifiers;
@property(nonatomic, copy, readwrite) NSString *status;
@property(nonatomic, readwrite, getter=isScanning) BOOL scanning;
@property(nonatomic, readwrite, getter=isConnected) BOOL connected;
@property(nonatomic, readwrite) fsm::InputState latestInput;
@property(nonatomic, readwrite) NSUInteger receivedPacketCount;
@property(nonatomic, readwrite) NSUInteger decodedPacketCount;
@property(nonatomic, readwrite) NSUInteger ignoredPacketCount;
@property(nonatomic, readwrite) NSUInteger lastPacketLength;
@property(nonatomic, readwrite) NSUInteger rawValueCallbackCount;
@property(nonatomic, readwrite) NSUInteger rawValueIdentityMatchCount;
@property(nonatomic, readwrite) NSUInteger rawValueMatchedErrorCount;
@property(nonatomic, readwrite) NSUInteger rawValueNotifyingCount;
@property(nonatomic, readwrite) NSUInteger rawForwardedCount;
@property(nonatomic, readwrite) NSUInteger notifySubscriptionConfirmationCount;
@property(nonatomic, readwrite) NSUInteger notifySubscriptionErrorCount;
@property(nonatomic, readwrite) NSUInteger initializationWriteACKCount;
@property(nonatomic, readwrite) NSUInteger initializationWriteErrorCount;
@property(nonatomic, copy, readwrite) NSString *lastPacketHex;
@property(nonatomic, copy, readwrite) NSString *lastPacketDisposition;
- (void)setStatusText:(NSString *)text;
- (void)scanOnMain;
- (void)beginRequestedScan;
- (void)stopScanOnMain;
- (void)connectOnMain:(NSString *)identifier;
- (void)sendHandshakeIfReady;
- (void)completeHandshake;
- (void)clearSession;
- (void)failSession:(NSString *)reason;
- (void)publishInput:(fsm::InputState)input;
- (void)rememberPeripheral:(CBPeripheral *)peripheral advertisedName:(NSString *)advertisedName RSSI:(NSInteger)RSSI;
- (void)publishDeviceList;
- (void)notifyDiagnostics;
- (void)resetDiagnostics;
@end

@implementation SMBluetooth {
    CBCentralManager *_central;
    CBPeripheral *_peripheral;
    CBCharacteristic *_writeCharacteristic;
    CBCharacteristic *_notifyCharacteristic;
    NSMutableDictionary<NSString *, CBPeripheral *> *_peripheralsByID;
    NSMutableDictionary<NSString *, SMBluetoothDevice *> *_devicesByID;
    fsm::DecoderConfig _decoderConfig;
    BOOL _scanRequested;
    BOOL _handshakePending;
    BOOL _handshakeSent;
    CBCharacteristicWriteType _handshakeWriteType;
    BOOL _diagnosticsDeliveryPending;
    NSUInteger _sessionGeneration;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _devices = @[];
        _systemConnectedDeviceIdentifiers = [NSSet set];
        _status = @"蓝牙未启动；点击扫描后选择自己的手柄";
        _lastPacketHex = @"";
        _lastPacketDisposition = @"none";
        _peripheralsByID = [NSMutableDictionary dictionary];
        _devicesByID = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)dealloc {
    _central.delegate = nil;
    _peripheral.delegate = nil;
    [_central stopScan];
    if (_peripheral) [_central cancelPeripheralConnection:_peripheral];
}

- (fsm::DecoderConfig)decoderConfig {
    return _decoderConfig;
}

- (NSInteger)bluetoothState { return _central ? _central.state : CBManagerStateUnknown; }
- (NSUInteger)connectionGeneration { return _sessionGeneration; }
- (BOOL)notifyCharacteristicPresent { return _notifyCharacteristic != nil; }
- (BOOL)notifyCharacteristicNotifying { return _notifyCharacteristic.isNotifying; }
- (NSString *)currentDeviceIdentifier { return _peripheral.identifier.UUIDString; }
- (NSString *)currentDeviceName {
    if (!_peripheral) return nil;
    return _peripheral.name ?: _devicesByID[_peripheral.identifier.UUIDString].name;
}

- (void)setStatusText:(NSString *)text {
    self.status = text;
    if (self.onStatusChanged) self.onStatusChanged(text);
}

- (void)publishInput:(fsm::InputState)input {
    self.latestInput = input;
    if (self.onInput) self.onInput(input);
}

- (void)notifyDiagnostics {
    // Input callbacks retain full rate. A diagnostic UI need not redraw at the
    // BLE notification rate; one coalesced main-queue refresh per 100 ms suffices.
    if (_diagnosticsDeliveryPending) return;
    _diagnosticsDeliveryPending = YES;
    __weak SMBluetooth *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        SMBluetooth *owner = weakSelf;
        if (!owner) return;
        owner->_diagnosticsDeliveryPending = NO;
        if (owner.onDiagnosticsChanged) owner.onDiagnosticsChanged();
    });
}

- (void)resetDiagnostics {
    self.receivedPacketCount = 0;
    self.decodedPacketCount = 0;
    self.ignoredPacketCount = 0;
    self.lastPacketLength = 0;
    self.lastPacketHex = @"";
    self.lastPacketDisposition = @"none";
    [self notifyDiagnostics];
}

- (void)publishDeviceList {
    self.devices = [[_devicesByID allValues]
        sortedArrayUsingComparator:^NSComparisonResult(SMBluetoothDevice *a,
                                                       SMBluetoothDevice *b) {
        // 127 means no RSSI sample, including peripherals retrieved from the
        // system connection list. Do not rank it as the strongest signal.
        if ((a.RSSI == 127) != (b.RSSI == 127)) return a.RSSI == 127 ? NSOrderedDescending : NSOrderedAscending;
        if (a.RSSI != b.RSSI) return a.RSSI > b.RSSI ? NSOrderedAscending : NSOrderedDescending;
        return [a.identifier compare:b.identifier];
    }];
    if (self.onDevicesChanged) self.onDevicesChanged(self.devices);
}

- (void)rememberPeripheral:(CBPeripheral *)peripheral advertisedName:(NSString *)advertisedName RSSI:(NSInteger)RSSI {
    NSString *identifier = peripheral.identifier.UUIDString;
    if (!identifier.length) return;
    _peripheralsByID[identifier] = peripheral;
    NSString *name = advertisedName.length ? advertisedName :
        (peripheral.name.length ? peripheral.name : @"未命名 BLE 设备");
    _devicesByID[identifier] = [[SMBluetoothDevice alloc] initWithIdentifier:identifier name:name RSSI:RSSI];
}

- (void)scan {
    SMOnMain(^{ [self scanOnMain]; });
}

- (void)scanOnMain {
    if (_peripheral) {
        [self setStatusText:@"请先断开当前手柄，再扫描其他设备"];
        return;
    }
    // Apple's Core Bluetooth overview explicitly warns that using these APIs
    // without the hosting app's privacy usage key can terminate the process.
    // ShowPowerAlertKey only controls the "Bluetooth is off" alert; it does not
    // supply a privacy purpose string. Do not gamble on undocumented system-app
    // exemptions, fake a usage key in memory, or modify SpringBoard's Info.plist.
    // https://developer.apple.com/documentation/corebluetooth
    id purpose = [NSBundle.mainBundle objectForInfoDictionaryKey:@"NSBluetoothAlwaysUsageDescription"];
    if (![purpose isKindOfClass:NSString.class] ||
        ![[purpose stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] length]) {
        [self stopScanOnMain];
        [self clearSession];
        [self setStatusText:@"为保护系统进程已拒绝启动蓝牙：当前宿主缺少 NSBluetoothAlwaysUsageDescription。不会修改 SpringBoard；需要具备该声明并获用户蓝牙授权的辅助进程。"];
        return;
    }
    const CBManagerAuthorization authorization = [CBManager authorization];
    if (authorization == CBManagerAuthorizationDenied ||
        authorization == CBManagerAuthorizationRestricted) {
        _scanRequested = NO;
        [self clearSession];
        [self setStatusText:@"蓝牙访问未授权。请检查系统权限；若当前系统进程不能授权，需要使用有蓝牙授权的辅助进程。"];
        return;
    }
    _scanRequested = YES;
    if (!_central) {
        [self setStatusText:@"正在初始化蓝牙；如系统弹出授权请求，请手动确认"];
        _central = [[CBCentralManager alloc]
            initWithDelegate:self queue:dispatch_get_main_queue()
            options:@{CBCentralManagerOptionShowPowerAlertKey : @NO}];
    } else if (_central.state == CBManagerStatePoweredOn) {
        [self beginRequestedScan];
    } else {
        [self centralManagerDidUpdateState:_central];
    }
}

- (void)beginRequestedScan {
    if (!_scanRequested || _central.state != CBManagerStatePoweredOn || _peripheral) return;
    NSMutableArray<CBUUID *> *services = nil;
    if (self.scanServiceUUIDs) {
        services = [NSMutableArray array];
        @try {
            for (id value in self.scanServiceUUIDs) {
                if (![value isKindOfClass:NSString.class] || ![value length])
                    @throw [NSException exceptionWithName:NSInvalidArgumentException reason:nil userInfo:nil];
                [services addObject:[CBUUID UUIDWithString:value]];
            }
        } @catch (__unused NSException *exception) {
            [self setStatusText:@"扫描服务 UUID 无效；未启动扫描"];
            return;
        }
        if (!services.count) { [self setStatusText:@"扫描服务列表为空；未启动扫描"]; return; }
    }
    [_central stopScan];
    [_peripheralsByID removeAllObjects];
    [_devicesByID removeAllObjects];
    [self refreshKnownDevices];
    // A foreground caller may retain the legacy unfiltered scan. The separate
    // background broker supplies the expected service explicitly.
    [_central scanForPeripheralsWithServices:services
                                    options:@{CBCentralManagerScanOptionAllowDuplicatesKey : @NO}];
    self.scanning = YES;
    [self setStatusText:@"正在扫描 BLE，并列出系统已连接的兼容设备；只选自己的手柄，连接后会验证协议"];
}

- (void)refreshKnownDevices {
    SMOnMain(^{
        if (!self->_central || self->_central.state != CBManagerStatePoweredOn || self->_peripheral) return;
        NSUUID *preferred = self.preferredPeripheralIdentifier.length
            ? [[NSUUID alloc] initWithUUIDString:self.preferredPeripheralIdentifier] : nil;
        if (preferred) {
            for (CBPeripheral *peripheral in [self->_central retrievePeripheralsWithIdentifiers:@[preferred]]) {
                // The system API should return only the requested identifier.
                // Keep that invariant explicit before adding a selectable item.
                if ([peripheral.identifier isEqual:preferred])
                    [self rememberPeripheral:peripheral advertisedName:nil RSSI:127];
            }
        }
    // A peripheral connected in Settings or another app may no longer
    // advertise. Query only the expected service, merging with the saved UUID.
    // Retrieval does not establish our local connection: the user must still
    // select an entry before connectOnMain validates services and handshakes.
    // https://developer.apple.com/documentation/corebluetooth/cbcentralmanager/retrieveconnectedperipherals(withservices:)
    NSMutableSet<NSString *> *systemConnected = [NSMutableSet set];
    for (CBPeripheral *peripheral in [self->_central retrieveConnectedPeripheralsWithServices:@[[CBUUID UUIDWithString:SMServiceUUID]]]) {
        [self rememberPeripheral:peripheral advertisedName:nil RSSI:127];
        if (peripheral.identifier.UUIDString.length) [systemConnected addObject:peripheral.identifier.UUIDString];
    }
    self.systemConnectedDeviceIdentifiers = systemConnected;
    [self publishDeviceList];
    });
}

- (void)stopScan {
    SMOnMain(^{
        [self stopScanOnMain];
        if (!self->_peripheral) [self setStatusText:@"扫描已停止；可选择列表中的手柄"];
    });
}

- (void)stopScanOnMain {
    _scanRequested = NO;
    [_central stopScan];
    self.scanning = NO;
}

- (void)connectDeviceID:(NSString *)identifier {
    NSString *selectedID = [identifier copy];
    SMOnMain(^{ [self connectOnMain:selectedID]; });
}

- (void)connectOnMain:(NSString *)identifier {
    if (_peripheral) {
        [self setStatusText:@"已有连接或连接请求；请先断开再选择设备"];
        return;
    }
    if (!_central || _central.state != CBManagerStatePoweredOn) {
        [self setStatusText:@"蓝牙尚未就绪；请先手动扫描"];
        return;
    }
    CBPeripheral *selected = _peripheralsByID[identifier];
    if (!selected) {
        [self setStatusText:@"设备不在本次扫描列表中；不会自动检索或连接未知设备"];
        return;
    }
    [self stopScanOnMain];
    [self resetDiagnostics];
    [self publishInput:fsm::InputState{}];
    _peripheral = selected;
    _peripheral.delegate = self;
    const NSUInteger generation = ++_sessionGeneration;
    [self setStatusText:@"正在连接手选设备并验证 BLE 服务"];
    [_central connectPeripheral:selected options:nil];

    __weak SMBluetooth *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        SMBluetooth *owner = weakSelf;
        if (owner && owner->_sessionGeneration == generation && !owner.connected) {
            [owner failSession:@"连接或协议握手超时；已释放全部输入，请手动重试"];
        }
    });
}

- (void)clearSession {
    ++_sessionGeneration;
    self.connected = NO;
    _handshakePending = NO;
    _handshakeSent = NO;
    _peripheral.delegate = nil;
    _peripheral = nil;
    _writeCharacteristic = nil;
    _notifyCharacteristic = nil;
    self.lastPacketHex = @"";
    [self publishInput:fsm::InputState{}];
    [self notifyDiagnostics];
}

- (void)failSession:(NSString *)reason {
    CBPeripheral *previous = _peripheral;
    [self clearSession];
    if (previous) [_central cancelPeripheralConnection:previous];
    [self setStatusText:reason];
}

- (void)disconnect {
    SMOnMain(^{
        [self stopScanOnMain];
        [self failSession:@"已主动断开；输入已清零，不会自动重连"];
    });
}

- (void)setDecoderConfig:(const fsm::DecoderConfig &)config {
    const fsm::DecoderConfig copiedConfig = config;
    SMOnMain(^{
        if (!fsm::validateDecoderConfig(copiedConfig)) {
            [self setStatusText:@"无效轴校准：请使用 0..13 字节偏移及 0≤最小值<中心<最大值≤255"];
            return;
        }
        self->_decoderConfig = copiedConfig;
        // A config edit must never carry a held button into a new mapping.
        [self publishInput:fsm::InputState{}];
        [self resetDiagnostics];
        if (self.connected) {
            fsm::InputState neutral;
            neutral.connected = true;
            [self publishInput:neutral];
        }
        [self setStatusText:@"输入校准已更新；请监视验证后重新启用映射"];
    });
}

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    if (central != _central) return;
    if (central.state == CBManagerStatePoweredOn) {
        [self beginRequestedScan];
        if (!_scanRequested && !_peripheral) [self setStatusText:@"蓝牙已就绪；点击扫描开始"];
        return;
    }
    if (central.state == CBManagerStateUnknown || central.state == CBManagerStateResetting) {
        self.scanning = NO;
        self.systemConnectedDeviceIdentifiers = [NSSet set];
        if (_peripheral) [self failSession:@"蓝牙正在重置；输入已释放，不会自动重连"];
        else [self setStatusText:@"蓝牙正在初始化或重置"];
        return;
    }
    [self stopScanOnMain];
    [self clearSession];
    self.systemConnectedDeviceIdentifiers = [NSSet set];
    [_peripheralsByID removeAllObjects];
    [_devicesByID removeAllObjects];
    [self publishDeviceList];
    switch (central.state) {
    case CBManagerStateUnauthorized:
        [self setStatusText:@"CoreBluetooth 未获授权；检查系统蓝牙权限及当前进程授权，不能仅靠连接代码绕过。"];
        break;
    case CBManagerStatePoweredOff:
        [self setStatusText:@"系统蓝牙已关闭；开启后请重新点击扫描"];
        break;
    case CBManagerStateUnsupported:
        [self setStatusText:@"当前进程或设备不支持 CoreBluetooth BLE 中央角色"];
        break;
    default:
        [self setStatusText:@"蓝牙不可用；输入已清零"];
        break;
    }
}

- (void)centralManager:(CBCentralManager *)central
 didDiscoverPeripheral:(CBPeripheral *)peripheral
     advertisementData:(NSDictionary<NSString *, id> *)advertisementData
                  RSSI:(NSNumber *)RSSI {
    if (central != _central || !_scanRequested || !self.scanning) return;
    // Discovery never initiates a connection, even when an advertised service
    // or a device name appears to match a Flydigi product.
    NSString *localName = advertisementData[CBAdvertisementDataLocalNameKey];
    [self rememberPeripheral:peripheral advertisedName:localName RSSI:RSSI ? RSSI.integerValue : 127];
    [self publishDeviceList];
}

- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {
    if (central != _central || peripheral != _peripheral) return;
    [self setStatusText:@"BLE 已连接；正在验证服务与通知特征"];
    [peripheral discoverServices:@[[CBUUID UUIDWithString:SMServiceUUID]]];
}

- (void)centralManager:(CBCentralManager *)central
 didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    if (central != _central || peripheral != _peripheral) return;
    [self failSession:[NSString stringWithFormat:@"连接失败（%@）；不会自动重连",
        error.localizedDescription ?: @"未知错误"]];
}

- (void)centralManager:(CBCentralManager *)central
 didDisconnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    if (central != _central || peripheral != _peripheral) return;
    [self clearSession];
    [self setStatusText:[NSString stringWithFormat:@"手柄已断开（%@）；输入已清零，请手动重连",
        error.localizedDescription ?: @"连接结束"]];
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    if (peripheral != _peripheral) return;
    if (error) {
        [self failSession:[NSString stringWithFormat:@"服务发现失败：%@", error.localizedDescription]];
        return;
    }
    CBUUID *expected = [CBUUID UUIDWithString:SMServiceUUID];
    for (CBService *service in peripheral.services) {
        if ([service.UUID isEqual:expected]) {
            // The original plugin has a distinct single-003 layout. Discover
            // the full selected service so its characteristic count is real.
            [peripheral discoverCharacteristics:nil forService:service];
            return;
        }
    }
    [self failSession:@"手选设备没有预期服务；已断开，不会向其他服务发送命令"];
}

- (void)peripheral:(CBPeripheral *)peripheral
 didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error {
    if (peripheral != _peripheral ||
        ![service.UUID isEqual:[CBUUID UUIDWithString:SMServiceUUID]]) return;
    if (error) {
        [self failSession:[NSString stringWithFormat:@"特征发现失败：%@", error.localizedDescription]];
        return;
    }
    _writeCharacteristic = nil;
    _notifyCharacteristic = nil;
    for (CBCharacteristic *characteristic in service.characteristics) {
        if ([characteristic.UUID isEqual:[CBUUID UUIDWithString:SMWriteUUID]]) _writeCharacteristic = characteristic;
        if ([characteristic.UUID isEqual:[CBUUID UUIDWithString:SMNotifyUUID]]) _notifyCharacteristic = characteristic;
    }
    const auto layout = fsm::selectFlydigiChannels(service.characteristics.count,
        SMChannelCapabilities(_writeCharacteristic), SMChannelCapabilities(_notifyCharacteristic));
    if (layout == fsm::FlydigiChannelLayout::Unsupported) {
        [self failSession:[NSString stringWithFormat:
            @"服务0001不支持已知写入/通知通道；发现 %@（UUID尾号/属性）。已断开，未发送初始化命令。",
            SMCharacteristicSummary(service.characteristics)]];
        return;
    }
    if (layout == fsm::FlydigiChannelLayout::Combined003) _writeCharacteristic = _notifyCharacteristic;
    // The old plugin uses type 0 (with response). Prefer it when advertised,
    // otherwise select no-response *before* sending. Never retry an ambiguously
    // failed write using the other type: the command might already have arrived.
    _handshakeWriteType = (_writeCharacteristic.properties & CBCharacteristicPropertyWrite)
        ? CBCharacteristicWriteWithResponse : CBCharacteristicWriteWithoutResponse;
    [peripheral setNotifyValue:YES forCharacteristic:_notifyCharacteristic];
}

- (void)peripheral:(CBPeripheral *)peripheral
 didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    if (peripheral != _peripheral || characteristic != _notifyCharacteristic) return;
    if (error || !characteristic.isNotifying) {
        ++self.notifySubscriptionErrorCount;
        [self failSession:[NSString stringWithFormat:@"通知订阅失败：%@",
            error.localizedDescription ?: @"通知已关闭"]];
        return;
    }
    ++self.notifySubscriptionConfirmationCount;
    if (self.connected || _handshakePending) return;
    _handshakePending = YES;
    [self sendHandshakeIfReady];
}

- (void)sendHandshakeIfReady {
    if (!_peripheral || !_writeCharacteristic || !_notifyCharacteristic.isNotifying ||
        !_handshakePending || _handshakeSent) return;
    if (_handshakeWriteType == CBCharacteristicWriteWithoutResponse &&
        !_peripheral.canSendWriteWithoutResponse) {
        [self setStatusText:@"设备仅支持无确认写入；等待 BLE 发送窗口，不会重复发送初始化命令"];
        return;
    }
    // Recovered initialization command only. No BA C0 00 MAC request, version
    // collection, device-mode probing, cloud traffic or remote configuration.
    const std::uint8_t handshake[] = {0xAC, 0x6F, 0x00};
    if ([_peripheral maximumWriteValueLengthForType:_handshakeWriteType] < sizeof(handshake)) {
        [self failSession:@"BLE 可写长度不足以容纳初始化命令；未发送，已断开"];
        return;
    }
    _handshakeSent = YES;
    [self setStatusText:_handshakeWriteType == CBCharacteristicWriteWithResponse
        ? @"通知已订阅；等待初始化命令确认"
        : @"无确认初始化命令仅发送一次；等待可识别输入验证。若仅有14字节报文，请先显式开启旧格式。"];
    [_peripheral writeValue:[NSData dataWithBytes:handshake length:sizeof(handshake)]
        forCharacteristic:_writeCharacteristic type:_handshakeWriteType];
}

- (void)peripheralIsReadyToSendWriteWithoutResponse:(CBPeripheral *)peripheral {
    if (peripheral == _peripheral && _handshakeWriteType == CBCharacteristicWriteWithoutResponse)
        [self sendHandshakeIfReady];
}

- (void)peripheral:(CBPeripheral *)peripheral
 didWriteValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    if (peripheral != _peripheral || characteristic != _writeCharacteristic ||
        !_handshakePending || !_handshakeSent || _handshakeWriteType != CBCharacteristicWriteWithResponse) return;
    if (error) {
        ++self.initializationWriteErrorCount;
        [self failSession:[NSString stringWithFormat:@"初始化命令失败：%@", error.localizedDescription]];
        return;
    }
    ++self.initializationWriteACKCount;
    [self completeHandshake];
}

- (void)completeHandshake {
    _handshakePending = NO;
    self.connected = YES;
    fsm::InputState neutral;
    neutral.connected = true;
    [self publishInput:neutral];
    [self setStatusText:@"手柄已连接；可配置按键和摇杆，再启用全局映射"];
}

- (void)peripheral:(CBPeripheral *)peripheral
 didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    ++self.rawValueCallbackCount;
    if (peripheral != _peripheral || characteristic != _notifyCharacteristic) return;
    ++self.rawValueIdentityMatchCount;
    if (error) {
        ++self.rawValueMatchedErrorCount;
        [self failSession:[NSString stringWithFormat:@"输入通知错误：%@", error.localizedDescription]];
        return;
    }
    NSData *data = characteristic.value;
    const BOOL notifying = characteristic.isNotifying;
    if (notifying) ++self.rawValueNotifyingCount;
    if (notifying && [data isKindOfClass:NSData.class] && self.onRawNotification) {
        ++self.rawForwardedCount;
        self.onRawNotification([data copy], characteristic.UUID.UUIDString);
    }
    ++self.receivedPacketCount;
    self.lastPacketLength = data.length;
    self.lastPacketHex = @"";
    const BOOL awaitingUnacknowledgedInput = _handshakePending && _handshakeSent &&
        _handshakeWriteType == CBCharacteristicWriteWithoutResponse;
    if (!self.connected && !awaitingUnacknowledgedInput) {
        ++self.ignoredPacketCount;
        self.lastPacketDisposition = @"waiting-for-handshake";
        [self notifyDiagnostics];
        return;
    }
    fsm::DecodeResult decoded = fsm::decodeFlydigiReport(
        static_cast<const std::uint8_t *>(data.bytes), data.length, _decoderConfig);
    self.lastPacketDisposition = [NSString stringWithUTF8String:fsm::decodeStatusName(decoded.status)];
    if (decoded.accepted()) {
        if (awaitingUnacknowledgedInput) [self completeHandshake];
        ++self.decodedPacketCount;
        self.lastPacketHex = SMInputHex(data);
        decoded.input.connected = true;
        [self publishInput:decoded.input];
    } else {
        ++self.ignoredPacketCount;
        // Unknown reports never refresh or modify active controls. The mapper's
        // independent stale-input watchdog must release a previously held touch.
    }
    [self notifyDiagnostics];
}

- (void)peripheral:(CBPeripheral *)peripheral didModifyServices:(NSArray<CBService *> *)invalidatedServices {
    if (peripheral != _peripheral) return;
    for (CBService *service in invalidatedServices) {
        if ([service.UUID isEqual:[CBUUID UUIDWithString:SMServiceUUID]]) {
            [self failSession:@"手柄服务发生变化；为避免错误输入已断开，请手动重连"];
            return;
        }
    }
}

@end
