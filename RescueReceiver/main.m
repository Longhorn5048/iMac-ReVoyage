#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/CoreAudio.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import "DisplaySignalState.h"
#import "CaptureDeviceSelection.h"
#import "../TargetBridge-Shared/DisplayPower.h"
#import "../TargetBridge-Shared/ReceiverDebug.h"

#include <errno.h>
#include <spawn.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

static NSString * const RVNetworkActiveNotification = @"re.voyage.display.network-active";
static NSString * const RVNetworkRecoveringNotification = @"re.voyage.display.network-recovering";
static NSString * const RVNetworkInactiveNotification = @"re.voyage.display.network-inactive";

static uint64_t RVMonotonicMilliseconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000ULL + (uint64_t)ts.tv_nsec / 1000000ULL;
}

@interface RescueWindow : NSWindow
@property(nonatomic, copy) void (^onEscape)(void);
@property(nonatomic, copy) void (^onShortcut)(unsigned int);
@property(nonatomic) unsigned int shortcutHeld;
@end
@implementation RescueWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (void)keyDown:(NSEvent *)event {
    unsigned int action = 0, held = self.shortcutHeld;
    if (rv_receiver_shortcut(&held, event.keyCode, 1, event.isARepeat,
        (event.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagOption | NSEventModifierFlagControl)) != 0, &action)) {
        self.shortcutHeld = held;
        if (action && self.onShortcut) self.onShortcut(action);
        return;
    }
    if (event.keyCode == 53 && self.onEscape) self.onEscape();
    else [super keyDown:event];
}
- (void)keyUp:(NSEvent *)event {
    unsigned int action = 0, held = self.shortcutHeld;
    if (rv_receiver_shortcut(&held, event.keyCode, 0, 0, 0, &action)) {
        self.shortcutHeld = held;
        return;
    }
    [super keyUp:event];
}
@end

/* Separate process and AVFoundation pipeline: no TargetBridge socket, codec,
 * FFmpeg, SDL or network configuration is needed for HDMI rescue. */
@interface RescueController : NSObject <NSApplicationDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, NSWindowDelegate>
@property(nonatomic, strong) RescueWindow *window;
@property(nonatomic, strong) NSStatusItem *menuItem;
@property(nonatomic) BOOL hdmiFullscreen;
@property(nonatomic) BOOL fullscreenDismissed;
@property(nonatomic) NSApplicationPresentationOptions savedPresentationOptions;
@property(nonatomic, strong) NSTextField *status;
@property(nonatomic, strong) AVCaptureSession *session;
@property(nonatomic, strong) AVCaptureVideoPreviewLayer *preview;
@property(nonatomic, strong) AVCaptureAudioPreviewOutput *audioPreview;
@property(nonatomic, copy) NSString *audioID;
@property(nonatomic) BOOL cursorHidden;
@property(nonatomic, copy) NSString *videoID;
@property(nonatomic, copy) NSString *videoFilter;
@property(nonatomic, copy) NSString *audioFilter;
@property(nonatomic) CFAbsoluteTime lastFrame;
@property(nonatomic) CFAbsoluteTime lastCaptureStart;
@property(nonatomic) BOOL showingVideo;
@property(nonatomic) BOOL captureInterrupted;
@property(nonatomic) IOPMAssertionID systemAssertion;
@property(nonatomic) IOPMAssertionID displayAssertion;
@property(nonatomic) struct rv_display_signal_state signalState;
@property(nonatomic) BOOL holdingDisplayAwake;
@property(nonatomic) BOOL networkVisible;
@property(nonatomic) enum rv_display_power_mode lastPowerMode;
@property(nonatomic, copy) NSString *powerRequestID;
@property(nonatomic) BOOL displaySleeping;
@property(nonatomic) BOOL displaySleepPending;
@property(nonatomic) BOOL manualRescue;
@property(nonatomic, strong) NSView *debugBar;
@property(nonatomic, strong) NSArray<NSTextField *> *debugLines;

@end

