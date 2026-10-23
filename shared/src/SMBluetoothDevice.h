#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface SMBluetoothDevice : NSObject
@property(nonatomic, copy, readonly) NSString *identifier;
@property(nonatomic, copy, readonly) NSString *name;
@property(nonatomic, readonly) NSInteger RSSI;
- (instancetype)initWithIdentifier:(NSString *)identifier name:(NSString *)name RSSI:(NSInteger)RSSI;
@end
NS_ASSUME_NONNULL_END
