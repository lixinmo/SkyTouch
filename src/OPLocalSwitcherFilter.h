#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// Live connection metadata controls the switcher, not the offline editor's
// remembered default. A missing/dead/stale/disconnected broker exposes all
// local plans. A live connection with an unresolved type exposes no plans yet.
// Result: {mode: "all"|"type"|"identifying", deviceType: -1|0|1|2,
//          deviceID: canonical UUID or ""}. No I/O or mutable global state.
NSDictionary *OPLocalSwitcherFilterState(NSDictionary * _Nullable broker,
    NSDictionary * _Nullable remembered, NSTimeInterval now, BOOL brokerAlive);
// Returns the original row objects in their original order; names, identifiers
// and current-selection markers are never rewritten by presentation filtering.
NSArray<NSDictionary *> *OPFilterLocalSwitcherRows(NSArray *rows, NSDictionary *state);
BOOL OPLocalSwitcherRowAllowed(NSDictionary *row, NSDictionary *state);
NS_ASSUME_NONNULL_END
