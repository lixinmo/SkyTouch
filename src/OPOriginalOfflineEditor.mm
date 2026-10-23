#import "OPOriginalOfflineEditor.h"
#import "OPOriginalBluetoothClient.h"
#import <objc/message.h>
#import <objc/runtime.h>
#include <array>
#include <cstring>

namespace op_offline_editor {
using VoidMethod=void(*)(id,SEL);
using IntMethod=void(*)(id,SEL,int);
struct Hook {const char *name;const char *arguments;IMP replacement;Method method=nullptr;IMP original=nullptr;};
static BOOL installed=NO,prepared=NO;
static __weak id owner;
static int editorType=-1;
static NSString *editorName=@"";
static NSString *stage=@"not-installed";
static NSUInteger preservedDisconnects=0,deferredTypeChanges=0;
static void connection(id,SEL,int);
static void peripheralType(id,SEL,int);
static void forceKeys(id,SEL);
static void toggleKeys(id,SEL);
static void checkBluetooth(id,SEL);
static std::array<Hook,5> hooks{{
    {"setBLEConnectMode:","i",(IMP)connection},
    {"updatePeripheralType:","i",(IMP)peripheralType},
    {"forceShowKeymappingIcon","",(IMP)forceKeys},
    {"onThumbLButtonOn","",(IMP)toggleKeys},
    {"checkBleConnection","",(IMP)checkBluetooth}
}};
static BOOL typeMatches(const char *type,char expected) {
    if(!type)return NO;
    while(*type && std::strchr("rnNoORV",*type))++type;
    return *type==expected && (type[1]=='\0' || (expected=='@' && type[1]=='"'));
}
static BOOL signature(Method method,char result,const char *arguments) {
    if(!method || method_getNumberOfArguments(method)!=2+std::strlen(arguments))return NO;
    NSMethodSignature *s=[NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    if(!s || !typeMatches(s.methodReturnType,result) ||
       !typeMatches([s getArgumentTypeAtIndex:0],'@') || !typeMatches([s getArgumentTypeAtIndex:1],':'))return NO;
    for(NSUInteger i=0;i<std::strlen(arguments);++i)
        if(!typeMatches([s getArgumentTypeAtIndex:i+2],arguments[i]))return NO;
    return YES;
}
static BOOL method(Class cls,const char *name,char result,const char *arguments,BOOL classMethod=NO) {
    SEL selector=sel_registerName(name);
    return signature(classMethod ? class_getClassMethod(cls,selector) : class_getInstanceMethod(cls,selector),result,arguments);
}
static BOOL owns(Class cls,Method method) {
    unsigned count=0;Method *list=class_copyMethodList(cls,&count);BOOL found=NO;
    for(unsigned i=0;i<count;++i)if(list[i]==method){found=YES;break;}
    free(list);return found;
}
static id get(id object,const char *name) {return ((id(*)(id,SEL))objc_msgSend)(object,sel_registerName(name));}
static void invoke(id object,const char *name) {((VoidMethod)objc_msgSend)(object,sel_registerName(name));}
static void setInt(id object,const char *name,int value) {((IntMethod)objc_msgSend)(object,sel_registerName(name),value);}
static void setObject(id object,const char *name,id value) {((void(*)(id,SEL,id))objc_msgSend)(object,sel_registerName(name),value);}
static id preferences(void) {return get(NSClassFromString(@"FZPreferRecordTool"),"sharedFZPreferRecordTool");}
static BOOL active(id self) {return installed && prepared && NSThread.isMainThread && self==owner;}
static BOOL implementationsMatch(void) {
    if(!installed)return NO;
    for(std::size_t i=0;i<hooks.size();++i) {
        const Hook &hook=hooks[i];
        if(method_getImplementation(hook.method)==hook.replacement)continue;
        // The BLE client observes real type reports outside this editing
        // adapter. Accept exactly its verified outer wrapper, never any
        // arbitrary later swizzle with a compatible-looking signature.
        if(i==1 && OPOriginalBluetoothClientWrapsPeripheralType(hook.replacement))continue;
        return NO;
    }
    return YES;
}
static void restoreIdentity(void) {
    id prefs=preferences();
    setInt(prefs,"setPeripheralType:",editorType);
    setObject(prefs,"setLastDeviceName:",editorName);
}
static BOOL hasSubpage(id self) {
    for(const char *name:{"winSetting","winImport","winSaveAs","winSaveHint","winOldFunctionSetting"})
        if(get(self,name))return YES;
    return NO;
}
static BOOL iconHidden(id icon) {
    return ((BOOL(*)(id,SEL))objc_msgSend)(icon,sel_registerName("isHidden"));
}
static void setIconHidden(id icon,BOOL hidden) {
    ((void(*)(id,SEL,BOOL))objc_msgSend)(icon,sel_registerName("setHidden:"),hidden);
}
static void connection(id self,SEL selector,int mode) {
    if(!active(self)){((IntMethod)hooks[0].original)(self,selector,mode);return;}
    id icon=get(self,"winKeyMappingIcon");const BOOL hidden=iconHidden(icon);
    restoreIdentity();
    @try {
        // Preserve the real mode, peripheral cleanup and real connection
        // callbacks. In particular, do not turn a disconnected mode into 2.
        ((IntMethod)hooks[0].original)(self,selector,mode);
    } @finally {
        // The vendor disconnect branch erases type/name and hides the keys.
        // Those are editor state here, not evidence of a physical connection.
        restoreIdentity();
        if(mode==2)invoke(icon,"show");
        setIconHidden(icon,hidden || hasSubpage(self));
        if(mode!=2)++preservedDisconnects;
    }
}
static void peripheralType(id self,SEL selector,int type) {
    if(!active(self)){((IntMethod)hooks[1].original)(self,selector,type);return;}
    // The original schedules hideFloatingWindow + reloadCurrentFDG on type
    // changes, removing drafts. The BLE client records the actual identity
    // separately; the next editor entry chooses that identity explicitly.
    restoreIdentity();++deferredTypeChanges;
}
static void forceKeys(id self,SEL selector) {
    if(!active(self)){((VoidMethod)hooks[2].original)(self,selector);return;}
    if(!hasSubpage(self))invoke(get(self,"winKeyMappingIcon"),"forceDisplay");
}
static void toggleKeys(id self,SEL selector) {
    if(!active(self)){((VoidMethod)hooks[3].original)(self,selector);return;}
    if(!hasSubpage(self))invoke(get(self,"winKeyMappingIcon"),"changeDisplayMode");
}
static void checkBluetooth(id self,SEL selector) {
    // checkBleConnection only shows a Bluetooth-disabled modal. Offline
    // editing must not require enabling the radio; discovery is unchanged.
    if(!active(self))((VoidMethod)hooks[4].original)(self,selector);
}
} // namespace op_offline_editor

BOOL OPInstallOriginalOfflineEditor(NSString **error) {
    using namespace op_offline_editor;
    if(error)*error=nil;
    if(!NSThread.isMainThread){if(error)*error=@"离线配置必须在主线程初始化";return NO;}
    if(installed){BOOL valid=implementationsMatch();if(!valid && error)*error=@"离线配置接口已被替换";return valid;}
    Class cls=NSClassFromString(@"FZCentralViewController"),prefs=NSClassFromString(@"FZPreferRecordTool");
    Class manager=NSClassFromString(@"FLEXManager"),icon=NSClassFromString(@"FZFloatingKeyMapping");
    BOOL valid=cls && prefs && manager && icon &&
        method(manager,"sharedManager",'@',"",YES) && method(manager,"fzVC",'@',"") &&
        method(prefs,"sharedFZPreferRecordTool",'@',"",YES) &&
        method(prefs,"peripheralType",'i',"") && method(prefs,"setPeripheralType:",'v',"i") &&
        method(prefs,"lastDeviceName",'@',"") && method(prefs,"setLastDeviceName:",'v',"@") &&
        method(cls,"reloadCurrentFDG",'v',"") && method(cls,"initConfigurationArray",'v',"") &&
        method(cls,"connectMode",'i',"") && method(cls,"onSelecteButtonOn",'v',"") &&
        method(icon,"show",'v',"") && method(icon,"forceDisplay",'v',"") &&
        method(icon,"changeDisplayMode",'v',"") && method(icon,"isHidden",@encode(BOOL)[0],"") && method(icon,"setHidden:",'v',@encode(BOOL));
    for(const char *name:{"winKeyMappingIcon","winSetting","winImport","winSaveAs","winSaveHint","winOldFunctionSetting","menuFloating"})
        valid=valid && method(cls,name,'@',"");
    for(Hook &hook:hooks) {
        hook.method=class_getInstanceMethod(cls,sel_registerName(hook.name));
        valid=valid && signature(hook.method,'v',hook.arguments) && owns(cls,hook.method);
        hook.original=hook.method ? method_getImplementation(hook.method) : nullptr;
        valid=valid && hook.original && hook.original!=hook.replacement;
    }
    if(!valid){if(error)*error=@"原版离线配置接口不兼容，未修改连接状态";return NO;}
    // Validate the complete set before installing any hook; roll back if a
    // later replacement ever races this main-thread-only installation.
    std::size_t changed=0;
    for(Hook &hook:hooks) {
        IMP previous=method_setImplementation(hook.method,hook.replacement);++changed;
        if(previous!=hook.original || method_getImplementation(hook.method)!=hook.replacement) {
            if(method_getImplementation(hook.method)==hook.replacement)method_setImplementation(hook.method,previous);
            for(std::size_t i=0;i+1<changed;++i)if(method_getImplementation(hooks[i].method)==hooks[i].replacement)
                method_setImplementation(hooks[i].method,hooks[i].original);
            if(error)*error=@"离线配置初始化冲突，已撤销";return NO;
        }
    }
    installed=YES;stage=@"installed";return YES;
}

BOOL OPPrepareOriginalOfflineEditor(NSInteger deviceType,NSString *deviceName,NSString **error) {
    using namespace op_offline_editor;
    if(error)*error=nil;
    if(!NSThread.isMainThread || !implementationsMatch() || deviceType<0 || deviceType>2 ||
       ![deviceName isKindOfClass:NSString.class]) {
        if(error)*error=@"离线配置的手柄类型或初始化状态无效";return NO;
    }
    id controller=get(get(NSClassFromString(@"FLEXManager"),"sharedManager"),"fzVC");
    if(![controller isKindOfClass:NSClassFromString(@"FZCentralViewController")]) {
        if(error)*error=@"原版配置控制器尚未创建";return NO;
    }
    if(prepared) {
        if(controller==owner && editorType==(int)deviceType && [editorName isEqualToString:deviceName])return YES;
        if(error)*error=@"当前正在编辑另一手柄类型，请保存后重新进入";return NO;
    }
    @try {
        owner=controller;editorType=(int)deviceType;editorName=[deviceName copy];prepared=YES;
        restoreIdentity();
        // reload is already wrapped by the motion fix: it initializes both
        // mapping representations and shows the current slot immediately.
        // Import/Setting/Save then read the same prefs.getCurrentFDG slot;
        // none of their original handlers depends on connectMode.
        invoke(controller,"reloadCurrentFDG");
        invoke(controller,"initConfigurationArray");
        stage=@"editing";return YES;
    } @catch(__unused NSException *exception) {
        prepared=NO;owner=nil;stage=@"failed";
        if(error)*error=@"无法初始化离线配置，已保留本地方案";return NO;
    }
}
void OPFinishOriginalOfflineEditor(void) {
    using namespace op_offline_editor;
    if(!NSThread.isMainThread)return;
    prepared=NO;owner=nil;stage=installed ? @"idle" : @"not-installed";
}
BOOL OPOriginalOfflineEditorEnabled(void) {return NSThread.isMainThread && op_offline_editor::prepared;}
NSDictionary *OPOriginalOfflineEditorStatus(void) {
    using namespace op_offline_editor;
    if(!NSThread.isMainThread)return @{@"available":@NO};
    int mode=owner ? ((int(*)(id,SEL))objc_msgSend)(owner,sel_registerName("connectMode")) : -1;
    return @{@"available":@YES,@"installed":@(installed),@"prepared":@(prepared),@"stage":stage,
        @"deviceType":@(editorType),@"connectMode":@(mode),@"implementationsMatch":@(implementationsMatch()),
        @"preservedDisconnects":@(preservedDisconnects),@"deferredTypeChanges":@(deferredTypeChanges)};
}