@implementation RescueController

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
    for (NSString *arg in args) {
        if ([arg hasPrefix:@"--video-name="]) self.videoFilter = [arg substringFromIndex:13];
        if ([arg hasPrefix:@"--audio-name="]) self.audioFilter = [arg substringFromIndex:13];
    }

    NSScreen *screen = NSScreen.mainScreen;
    self.window = [[RescueWindow alloc] initWithContentRect:screen.frame
                                              styleMask:NSWindowStyleMaskBorderless
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    self.window.delegate = self;
    __weak RescueController *weakSelf = self;
    self.window.onEscape = ^{
        RescueController *controller = weakSelf;
        controller.fullscreenDismissed = YES;
        [controller updateVideoPresentation:controller.showingVideo];
    };
    self.window.onShortcut = ^(unsigned int action) {
        NSString *name = action == RV_RECEIVER_SHORTCUT_DEBUG ? @RV_RECEIVER_DEBUG_TOGGLE_NOTIFICATION : @RV_RECEIVER_RESCUE_TOGGLE_NOTIFICATION;
        [[NSDistributedNotificationCenter defaultCenter] postNotificationName:name object:nil userInfo:nil deliverImmediately:YES];
    };
    self.menuItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.menuItem.button.title = @"HDMI";
    NSMenu *menu = [NSMenu new];
    NSMenuItem *fullscreen = [menu addItemWithTitle:@"显示 HDMI 全屏（Esc 返回桌面）" action:@selector(showHDMIFullscreen:) keyEquivalent:@""];
    fullscreen.target = self;
    self.menuItem.menu = menu;
    self.window.backgroundColor = NSColor.blackColor;
    self.window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                     NSWindowCollectionBehaviorFullScreenAuxiliary;
    self.window.level = NSNormalWindowLevel - 1;
    self.window.opaque = YES;
    self.window.contentView.wantsLayer = YES;
    self.window.contentView.layer.backgroundColor = NSColor.blackColor.CGColor;

    NSNotificationCenter *notifications = NSNotificationCenter.defaultCenter;
    [notifications addObserver:self selector:@selector(captureDeviceDisconnected:)
                          name:AVCaptureDeviceWasDisconnectedNotification object:nil];
    [notifications addObserver:self selector:@selector(captureSessionRuntimeError:)
                          name:AVCaptureSessionRuntimeErrorNotification object:nil];
    [notifications addObserver:self selector:@selector(captureSessionWasInterrupted:)
                          name:AVCaptureSessionWasInterruptedNotification object:nil];
    [notifications addObserver:self selector:@selector(captureSessionInterruptionEnded:)
                          name:AVCaptureSessionInterruptionEndedNotification object:nil];
    [[NSDistributedNotificationCenter defaultCenter] addObserver:self
        selector:@selector(networkSignalChanged:)
        name:RVNetworkActiveNotification object:nil
        suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    [[NSDistributedNotificationCenter defaultCenter] addObserver:self
        selector:@selector(networkSignalChanged:)
        name:RVNetworkInactiveNotification object:nil
        suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    [[NSDistributedNotificationCenter defaultCenter] addObserver:self
        selector:@selector(displayPowerRequested:) name:@RV_POWER_REQUEST_NOTIFICATION object:nil
        suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    [[NSDistributedNotificationCenter defaultCenter] addObserver:self
        selector:@selector(receiverRestarted:) name:@RV_RECEIVER_RESTART_NOTIFICATION object:nil
        suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    [[NSDistributedNotificationCenter defaultCenter] addObserver:self
        selector:@selector(networkSignalChanged:) name:RVNetworkRecoveringNotification object:nil
        suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    rv_display_signal_init(&_signalState);

    self.status = [NSTextField labelWithString:@"等待 HDMI/UVC 输入…"];
    self.status.textColor = NSColor.whiteColor;
    self.status.backgroundColor = NSColor.clearColor;
    self.status.font = [NSFont systemFontOfSize:24 weight:NSFontWeightMedium];
    self.status.alignment = NSTextAlignmentCenter;
    self.status.frame = NSMakeRect(0, NSMidY(screen.frame) - 24, NSWidth(screen.frame), 48);
    [self.window.contentView addSubview:self.status];
    self.debugBar = [[NSView alloc] initWithFrame:NSZeroRect];
    self.debugBar.wantsLayer = YES;
    self.debugBar.layer.backgroundColor = [NSColor colorWithWhite:0.03 alpha:0.90].CGColor;
    self.debugBar.hidden = YES;
    NSMutableArray *lines = [NSMutableArray new];
    for (int i = 0; i < 2; ++i) {
        NSTextField *line = [NSTextField labelWithString:@""];
        line.textColor = NSColor.whiteColor;
        line.font = [NSFont monospacedSystemFontOfSize:14 weight:NSFontWeightRegular];
        line.lineBreakMode = NSLineBreakByClipping;
        [self.debugBar addSubview:line]; [lines addObject:line];
    }
    self.debugLines = lines;
    [self.window.contentView addSubview:self.debugBar];
    [self layoutDebugBar];
    [self.window makeKeyAndOrderFront:nil];

    /* Keep the iMac responsive to USB/network while its display may sleep. */
    IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep,
                                kIOPMAssertionLevelOn, CFSTR("iMac ReVoyage input monitor"),
                                &_systemAssertion);
    [NSTimer scheduledTimerWithTimeInterval:1.0 target:self
                                   selector:@selector(tick:) userInfo:nil repeats:YES];
    [self updateVideoPresentation:NO];
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:@RV_RESCUE_READY_NOTIFICATION
        object:nil userInfo:nil deliverImmediately:YES];
    [self requestCapturePermissions];
}

- (void)requestCapturePermissions {
    AVAuthorizationStatus camera = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    if (camera == AVAuthorizationStatusNotDetermined) {
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
            (void)granted;
            dispatch_async(dispatch_get_main_queue(), ^{ [self requestCapturePermissions]; });
        }];
        return;
    }
    if (camera != AVAuthorizationStatusAuthorized) {
        self.status.stringValue = @"请在系统设置中允许摄像头访问";
        return;
    }
    AVAuthorizationStatus microphone = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    if (microphone == AVAuthorizationStatusNotDetermined) {
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
            (void)granted;
            dispatch_async(dispatch_get_main_queue(), ^{ [self requestCapturePermissions]; });
        }];
        return;
    }
    [self findAndStartCapture];
}

