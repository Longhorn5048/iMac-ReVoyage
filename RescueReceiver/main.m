#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/CoreAudio.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import "DisplaySignalState.h"
#import "ShellPresentation.h"
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

/* Shell text follows the Receiver's language; only zh has a translation here. */
static NSString *RVShellText(NSString *key, BOOL chinese) {
    static NSDictionary<NSString *, NSArray<NSString *> *> *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @{
            @"title_no_signal": @[@"No Signal", @"无信号"],
            @"waiting_input": @[@"Waiting for HDMI/UVC input…", @"等待 HDMI/UVC 输入…"],
            @"waiting_any": @[@"Waiting for HDMI or network video…", @"等待 HDMI / 网络画面…"],
            @"camera_denied": @[@"HDMI Rescue needs camera access", @"HDMI Rescue 需要摄像头权限"],
            @"waiting_card": @[@"Waiting for an HDMI/UVC capture device…", @"等待可识别的 HDMI/UVC 采集卡…"],
            @"open_failed": @[@"Cannot open the video device: %@", @"视频设备无法打开：%@"],
            @"waiting_hdmi": @[@"Waiting for HDMI video…", @"等待 HDMI 画面…"],
            @"capture_retry": @[@"HDMI capture unavailable, retrying…", @"HDMI 采集暂不可用，正在重试…"],
            @"capture_interrupted": @[@"HDMI capture interrupted, waiting…", @"HDMI 采集暂时中断，等待恢复…"],
            @"capture_reconnect": @[@"Reconnecting HDMI video…", @"重新连接 HDMI 画面…"],
            @"manual_rescue": @[@"Manual Rescue: waiting for HDMI/UVC input… (R returns to the stream)",
                                @"手动 Rescue：等待 HDMI/UVC 输入…（R 返回串流）"],
            @"address": @[@"Connect from Sender: %@", @"在 Sender 中连接：%@"],
            @"hint": @[@"R: HDMI Rescue  ·  P: permissions  ·  Esc twice: iMac desktop",
                       @"R 切换 HDMI Rescue  ·  P 权限设置  ·  连按两次 Esc 返回 iMac 桌面"],
            @"exit_confirm": @[@"Press Esc again for the iMac desktop", @"再按一次 Esc 返回 iMac 桌面"],
            @"toast_rescue": @[@"HDMI Rescue", @"HDMI Rescue"],
            @"toast_network": @[@"Network stream", @"网络串流"],
            @"permissions_missing": @[@"Missing permissions: %@  (press P)", @"缺少权限：%@（按 P 处理）"],
            @"camera": @[@"Camera", @"摄像头"],
            @"microphone": @[@"Microphone", @"麦克风"],
            @"input": @[@"Input Monitoring", @"输入监控"],
            @"accessibility": @[@"Accessibility", @"辅助功能"],
            @"menu_return": @[@"Return to ReVoyage full screen", @"返回 ReVoyage 全屏"],
            @"menu_standby": @[@"Turn the display off after 60 s without signal", @"无信号 60 秒后熄屏"],
            @"menu_permissions": @[@"Open permission settings…", @"打开权限设置…"],
        };
    });
    NSArray<NSString *> *pair = table[key];
    return pair ? pair[chinese ? 1 : 0] : key;
}

static NSString * const RVNoSignalStandbyKey = @"NoSignalDisplayOffSeconds";

