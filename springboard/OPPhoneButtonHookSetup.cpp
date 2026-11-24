#include "OPPhoneButtonHookSetup.h"
#include "../src/OPPhoneButtonProtocol.hpp"
#include <cstring>
#include <iterator>

using namespace op_phone_buttons;
namespace {
struct HookSpec {
    const char *className,*name,*result,*argument;
    OPButtonHookKind kind;
    uint32_t bit;
    bool primary;
};
static constexpr HookSpec hooks[]={
    {"SBRingerHardwareButton","performActionsForButtonDown:","v","@",OPActionDown,action,true},
    {"SBRingerHardwareButton","performActionsForButtonUp:","v","@",OPActionUp,action,true},
    {"SBRingerHardwareButton","performActionsForButtonLongPress:","v","@",OPActionLong,action,true},
    {"SpringBoard","_handlePhysicalButtonEvent:","B","@",OPPhysicalEvent,volumeUp|volumeDown|side,true},
    {"SBVolumeHardwareButton","volumeIncreasePress:","v","@",OPNativeGesture,volumeUp,true},
    {"SBVolumeHardwareButton","volumeDecreasePress:","v","@",OPNativeGesture,volumeDown,true},
    {"SBLockHardwareButton","buttonDown:","v","@",OPNativeGesture,side,true},
    {"SBLockHardwareButton","singlePress:","v","@",OPNativeGesture,side,false},
    {"SBLockHardwareButton","doublePress:","v","@",OPNativeGesture,side,false},
    {"SBLockHardwareButton","triplePress:","v","@",OPNativeGesture,side,false},
    {"SBLockHardwareButton","quadruplePress:","v","@",OPNativeGesture,side,false},
    {"SBLockHardwareButton","longPress:","v","@",OPNativeGesture,side,false},
    {"SBLockHardwareButton","terminalLockLongPress:","v","@",OPNativeGesture,side,false},
    {"SBVolumeHardwareButtonActions","volumeIncreasePressDownWithModifiers:","v","q",OPVolumeDownAction,volumeUp,false},
    {"SBVolumeHardwareButtonActions","volumeDecreasePressDownWithModifiers:","v","q",OPVolumeDownAction,volumeDown,false},
    {"SBVolumeHardwareButtonActions","volumeIncreasePressUp","v",nullptr,OPNativeAction,volumeUp,false},
    {"SBVolumeHardwareButtonActions","volumeDecreasePressUp","v",nullptr,OPNativeAction,volumeDown,false},
    {"SBLockHardwareButtonActions","performInitialButtonDownActions","v",nullptr,OPSideDownAction,side,false},
    {"SBLockHardwareButtonActions","performSecondButtonDownActions","v",nullptr,OPSideDownAction,side,false},
    {"SBLockHardwareButtonActions","performInitialButtonUpActions","v",nullptr,OPNativeAction,side,false},
    {"SBLockHardwareButtonActions","performFinalButtonUpActions","v",nullptr,OPNativeAction,side,false},
    {"SBLockHardwareButtonActions","performSinglePressAction","v",nullptr,OPNativeAction,side,false},
    {"SBLockHardwareButtonActions","performSinglePressDidFailActions","v",nullptr,OPNativeAction,side,false},
    {"SBLockHardwareButtonActions","performDoublePressActions","v",nullptr,OPNativeAction,side,false},
    {"SBLockHardwareButtonActions","performTriplePressActions","v",nullptr,OPNativeAction,side,false},
    {"SBLockHardwareButtonActions","performLongPressActions","v",nullptr,OPNativeAction,side,false},
    {"SBLockHardwareButtonActions","performLongPressCancelledActions","v",nullptr,OPNativeAction,side,false},
    {"SBLockHardwareButtonActions","performTerminalLockLongPressActions","v",nullptr,OPNativeAction,side,false},
    {"SBLockHardwareButtonActions","performButtonUpPreActions","B",nullptr,OPNativeBoolAction,side,false},
};
static_assert(std::size(hooks)==OPButtonCoreHooks+OPButtonNativeHooks);
struct MethodSpec {const char *className,*name,*result,*argument;};
// Stable ABI diagnostics 5..15. The four core replacements occupy 1..4,
// and the native click/action replacements start at 32.
static constexpr MethodSpec readMethods[]={
    {"UIPressesEvent","allPresses","@",nullptr},{"UIPressesEvent","_cloneEvent","@",nullptr},
    {"UIPressesEvent","_removePress:","v","@"},
    {"UIPress","type","q",nullptr},{"UIPress","phase","q",nullptr},{"UIPress","timestamp","d",nullptr},
    {"SBPressGestureRecognizer","latestPressType","q",nullptr},{"SBPressGestureRecognizer","latestPressPhase","q",nullptr},
    {"SBPressGestureRecognizer","latestPressTimestamp","d",nullptr},
    {"SBVolumeHardwareButton","buttonActions","@",nullptr},{"SBLockHardwareButton","buttonActions","@",nullptr},
};
static bool methodABI(Method method,const char *result,const char *argument) {
    if(!method || method_getNumberOfArguments(method)!=(argument ? 3u : 2u))return false;
    char type[32]{};
    method_getReturnType(method,type,sizeof(type));
    if(strcmp(type,result))return false;
    if(!argument)return true;
    method_getArgumentType(method,2,type,sizeof(type));
    return argument[0]=='@' ? type[0]=='@' : !strcmp(type,argument);
}
}
OPButtonSetupResult OPPrepareButtonHooks(OPButtonHookTable *table,const OPButtonHookReplacements *replacements,uint8_t *detail) {
    *detail=0;
    for(const char *name:{"SpringBoard","SBRingerHardwareButton","SBVolumeHardwareButton","SBLockHardwareButton",
                         "SBVolumeHardwareButtonActions","SBLockHardwareButtonActions"})
        if(!objc_lookUpClass(name))return OPButtonWaitingForClasses;

    // Validate every method before replacing the first one. For optional
    // routes, absence is supported but a mismatched existing ABI is not.
    for(size_t i=0;i<std::size(readMethods);++i) {
        const auto &read=readMethods[i];
        Method method=class_getInstanceMethod(objc_lookUpClass(read.className),sel_registerName(read.name));
        if(!methodABI(method,read.result,read.argument)) {
            *detail=static_cast<uint8_t>(i+5);return OPButtonWrongABI;
        }
    }
    Method methods[std::size(hooks)]{};
    for(size_t i=0;i<std::size(hooks);++i) {
        const auto &spec=hooks[i];
        Class target=objc_lookUpClass(spec.className);
        Method method=class_getInstanceMethod(target,sel_registerName(spec.name));
        const int nativeIndex=static_cast<int>(i)-OPButtonCoreHooks;
        const bool required=spec.primary || nativeIndex==3 || (nativeIndex>=9 && nativeIndex<=17);
        if(!method && !required)continue;
        if(!methodABI(method,spec.result,spec.argument)) {
            *detail=static_cast<uint8_t>(nativeIndex<0 ? i+1 : 32+nativeIndex);return OPButtonWrongABI;
        }
        methods[i]=method;
        auto &entry=table->entries[i];
        entry.target=target;entry.selector=method_getName(method);
        entry.bit=spec.bit;entry.primary=spec.primary;entry.replacement=replacements->entries[spec.kind];
    }
    bool ok=true;
    for(size_t i=0;i<std::size(hooks);++i) {
        Method method=methods[i];if(!method)continue;
        auto &entry=table->entries[i];
        // Publish the predecessor in the hook table before the replacement
        // can be called. Never replace an inherited implementation globally.
        entry.original=method_getImplementation(method);
        if(!entry.original || entry.original==entry.replacement){ok=false;continue;}
        if(!class_addMethod(entry.target,entry.selector,entry.replacement,method_getTypeEncoding(method)))
            method_setImplementation(class_getInstanceMethod(entry.target,entry.selector),entry.replacement);
        if(class_getMethodImplementation(entry.target,entry.selector)!=entry.replacement)ok=false;
    }
    return ok ? OPButtonHooksReady : OPButtonHookConflict;
}
