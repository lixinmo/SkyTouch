#import "OPLocalSwitcherFilter.h"
#import <CoreFoundation/CoreFoundation.h>
#include <cmath>

static BOOL OPLocalSwitcherType(id value, NSInteger *result) {
    if(![value isKindOfClass:NSNumber.class] ||
       CFGetTypeID((__bridge CFTypeRef)value)!=CFNumberGetTypeID() ||
       CFNumberIsFloatType((__bridge CFNumberRef)value) ||
       [value compare:@0]==NSOrderedAscending || [value compare:@2]==NSOrderedDescending)return NO;
    *result=[value integerValue];return YES;
}
static NSString *OPLocalSwitcherUUID(id value) {
    if(![value isKindOfClass:NSString.class] || [value length]!=36)return nil;
    return [[NSUUID alloc]initWithUUIDString:value].UUIDString;
}
static BOOL OPLocalSwitcherTrue(id value) {
    // The broker writes booleans. Also accept the equivalent integral 1 from
    // plist producers, but never strings or floating-point truthy values.
    if(![value isKindOfClass:NSNumber.class])return NO;
    if(CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID())return [value boolValue];
    return !CFNumberIsFloatType((__bridge CFNumberRef)value) && [value isEqualToNumber:@1];
}
NSDictionary *OPLocalSwitcherFilterState(NSDictionary *broker, NSDictionary *remembered,
    NSTimeInterval now, BOOL brokerAlive) {
    NSDictionary *all=@{@"mode":@"all",@"deviceType":@-1,@"deviceID":@""};
    if(!brokerAlive || ![broker isKindOfClass:NSDictionary.class] ||
       !OPLocalSwitcherTrue(broker[@"running"]) || !OPLocalSwitcherTrue(broker[@"connected"]))return all;
    id timestamp=broker[@"time"];
    if(![timestamp isKindOfClass:NSNumber.class] ||
       CFGetTypeID((__bridge CFTypeRef)timestamp)!=CFNumberGetTypeID())return all;
    const NSTimeInterval time=[timestamp doubleValue],age=now-time;
    if(!std::isfinite(now) || !std::isfinite(time) || now<=0 || time<=0 || age<0 || age>3)return all;
    NSString *identifier=OPLocalSwitcherUUID(broker[@"deviceID"]);
    if(!identifier)return all;
    NSInteger type=-1;
    BOOL known=OPLocalSwitcherType(broker[@"currentPeripheralType"],&type);
    if(!known && [remembered isKindOfClass:NSDictionary.class] &&
       [identifier isEqualToString:OPLocalSwitcherUUID(remembered[@"identifier"])])
        known=OPLocalSwitcherType(remembered[@"peripheralType"],&type);
    return @{@"mode":known ? @"type" : @"identifying",@"deviceType":@(known ? type : -1),@"deviceID":identifier};
}
BOOL OPLocalSwitcherRowAllowed(NSDictionary *row, NSDictionary *state) {
    if(![row isKindOfClass:NSDictionary.class] || ![state isKindOfClass:NSDictionary.class])return NO;
    if([state[@"mode"] isEqual:@"all"])return YES;
    if([state[@"mode"] isEqual:@"phone"]) {
        NSInteger type=-1;
        // The current phone report adapter supports gamepad and v1 layouts.
        // Q1 keyboard/mouse has a different wire format, never reinterpret it.
        return OPLocalSwitcherType(row[@"deviceType"],&type) && (type==0 || type==2);
    }
    if(![state[@"mode"] isEqual:@"type"])return NO;
    NSInteger wanted=-1,actual=-1;
    return OPLocalSwitcherType(state[@"deviceType"],&wanted) &&
        OPLocalSwitcherType(row[@"deviceType"],&actual) && wanted==actual;
}
NSArray<NSDictionary *> *OPFilterLocalSwitcherRows(NSArray *rows, NSDictionary *state) {
    NSMutableArray<NSDictionary *> *filtered=[NSMutableArray array];
    for(NSDictionary *row in rows)if(OPLocalSwitcherRowAllowed(row,state))[filtered addObject:row];
    return [filtered copy];
}
