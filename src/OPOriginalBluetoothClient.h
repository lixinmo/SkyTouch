#pragma once
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
// Install on main after original dlopen, BEFORE the original controller exists.
// Replaces its initBLE and narrowly observes its connection toast. No
// CBCentralManager/CBPeripheral is constructed.
// Initial connected-state hydration preserves device/profile setup without
// repeating the vendor's new-connection toast; later transitions still notify.
BOOL OPInstallOriginalBluetoothClient(NSString * _Nullable * _Nullable error);
// Final consumer shutdown; never disconnects or stops the broker's radio.
void OPStopOriginalBluetoothClient(void);
BOOL OPOriginalBluetoothClientReady(void);
// Sanitized consumer/broker state. Contains no raw packet or account material.
NSDictionary *OPOriginalBluetoothClientStatus(void);
// Used by the native editor to verify the one permitted observer chain.
BOOL OPOriginalBluetoothClientWrapsPeripheralType(IMP implementation);
NS_ASSUME_NONNULL_END
