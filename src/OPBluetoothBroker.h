#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString *const OPBluetoothBrokerPortName;
FOUNDATION_EXPORT NSString *const OPBluetoothBrokerStatusPath;
FOUNDATION_EXPORT NSString *const OPBluetoothBrokerSelectionPath;
FOUNDATION_EXPORT const char *const OPBluetoothBrokerStopNotification;
// Wakeup only: payloads still use the authenticated, sequenced IPC channel.
FOUNDATION_EXPORT const char *const OPBluetoothBrokerDataNotification;

// Root, main thread, Foundation-only. Independent of every mapping/UI session.
int OPRunBluetoothBroker(void);
// May block briefly during startup; use from a background queue in UIKit code.
BOOL OPEnsureBluetoothBrokerRunning(NSString * _Nullable * _Nullable error);
// Adds version=1 and the separate broker token. Does not start the broker.
// op=status|input,cursor:uint64 | op=select,id:UUID-string | op=scan.
// input omits discovery rows and UI/status strings from the hot path.
// Status packets are RAM-only {seq,timeNs,value:NSData,uuid}; all clocks are
// mach_continuous_time converted to nanoseconds. Drain <=64 packets per reply.
// Reset receiver input on epoch/generation change or overflow, never replay.
// Optional metadata: lastKnownPeripheralType/device ID/name survive disconnect
// and game switches. currentPeripheralType is present only for a connected UUID
// matching that remembered record; neither field asserts fresh controller input.
NSDictionary * _Nullable OPBluetoothBrokerRequest(NSDictionary *request, NSTimeInterval timeout,
                                                   NSString * _Nullable * _Nullable error);
// Sanitized disk snapshot: no token, payload, hexadecimal data or account info.
NSDictionary * _Nullable OPBluetoothBrokerStatus(void);
NS_ASSUME_NONNULL_END
