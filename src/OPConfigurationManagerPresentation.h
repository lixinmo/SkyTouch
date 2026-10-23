#pragma once
#import <Foundation/Foundation.h>
#include <cmath>

NS_ASSUME_NONNULL_BEGIN
static inline NSURL * _Nullable OPConfigurationBackupFileURL(NSString *path) {
    if(![path isKindOfClass:NSString.class] || !path.isAbsolutePath ||
       [path rangeOfString:@"\0"].location!=NSNotFound)return nil;
    // https://www.tigisoftware.com/default/?page_id=177 documents
    // filza://view/path/to/file. Let Foundation encode filename characters.
    NSURLComponents *parts=[NSURLComponents new];parts.scheme=@"filza";parts.host=@"view";parts.path=path;
    return parts.URL;
}
static inline NSTimeInterval OPConfigurationBackupTimestamp(id value) {
    NSTimeInterval time=[value isKindOfClass:NSDate.class] ? [value timeIntervalSince1970] :
        ([value isKindOfClass:NSNumber.class] ? [value doubleValue] : 0);
    return std::isfinite(time) && time>0 ? time : 0;
}
static inline NSArray<NSDictionary *> *OPConfigurationSortedBackupRows(id raw) {
    if(![raw isKindOfClass:NSArray.class])return @[];
    NSMutableArray<NSDictionary *> *rows=[NSMutableArray array];
    for(id item in (NSArray *)raw) {
        if(![item isKindOfClass:NSDictionary.class])continue;
        NSString *filename=item[@"filename"];
        if(![filename isKindOfClass:NSString.class] || !filename.length || filename.length>255 ||
           [filename containsString:@"/"] || [filename isEqual:@"."] || [filename isEqual:@".."] ||
           [filename rangeOfString:@"\0"].location!=NSNotFound || ![item[@"size"] isKindOfClass:NSNumber.class])continue;
        double size=[item[@"size"] doubleValue];
        if(!std::isfinite(size) || size<0 || size>static_cast<double>(LLONG_MAX))continue;
        [rows addObject:[item copy]];
    }
    [rows sortUsingComparator:^NSComparisonResult(NSDictionary *left,NSDictionary *right) {
        NSTimeInterval a=OPConfigurationBackupTimestamp(left[@"createdAt"]),b=OPConfigurationBackupTimestamp(right[@"createdAt"]);
        if(a!=b)return a>b ? NSOrderedAscending : NSOrderedDescending;
        return [left[@"filename"] compare:right[@"filename"] options:NSLiteralSearch];
    }];
    return rows;
}
NS_ASSUME_NONNULL_END
