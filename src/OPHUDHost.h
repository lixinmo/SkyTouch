#pragma once
#import <UIKit/UIKit.h>
// Experimental host adaptation only. The original UI and mapping implementation
// are supplied by the byte-preserved vendor dylib, not rebuilt in this module.
int OPRunHUD(void);
// Verification target override is restricted to our own non-injected Probe.
int OPRunHUDWithOptions(BOOL verifyUIOnly, NSString * _Nullable targetBundle);
// Supervisor-owned engine process for one selected global profile. Its source
// bundle identifies stored FDG only; output is not restricted to that app.
// Original controller/views stay
// internal; no hosted global window or original-UI physical input is created.
// Never combines with UI-only options.
int OPRunManagedHUD(NSString * _Nonnull sessionIdentifier, NSString * _Nonnull targetBundle);
// Persistent system-wide configuration icon. The original library is loaded
// only while editing; closing replaces this process to release its singleton.
int OPRunFloatingConfiguration(NSString * _Nonnull targetBundle);
// Read-only process inspection. Emits JSON, creates no UIKit application or
// windows, loads no original library, and never dispatches a HID event.
int OPInspectHost(void);
UIInterfaceOrientation OPTargetOrientation(void);
