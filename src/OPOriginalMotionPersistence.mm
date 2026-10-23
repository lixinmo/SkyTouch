#import "OPOriginalMotionPersistence.h"
#import <objc/runtime.h>
#include <cstring>
#include <cstdlib>

namespace op_motion_persistence {
using PropertyMethod=id (*)(id,SEL,id,int);
using ObjectMethod=id (*)(id,SEL);
typedef id (*RetainedObjectMethod)(id,SEL) __attribute__((ns_returns_retained));
using IntMethod=int (*)(id,SEL);
static Class keyClass=Nil;
static Method readMethod=nullptr, writeMethod=nullptr, copyMethod=nullptr;
static IMP originalRead=nullptr, originalWrite=nullptr, originalCopy=nullptr;
static BOOL installed=NO;
static char metadataKey;

static id readProperty(id self,SEL command,id JSON,int deviceType);
static id writeProperties(id self,SEL command,id properties,int deviceType);
static id copyProperty(id self,SEL command) __attribute__((ns_returns_retained));

static BOOL signature(Method method,char result,const char *arguments) {
    if(!method || method_getNumberOfArguments(method)!=2+std::strlen(arguments))return NO;
    NSMethodSignature *value=[NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    auto matches=[](const char *type,char expected)->BOOL {
        if(!type)return NO;
        while(*type && std::strchr("rnNoORV",*type))++type;
        return *type==expected && (type[1]=='\0' || (expected=='@' && type[1]=='"'));
    };
    if(!value || !matches(value.methodReturnType,result) ||
       !matches([value getArgumentTypeAtIndex:0],'@') || !matches([value getArgumentTypeAtIndex:1],':'))return NO;
    for(NSUInteger i=0;i<std::strlen(arguments);++i)
        if(!matches([value getArgumentTypeAtIndex:i+2],arguments[i]))return NO;
    return YES;
}
static BOOL ownsMethod(Class cls,Method method) {
    unsigned count=0;Method *list=class_copyMethodList(cls,&count);BOOL found=NO;
    for(unsigned i=0;i<count;++i)if(list[i]==method){found=YES;break;}
    free(list);return found;
}
static BOOL intValue(id target,SEL selector,int *value) {
    Method method=class_getInstanceMethod(object_getClass(target),selector);
    if(!signature(method,'i',""))return NO;
    *value=((IntMethod)method_getImplementation(method))(target,selector);return YES;
}
static BOOL isMotionKey(id key) {
    int type=0;
    return [key isKindOfClass:keyClass] && intValue(key,@selector(type),&type) && type==35;
}
static NSDictionary *metadata(id key) {return objc_getAssociatedObject(key,&metadataKey);}
static void setMetadata(id key,NSDictionary *value) {
    objc_setAssociatedObject(key,&metadataKey,[value copy],OBJC_ASSOCIATION_RETAIN);
}
static NSSet<NSString *> *vendorFields(void) {
    static NSSet *fields;static dispatch_once_t once;
    dispatch_once(&once,^{fields=[NSSet setWithArray:@[@"key",@"key_id",@"x",@"y",@"type",@"sub_type",@"show",
        @"senty_x",@"senty_y",@"speedy_gua",@"click_times",@"angle",@"range",@"switchRKey",@"ban",
        @"radius_change",@"duration",@"js_link",@"radius"]];});
    return fields;
}
static id readProperty(id self,SEL command,id JSON,int deviceType) {
    id key=((PropertyMethod)originalRead)(self,command,JSON,deviceType);
    if(isMotionKey(key) && [JSON isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *extensions=[NSMutableDictionary dictionary];
        for(id name in JSON)if([name isKindOfClass:NSString.class] && ![vendorFields() containsObject:name])
            extensions[name]=JSON[name];
        setMetadata(key,@{@"xPresent":@([JSON objectForKey:@"senty_x"]!=nil),
                          @"yPresent":@([JSON objectForKey:@"senty_y"]!=nil),@"extensions":[extensions copy]});
    }
    return key;
}
static id copyProperty(id self,SEL command) {
    id key=((RetainedObjectMethod)originalCopy)(self,command);
    NSDictionary *source=metadata(self);
    if(source && key)setMetadata(key,source);
    return key;
}
static void preserveSensitivity(NSMutableDictionary *JSON,id key,NSDictionary *source,NSString *name,NSString *presence,SEL getter) {
    int value=0;if(!intValue(key,getter,&value))return;
    // The vendor initializes missing senty fields to -1. An explicit -1 from
    // the cloud/editor is also valid: sensitivity 1 with reverse enabled.
    // Keep those cases distinct. Other negative values cannot be that sentinel.
    if(value>0 || [source[presence] boolValue] || value < -1)JSON[name]=@(value);
    else [JSON removeObjectForKey:name];
}
static id writeProperties(id self,SEL command,id properties,int deviceType) {
    id output=((PropertyMethod)originalWrite)(self,command,properties,deviceType);
    if(![properties isKindOfClass:NSArray.class] || ![output isKindOfClass:NSArray.class] ||
       [properties count]!=[output count])return output;
    NSMutableArray *result=nil;
    for(NSUInteger i=0;i<[properties count];++i) {
        id key=properties[i];if(!isMotionKey(key) || ![output[i] isKindOfClass:NSDictionary.class])continue;
        NSDictionary *source=metadata(key);
        NSMutableDictionary *JSON=[output[i] mutableCopy];
        // Retain newer cloud extension fields that this older model cannot
        // represent, while letting all supported fields reflect current edits.
        NSDictionary *extensions=source[@"extensions"];
        if([extensions isKindOfClass:NSDictionary.class])[JSON addEntriesFromDictionary:extensions];
        preserveSensitivity(JSON,key,source,@"senty_x",@"xPresent",@selector(senty_x));
        preserveSensitivity(JSON,key,source,@"senty_y",@"yPresent",@selector(senty_y));
        if(![JSON isEqual:output[i]]) {
            if(!result)result=[output mutableCopy];
            result[i]=JSON;
        }
    }
    return result ?: output;
}
static BOOL matchesInstalled(void) {
    return installed && method_getImplementation(readMethod)==(IMP)readProperty &&
        method_getImplementation(writeMethod)==(IMP)writeProperties && method_getImplementation(copyMethod)==(IMP)copyProperty;
}
} // namespace op_motion_persistence

BOOL OPOriginalMotionSensitivityIsPresent(id key,BOOL horizontal) {
    using namespace op_motion_persistence;
    if(!isMotionKey(key))return NO;
    int value=0;
    if(!intValue(key,horizontal ? @selector(senty_x) : @selector(senty_y),&value))return NO;
    return value>0 || value < -1 || [metadata(key)[horizontal ? @"xPresent" : @"yPresent"] boolValue];
}
void OPMarkOriginalMotionSensitivityAxesPresent(id key,BOOL horizontal,BOOL vertical) {
    using namespace op_motion_persistence;
    if(!isMotionKey(key) || (!horizontal && !vertical))return;
    NSMutableDictionary *source=[metadata(key) mutableCopy] ?: [NSMutableDictionary dictionary];
    if(horizontal)source[@"xPresent"]=@YES;
    if(vertical)source[@"yPresent"]=@YES;
    setMetadata(key,source);
}
void OPMarkOriginalMotionSensitivityPresent(id key) {
    OPMarkOriginalMotionSensitivityAxesPresent(key,YES,YES);
}

BOOL OPInstallOriginalMotionPersistenceFix(NSString **error) {
    using namespace op_motion_persistence;
    if(error)*error=nil;
    if(!NSThread.isMainThread){if(error)*error=@"体感配置保存修复必须在主线程安装";return NO;}
    if(installed){BOOL valid=matchesInstalled();if(!valid && error)*error=@"体感配置读写方法已被替换";return valid;}
    Class io=NSClassFromString(@"FZCFGIOCenter"),key=NSClassFromString(@"FZCFGPropertyKey");
    Method read=class_getInstanceMethod(io,@selector(getPropertyKey:type:));
    Method write=class_getInstanceMethod(io,@selector(getJsonPropertyKey:type:));
    Method copy=class_getInstanceMethod(key,@selector(copy));
    if(!io || !key || !signature(read,'@',"@i") || !signature(write,'@',"@i") || !signature(copy,'@',"") ||
       !ownsMethod(io,read) || !ownsMethod(io,write) || !ownsMethod(key,copy) ||
       !signature(class_getInstanceMethod(key,@selector(type)),'i',"") ||
       !signature(class_getInstanceMethod(key,@selector(senty_x)),'i',"") ||
       !signature(class_getInstanceMethod(key,@selector(senty_y)),'i',"")) {
        if(error)*error=@"原体感配置读写接口 ABI 不匹配，未安装修复";return NO;
    }
    keyClass=key;readMethod=read;writeMethod=write;copyMethod=copy;
    originalRead=method_getImplementation(read);originalWrite=method_getImplementation(write);originalCopy=method_getImplementation(copy);
    struct Change {Method method;IMP expected;IMP replacement;IMP observed;};
    Change changes[]={{read,originalRead,(IMP)readProperty,nullptr},{write,originalWrite,(IMP)writeProperties,nullptr},
                      {copy,originalCopy,(IMP)copyProperty,nullptr}};
    unsigned changed=0;BOOL valid=YES;
    for(auto &change:changes) {
        change.observed=method_setImplementation(change.method,change.replacement);++changed;
        if(change.observed!=change.expected || method_getImplementation(change.method)!=change.replacement){valid=NO;break;}
    }
    if(!valid) {
        while(changed){auto &change=changes[--changed];if(method_getImplementation(change.method)==change.replacement)
            method_setImplementation(change.method,change.observed);}
        if(error)*error=@"体感配置读写安装冲突，已撤销修复";return NO;
    }
    installed=YES;return YES;
}
