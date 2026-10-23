#include <notify.h>
#include <string.h>

// Package maintenance only: request graceful shutdown of our own services.
// It never kills the configuration App or touches another package.
int main(int argc, char **argv) {
    const int packageMaintenance=argc==2 && strcmp(argv[1],"--package-maintenance")==0;
    if (argc != 1 && !packageMaintenance) return 64;
    int result = 0;
    if(packageMaintenance)result |= (int)notify_post("com.lixinmo.skytouch.buttons.maintenance");
    result |= (int)notify_post("com.lixinmo.skytouch.runtime.maintenance-stop");
    result |= (int)notify_post("com.lixinmo.skytouch.floating.stop");
    result |= (int)notify_post("com.lixinmo.skytouch.original.supervisor.stop");
    result |= (int)notify_post("com.lixinmo.skytouch.original.bluetooth.stop");
    result |= (int)notify_post("com.lixinmo.skytouch.original.ui-only.stop");
    result |= (int)notify_post("com.lixinmo.skytouch.original.stop");
    result |= (int)notify_post("com.lixinmo.skytouch.stop");
    return result ? 69 : 0;
}