- (AVCaptureDevice *)findDevice:(NSString *)mediaType filter:(NSString *)filter {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSArray<AVCaptureDevice *> *devices = [AVCaptureDevice devicesWithMediaType:mediaType];
#pragma clang diagnostic pop
    NSMutableArray *records = [NSMutableArray new];
    for (AVCaptureDevice *device in devices) {
        BOOL external;
        if ([mediaType isEqualToString:AVMediaTypeVideo]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            external = [device.deviceType isEqualToString:AVCaptureDeviceTypeExternalUnknown];
#pragma clang diagnostic pop
        } else {
            external = device.transportType != kAudioDeviceTransportTypeBuiltIn;
        }
        [records addObject:@{@"name": device.localizedName, @"id": device.uniqueID, @"external": @(external)}];
    }
    NSString *identifier = RVRescueSelectDevice(records, filter,
        [mediaType isEqualToString:AVMediaTypeVideo] ? self.videoID : self.audioID,
        [mediaType isEqualToString:AVMediaTypeAudio]);
    for (AVCaptureDevice *device in devices) {
        if ([device.uniqueID isEqualToString:identifier]) return device;
    }
    return nil;
}

- (void)findAndStartCapture {
    if (self.captureInterrupted) return;
    AVCaptureDevice *video = [self findDevice:AVMediaTypeVideo filter:self.videoFilter];
    if (!video) {
        if (self.session) [self stopCaptureSession];
        self.status.stringValue = @"等待可识别的 HDMI/UVC 采集卡…";
        return;
    }
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    AVCaptureDevice *audio = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] == AVAuthorizationStatusAuthorized
        ? [self findDevice:AVMediaTypeAudio filter:self.audioFilter] : nil;
    BOOL sameAudio = (!audio && !self.audioID) || [audio.uniqueID isEqualToString:self.audioID];
    if (self.session && [self.videoID isEqualToString:video.uniqueID] &&
        sameAudio && self.session.isRunning && (now - self.lastFrame < 2.0 || now - self.lastCaptureStart < 5.0)) return;
    [self stopCaptureSession];
    self.videoID = video.uniqueID;

    NSError *error = nil;
    AVCaptureDeviceInput *videoInput = [AVCaptureDeviceInput deviceInputWithDevice:video error:&error];
    if (!videoInput) {
        self.status.stringValue = [NSString stringWithFormat:@"视频设备无法打开：%@", error.localizedDescription];
        return;
    }
    AVCaptureSession *session = [AVCaptureSession new];
    if ([session canAddInput:videoInput]) [session addInput:videoInput];
    AVCaptureVideoDataOutput *frames = [AVCaptureVideoDataOutput new];
    frames.alwaysDiscardsLateVideoFrames = YES;
    [frames setSampleBufferDelegate:self queue:dispatch_queue_create("re.voyage.rescue.frames", DISPATCH_QUEUE_SERIAL)];
    if ([session canAddOutput:frames]) [session addOutput:frames];

    if ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] == AVAuthorizationStatusAuthorized) {
        if (audio) {
            AVCaptureDeviceInput *audioInput = [AVCaptureDeviceInput deviceInputWithDevice:audio error:&error];
            if (audioInput && [session canAddInput:audioInput]) {
                [session addInput:audioInput];
                AVCaptureAudioPreviewOutput *audioPreview = [AVCaptureAudioPreviewOutput new];
                audioPreview.volume = 0.0f;
                if ([session canAddOutput:audioPreview]) {
                    [session addOutput:audioPreview]; self.audioPreview = audioPreview;
                }
                NSLog(@"Rescue audio input: %@", audio.localizedName);
            }
        }
    }
    self.audioID = audio.uniqueID;

    self.preview = [AVCaptureVideoPreviewLayer layerWithSession:session];
    self.preview.videoGravity = AVLayerVideoGravityResizeAspect;
    self.preview.frame = self.window.contentView.bounds;
    [self.window.contentView.layer insertSublayer:self.preview atIndex:0];
    self.session = session;
    self.lastFrame = 0;
    self.lastCaptureStart = now;
    self.showingVideo = NO;
    self.status.stringValue = @"等待 HDMI 画面…";
    [session startRunning];
    NSLog(@"Rescue video input: %@", video.localizedName);
}

