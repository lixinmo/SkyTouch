#import "OPPhoneProfile.h"
#include <cmath>

namespace {
NSDictionary<NSString *,NSNumber *> *keyBits(NSInteger type) {
    // Verified against +[FZCFGCenter getKeyIDByName:type:] in the pinned
    // vendor image (0x1c1d98), including its separate type-2 branch. Composite
    // IDs are not raw bit positions. SELECT/L3 and system/menu keys are omitted
    // because the original updateKey path uses them as editor shortcuts.
    if(type==2)return @{@"A":@4,@"B":@5,@"LB":@10,@"LT":@12};
    if(type==0)return @{@"UP":@0,@"RIGHT":@1,@"DOWN":@2,@"LEFT":@3,
        @"A":@4,@"B":@5,@"X":@7,@"Y":@8,@"LB":@10,@"RB":@11,@"LT":@12,@"RT":@13,@"R3":@15};
    return @{};
}
BOOL fail(NSString **error,NSString *message){if(error)*error=message;return NO;}
BOOL integer(id value,NSInteger *result) {
    if(![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value)!=CFNumberGetTypeID() ||
       CFNumberIsFloatType((__bridge CFNumberRef)value))return NO;
    *result=[value integerValue];return YES;
}
// js_link is stored in both FZCFGPropertyKey and macro sub-actions. The vendor
// initializes it to -1 (FZCFGSubPropertyMacro init, 0x1c12d4) and serializes
// nonnegative values (0x1d7578). Preserve an entire macro or disable it; removing
// individual steps would change the ordering/timing of the remaining gesture.
BOOL inspectLink(NSDictionary *value,BOOL *linked,NSString **error) {
    id link=value[@"js_link"];NSInteger number=0;
    if(link && !integer(link,&number))return fail(error,@"方案中的摇杆联动字段格式无效。");
    if(link && number>=0)*linked=YES;
    return YES;
}
}
NSArray<NSString *> *OPPhoneBindableKeys(NSInteger type) {
    if(type==2)return @[@"LB",@"A",@"B",@"LT"];
    if(type==0)return @[@"LB",@"A",@"B",@"LT",@"X",@"Y",@"RB",@"RT",@"UP",@"RIGHT",@"DOWN",@"LEFT",@"R3"];
    return @[];
}
BOOL OPPhoneLogicalKeyMask(NSString *key,NSInteger type,uint32_t *mask) {
    if(mask)*mask=0;
    if(![key isKindOfClass:NSString.class])return NO;
    NSNumber *bit=keyBits(type)[key];if(!bit)return NO;
    if(mask)*mask=UINT32_C(1)<<bit.unsignedIntValue;return YES;
}
NSData *OPPhoneRuntimeProfile(NSData *source,NSInteger type,NSString **error) {
    if(error)*error=nil;
    if(type!=0 && type!=2){fail(error,@"手机模式暂不支持键鼠方案；请选择手柄或半柄方案。");return nil;}
    if(![source isKindOfClass:NSData.class] || !source.length || source.length>16*1024*1024){fail(error,@"方案数据无效或过大。");return nil;}
    id root=[NSJSONSerialization JSONObjectWithData:source options:0 error:nil];
    if(![root isKindOfClass:NSDictionary.class]){fail(error,@"方案不是有效的 FDG 文件。");return nil;}
    NSString *listKey=type==0 ? @"gamepad_list" : @"v1_list";id rows=root[listKey];
    if(![rows isKindOfClass:NSArray.class] || ![rows count] || ![rows[0] isKindOfClass:NSDictionary.class]){
        fail(error,@"当前布局没有已选择的方案。");return nil;
    }
    NSDictionary *original=rows[0];NSMutableDictionary *plan=[original mutableCopy];
    NSUInteger surviving=0,macroSteps=0;
    for(NSString *field in @[@"keys",@"joysticks",@"macros"]) {
        id list=original[field];if(!list)continue;
        if(![list isKindOfClass:NSArray.class] || [list count]>4096){fail(error,@"方案映射列表格式无效或项目过多。");return nil;}
        NSMutableArray *kept=[NSMutableArray array];
        for(id item in list) {
            if(![item isKindOfClass:NSDictionary.class] || ![item count]){fail(error,@"方案包含空的或无效的映射项目。");return nil;}
            if([field isEqual:@"joysticks"])continue;
            BOOL linked=NO;
            if([field isEqual:@"keys"]) {
                NSInteger kind=0;
                if(item[@"type"] && !integer(item[@"type"],&kind)){fail(error,@"方案按键动作类型无效。");return nil;}
                if(kind==35) {
                    // Type 35 consumes relative motion, not js_link. An old
                    // editor can leave that unrelated field behind after an
                    // action change. Sanitize only this runtime copy, without
                    // losing the motion action or touching the shared FDG.
                    NSDictionary *motion=item;
                    if(item[@"js_link"]) {
                        NSMutableDictionary *updated=[item mutableCopy];updated[@"js_link"]=@(-1);motion=updated;
                    }
                    [kept addObject:motion];++surviving;continue;
                }
                if(!inspectLink(item,&linked,error))return nil;
                // These vendor actions depend on an analog joystick. Ordinary
                // touch, swipe, macro and motion-view actions are retained.
                if(kind==5 || kind==6 || kind==7)linked=YES;
            } else {
                // Only macro_keys is decoded as macro sub-actions by the
                // vendor (getPropertyMacro:type:, 0x1d0a88). Never interpret
                // similarly named fields inside unknown extension metadata.
                id steps=item[@"macro_keys"];
                if(steps && (![steps isKindOfClass:NSArray.class] || [steps count]>4096)) {
                    fail(error,@"方案宏步骤列表格式无效或项目过多。");return nil;
                }
                for(id step in steps) {
                    if(++macroSteps>65536 || ![step isKindOfClass:NSDictionary.class] || ![step count]) {
                        fail(error,@"方案包含无效的宏步骤或步骤过多。");return nil;
                    }
                    if(!inspectLink(step,&linked,error))return nil;
                }
            }
            if(!linked){[kept addObject:item];++surviving;}
        }
        plan[field]=kept;
    }
    plan[@"joysticks"]=@[];
    if(!surviving){fail(error,@"该方案只有摇杆或摇杆联动动作，手机模式没有可执行的按键动作。原方案已保留。");return nil;}
    NSMutableDictionary *projected=[root mutableCopy];NSMutableArray *selected=[rows mutableCopy];
    selected[0]=plan;projected[listKey]=selected;
    NSData *result=[NSJSONSerialization dataWithJSONObject:projected options:NSJSONWritingSortedKeys error:nil];
    if(!result)fail(error,@"无法生成手机模式的临时运行配置。");return result;
}