@interface RescueWindow : NSWindow
@property(nonatomic, copy) void (^onEscape)(void);
@property(nonatomic, copy) void (^onPermissions)(void);
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
    const BOOL modified = (event.modifierFlags &
        (NSEventModifierFlagCommand | NSEventModifierFlagOption | NSEventModifierFlagControl)) != 0;
    if (event.keyCode == 53 && self.onEscape) { if (!event.isARepeat) self.onEscape(); }
    else if (event.keyCode == 35 && !modified && self.onPermissions) { if (!event.isARepeat) self.onPermissions(); }
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
@property(nonatomic) enum rv_shell_view shellView;
@property(nonatomic) uint64_t exitArmedMs;
@property(nonatomic) uint64_t noSignalSinceMs;
@property(nonatomic) uint64_t presentationGeneration;
@property(nonatomic) uint64_t toastGeneration;
@property(nonatomic) BOOL standbyRequested;
@property(nonatomic) BOOL permissionPromptPending;
@property(nonatomic) BOOL returnWhenPermitted;
@property(nonatomic, strong) NSTextField *titleLabel;
@property(nonatomic, strong) NSTextField *infoLabel;
@property(nonatomic, strong) NSTextField *permissionLabel;
@property(nonatomic, strong) NSTextField *hintLabel;
@property(nonatomic, strong) NSTextField *toastLabel;
@property(nonatomic, copy) NSString *statusKey;
@property(nonatomic, copy) NSString *statusDetail;
@property(nonatomic, copy) NSString *receiverAddress;
@property(nonatomic, copy) NSString *receiverLanguage;
@property(nonatomic, strong) NSNumber *receiverInputMonitoring;
@property(nonatomic, strong) NSNumber *receiverAccessibility;
@property(nonatomic, strong) NSMenuItem *returnItem;
@property(nonatomic, strong) NSMenuItem *standbyItem;
@property(nonatomic, strong) NSMenuItem *permissionsItem;

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
        if (!controller.hdmiFullscreen) return;
        uint64_t armed = controller.exitArmedMs;
        const BOOL confirmed = rv_shell_exit_press(&armed, RVMonotonicMilliseconds());
        controller.exitArmedMs = armed;
        if (!confirmed) { [controller showToast:[controller text:@"exit_confirm"]]; return; }
        controller.fullscreenDismissed = YES;
        [controller updateVideoPresentation:controller.showingVideo];
    };
    self.window.onPermissions = ^{ [weakSelf openPermissionSettings:nil]; };
    self.window.onShortcut = ^(unsigned int action) {
        NSString *name = action == RV_RECEIVER_SHORTCUT_DEBUG ? @RV_RECEIVER_DEBUG_TOGGLE_NOTIFICATION : @RV_RECEIVER_RESCUE_TOGGLE_NOTIFICATION;
        [[NSDistributedNotificationCenter defaultCenter] postNotificationName:name object:nil userInfo:nil deliverImmediately:YES];
    };
    self.menuItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.menuItem.button.title = @"ReVoyage";
    NSMenu *menu = [NSMenu new];
    self.returnItem = [menu addItemWithTitle:@"" action:@selector(showHDMIFullscreen:) keyEquivalent:@""];
    self.permissionsItem = [menu addItemWithTitle:@"" action:@selector(openPermissionSettings:) keyEquivalent:@""];
    self.standbyItem = [menu addItemWithTitle:@"" action:@selector(toggleNoSignalStandby:) keyEquivalent:@""];
    for (NSMenuItem *item in menu.itemArray) item.target = self;
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

    self.titleLabel = [self shellLabelWithSize:56 weight:NSFontWeightSemibold white:0.92];
    self.status = [self shellLabelWithSize:22 weight:NSFontWeightRegular white:0.70];
    self.infoLabel = [self shellLabelWithSize:18 weight:NSFontWeightRegular white:0.55];
    self.permissionLabel = [self shellLabelWithSize:17 weight:NSFontWeightMedium white:1.0];
    self.permissionLabel.textColor = [NSColor colorWithRed:1.0 green:0.72 blue:0.30 alpha:1.0];
    self.hintLabel = [self shellLabelWithSize:14 weight:NSFontWeightRegular white:0.38];
    self.toastLabel = [self shellLabelWithSize:20 weight:NSFontWeightMedium white:0.95];
    self.toastLabel.hidden = YES;
    self.statusKey = @"waiting_input";
    [self refreshShellText];
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
    [self layoutShell];
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
    /* The system prompt sits below the shell's window level. Step back while
     * it is on screen, otherwise nobody can answer it. */
    AVAuthorizationStatus camera = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    AVAuthorizationStatus microphone = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    NSString *pending = camera == AVAuthorizationStatusNotDetermined ? AVMediaTypeVideo :
        (camera == AVAuthorizationStatusAuthorized && microphone == AVAuthorizationStatusNotDetermined) ? AVMediaTypeAudio : nil;
    if (pending) {
        self.permissionPromptPending = YES;
        [self updateVideoPresentation:self.showingVideo];
        [AVCaptureDevice requestAccessForMediaType:pending completionHandler:^(BOOL granted) {
            (void)granted;
            dispatch_async(dispatch_get_main_queue(), ^{
                self.permissionPromptPending = NO;
                [self requestCapturePermissions];
            });
        }];
        return;
    }
    [self updateVideoPresentation:self.showingVideo];
    if (camera != AVAuthorizationStatusAuthorized) {
        [self showStatus:@"camera_denied" detail:nil];
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
        [self showStatus:@"waiting_card" detail:nil];
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
        [self showStatus:@"open_failed" detail:error.localizedDescription ?: @""];
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
    [self showStatus:@"waiting_hdmi" detail:nil];
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
        [self showStatus:@"waiting_card" detail:nil];
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
        [self showStatus:@"capture_retry" detail:nil];
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
        [self showStatus:@"capture_interrupted" detail:nil];
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
        [self showStatus:@"capture_reconnect" detail:nil];
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
    const BOOL wasNetworkVisible = self.networkVisible;
    self.networkVisible = [notification.name isEqualToString:RVNetworkActiveNotification];
    BOOL wasManualRescue = self.manualRescue;
    self.manualRescue = [notification.userInfo[@"manualRescue"] boolValue];
    NSDictionary *info = notification.userInfo;
    id address = info[@"address"], language = info[@"language"];
    id inputMonitoring = info[@"inputMonitoring"], accessibility = info[@"accessibility"];
    if ([address isKindOfClass:NSString.class]) self.receiverAddress = address;
    if ([language isKindOfClass:NSString.class]) self.receiverLanguage = language;
    if ([inputMonitoring isKindOfClass:NSNumber.class]) self.receiverInputMonitoring = inputMonitoring;
    if ([accessibility isKindOfClass:NSNumber.class]) self.receiverAccessibility = accessibility;
    /* A new picture on either path ends a visit to the iMac desktop. */
    if (self.networkVisible && !wasNetworkVisible) self.fullscreenDismissed = NO;
    if (self.manualRescue != wasManualRescue)
        [self showToast:[self text:self.manualRescue ? @"toast_rescue" : @"toast_network"]];
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
    self.receiverInputMonitoring = nil;
    self.receiverAccessibility = nil;
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
    if (on.boolValue) {
        self.holdingDisplayAwake = NO; /* Explicit wake must always declare activity. */
        /* It also restarts the no-signal standby countdown: the picture it
         * announces has not arrived yet. */
        self.noSignalSinceMs = now ? now : 1;
        self.standbyRequested = NO;
    }
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
    if (self.returnWhenPermitted && [self missingPermissions].count == 0) {
        self.returnWhenPermitted = NO;
        self.fullscreenDismissed = NO;
    }
    [self updateVideoPresentation:active];
    /* Another app taking focus must not leave the shell without a keyboard. */
    if (self.hdmiFullscreen && !NSApp.isActive) {
        [NSApp activateIgnoringOtherApps:YES];
        [self.window makeKeyAndOrderFront:nil];
    }
}