- (void)stopCaptureSession {
    self.audioPreview.volume = 0.0f;
    [self.session stopRunning];
    self.audioPreview = nil; self.audioID = nil;
    self.session = nil;
    [self.preview removeFromSuperlayer];
    self.preview = nil;
    self.videoID = nil;
    self.lastFrame = 0;
    self.lastCaptureStart = 0;
    self.captureInterrupted = NO;
    [self updateVideoPresentation:NO];
}

- (void)captureDeviceDisconnected:(NSNotification *)notification {
    AVCaptureDevice *device = notification.object;
    if (![device isKindOfClass:AVCaptureDevice.class]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![device.uniqueID isEqualToString:self.videoID] && ![device.uniqueID isEqualToString:self.audioID]) return;
        NSLog(@"Rescue video device disconnected: %@", device.localizedName);
        [self stopCaptureSession];
        self.status.stringValue = @"等待可识别的 HDMI/UVC 采集卡…";
    });
}

- (void)captureSessionRuntimeError:(NSNotification *)notification {
    AVCaptureSession *session = notification.object;
    if (![session isKindOfClass:AVCaptureSession.class]) return;
    NSError *error = notification.userInfo[AVCaptureSessionErrorKey];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (session != self.session) return;
        NSLog(@"Rescue capture session failed: %@", error.localizedDescription ?: @"unknown error");
        [self stopCaptureSession];
        self.status.stringValue = @"HDMI 采集暂不可用，正在重试…";
    });
}

- (void)captureSessionWasInterrupted:(NSNotification *)notification {
    AVCaptureSession *session = notification.object;
    if (![session isKindOfClass:AVCaptureSession.class]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (session != self.session) return;
        NSLog(@"Rescue capture session interrupted");
        self.captureInterrupted = YES;
        self.lastFrame = 0;
        [self updateVideoPresentation:NO];
        self.status.stringValue = @"HDMI 采集暂时中断，等待恢复…";
    });
}

- (void)captureSessionInterruptionEnded:(NSNotification *)notification {
    AVCaptureSession *session = notification.object;
    if (![session isKindOfClass:AVCaptureSession.class]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (session != self.session) return;
        NSLog(@"Rescue capture session interruption ended");
        self.captureInterrupted = NO;
        self.lastFrame = 0;
        self.lastCaptureStart = 0;
        self.status.stringValue = @"重新连接 HDMI 画面…";
        [self findAndStartCapture];
    });
}

