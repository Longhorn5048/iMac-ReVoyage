/* Exercise the real controller without capture, windows, services or power
 * actions. Every IOKit assertion and pmset/spawn call below is a stub. */
#define CGDisplayHideCursor rv_test_hide_cursor
#define CGDisplayShowCursor rv_test_show_cursor
#define main rv_unused_rescue_main
#define IOPMAssertionCreateWithName rv_test_assertion_create
#define IOPMAssertionDeclareUserActivity rv_test_user_activity
#define IOPMAssertionRelease rv_test_assertion_release
#define posix_spawn rv_test_spawn
#define waitpid rv_test_waitpid
#include "../main.m"
#undef main
#include <assert.h>
#include <stdatomic.h>

static unsigned assertionCreates, assertionReleases, wakes;
CGError rv_test_hide_cursor(CGDirectDisplayID display) { (void)display; return kCGErrorSuccess; }
CGError rv_test_show_cursor(CGDirectDisplayID display) { (void)display; return kCGErrorSuccess; }
static atomic_int spawnResult, waitDelayMs;
IOReturn rv_test_assertion_create(CFStringRef type, IOPMAssertionLevel level,
    CFStringRef name, IOPMAssertionID *id) {
    (void)type; (void)level; (void)name;
    *id = ++assertionCreates;
    return kIOReturnSuccess;
}
IOReturn rv_test_user_activity(CFStringRef name, IOPMUserActiveType type, IOPMAssertionID *id) {
    (void)name; (void)type; *id = ++wakes;
    return kIOReturnSuccess;
}
IOReturn rv_test_assertion_release(IOPMAssertionID id) { (void)id; assertionReleases++; return kIOReturnSuccess; }
int rv_test_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *actions,
    const posix_spawnattr_t *attrs, char *const argv[], char *const envp[]) {
    (void)actions; (void)attrs; (void)envp;
    assert(strcmp(path, "/usr/bin/pmset") == 0 && strcmp(argv[1], "displaysleepnow") == 0);
    *pid = 123;
    return atomic_load(&spawnResult);
}
pid_t rv_test_waitpid(pid_t pid, int *status, int options) {
    (void)options;
    usleep((useconds_t)atomic_load(&waitDelayMs) * 1000);
    *status = 0;
    return pid;
}

@interface TestAudioPreview : NSObject
@property(nonatomic) float volume;
@end
@implementation TestAudioPreview
@end

