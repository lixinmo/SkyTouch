#pragma once
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
UIViewController *OPMakeConfigurationManager(void);
// Prevent external navigation from leaving an operation or restart prompt.
BOOL OPConfigurationManagementUIIsBusy(void);
NS_ASSUME_NONNULL_END