- (void)showHDMIFullscreen:(id)sender {
    (void)sender;
    self.fullscreenDismissed = NO;
    self.returnWhenPermitted = NO;
    [self updateVideoPresentation:self.showingVideo];
}

- (void)toggleNoSignalStandby:(id)sender {
    (void)sender;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setInteger:[defaults integerForKey:RVNoSignalStandbyKey] > 0 ? 0 : 60 forKey:RVNoSignalStandbyKey];
    [self refreshShellText];
    [self updateVideoPresentation:self.showingVideo];
}

- (BOOL)chinese {
    NSString *language = self.receiverLanguage.length ? self.receiverLanguage : NSLocale.preferredLanguages.firstObject;
    return [language hasPrefix:@"zh"];
}

- (NSString *)text:(NSString *)key { return RVShellText(key, [self chinese]); }

- (NSTextField *)shellLabelWithSize:(CGFloat)size weight:(NSFontWeight)weight white:(CGFloat)white {
    NSTextField *label = [NSTextField labelWithString:@""];
    label.textColor = [NSColor colorWithWhite:white alpha:1.0];
    label.backgroundColor = NSColor.clearColor;
    label.font = [NSFont systemFontOfSize:size weight:weight];
    label.alignment = NSTextAlignmentCenter;
    label.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self.window.contentView addSubview:label];
    return label;
}

