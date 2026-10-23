#import "OPOriginalMotionFix.h"
#import <objc/runtime.h>
#include <cstring>
#include <cstdint>

namespace op_motion_configuration {
using VoidMethod=void (*)(id,SEL);
using ApplyMethod=void (*)(id,SEL,id);
using ObjectMethod=id (*)(id,SEL);
static Class controllerClass=Nil, preferencesClass=Nil, entityClass=Nil;
static Method reloadMethod=nullptr, applyMethod=nullptr, sharedMethod=nullptr, currentMethod=nullptr, typeMethod=nullptr;
static IMP originalReload=nullptr, originalApply=nullptr, originalShared=nullptr, originalCurrent=nullptr, originalType=nullptr;
static BOOL installed=NO, reloading=NO;
static std::uint64_t syncCalls=0, completedSyncs=0, rejectedSyncs=0, emptySyncs=0;
static int lastDeviceType=-1;
static NSString *stage=@"not-installed";
static NSArray<NSDictionary *> *lastFPSKeys=@[];
static BOOL lastFPSKeysAvailable=NO;

static void reload(id self,SEL command);

static BOOL sameType(const char *type,char expected) {
    if(!type)return NO;
    while(*type && std::strchr("rnNoORV",*type))++type;
    if(*type!=expected)return NO;
    return type[1]=='\0' || (expected=='@' && type[1]=='"');
}
static BOOL signature(Method method,char result,const char *arguments) {
    if(!method || method_getNumberOfArguments(method)!=2+std::strlen(arguments))return NO;
    NSMethodSignature *value=[NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    if(!value || !sameType(value.methodReturnType,result) ||
       !sameType([value getArgumentTypeAtIndex:0],'@') || !sameType([value getArgumentTypeAtIndex:1],':'))return NO;
    for(NSUInteger i=0;i<std::strlen(arguments);++i)
        if(!sameType([value getArgumentTypeAtIndex:i+2],arguments[i]))return NO;
    return YES;
}
static BOOL ownsMethod(Class cls,Method method) {
    unsigned count=0;Method *methods=class_copyMethodList(cls,&count);BOOL found=NO;
    for(unsigned i=0;i<count;++i)if(methods[i]==method){found=YES;break;}
    free(methods);return found;
}
static BOOL implementationsMatch(void) {
    return installed && method_getImplementation(reloadMethod)==(IMP)reload &&
        method_getImplementation(applyMethod)==originalApply &&
        method_getImplementation(sharedMethod)==originalShared &&
        method_getImplementation(currentMethod)==originalCurrent &&
        method_getImplementation(typeMethod)==originalType;
}
static void fail(NSString *reason) {
    // A void vendor callback cannot return an NSError. Propagate an explicit
    // failure so callers cannot mistake a partially applied reload for success.
    [NSException raise:NSInternalInconsistencyException format:@"体感配置同步失败：%@",reason];
}
static void inspectFPSKeys(id entity) {
    lastFPSKeys=@[];lastFPSKeysAvailable=NO;
    // Optional diagnostics must never become another application precondition.
    // Types3/4 are FPS view/shoot; type35 is the cloud MOBA motion-view
    // property. It retains signed gains for its separate reverse controls.
    @try {
        if(!entity){lastFPSKeysAvailable=YES;return;}
        Method listMethod=class_getInstanceMethod(object_getClass(entity),@selector(keyList));
        if(!signature(listMethod,'@',""))return;
        id keys=((ObjectMethod)method_getImplementation(listMethod))(entity,@selector(keyList));
        if(![keys isKindOfClass:NSArray.class] || [keys count]>4096)return;
        NSMutableArray *result=[NSMutableArray array];
        for(id key in keys) {
            Method kind=class_getInstanceMethod(object_getClass(key),@selector(type));
            Method horizontal=class_getInstanceMethod(object_getClass(key),@selector(senty_x));
            Method vertical=class_getInstanceMethod(object_getClass(key),@selector(senty_y));
            if(!signature(kind,'i',"") || !signature(horizontal,'i',"") || !signature(vertical,'i',""))continue;
            int type=((int(*)(id,SEL))method_getImplementation(kind))(key,@selector(type));
            if(type!=3 && type!=4 && type!=35)continue;
            int x=((int(*)(id,SEL))method_getImplementation(horizontal))(key,@selector(senty_x));
            int y=((int(*)(id,SEL))method_getImplementation(vertical))(key,@selector(senty_y));
            NSMutableDictionary *record=[@{@"type":@(type),@"sentyX":@(x),@"sentyY":@(y)} mutableCopy];
            Method duration=class_getInstanceMethod(object_getClass(key),@selector(duration));
            if(signature(duration,'i',""))record[@"duration"]=@(((int(*)(id,SEL))method_getImplementation(duration))(key,@selector(duration)));
            [result addObject:record];
        }
        lastFPSKeys=[result copy];lastFPSKeysAvailable=YES;
    } @catch(__unused NSException *exception) {lastFPSKeys=@[];}
}
static void reload(id self,SEL command) {
    if(!NSThread.isMainThread)fail(@"配置重载必须在主线程执行");
    ++syncCalls;
    BOOL ownsReload=NO;
    @try {
        if(!implementationsMatch())fail(@"原配置方法已被替换");
        if(reloading)fail(@"检测到递归配置重载");
        if(![self isKindOfClass:controllerClass] ||
           method_getImplementation(class_getInstanceMethod(object_getClass(self),@selector(reloadCurrentFDG)))!=(IMP)reload ||
           method_getImplementation(class_getInstanceMethod(object_getClass(self),@selector(applyEntity:)))!=originalApply)
            fail(@"原配置控制器接口不匹配");
        reloading=YES;ownsReload=YES;stage=@"applying";
        id preferences=((ObjectMethod)originalShared)(preferencesClass,@selector(sharedFZPreferRecordTool));
        if(![preferences isKindOfClass:preferencesClass] ||
           method_getImplementation(class_getInstanceMethod(object_getClass(preferences),@selector(getCurrentFDG)))!=originalCurrent ||
           method_getImplementation(class_getInstanceMethod(object_getClass(preferences),@selector(peripheralType)))!=originalType)
            fail(@"原配置存储接口不匹配");
        lastDeviceType=((int(*)(id,SEL))originalType)(preferences,@selector(peripheralType));
        id entity=((ObjectMethod)originalCurrent)(preferences,@selector(getCurrentFDG));
        if(entity && ![entity isKindOfClass:entityClass])fail(@"当前方案不是原配置实体");
        inspectFPSKeys(entity);
        Method clear=class_getInstanceMethod(object_getClass(self),@selector(clearTouchList));
        if(!signature(clear,'v',""))fail(@"原触点取消接口不匹配");
        // Resetting the C table does not send terminal touch events. Resolve
        // this IMP at call time: OriginalPort legitimately hooks it after this
        // installer, and that bridge hook also cancels system-side contacts.
        ((VoidMethod)method_getImplementation(clear))(self,@selector(clearTouchList));
        // Local reload previously updated only FZMapping. Wasp identification
        // and local editing can change the entity after the legacy C mapper
        // was initialized. Reapply on every call, including in-place edits.
        // nil preserves the vendor apply/reload behavior: the legacy C table
        // resets, while fd_file_parsing_new:nil returns without parsing.
        ((ApplyMethod)originalApply)(self,@selector(applyEntity:),entity);
        if(!implementationsMatch())fail(@"应用方案期间原配置方法已被替换");
        ((VoidMethod)originalReload)(self,command);
        ++completedSyncs;if(!entity)++emptySyncs;stage=@"synchronized";
    } @catch(NSException *exception) {
        ++rejectedSyncs;stage=@"rejected";@throw exception;
    } @finally {
        if(ownsReload)reloading=NO;
    }
}
} // namespace op_motion_configuration

BOOL OPInstallOriginalMotionConfigurationFix(NSString **error) {
    using namespace op_motion_configuration;
    if(error)*error=nil;
    if(!NSThread.isMainThread){if(error)*error=@"体感配置同步修复必须在主线程安装";return NO;}
    if(installed) {
        const BOOL valid=implementationsMatch();
        if(!valid && error)*error=@"体感配置同步修复依赖的原方法已被替换";
        return valid;
    }
    Class candidateController=NSClassFromString(@"FZCentralViewController");
    Class candidatePreferences=NSClassFromString(@"FZPreferRecordTool");
    Class candidateEntity=NSClassFromString(@"FZCFGEntity");
    Method candidateReload=class_getInstanceMethod(candidateController,@selector(reloadCurrentFDG));
    Method candidateApply=class_getInstanceMethod(candidateController,@selector(applyEntity:));
    Method candidateShared=class_getClassMethod(candidatePreferences,@selector(sharedFZPreferRecordTool));
    Method candidateCurrent=class_getInstanceMethod(candidatePreferences,@selector(getCurrentFDG));
    Method candidateType=class_getInstanceMethod(candidatePreferences,@selector(peripheralType));
    Method candidateClear=class_getInstanceMethod(candidateController,@selector(clearTouchList));
    if(!candidateController || !candidatePreferences || !candidateEntity ||
       !signature(candidateReload,'v',"") || !signature(candidateApply,'v',"@") ||
       !signature(candidateShared,'@',"") || !signature(candidateCurrent,'@',"") || !signature(candidateType,'i',"") ||
       !signature(candidateClear,'v',"") ||
       !ownsMethod(candidateController,candidateReload) || !ownsMethod(candidateController,candidateApply) ||
       !ownsMethod(object_getClass(candidatePreferences),candidateShared) || !ownsMethod(candidatePreferences,candidateCurrent) ||
       !ownsMethod(candidatePreferences,candidateType)) {
        if(error)*error=@"原体感配置接口缺失或 ABI 不匹配，未安装修复";return NO;
    }
    IMP candidateReloadIMP=method_getImplementation(candidateReload);
    IMP candidateApplyIMP=method_getImplementation(candidateApply);
    IMP candidateSharedIMP=method_getImplementation(candidateShared);
    IMP candidateCurrentIMP=method_getImplementation(candidateCurrent);
    IMP candidateTypeIMP=method_getImplementation(candidateType);
    if(!candidateReloadIMP || !candidateApplyIMP || !candidateSharedIMP || !candidateCurrentIMP || !candidateTypeIMP || candidateReloadIMP==(IMP)reload) {
        if(error)*error=@"原体感配置实现无效，未安装修复";return NO;
    }
    controllerClass=candidateController;preferencesClass=candidatePreferences;entityClass=candidateEntity;
    reloadMethod=candidateReload;applyMethod=candidateApply;sharedMethod=candidateShared;currentMethod=candidateCurrent;typeMethod=candidateType;
    originalReload=candidateReloadIMP;originalApply=candidateApplyIMP;originalShared=candidateSharedIMP;originalCurrent=candidateCurrentIMP;originalType=candidateTypeIMP;
    // One mutation after all checks; restore the observed implementation if
    // another installer raced this main-thread registration.
    IMP previous=method_setImplementation(reloadMethod,(IMP)reload);
    if(previous!=originalReload || method_getImplementation(reloadMethod)!=(IMP)reload) {
        if(method_getImplementation(reloadMethod)==(IMP)reload)method_setImplementation(reloadMethod,previous);
        if(error)*error=@"体感配置方法安装冲突，已撤销修复";return NO;
    }
    installed=YES;stage=@"installed";
    return YES;
}

NSDictionary *OPOriginalMotionConfigurationFixStatus(void) {
    using namespace op_motion_configuration;
    if(!NSThread.isMainThread)return @{@"available":@NO,@"stage":@"requires-main-thread"};
    return @{@"available":@YES,@"installed":@(installed),@"implementationsMatch":@(implementationsMatch()),
        @"stage":stage,@"syncCalls":@(syncCalls),@"completedSyncs":@(completedSyncs),
        @"rejectedSyncs":@(rejectedSyncs),@"emptySyncs":@(emptySyncs),@"lastDeviceType":@(lastDeviceType),
        @"fpsKeysAvailable":@(lastFPSKeysAvailable),@"fpsKeys":lastFPSKeys,
        @"motionKeysAvailable":@(lastFPSKeysAvailable),@"motionKeys":lastFPSKeys};
}
