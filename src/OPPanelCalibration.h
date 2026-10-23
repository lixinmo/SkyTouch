#pragma once
#import <UIKit/UIKit.h>
#include <cstdint>

// Called by this configuration application's own UIApplication subclass before
// normal event delivery. No swizzle, global monitoring or input generation.
void OPRecordPanelFromConfigurationEvent(UIEvent *event);
// Same-device, same-kernel-boot reference captured from the configuration UI.
BOOL OPReadPanelCalibration(std::uint64_t *senderID);
