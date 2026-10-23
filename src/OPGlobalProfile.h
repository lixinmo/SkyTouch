#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// A global selection is an immutable copy of the original local.fdg plus its
// six mapping preference values. Choosing a source game does not publish it.
// The current device type selects list[0]: 0 gamepad, 1 keyboard/mouse, 2 v1.
// A selected plan may contain keys, joysticks, macros, or a combination.
// Account archives, cloud credentials and unrelated preferences are never read.
BOOL OPPublishGlobalProfile(NSString *sourceBundleID, NSString *sourceDisplayName,
                            NSInteger deviceType,
                            NSString * _Nullable * _Nullable error);
// Safe, bounded reads of this project's original library. No vendor loading,
// account files, or source-library mutation. The caller owns editor exclusion.
NSData * _Nullable OPReadLocalProfileLibrary(NSString *sourceBundleID,
                                           NSString * _Nullable * _Nullable error);
// Publish an explicitly selected immutable FDG snapshot. Uses the same schema,
// source defaults, publish lock, readback checks and atomic commit as above.
// Does not overwrite source local.fdg or change service enable/disable state.
// After a successful commit, retains the active snapshot plus four most
// recent history snapshots. Readers share the publication/cleanup lock.
BOOL OPPublishGlobalProfileSnapshot(NSString *sourceBundleID,NSString *sourceDisplayName,
                                    NSInteger deviceType,NSData *snapshotData,
                                    NSString * _Nullable * _Nullable error);

// Returns a verified schema-3 manifest, or nil with a reason. Schema 2 cannot
// identify a specific mapping and requires the user to apply a scheme again.
// The two extra return-only fields are computed after verification:
// snapshotPath: fixed project root + validated revision UUID + mapping.fdg;
// snapshotData: exact bytes whose SHA-256 and selected mapping were verified.
// Consumers must use snapshotData; historical paths may be reclaimed after
// this read finishes and another selection is successfully committed.
// Neither field is accepted from or written to the persistent manifest/index.
NSDictionary * _Nullable OPReadGlobalProfile(NSString * _Nullable * _Nullable error);

// Maintenance after migration/startup: same bounded history policy, only after
// verifying the current snapshot. Never traverses source Profiles or links.
// Publication already invokes this cleanup automatically after committing.
BOOL OPPruneGlobalProfileHistory(NSString * _Nullable * _Nullable error);


NS_ASSUME_NONNULL_END
