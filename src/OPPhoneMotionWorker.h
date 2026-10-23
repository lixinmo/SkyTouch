#pragma once
#import <Foundation/Foundation.h>
// Private inherited socketpair entry of SkyTouchMapping, never a public service.
// Validates root caller/parent/bundle/FD, then permanently drops this child to
// mobile before constructing a CoreMotion manager. No HID output exists here.
int OPRunPhoneMotionWorker(int inheritedFD);