- (void)captureOutput:(AVCaptureOutput *)output
 didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
        fromConnection:(AVCaptureConnection *)connection {
    (void)sampleBuffer; (void)connection;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![self.session.outputs containsObject:output]) return;
        self.lastFrame = CFAbsoluteTimeGetCurrent();
        rv_display_signal_note_hdmi_frame(&self->_signalState, RVMonotonicMilliseconds());
    });
}

- (void)networkSignalChanged:(NSNotification *)notification {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self networkSignalChanged:notification]; });
        return;
    }
    self.networkVisible = [notification.name isEqualToString:RVNetworkActiveNotification];
    BOOL wasManualRescue = self.manualRescue;
    self.manualRescue = [notification.userInfo[@"manualRescue"] boolValue];
    self.debugBar.hidden = ![notification.userInfo[@"debugVisible"] boolValue];
    for (int i = 0; i < 2; ++i) {
        id text = notification.userInfo[i == 0 ? @"debugLine1" : @"debugLine2"];
        if (self.debugLines.count > (NSUInteger)i)
            self.debugLines[i].stringValue = [text isKindOfClass:NSString.class] ? text : @"";
    }
    if (self.manualRescue && !wasManualRescue) self.fullscreenDismissed = NO;
    [self layoutDebugBar];
    BOOL active = self.networkVisible || [notification.name isEqualToString:RVNetworkRecoveringNotification];
    id timestamp = notification.userInfo[@"frameMs"];
    uint64_t frameMs = [timestamp isKindOfClass:NSNumber.class] ? [timestamp unsignedLongLongValue] : 0;
    rv_display_signal_set_network(&_signalState, active, frameMs, RVMonotonicMilliseconds());
    [self updateVideoPresentation:self.showingVideo];
}

- (void)receiverRestarted:(NSNotification *)notification {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self receiverRestarted:notification]; });
        return;
    }
    self.powerRequestID = nil;
    self.networkVisible = NO;
    self.manualRescue = NO;
    self.debugBar.hidden = YES;
    rv_display_signal_init(&_signalState);
    [self updateVideoPresentation:self.showingVideo];
}

- (void)replyToPowerRequest:(NSString *)requestID displayOn:(BOOL)on accepted:(BOOL)accepted {
    if (!requestID) return;
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:@RV_POWER_RESULT_NOTIFICATION
        object:nil userInfo:@{@"requestID":requestID, @"displayOn":@(on), @"accepted":@(accepted)}
        deliverImmediately:YES];
}

- (void)displayPowerRequested:(NSNotification *)notification {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self displayPowerRequested:notification]; });
        return;
    }
    NSDictionary *info = notification.userInfo;
    NSString *requestID = info[@"requestID"];
    NSNumber *on = info[@"displayOn"], *issued = info[@"issuedMs"];
    uint64_t now = RVMonotonicMilliseconds();
    if (![requestID isKindOfClass:NSString.class] || requestID.length == 0 || requestID.length > 128 ||
        ![on isKindOfClass:NSNumber.class] || (on.intValue != 0 && on.intValue != 1) ||
        ![issued isKindOfClass:NSNumber.class] || now < issued.unsignedLongLongValue ||
        now - issued.unsignedLongLongValue >= RV_POWER_REQUEST_TIMEOUT_MS) return;
    self.powerRequestID = requestID;
    rv_display_power_set_manual_off(&_signalState, !on.boolValue);
    if (on.boolValue) self.holdingDisplayAwake = NO; /* Explicit wake must always declare activity. */
    [self updateVideoPresentation:self.showingVideo];
    if (on.boolValue) {
        [self replyToPowerRequest:requestID displayOn:YES accepted:self.holdingDisplayAwake];
    } else if (!self.displaySleepPending) {
        [self requestDisplaySleepAt:now requestID:requestID issuedMs:issued.unsignedLongLongValue];
    } else {
        /* A stale in-flight off operation must finish before accepting another. */
        rv_display_power_set_manual_off(&_signalState, 0);
        [self updateVideoPresentation:self.showingVideo];
        [self replyToPowerRequest:requestID displayOn:NO accepted:NO];
    }
}

- (void)tick:(NSTimer *)timer {
    (void)timer;
    if ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo] == AVAuthorizationStatusAuthorized) {
        [self findAndStartCapture];
    }
    BOOL active = self.lastFrame > 0 && CFAbsoluteTimeGetCurrent() - self.lastFrame < 2.0;
    [self updateVideoPresentation:active];
}

