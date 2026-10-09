#import "tb_storage_bridge.h"

#import <Foundation/Foundation.h>
#include <stdlib.h>
#include <string.h>

char *tb_storage_copy_removable_volumes_json(void) {
    @autoreleasepool {
        NSFileManager *fileManager = NSFileManager.defaultManager;
        NSArray<NSURLResourceKey> *keys = @[
            NSURLVolumeNameKey,
            NSURLVolumeUUIDStringKey,
            NSURLVolumeIsRemovableKey,
            NSURLVolumeIsEjectableKey
        ];
        NSArray<NSURL *> *mounted = [fileManager mountedVolumeURLsIncludingResourceValuesForKeys:keys
                                                                                           options:NSVolumeEnumerationSkipHiddenVolumes];
        NSMutableArray<NSDictionary<NSString *, NSString *> *> *volumes = [NSMutableArray array];
        NSMutableSet<NSString *> *seenIdentifiers = [NSMutableSet set];
        for (NSURL *url in mounted) {
            if ([url.path isEqualToString:@"/"]) continue;
            NSError *error = nil;
            NSDictionary<NSURLResourceKey, id> *values = [url resourceValuesForKeys:keys error:&error];
            if (!values || error) continue;

            BOOL removable = [values[NSURLVolumeIsRemovableKey] boolValue];
            BOOL ejectable = [values[NSURLVolumeIsEjectableKey] boolValue];
            if (!removable && !ejectable) continue;

            NSString *name = values[NSURLVolumeNameKey];
            NSString *uuid = values[NSURLVolumeUUIDStringKey];
            if (![name isKindOfClass:NSString.class] || name.length == 0 || name.length > 128 ||
                ![uuid isKindOfClass:NSString.class] || uuid.length == 0 || uuid.length > 128) continue;

            BOOL hasControl = NO;
            for (NSUInteger i = 0; i < name.length; i++) {
                if ([[NSCharacterSet controlCharacterSet] characterIsMember:[name characterAtIndex:i]]) {
                    hasControl = YES;
                    break;
                }
            }
            if (hasControl || [seenIdentifiers containsObject:uuid]) continue;
            [seenIdentifiers addObject:uuid];
            [volumes addObject:@{@"id": uuid, @"name": name}];
            if (volumes.count >= 32) break;
        }

        [volumes sortUsingComparator:^NSComparisonResult(NSDictionary<NSString *,NSString *> *left,
                                                          NSDictionary<NSString *,NSString *> *right) {
            return [left[@"name"] localizedStandardCompare:right[@"name"]];
        }];
        NSDictionary *snapshot = @{@"schemaVersion": @1, @"volumes": volumes};
        NSError *jsonError = nil;
        NSData *json = [NSJSONSerialization dataWithJSONObject:snapshot
                                                       options:NSJSONWritingSortedKeys
                                                         error:&jsonError];
        if (!json || jsonError) return NULL;
        char *copy = malloc(json.length + 1);
        if (!copy) return NULL;
        memcpy(copy, json.bytes, json.length);
        copy[json.length] = '\0';
        return copy;
    }
}
