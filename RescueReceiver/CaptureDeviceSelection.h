#import <Foundation/Foundation.h>

/* Names vary across UVC firmware: USB Video, USB3 Video, USB 3.0 Video… */
static BOOL RVRescueCaptureName(NSString *name, BOOL audio) {
    NSString *lower = name.lowercaseString;
    if ([lower containsString:@"ms2130"] || [lower containsString:@"hdmi"] ||
        [lower containsString:@"capture"]) return YES;
    if ([lower containsString:@"usb"] && [lower containsString:audio ? @"audio" : @"video"]) return YES;
    return !audio && [lower containsString:@"uvc"];
}

/* Never silently switch to the iMac camera or choose between multiple cards.
 * A previously selected device wins while it is still present. */
static NSString *RVRescueSelectDevice(NSArray<NSDictionary *> *devices, NSString *filter,
                                     NSString *currentID, BOOL audio) {
    NSMutableArray<NSString *> *matches = [NSMutableArray new];
    NSMutableArray<NSString *> *external = [NSMutableArray new];
    for (NSDictionary *device in devices) {
        NSString *name = device[@"name"], *identifier = device[@"id"];
        if (filter.length) {
            if ([name rangeOfString:filter options:NSCaseInsensitiveSearch].location != NSNotFound)
                [matches addObject:identifier];
        } else if ([device[@"external"] boolValue]) {
            [external addObject:identifier];
            if (RVRescueCaptureName(name, audio)) [matches addObject:identifier];
        }
    }
    NSArray<NSString *> *candidates = matches.count || filter.length || audio ? matches : external;
    if (currentID && [candidates containsObject:currentID]) return currentID;
    return candidates.count == 1 ? candidates.firstObject : nil;
}