- (void)showHDMIFullscreen:(id)sender {
    (void)sender;
    self.fullscreenDismissed = NO;
    [self updateVideoPresentation:self.showingVideo];
}

- (void)presentHDMIFullscreen:(BOOL)fullscreen {
    if (!self.window || fullscreen == self.hdmiFullscreen) return;
    self.hdmiFullscreen = fullscreen;
    if (fullscreen) {
        self.savedPresentationOptions = NSApp.presentationOptions;
        [self.window setFrame:(self.window.screen ?: NSScreen.mainScreen).frame display:YES];
        self.window.level = NSStatusWindowLevel + 1;
        [NSApp activateIgnoringOtherApps:YES];
        NSApp.presentationOptions = NSApplicationPresentationHideDock | NSApplicationPresentationHideMenuBar;
        [self.window makeKeyAndOrderFront:nil];
    } else {
        NSApp.presentationOptions = self.savedPresentationOptions;
        self.window.level = NSNormalWindowLevel - 1;
        [self.window orderBack:nil];
    }
}

- (void)updateVideoPresentation:(BOOL)active {
    const uint64_t now = RVMonotonicMilliseconds();
    enum rv_display_power_mode power = rv_display_power_update(&_signalState, now);
    BOOL enteredRescue = power == RV_POWER_RESCUE_LOCK && self.lastPowerMode != RV_POWER_RESCUE_LOCK;
    self.lastPowerMode = power;
    unsigned int sources = rv_display_signal_active_sources(&_signalState, now);
    if (!self.networkVisible) sources &= ~RV_DISPLAY_SIGNAL_NETWORK;
    const BOOL hdmiVisible = active && (sources & RV_DISPLAY_SIGNAL_HDMI_FRAMES) &&
        !(sources & RV_DISPLAY_SIGNAL_NETWORK) && power != RV_POWER_MANUAL_OFF;
    if (!active && !self.manualRescue) self.fullscreenDismissed = NO;
    [self presentHDMIFullscreen:(hdmiVisible || (self.manualRescue && power != RV_POWER_MANUAL_OFF)) && !self.fullscreenDismissed];
    const BOOL anyInput = !self.fullscreenDismissed && sources != RV_DISPLAY_SIGNAL_NONE;
    self.audioPreview.volume = rv_display_signal_hdmi_audio_allowed(sources) ? 1.0f : 0.0f;
    int cursorAction = rv_display_cursor_action(self.cursorHidden, anyInput);
    if (cursorAction > 0 && CGDisplayHideCursor(CGMainDisplayID()) == kCGErrorSuccess) self.cursorHidden = YES;
    if (cursorAction < 0 && CGDisplayShowCursor(CGMainDisplayID()) == kCGErrorSuccess) self.cursorHidden = NO;
    self.showingVideo = active;
    self.status.hidden = active || (sources & RV_DISPLAY_SIGNAL_NETWORK) != 0;
    if (self.manualRescue && !active) self.status.stringValue = @"手动 Rescue：等待 HDMI/UVC 输入…（R 返回串流）";
    if (active) self.status.stringValue = @"救援锁定：保持亮屏，等待 HDMI / 网络画面…";

    if (power == RV_POWER_MANUAL_OFF) {
        self.holdingDisplayAwake = NO;
        if (self.displayAssertion != kIOPMNullAssertionID) {
            IOPMAssertionRelease(self.displayAssertion);
            self.displayAssertion = kIOPMNullAssertionID;
        }
        return; /* Frames/HDMI reconnects cannot override explicit off. */
    }
    const BOOL needsWake = enteredRescue || !self.holdingDisplayAwake || self.displaySleeping;
    if (self.displayAssertion == kIOPMNullAssertionID) {
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep,
                                    kIOPMAssertionLevelOn, CFSTR("ReVoyage display / Rescue Lock"),
                                    &_displayAssertion);
    }
    if (needsWake) {
        IOPMAssertionID activity = kIOPMNullAssertionID;
        IOPMAssertionDeclareUserActivity(CFSTR("ReVoyage display awake / Rescue Lock"),
                                         kIOPMUserActiveLocal, &activity);
        self.displaySleeping = NO;
    }
    self.holdingDisplayAwake = self.displayAssertion != kIOPMNullAssertionID;
    /* No timeout, old LKG preference or HDMI content heuristic can sleep here. */
}