- (void)layoutShell {
    if (!self.window) return;
    const NSRect bounds = self.window.contentView.bounds;
    const CGFloat width = NSWidth(bounds), middle = NSMidY(bounds);
    self.titleLabel.frame = NSMakeRect(0, middle + 24, width, 76);
    self.status.frame = NSMakeRect(0, middle - 28, width, 34);
    self.infoLabel.frame = NSMakeRect(0, middle - 70, width, 28);
    self.permissionLabel.frame = NSMakeRect(0, middle - 112, width, 28);
    self.hintLabel.frame = NSMakeRect(0, 36, width, 22);
    self.toastLabel.frame = NSMakeRect(0, NSHeight(bounds) * 0.78, width, 32);
}

- (void)showStatus:(NSString *)key detail:(NSString *)detail {
    self.statusKey = key;
    self.statusDetail = detail;
    [self refreshShellText];
}

- (void)showToast:(NSString *)message {
    self.toastLabel.stringValue = message ?: @"";
    self.toastLabel.hidden = NO;
    const uint64_t generation = ++self.toastGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(RV_SHELL_EXIT_CONFIRM_MS * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        if (self.toastGeneration == generation) self.toastLabel.hidden = YES;
    });
}

/* Camera/microphone belong to this process. Input Monitoring and Accessibility
 * belong to the Network Receiver, which reports them with its signal state. */
- (NSArray<NSString *> *)missingPermissions {
    NSMutableArray<NSString *> *missing = [NSMutableArray new];
    if ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo] != AVAuthorizationStatusAuthorized)
        [missing addObject:@"camera"];
    if ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] != AVAuthorizationStatusAuthorized)
        [missing addObject:@"microphone"];
    if (self.receiverInputMonitoring && !self.receiverInputMonitoring.boolValue) [missing addObject:@"input"];
    if (self.receiverAccessibility && !self.receiverAccessibility.boolValue) [missing addObject:@"accessibility"];
    return missing;
}

- (void)openPermissionSettings:(id)sender {
    (void)sender;
    NSString *first = [self missingPermissions].firstObject;
    if (!first) return;
    NSString *mediaType = [first isEqualToString:@"camera"] ? AVMediaTypeVideo :
                          [first isEqualToString:@"microphone"] ? AVMediaTypeAudio : nil;
    if (mediaType && [AVCaptureDevice authorizationStatusForMediaType:mediaType] == AVAuthorizationStatusNotDetermined) {
        if (!self.permissionPromptPending) [self requestCapturePermissions];
        return;
    }
    NSDictionary<NSString *, NSString *> *anchors = @{ @"camera": @"Privacy_Camera", @"microphone": @"Privacy_Microphone",
        @"input": @"Privacy_ListenEvent", @"accessibility": @"Privacy_Accessibility" };
    NSURL *url = [NSURL URLWithString:[@"x-apple.systempreferences:com.apple.preference.security?"
        stringByAppendingString:anchors[first]]];
    /* System Preferences needs the desktop; come back once nothing is missing. */
    self.fullscreenDismissed = YES;
    self.returnWhenPermitted = YES;
    [self updateVideoPresentation:self.showingVideo];
    if (url) [NSWorkspace.sharedWorkspace openURL:url];
}

