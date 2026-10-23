#import "../src/OPStoragePaths.h"
#import "../src/OPBluetoothBroker.h"
int main(int argc,char **) { @autoreleasepool {
    NSString *storageError=nil;
    if(!OPStorageDirectoriesReady(&storageError)) {
        NSLog(@"[SkyTouch] Storage unavailable: %@",storageError);return 74;
    }
    return argc==1 ? OPRunBluetoothBroker() : 64;
} }