- (void)requestDisplaySleepAt:(uint64_t)now requestID:(NSString *)requestID issuedMs:(uint64_t)issuedMs {
    (void)now;
    self.displaySleepPending = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        pid_t pid = 0;
        char *argv[] = { "/usr/bin/pmset", "displaysleepnow", NULL };
        int result = posix_spawn(&pid, argv[0], NULL, NULL, argv, environ);
        int status = 0;
        if (result == 0) {
            pid_t waited;
            do { waited = waitpid(pid, &status, 0); } while (waited < 0 && errno == EINTR);
            result = waited == pid && WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : EIO;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.displaySleepPending = NO;
            self.displaySleeping = result == 0;
            uint64_t finished = RVMonotonicMilliseconds();
            BOOL current = [self.powerRequestID isEqualToString:requestID];
            BOOL accepted = result == 0 && current && self->_signalState.manual_off &&
                finished >= issuedMs && finished - issuedMs < RV_POWER_REQUEST_TIMEOUT_MS;
            if (current && !accepted) rv_display_power_set_manual_off(&self->_signalState, 0);
            /* Wake after a late/stale pmset completion if intent is now Awake. */
            [self updateVideoPresentation:self.showingVideo];
            [self replyToPowerRequest:requestID displayOn:NO accepted:accepted];
            NSLog(@"Manual display-off request %@: %@ (%d)", requestID, accepted ? @"accepted" : @"failed/expired", result);
        });
    });
}

- (void)layoutDebugBar {
    if (!self.window || self.debugLines.count != 2) return;
    NSRect bounds = self.window.contentView.bounds;
    CGFloat height = NSWidth(bounds) >= 1600 ? 70 : 56;
    self.debugBar.frame = NSMakeRect(0, NSHeight(bounds) - height, NSWidth(bounds), height);
    for (int i = 0; i < 2; ++i) {
        NSTextField *line = self.debugLines[i];
        CGFloat fontSize = NSWidth(bounds) >= 1600 ? 17 : 14;
        NSFont *font = [NSFont monospacedSystemFontOfSize:fontSize weight:NSFontWeightRegular];
        CGFloat width = [line.stringValue sizeWithAttributes:@{NSFontAttributeName:font}].width;
        if (width > NSWidth(bounds) - 24) fontSize *= (NSWidth(bounds) - 24) / width;
        line.font = [NSFont monospacedSystemFontOfSize:fontSize weight:NSFontWeightRegular];
        line.frame = NSMakeRect(12, height * (i == 0 ? 0.52 : 0.12), NSWidth(bounds) - 24, height * 0.4);
    }
}

- (void)windowDidResize:(NSNotification *)notification {
    (void)notification;
    self.preview.frame = self.window.contentView.bounds;
    [self layoutDebugBar];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [[NSDistributedNotificationCenter defaultCenter] removeObserver:self];
    [self presentHDMIFullscreen:NO];
    [self.session stopRunning];
    self.audioPreview.volume = 0.0f;
    if (self.cursorHidden) { CGDisplayShowCursor(CGMainDisplayID()); self.cursorHidden = NO; }
    if (self.displayAssertion != kIOPMNullAssertionID) IOPMAssertionRelease(self.displayAssertion);
    if (self.systemAssertion != kIOPMNullAssertionID) IOPMAssertionRelease(self.systemAssertion);
}
@end

int main(int argc, const char *argv[]) {
    (void)argc; (void)argv;
    @autoreleasepool {
        for (NSString *arg in NSProcessInfo.processInfo.arguments) {
            if ([arg isEqualToString:@"--list-devices"]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                for (AVCaptureDevice *device in [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo])
                    printf("video: %s\n", device.localizedName.UTF8String);
                for (AVCaptureDevice *device in [AVCaptureDevice devicesWithMediaType:AVMediaTypeAudio])
                    printf("audio: %s\n", device.localizedName.UTF8String);
#pragma clang diagnostic pop
                return 0;
            }
        }
        NSApplication *app = NSApplication.sharedApplication;
        app.activationPolicy = NSApplicationActivationPolicyAccessory;
        RescueController *controller = [RescueController new];
        app.delegate = controller;
        [app run];
    }
    return 0;
}