- (void)refreshShellText {
    self.titleLabel.stringValue = [self text:@"title_no_signal"];
    NSString *status = [self text:self.statusKey ?: @"waiting_input"];
    self.status.stringValue = self.statusDetail
        ? [status stringByReplacingOccurrencesOfString:@"%@" withString:self.statusDetail] : status;
    self.infoLabel.stringValue = self.receiverAddress.length
        ? [[self text:@"address"] stringByReplacingOccurrencesOfString:@"%@" withString:self.receiverAddress] : @"";
    NSMutableArray<NSString *> *names = [NSMutableArray new];
    for (NSString *key in [self missingPermissions]) [names addObject:[self text:key]];
    self.permissionLabel.stringValue = names.count
        ? [[self text:@"permissions_missing"] stringByReplacingOccurrencesOfString:@"%@"
              withString:[names componentsJoinedByString:@" · "]] : @"";
    self.hintLabel.stringValue = [self text:@"hint"];
    self.returnItem.title = [self text:@"menu_return"];
    self.permissionsItem.title = [self text:@"menu_permissions"];
    self.permissionsItem.hidden = names.count == 0;
    self.standbyItem.title = [self text:@"menu_standby"];
    self.standbyItem.state = [NSUserDefaults.standardUserDefaults integerForKey:RVNoSignalStandbyKey] > 0
        ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)coverScreen {
    self.savedPresentationOptions = NSApp.presentationOptions;
    [self.window setFrame:(self.window.screen ?: NSScreen.mainScreen).frame display:YES];
    [self layoutShell];
    self.window.level = NSStatusWindowLevel + 1;
    [NSApp activateIgnoringOtherApps:YES];
    NSApp.presentationOptions = NSApplicationPresentationHideDock | NSApplicationPresentationHideMenuBar;
    [self.window makeKeyAndOrderFront:nil];
}

- (void)uncoverScreen {
    NSApp.presentationOptions = self.savedPresentationOptions;
    self.window.level = NSNormalWindowLevel - 1;
    [self.window orderBack:nil];
}

/* YES covers the whole screen above the Dock and menu bar, with HDMI video or
 * the no-signal page. */
- (void)presentHDMIFullscreen:(BOOL)fullscreen {
    if (!self.window || fullscreen == self.hdmiFullscreen) return;
    self.hdmiFullscreen = fullscreen;
    self.exitArmedMs = 0;
    const uint64_t generation = ++self.presentationGeneration;
    if (fullscreen) { [self coverScreen]; return; }
    if (self.shellView != RV_SHELL_VIEW_NETWORK) { [self uncoverScreen]; return; }
    /* Stay in front until the network window has taken the screen, so the
     * handoff never shows the desktop underneath. */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(RV_SHELL_NETWORK_HANDOFF_MS * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        if (self.presentationGeneration == generation && !self.hdmiFullscreen) [self uncoverScreen];
    });
}

- (void)requestNoSignalStandby {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        pid_t pid = 0;
        char *argv[] = { "/usr/bin/pmset", "displaysleepnow", NULL };
        if (posix_spawn(&pid, argv[0], NULL, NULL, argv, environ) == 0) {
            int status = 0;
            pid_t waited;
            do { waited = waitpid(pid, &status, 0); } while (waited < 0 && errno == EINTR);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            /* A picture that arrived meanwhile wakes the panel again here. */
            self.displaySleeping = YES;
            [self updateVideoPresentation:self.showingVideo];
        });
    });
}

