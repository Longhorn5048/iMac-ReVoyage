#import "../CaptureDeviceSelection.h"
#include <assert.h>
static NSDictionary *device(NSString *name, NSString *identifier, BOOL external) {
    return @{@"name":name, @"id":identifier, @"external":@(external)};
}
int main(void) { @autoreleasepool {
    NSDictionary *camera = device(@"FaceTime HD Camera", @"internal", NO);
    for (NSString *name in @[@"USB3 Video", @"USB Video", @"USB 3.0 Video", @"MS2130S", @"HDMI Capture"]) {
        NSArray *devices = @[camera, device(name, @"card", YES)];
        assert([RVRescueSelectDevice(devices, nil, nil, NO) isEqual:@"card"]);
    }
    assert(RVRescueSelectDevice(@[camera], nil, nil, NO) == nil);
    NSArray *two = @[camera, device(@"USB3 Video", @"one", YES), device(@"USB Video", @"two", YES)];
    assert(RVRescueSelectDevice(two, nil, nil, NO) == nil);
    assert([RVRescueSelectDevice(two, nil, @"two", NO) isEqual:@"two"]);
    assert([RVRescueSelectDevice(two, @"USB3", nil, NO) isEqual:@"one"]);
    assert(RVRescueSelectDevice(two, @"missing", nil, NO) == nil);
    NSArray *audio = @[device(@"Built-in Microphone", @"mic", NO), device(@"USB3 Audio", @"hdmi-audio", YES)];
    assert([RVRescueSelectDevice(audio, nil, nil, YES) isEqual:@"hdmi-audio"]);
    assert(RVRescueSelectDevice(@[device(@"USB Podcast Microphone", @"mic", YES)], nil, nil, YES) == nil);
    puts("Capture device selection passed");
} return 0; }
