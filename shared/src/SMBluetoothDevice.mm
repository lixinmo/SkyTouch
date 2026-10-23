#import "SMBluetoothDevice.h"

@implementation SMBluetoothDevice
- (instancetype)initWithIdentifier:(NSString *)identifier name:(NSString *)name RSSI:(NSInteger)RSSI {
    self = [super init];
    if (self) { _identifier = [identifier copy]; _name = [name copy]; _RSSI = RSSI; }
    return self;
}
@end