- (void)updateVideoPresentation:(BOOL)active {
    const uint64_t now = RVMonotonicMilliseconds();
    enum rv_display_power_mode power = rv_display_power_update(&_signalState, now);
    BOOL enteredRescue = power == RV_POWER_RESCUE_LOCK && self.lastPowerMode != RV_POWER_RESCUE_LOCK;
    self.lastPowerMode = power;
    unsigned int sources = rv_display_signal_active_sources(&_signalState, now);
    if (!self.networkVisible) sources &= ~RV_DISPLAY_SIGNAL_NETWORK;
    /* The shell covers the screen whenever the network stream is not on it,
     * including while the panel is off: a stray wake must not show the desktop. */
    const enum rv_shell_view view = rv_shell_view_for(sources, active, self.manualRescue,
        self.fullscreenDismissed || self.permissionPromptPending);
    self.shellView = view;
    [self presentHDMIFullscreen:rv_shell_view_covers(view)];
    if (view != RV_SHELL_VIEW_NO_SIGNAL) { self.noSignalSinceMs = 0; self.standbyRequested = NO; }
    else if (!self.noSignalSinceMs) self.noSignalSinceMs = now ? now : 1;
    const BOOL anyInput = view != RV_SHELL_VIEW_DESKTOP;
    self.audioPreview.volume = rv_display_signal_hdmi_audio_allowed(sources) ? 1.0f : 0.0f;
    int cursorAction = rv_display_cursor_action(self.cursorHidden, anyInput);
    if (cursorAction > 0 && CGDisplayHideCursor(CGMainDisplayID()) == kCGErrorSuccess) self.cursorHidden = YES;
    if (cursorAction < 0 && CGDisplayShowCursor(CGMainDisplayID()) == kCGErrorSuccess) self.cursorHidden = NO;
    self.showingVideo = active;
    const BOOL pageHidden = active || (sources & RV_DISPLAY_SIGNAL_NETWORK) != 0;
    self.titleLabel.hidden = self.status.hidden = self.infoLabel.hidden = pageHidden;
    self.permissionLabel.hidden = self.hintLabel.hidden = pageHidden;
    if (!pageHidden) [self refreshShellText];
    if (self.manualRescue && !active) [self showStatus:@"manual_rescue" detail:nil];
    if (active) [self showStatus:@"waiting_any" detail:nil];

    if (power == RV_POWER_MANUAL_OFF) {
        self.holdingDisplayAwake = NO;
        if (self.displayAssertion != kIOPMNullAssertionID) {
            IOPMAssertionRelease(self.displayAssertion);
            self.displayAssertion = kIOPMNullAssertionID;
        }
        return; /* Frames/HDMI reconnects cannot override explicit off. */
    }
    const uint64_t standbyMs = (uint64_t)MAX((NSInteger)0,
        [NSUserDefaults.standardUserDefaults integerForKey:RVNoSignalStandbyKey]) * 1000ULL;
    if (standbyMs && view == RV_SHELL_VIEW_NO_SIGNAL) {
        const uint64_t idleMs = (uint64_t)(CGEventSourceSecondsSinceLastEventType(
            kCGEventSourceStateCombinedSessionState, kCGAnyInputEventType) * 1000.0);
        if (rv_shell_no_signal_should_sleep(self.noSignalSinceMs, now, idleMs, standbyMs)) {
            /* Monitor-style standby: only the panel sleeps. HDMI or network
             * frames, or the iMac's own keyboard/mouse, light it again. */
            self.holdingDisplayAwake = NO;
            if (self.displayAssertion != kIOPMNullAssertionID) {
                IOPMAssertionRelease(self.displayAssertion);
                self.displayAssertion = kIOPMNullAssertionID;
            }
            if (!self.standbyRequested && !self.displaySleepPending) {
                self.standbyRequested = YES;
                [self requestNoSignalStandby];
            }
            return;
        }
        self.standbyRequested = NO;
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
    /* Only the opt-in no-signal standby above can sleep here: no old LKG
     * preference and no HDMI content heuristic. */
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
    [self layoutShell];
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
