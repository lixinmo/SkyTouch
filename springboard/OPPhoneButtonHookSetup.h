#pragma once
#include <objc/runtime.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    OPActionDown, OPActionUp, OPActionLong, OPPhysicalEvent,
    OPNativeGesture, OPVolumeDownAction, OPSideDownAction, OPNativeAction, OPNativeBoolAction,
    OPButtonHookKindCount
} OPButtonHookKind;

enum { OPButtonCoreHooks=4, OPButtonNativeHooks=25 };
typedef struct {
    Class target;
    SEL selector;
    IMP original;
    IMP replacement;
    uint32_t bit;
    bool primary;
} OPInstalledButtonHook;
typedef struct {
    OPInstalledButtonHook entries[OPButtonCoreHooks+OPButtonNativeHooks];
} OPButtonHookTable;
typedef struct {
    IMP entries[OPButtonHookKindCount];
} OPButtonHookReplacements;
typedef enum {
    OPButtonWaitingForClasses, OPButtonWrongABI, OPButtonHookConflict, OPButtonHooksReady
} OPButtonSetupResult;

// Only the SpringBoard main thread installs hooks and updates this table.
OPButtonSetupResult OPPrepareButtonHooks(OPButtonHookTable *,const OPButtonHookReplacements *,uint8_t *);

#ifdef __cplusplus
}
#endif