@interface TestRescueController : RescueController
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *replies;
@property(nonatomic) BOOL presentedFullscreen;
@end
@implementation TestRescueController
- (void)presentHDMIFullscreen:(BOOL)fullscreen { self.presentedFullscreen = fullscreen; }
- (void)replyToPowerRequest:(NSString *)requestID displayOn:(BOOL)on accepted:(BOOL)accepted {
    [self.replies addObject:@{@"requestID":requestID, @"displayOn":@(on), @"accepted":@(accepted)}];
}
@end
static void request(TestRescueController *c, NSString *id, BOOL on, uint64_t issued) {
    NSNotification *n = [NSNotification notificationWithName:@RV_POWER_REQUEST_NOTIFICATION object:nil
        userInfo:@{@"requestID":id, @"displayOn":@(on), @"issuedMs":@(issued)}];
    [c displayPowerRequested:n];
}
static void finish(TestRescueController *c) {
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 2;
    while (c.displaySleepPending && CFAbsoluteTimeGetCurrent() < deadline)
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.01, true);
    assert(!c.displaySleepPending);
}
int main(void) { @autoreleasepool {
    TestRescueController *c = [TestRescueController new];
    c.replies = [NSMutableArray new];
    struct rv_display_signal_state state;
    rv_display_signal_init(&state); c.signalState = state;
    [c updateVideoPresentation:NO];
    assert(c.holdingDisplayAwake && assertionCreates == 1 && wakes == 1);
    request(c, @"future", NO, RVMonotonicMilliseconds() + 10000);
    request(c, @"expired", NO, RVMonotonicMilliseconds() - 6000);
    assert(c.replies.count == 0 && !c.signalState.manual_off);

    request(c, @"off", NO, RVMonotonicMilliseconds()); finish(c);
    assert(c.signalState.manual_off && c.displaySleeping && !c.holdingDisplayAwake);
    assert(assertionReleases == 1 && [c.replies.lastObject[@"accepted"] boolValue]);
    request(c, @"wake", YES, RVMonotonicMilliseconds());
    assert(!c.signalState.manual_off && !c.displaySleeping && c.holdingDisplayAwake);
    assert([c.replies.lastObject[@"accepted"] boolValue]);

    atomic_store(&spawnResult, EIO);
    request(c, @"failed", NO, RVMonotonicMilliseconds()); finish(c);
    assert(!c.signalState.manual_off && c.holdingDisplayAwake);
    assert(![c.replies.lastObject[@"accepted"] boolValue]);
    atomic_store(&spawnResult, 0);

    request(c, @"stale-off", NO, RVMonotonicMilliseconds());
    request(c, @"new-wake", YES, RVMonotonicMilliseconds()); finish(c);
    assert(!c.signalState.manual_off && c.holdingDisplayAwake && !c.displaySleeping);
    assert(![c.replies.lastObject[@"accepted"] boolValue]);

    request(c, @"restart-off", NO, RVMonotonicMilliseconds());
    [c receiverRestarted:nil]; finish(c);
    assert(!c.signalState.manual_off && c.signalState.rescue_locked && c.holdingDisplayAwake);
    assert(![c.replies.lastObject[@"accepted"] boolValue]);

    atomic_store(&waitDelayMs, 200);
    request(c, @"late-off", NO, RVMonotonicMilliseconds() - 4900); finish(c);
    assert(!c.signalState.manual_off && c.holdingDisplayAwake && !c.displaySleeping);
    assert(![c.replies.lastObject[@"accepted"] boolValue]);
    TestAudioPreview *audio = [TestAudioPreview new];
    c.audioPreview = (AVCaptureAudioPreviewOutput *)audio;
    state = c.signalState;
    rv_display_signal_note_hdmi_frame(&state, RVMonotonicMilliseconds());
    c.signalState = state;
    [c updateVideoPresentation:YES];
    assert(c.presentedFullscreen);
    c.fullscreenDismissed = YES;
    [c updateVideoPresentation:YES];
    assert(!c.presentedFullscreen && !c.cursorHidden);
    [c showHDMIFullscreen:nil];
    assert(c.presentedFullscreen);
    NSNotification *recovering = [NSNotification notificationWithName:RVNetworkRecoveringNotification object:nil
        userInfo:@{@"frameMs":@(RVMonotonicMilliseconds())}];
    [c networkSignalChanged:recovering];
    assert(c.signalState.rescue_locked && !c.networkVisible && audio.volume == 1.0f);
    NSNotification *active = [NSNotification notificationWithName:RVNetworkActiveNotification object:nil
        userInfo:@{@"frameMs":@(RVMonotonicMilliseconds())}];
    [c networkSignalChanged:active];
    assert(c.networkVisible && audio.volume == 0.0f && !c.presentedFullscreen);
    [c networkSignalChanged:[NSNotification notificationWithName:RVNetworkInactiveNotification object:nil]];
    assert(!c.networkVisible && c.signalState.rescue_locked && audio.volume == 1.0f && c.presentedFullscreen);
    unsigned before = wakes;
    request(c, @"wake-already-awake", YES, RVMonotonicMilliseconds());
    assert(wakes == before + 1); /* Explicit wake is not inferred from our cached intent. */
    state = c.signalState;
    state.rescue_locked = 0; state.network_active = 1;
    state.network_updated_ms = state.network_frame_ms = RVMonotonicMilliseconds();
    c.signalState = state;
    [c updateVideoPresentation:NO];
    assert(c.lastPowerMode == RV_POWER_NORMAL);
    before = wakes;
    [c networkSignalChanged:[NSNotification notificationWithName:RVNetworkInactiveNotification object:nil]];
    assert(c.lastPowerMode == RV_POWER_RESCUE_LOCK && wakes == before + 1);
    NSNotification *manual = [NSNotification notificationWithName:RVNetworkInactiveNotification object:nil
        userInfo:@{@"manualRescue":@YES, @"debugVisible":@YES, @"debugLine1":@"diagnostics"}];
    [c networkSignalChanged:manual];
    [c updateVideoPresentation:NO];
    assert(c.manualRescue && c.presentedFullscreen); /* R works even without HDMI frames. */
    [c networkSignalChanged:active];
    assert(!c.manualRescue && !c.presentedFullscreen);
    [c networkSignalChanged:manual];
    [c receiverRestarted:nil];
    assert(!c.manualRescue);
    puts("Rescue controller: off/wake, failure, expiry, stale completion and restart safety passed (all power calls stubbed)");
} return 0; }
