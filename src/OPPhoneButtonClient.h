#pragma once
#import <Foundation/Foundation.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN
// Mapping-service side of the phone input bridge. All API calls/callbacks are
// on the main thread. YES means startup was scheduled, not that hooks are ready.
// Ready requires an authenticated, fresh, complete four-button handshake.
BOOL OPStartPhoneButtonClient(void (^onState)(uint32_t mask),dispatch_block_t invalidated,
                             NSString * _Nullable * _Nullable error);
BOOL OPPhoneButtonClientReady(void);
void OPSetPhoneButtonClientArmed(BOOL armed);
void OPStopPhoneButtonClient(void);
NSDictionary *OPPhoneButtonClientStatus(void);
NS_ASSUME_NONNULL_END
