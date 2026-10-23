#pragma once

#import <Foundation/Foundation.h>
#import "SMBluetoothDevice.h"

#ifndef __cplusplus
#error SMBluetooth.h must be imported from an Objective-C++ translation unit.
#endif

#include "../core/FlydigiProtocol.hpp"

NS_ASSUME_NONNULL_BEGIN

// Standalone input adapter: no UIKit, target-app access, touch injection,
// telemetry, file persistence, auto-connect or automatic startup.
// Entry methods may be called from any queue. Read properties and assign/read
// callbacks on the main queue; every callback is delivered on the main queue.
@interface SMBluetooth : NSObject
@property(nonatomic, copy, nullable) void (^onDevicesChanged)(NSArray<SMBluetoothDevice *> *devices);
@property(nonatomic, copy, nullable) void (^onInput)(fsm::InputState state);
@property(nonatomic, copy, nullable) void (^onStatusChanged)(NSString *status);
@property(nonatomic, copy, nullable) void (^onDiagnosticsChanged)(void);
// Unmodified, error-free notifications from the validated notify channel. Runs
// before decoding, including metadata/legacy reports. Consumers must copy or
// consume each notification once; this callback never runs for heartbeats.
@property(nonatomic, copy, nullable) void (^onRawNotification)(NSData *value, NSString *characteristicUUID);
// Main-queue configuration. nil preserves the foreground adapter's unfiltered
// scan; a background central can specify its advertised service UUIDs.
@property(nonatomic, copy, nullable) NSArray<NSString *> *scanServiceUUIDs;
// An explicitly selected, previously saved peripheral UUID. Retrieval merely
// makes that known peripheral available for selection; it does not connect.
@property(nonatomic, copy, nullable) NSString *preferredPeripheralIdentifier;

@property(nonatomic, copy, readonly) NSArray<SMBluetoothDevice *> *devices;
// IDs returned by the latest system-connected expected-service query. This
// records retrieval provenance, not this manager's local connection state;
// cached UUIDs and advertisement discoveries alone never enter this set.
@property(nonatomic, copy, readonly) NSSet<NSString *> *systemConnectedDeviceIdentifiers;
@property(nonatomic, copy, readonly) NSString *status;
@property(nonatomic, readonly, getter=isScanning) BOOL scanning;
// True only after service/characteristic validation, notification subscription,
// and either the acknowledged AC 6F 00 write or (for write-without-response-only
// devices) the first recognized input after that one write. Never arms a mapper.
@property(nonatomic, readonly, getter=isConnected) BOOL connected;
@property(nonatomic, readonly) NSInteger bluetoothState;
@property(nonatomic, readonly) NSUInteger connectionGeneration;
@property(nonatomic, copy, readonly, nullable) NSString *currentDeviceIdentifier;
@property(nonatomic, copy, readonly, nullable) NSString *currentDeviceName;
@property(nonatomic, readonly) fsm::InputState latestInput;
@property(nonatomic, readonly) fsm::DecoderConfig decoderConfig;
@property(nonatomic, readonly) NSUInteger receivedPacketCount;
@property(nonatomic, readonly) NSUInteger decodedPacketCount;
@property(nonatomic, readonly) NSUInteger ignoredPacketCount;
@property(nonatomic, readonly) NSUInteger lastPacketLength;
// Main-queue, process-lifetime counters. These do not contain report bytes and
// are not reset by reconnects or decoder changes. A connection/write ACK is
// distinct from a value callback reaching the selected notification channel.
@property(nonatomic, readonly) NSUInteger rawValueCallbackCount;
@property(nonatomic, readonly) NSUInteger rawValueIdentityMatchCount;
@property(nonatomic, readonly) NSUInteger rawValueMatchedErrorCount;
@property(nonatomic, readonly) NSUInteger rawValueNotifyingCount;
@property(nonatomic, readonly) NSUInteger rawForwardedCount;
@property(nonatomic, readonly) NSUInteger notifySubscriptionConfirmationCount;
@property(nonatomic, readonly) NSUInteger notifySubscriptionErrorCount;
@property(nonatomic, readonly) NSUInteger initializationWriteACKCount;
@property(nonatomic, readonly) NSUInteger initializationWriteErrorCount;
@property(nonatomic, readonly) BOOL notifyCharacteristicPresent;
@property(nonatomic, readonly) BOOL notifyCharacteristicNotifying;
// Empty for metadata, unknown lengths, unsupported modes or not-ready sessions.
// Contains at most 20 bytes of a recognized input report, kept in RAM only.
@property(nonatomic, copy, readonly) NSString *lastPacketHex;
@property(nonatomic, copy, readonly) NSString *lastPacketDisposition;

// init is inert: it does not construct CBCentralManager or request permission.
// scan refuses if the hosting bundle has no NSBluetoothAlwaysUsageDescription;
// a tweak's own plist cannot satisfy that requirement for SpringBoard.
- (void)scan;
- (void)stopScan;
// Refreshes the saved UUID and system-connected expected-service peripherals
// on the main queue. Never starts/stops a scan, connects or disrupts a session.
- (void)refreshKnownDevices;
// Only an ID in the current user-requested discovery list is accepted.
- (void)connectDeviceID:(NSString *)identifier;
- (void)disconnect;
// Reject invalid calibration. A successful change sends a disconnected neutral
// state first, so consumers must disarm; the link itself stays open for learning.
- (void)setDecoderConfig:(const fsm::DecoderConfig &)config;
@end

NS_ASSUME_NONNULL_END
