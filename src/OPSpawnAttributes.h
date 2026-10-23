#pragma once
#include <spawn.h>

// Establish the supervisor's own group as part of spawn, before it can run or
// the configuration app can exit. A later child-side setpgid/setsid leaves a
// race with the launcher's process-group cleanup. Engine children intentionally
// keep inheriting this supervisor group; this does not alter signal handling.
static inline int OPSpawnInNewProcessGroup(posix_spawnattr_t *attributes) {
    short flags=0;
    int code=posix_spawnattr_getflags(attributes,&flags);
    if(!code)code=posix_spawnattr_setpgroup(attributes,0);
    if(!code)code=posix_spawnattr_setflags(attributes,flags|POSIX_SPAWN_SETPGROUP);
    return code;
}
