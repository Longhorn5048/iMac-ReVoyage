#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreMedia/CoreMedia.h>
#include "protocol.h"
#include "rate_limit.h"
#include "../TargetBridge-Shared/LocalConnection.h"
#include <math.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <unistd.h>

static volatile sig_atomic_t running = 1;
static void stop_service(int sig) { (void)sig; running = 0; }
static double monotonic(void) { return NSProcessInfo.processInfo.systemUptime; }
static BOOL transfer(int fd, void *bytes, size_t count, BOOL sending) {
    uint8_t *cursor = bytes;
    double deadline = monotonic() + (sending ? 0.5 : 8.0);
    while (count && running && monotonic() < deadline) {
        ssize_t n = sending ? send(fd, cursor, count, 0) : recv(fd, cursor, count, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return NO;
        cursor += n; count -= (size_t)n;
    }
    return count == 0;
}
static NSData *packet(uint8_t type, NSData *payload) {
    if (payload.length + 1 > RV_MEDIA_MAX_PACKET) return nil;
    uint32_t count = htonl((uint32_t)payload.length + 1);
    NSMutableData *data = [NSMutableData dataWithBytes:&count length:4];
    [data appendBytes:&type length:1]; [data appendData:payload ?: NSData.data];
    return data;
}
static NSData *json(id object) { return [NSJSONSerialization dataWithJSONObject:object options:0 error:nil]; }
static BOOL send_direct(int fd, uint8_t type, NSData *data) {
    NSData *message = packet(type, data);
    return message && transfer(fd, (void *)message.bytes, message.length, YES);
}
static NSData *receive_packet(int fd, uint8_t *type) {
    uint32_t header;
    if (!transfer(fd, &header, 4, NO)) return nil;
    uint32_t size = ntohl(header);
    if (size < 1 || size > RV_MEDIA_MAX_REQUEST + 1) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:size];
    if (!transfer(fd, data.mutableBytes, size, NO)) return nil;
    *type = ((uint8_t *)data.bytes)[0];
    return [data subdataWithRange:NSMakeRange(1, size - 1)];
}
static NSData *load_key(NSString *path) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW);
    struct stat info;
    if (fd < 0) return nil;
    BOOL valid = fstat(fd, &info) == 0 && S_ISREG(info.st_mode) && info.st_uid == getuid() &&
                 (info.st_mode & 077) == 0 && info.st_size >= 64 && info.st_size <= 66;
    char bytes[67] = {0}; ssize_t n = valid ? read(fd, bytes, 66) : -1; close(fd);
    if (n < 64 || (n > 64 && bytes[64] != '\n') || (n > 65 && bytes[65] != '\n')) return nil;
    for (int i = 0; i < 64; ++i)
        if (!((bytes[i] >= '0' && bytes[i] <= '9') || (bytes[i] >= 'a' && bytes[i] <= 'f'))) return nil;
    return [NSData dataWithBytes:bytes length:64];
}
static BOOL authenticate(int fd, NSData *key) {
    uint8_t nonce[32], expected[32]; arc4random_buf(nonce, 32);
    if (!send_direct(fd, RV_MEDIA_CHALLENGE, [NSData dataWithBytes:nonce length:32])) return NO;
    uint8_t type = 0; NSData *reply = receive_packet(fd, &type);
    if (type != RV_MEDIA_AUTH || reply.length != 64) return NO;
    const uint8_t *bytes = reply.bytes;
    rv_media_proof(nonce, bytes, key.bytes, 0, expected);
    if (!rv_media_equal(expected, bytes + 32, 32)) return NO;
    rv_media_proof(nonce, bytes, key.bytes, 1, expected);
    return send_direct(fd, RV_MEDIA_PROOF, [NSData dataWithBytes:expected length:32]);
}

/* A bounded queue is shared by capture delegates and one socket writer.
 * Video is independently decodable JPEG: old queued frames may be replaced.
 * Audio overflow aborts the stream instead of building seconds of stale audio. */
@interface RVWriter : NSObject
@property(nonatomic) int fd;
@property(nonatomic) BOOL closed;
@property(nonatomic) NSUInteger queuedBytes;
@property(nonatomic) NSUInteger queuedPCMBytes;
@property(nonatomic) struct rv_rate_limit pcmRate;
@property(nonatomic,strong) NSCondition *condition;
@property(nonatomic,strong) NSMutableArray<NSDictionary *> *messages;
- (instancetype)initWithFD:(int)fd;
- (BOOL)enqueue:(uint8_t)type data:(NSData *)data;
- (void)discardMedia;
- (void)run;
- (void)close;
- (BOOL)isClosed;
@end
@implementation RVWriter
- (instancetype)initWithFD:(int)fd {
    if ((self = [super init])) { _fd = fd; _pcmRate = rv_rate_limit_create(1, 10000, monotonic()); _condition = [NSCondition new]; _messages = [NSMutableArray array]; }
    return self;
}
- (BOOL)enqueue:(uint8_t)type data:(NSData *)data {
    NSData *message = packet(type, data); if (!message) return NO;
    [_condition lock];
    if (type == RV_MEDIA_JPEG) {
        for (NSInteger i = (NSInteger)_messages.count - 1; i >= 0; --i) {
            if ([_messages[i][@"type"] unsignedCharValue] == RV_MEDIA_JPEG) {
                _queuedBytes -= [_messages[i][@"data"] length]; [_messages removeObjectAtIndex:i];
            }
        }
    }
    BOOL accepted = !_closed && _messages.count < 64 && message.length <= RV_MEDIA_MAX_QUEUED - _queuedBytes &&
                    (type != RV_MEDIA_PCM || (_queuedPCMBytes + message.length <= 10000 && rv_rate_limit_admit(&_pcmRate, message.length, monotonic())));
    if (accepted) {
        [_messages addObject:@{@"type":@(type), @"data":message}]; _queuedBytes += message.length;
        if (type == RV_MEDIA_PCM) _queuedPCMBytes += message.length;
        [_condition signal];
    } else if (!_closed && type != RV_MEDIA_JPEG) {
        _closed = YES; shutdown(_fd, SHUT_RDWR); [_condition broadcast];
    }
    [_condition unlock]; return accepted;
}
- (void)run {
    for (;;) { @autoreleasepool {
        [_condition lock]; while (!_closed && _messages.count == 0) [_condition wait];
        if (_closed) { [_condition unlock]; break; }
        NSDictionary *first = _messages.firstObject; NSData *data = first[@"data"];
        [_messages removeObjectAtIndex:0]; _queuedBytes -= data.length;
        if ([first[@"type"] unsignedCharValue] == RV_MEDIA_PCM) _queuedPCMBytes -= data.length;
        [_condition unlock];
        if (!transfer(_fd, (void *)data.bytes, data.length, YES)) { [self close]; break; }
    } }
}
- (void)discardMedia {
    [_condition lock];
    for (NSInteger i = (NSInteger)_messages.count - 1; i >= 0; --i) {
        uint8_t type = [_messages[i][@"type"] unsignedCharValue];
        if (type == RV_MEDIA_JPEG || type == RV_MEDIA_PCM) {
            NSUInteger size = [_messages[i][@"data"] length];
            _queuedBytes -= size;
            if (type == RV_MEDIA_PCM) _queuedPCMBytes -= size;
            [_messages removeObjectAtIndex:i];
        }
    }
    [_condition unlock];
}
- (void)close {
    [_condition lock]; if (_closed) { [_condition unlock]; return; }
    _closed = YES; [_messages removeAllObjects]; _queuedBytes = 0; _queuedPCMBytes = 0;
    shutdown(_fd, SHUT_RDWR); [_condition broadcast]; [_condition unlock];
}
- (BOOL)isClosed { [_condition lock]; BOOL value=_closed; [_condition unlock]; return value; }
@end

static NSDictionary *menuStrings(void) {
    NSString *settingsPath=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/TargetBridge Receiver/settings.json"];
    NSData *settingsData=[NSData dataWithContentsOfFile:settingsPath];
    NSDictionary *settings=settingsData.length<=8192 && settingsData ? [NSJSONSerialization JSONObjectWithData:settingsData options:0 error:nil] : nil;
    NSString *language=[settings isKindOfClass:NSDictionary.class] ? settings[@"language"] : nil;
    if (![language isKindOfClass:NSString.class] || [language isEqual:@"auto"]) language=NSLocale.preferredLanguages.firstObject;
    NSString *code=[[language componentsSeparatedByString:@"-"] firstObject];
    if (![@[@"en",@"zh",@"it",@"de",@"fr"] containsObject:code]) code=@"en";
    static NSString *loadedCode; static NSDictionary *strings;
    if (![loadedCode isEqual:code]) {
        NSString *path=[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:[@"Languages/" stringByAppendingString:[code stringByAppendingString:@".json"]]];
        NSData *data=[NSData dataWithContentsOfFile:path];
        id decoded=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        strings=[decoded isKindOfClass:NSDictionary.class] ? decoded : @{}; loadedCode=code;
    }
    return strings;
}
static NSString *menuText(NSDictionary *strings, NSString *key, NSString *fallback) {
    id value=strings[[@"receiver.media." stringByAppendingString:key]];
    return [value isKindOfClass:NSString.class] ? value : fallback;
}

@interface RVPrivacyMenu : NSObject
@property(nonatomic,strong) NSStatusItem *item;
@property(nonatomic,strong) RVWriter *writer;
- (void)update:(RVWriter *)writer camera:(BOOL)camera microphone:(BOOL)microphone;
- (void)stopSharing:(id)sender;
@end
@implementation RVPrivacyMenu
- (instancetype)init {
    if ((self = [super init])) {
        _item = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
        NSMenu *menu = [NSMenu new];
        NSMenuItem *stop = [[NSMenuItem alloc] initWithTitle:@"Stop sharing / 停止共享" action:@selector(stopSharing:) keyEquivalent:@""];
        stop.target = self; [menu addItem:stop]; _item.menu = menu;
        [self update:nil camera:NO microphone:NO];
    }
    return self;
}
- (void)update:(RVWriter *)writer camera:(BOOL)camera microphone:(BOOL)microphone {
    _writer = writer;
    _item.button.title = camera || microphone ? @"● ReVoyage" : @"○ ReVoyage";
    NSDictionary *strings=menuStrings();
    _item.menu.itemArray.firstObject.title=menuText(strings,@"stop",@"Stop sharing");
    NSString *on=menuText(strings,@"on",@"On"), *off=menuText(strings,@"off",@"Off");
    NSString *status=menuText(strings,@"status",@"Camera: %{camera}\nMicrophone: %{microphone}");
    _item.button.toolTip=[[status stringByReplacingOccurrencesOfString:@"%{camera}" withString:camera ? on : off]
        stringByReplacingOccurrencesOfString:@"%{microphone}" withString:microphone ? on : off];
}
- (void)stopSharing:(id)sender { (void)sender; [_writer close]; [self update:nil camera:NO microphone:NO]; }
@end
static RVPrivacyMenu *privacyMenu;

static NSString *permission(AVMediaType type) {
    switch ([AVCaptureDevice authorizationStatusForMediaType:type]) {
        case AVAuthorizationStatusAuthorized: return @"authorized";
        case AVAuthorizationStatusDenied: return @"denied";
        case AVAuthorizationStatusRestricted: return @"restricted";
        default: return @"notDetermined";
    }
}
static NSArray<AVCaptureDevice *> *devices(AVMediaType type) {
    NSArray *types = [type isEqual:AVMediaTypeVideo] ? @[AVCaptureDeviceTypeBuiltInWideAngleCamera, AVCaptureDeviceTypeExternalUnknown]
                                                    : @[AVCaptureDeviceTypeBuiltInMicrophone, AVCaptureDeviceTypeExternalUnknown];
    return [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:types mediaType:type position:AVCaptureDevicePositionUnspecified].devices;
}
static NSDictionary *registry(BOOL fixture) {
    NSMutableArray *rows = [NSMutableArray array];
    if (fixture) {
        [rows addObjectsFromArray:@[@{@"id":@"fixture-camera", @"name":@"Fixture Camera", @"kind":@"camera"},
                                   @{@"id":@"fixture-microphone", @"name":@"Fixture Microphone", @"kind":@"microphone"}]];
    } else {
        for (AVMediaType type in @[AVMediaTypeVideo, AVMediaTypeAudio]) {
            for (AVCaptureDevice *device in devices(type)) {
                if (rows.count >= 32 || device.uniqueID.length > 512 || device.localizedName.length > 128) continue;
                [rows addObject:@{@"id":device.uniqueID, @"name":device.localizedName,
                    @"kind":[type isEqual:AVMediaTypeVideo] ? @"camera" : @"microphone"}];
            }
        }
    }
    return @{@"schema":@1, @"supportsBandwidthLimit":@YES, @"devices":rows, @"cameraPermission":fixture ? @"authorized" : permission(AVMediaTypeVideo),
             @"microphonePermission":fixture ? @"authorized" : permission(AVMediaTypeAudio)};
}
// A FIN can sit behind unread heartbeats; peeking one byte cannot establish
// liveness during an authorization prompt. Drain bounded control traffic and
// reject any queued command while configuration is pending.
static BOOL permission_peer_alive(RVWriter *writer) {
    if ([writer isClosed]) return NO;
    for (int count=0; count<64; count++) {
        struct pollfd p={.fd=writer.fd,.events=POLLIN};
        int result=poll(&p,1,0);
        if (result==0 || (result<0 && errno==EINTR)) return ![writer isClosed];
        if (result<0 || (p.revents&(POLLHUP|POLLERR|POLLNVAL))) break;
        if (!(p.revents&POLLIN)) return ![writer isClosed];
        uint8_t type=0; NSData *payload=receive_packet(writer.fd,&type);
        if (!payload || type!=RV_MEDIA_HEARTBEAT || payload.length ||
            ![writer enqueue:RV_MEDIA_HEARTBEAT data:NSData.data]) break;
    }
    [writer close]; return NO;
}
static BOOL authorize(AVMediaType type, RVWriter *writer) {
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:type];
    if (status == AVAuthorizationStatusAuthorized) return permission_peer_alive(writer);
    if (status != AVAuthorizationStatusNotDetermined) return NO;
    dispatch_semaphore_t complete = dispatch_semaphore_create(0);
    __block BOOL granted = NO;
    [AVCaptureDevice requestAccessForMediaType:type completionHandler:^(BOOL allowed) { granted = allowed; dispatch_semaphore_signal(complete); }];
    double deadline=monotonic()+120;
    while (running && monotonic()<deadline) {
        if (dispatch_semaphore_wait(complete, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0)
            return granted && running && permission_peer_alive(writer);
        if (!permission_peer_alive(writer)) return NO;
    }
    return NO;
}

@interface RVCapture : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate>
@property(nonatomic,strong) AVCaptureSession *camera;
@property(nonatomic,strong) AVCaptureSession *microphone;
@property(nonatomic,strong) RVWriter *writer;
@property(nonatomic) struct rv_rate_limit cameraRate;
@property(nonatomic,strong) CIContext *imageContext;
@property(nonatomic,strong) dispatch_queue_t videoQueue;
@property(nonatomic,strong) dispatch_queue_t audioQueue;
@property(nonatomic) double lastFrame;
@property(nonatomic) uint64_t frameSequence, audioSequence;
@property(nonatomic) BOOL stopped;
// Each flag is read and written only on its corresponding delegate queue.
@property(nonatomic) BOOL videoPublishing, audioPublishing;
@property(nonatomic,strong) NSMutableArray *observers;
- (NSString *)configure:(NSDictionary *)request;
- (void)stop;
- (void)publishAfterStatus;
@end
@implementation RVCapture
- (instancetype)init {
    if ((self = [super init])) {
        _videoQueue = dispatch_queue_create("re.voyage.media.video", DISPATCH_QUEUE_SERIAL);
        _audioQueue = dispatch_queue_create("re.voyage.media.audio", DISPATCH_QUEUE_SERIAL);
        _imageContext = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer:@NO}];
        _cameraRate = rv_rate_limit_create(25, 262157, monotonic());
        _observers = [NSMutableArray array];
    }
    return self;
}
- (NSString *)addDevice:(NSString *)identifier type:(AVMediaType)type {
    if (!identifier) return nil;
    AVCaptureDevice *chosen = nil;
    for (AVCaptureDevice *device in devices(type)) if ([device.uniqueID isEqual:identifier]) { chosen = device; break; }
    if (!chosen) return @"device_missing";
    if (!authorize(type, _writer)) return @"permission_denied";
    NSError *error; AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:chosen error:&error];
    if (!input) return @"device_busy";
    AVCaptureSession *session = [AVCaptureSession new]; [session beginConfiguration];
    BOOL video = [type isEqual:AVMediaTypeVideo];
    if (video) {
        if (![session canSetSessionPreset:AVCaptureSessionPreset1280x720]) return @"format_unsupported";
        session.sessionPreset = AVCaptureSessionPreset1280x720;
    }
    if (![session canAddInput:input]) return @"device_busy";
    [session addInput:input];
    if (video) {
        AVCaptureVideoDataOutput *output = [AVCaptureVideoDataOutput new];
        output.alwaysDiscardsLateVideoFrames = YES;
        output.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA)};
        [output setSampleBufferDelegate:self queue:_videoQueue];
        if (![session canAddOutput:output]) return @"format_unsupported";
        [session addOutput:output]; _camera = session;
    } else {
        AVCaptureAudioDataOutput *output = [AVCaptureAudioDataOutput new];
        output.audioSettings = @{AVFormatIDKey:@(kAudioFormatLinearPCM), AVSampleRateKey:@48000,
            AVNumberOfChannelsKey:@1, AVLinearPCMBitDepthKey:@16, AVLinearPCMIsFloatKey:@NO,
            AVLinearPCMIsBigEndianKey:@NO, AVLinearPCMIsNonInterleaved:@NO};
        [output setSampleBufferDelegate:self queue:_audioQueue];
        if (![session canAddOutput:output]) return @"format_unsupported";
        [session addOutput:output]; _microphone = session;
    }
    __weak RVCapture *weak = self;
    for (NSString *name in @[AVCaptureSessionRuntimeErrorNotification, AVCaptureSessionWasInterruptedNotification,
                             AVCaptureDeviceWasDisconnectedNotification]) {
        id observer = [NSNotificationCenter.defaultCenter addObserverForName:name
            object:[name isEqual:AVCaptureDeviceWasDisconnectedNotification] ? chosen : session queue:nil
            usingBlock:^(NSNotification *notification) { (void)notification; [weak.writer close]; }];
        [_observers addObject:observer];
    }
    [session commitConfiguration];
    if ([_writer isClosed]) return @"capture_failed";
    [session startRunning];
    if ([_writer isClosed]) { [session stopRunning]; return @"capture_failed"; }
    return session.running ? nil : @"capture_failed";
}
- (NSString *)configure:(NSDictionary *)request {
    _cameraRate = rv_rate_limit_create(request[@"cameraMbps"] ? [request[@"cameraMbps"] doubleValue] : 25, 262157, monotonic());
    // Obtain all requested permissions before opening either device. A local
    // stop or disconnect during the prompt cannot start capture afterward.
    for (NSString *key in @[@"cameraID",@"microphoneID"]) {
        if (!request[key]) continue;
        AVMediaType type = [key isEqual:@"cameraID"] ? AVMediaTypeVideo : AVMediaTypeAudio;
        BOOL found = NO;
        for (AVCaptureDevice *device in devices(type)) if ([device.uniqueID isEqual:request[key]]) { found=YES; break; }
        if (!found) return @"device_missing";
        if (!authorize(type,_writer)) return @"permission_denied";
    }
    NSString *error = [self addDevice:request[@"cameraID"] type:AVMediaTypeVideo];
    if (!error) error = [self addDevice:request[@"microphoneID"] type:AVMediaTypeAudio];
    if (error) [self stop];
    return error;
}
- (void)stop {
    for (id observer in _observers) [NSNotificationCenter.defaultCenter removeObserver:observer];
    [_observers removeAllObjects];
    [_camera stopRunning]; [_microphone stopRunning];
    // Drain capture callbacks before another connection can own the devices.
    dispatch_sync(_videoQueue, ^{ self.stopped = YES; self.videoPublishing = NO; });
    dispatch_sync(_audioQueue, ^{ self.audioPublishing = NO; });
    _camera = nil; _microphone = nil;
}
- (void)publishAfterStatus {
    if (_stopped || [_writer isClosed]) return;
    // The socket writer sees the ACK before either queue can publish sequence 0.
    dispatch_sync(_videoQueue, ^{ self.videoPublishing = YES; });
    dispatch_sync(_audioQueue, ^{ self.audioPublishing = YES; });
}
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sample fromConnection:(AVCaptureConnection *)connection {
    @autoreleasepool {
    (void)connection;
    if ([output isKindOfClass:AVCaptureVideoDataOutput.class]) {
        if (!_videoPublishing) return;
        double now = monotonic(); if (now < _lastFrame) return;
        _lastFrame = MAX(_lastFrame + 0.05, now + 0.01);
        CVPixelBufferRef pixels = CMSampleBufferGetImageBuffer(sample);
        if (!pixels || CVPixelBufferGetWidth(pixels) != 1280 || CVPixelBufferGetHeight(pixels) != 720) return;
        CGColorSpaceRef color = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        NSData *jpeg = [_imageContext JPEGRepresentationOfImage:[CIImage imageWithCVPixelBuffer:pixels]
            colorSpace:color options:@{(id)kCGImageDestinationLossyCompressionQuality:@0.65}]; CGColorSpaceRelease(color);
        if (!jpeg || jpeg.length > 262144 || !rv_rate_limit_admit(&_cameraRate, jpeg.length + 13, now)) return;
        uint8_t sequence[8]; rv_media_put_u64(sequence, _frameSequence++);
        NSMutableData *payload = [NSMutableData dataWithBytes:sequence length:8]; [payload appendData:jpeg];
        [_writer enqueue:RV_MEDIA_JPEG data:payload];
    } else {
        if (!_audioPublishing) return;
        const AudioStreamBasicDescription *format = CMAudioFormatDescriptionGetStreamBasicDescription(CMSampleBufferGetFormatDescription(sample));
        if (!format || format->mFormatID != kAudioFormatLinearPCM || format->mSampleRate != 48000 ||
            format->mChannelsPerFrame != 1 || format->mBitsPerChannel != 16 || format->mBytesPerFrame != 2 ||
            (format->mFormatFlags & (kAudioFormatFlagIsFloat | kAudioFormatFlagIsBigEndian | kAudioFormatFlagIsNonInterleaved)) ||
            !(format->mFormatFlags & kAudioFormatFlagIsSignedInteger)) { [_writer close]; return; }
        CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
        size_t count = block ? CMBlockBufferGetDataLength(block) : 0;
        if (count == 0 || count > 32768 || count % 2) return;
        uint8_t bytes[RV_MEDIA_PCM_CHUNK * 2];
        for (size_t offset = 0; offset < count; offset += sizeof(bytes)) {
            size_t size = MIN(sizeof(bytes), count - offset);
            if (CMBlockBufferCopyDataBytes(block, offset, size, bytes) != noErr) { [_writer close]; return; }
            uint8_t sequence[8]; rv_media_put_u64(sequence, _audioSequence); _audioSequence += size / 2;
            NSMutableData *payload = [NSMutableData dataWithBytes:sequence length:8]; [payload appendBytes:bytes length:size];
            [_writer enqueue:RV_MEDIA_PCM data:payload];
        }
    }
    }
}
@end

static BOOL valid_request(id object) {
    if (![object isKindOfClass:NSDictionary.class] || ![object[@"schema"] isEqual:@1] || [object count] > 4) return NO;
    if (CFGetTypeID((__bridge CFTypeRef)object[@"schema"]) == CFBooleanGetTypeID()) return NO;
    for (NSString *key in object) {
        if ([key isEqual:@"schema"]) continue;
        if ([key isEqual:@"cameraMbps"]) {
            id value = object[key];
            if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() ||
                !isfinite([value doubleValue]) || [value doubleValue] < 1 || [value doubleValue] > 1000) return NO;
            continue;
        }
        if (![@[@"cameraID", @"microphoneID"] containsObject:key] || ![object[key] isKindOfClass:NSString.class] ||
            [object[key] length] == 0 || [object[key] length] > 512) return NO;
    }
    return YES;
}
static void serve(int fd, NSData *key, BOOL fixture) {
    struct timeval timeout = {.tv_sec=1};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    timeout.tv_sec = 0; timeout.tv_usec = 500000; setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    int yes = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes)); setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof(yes));
    int sendBytes = 65536; setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sendBytes, sizeof(sendBytes));
    if (!authenticate(fd, key) || !send_direct(fd, RV_MEDIA_REGISTRY, json(registry(fixture)))) return;
    RVWriter *writer = [[RVWriter alloc] initWithFD:fd];
    if (!fixture) dispatch_async(dispatch_get_main_queue(), ^{ [privacyMenu update:writer camera:NO microphone:NO]; });
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ [writer run]; });
    RVCapture *capture = nil; double lastCommand = monotonic();
    while (running) { @autoreleasepool {
        struct pollfd p = {.fd=fd, .events=POLLIN}; int ready = poll(&p, 1, 1000);
        if (ready < 0 && errno == EINTR) continue;
        if (ready < 0 || p.revents & (POLLHUP | POLLERR) || monotonic() - lastCommand > 8) break;
        if (!ready) continue;
        uint8_t type = 0; NSData *data = receive_packet(fd, &type); if (!data) break; lastCommand = monotonic();
        if (type == RV_MEDIA_HEARTBEAT && data.length == 0) { [writer enqueue:RV_MEDIA_HEARTBEAT data:NSData.data]; continue; }
        if (type != RV_MEDIA_REQUEST && type != RV_MEDIA_STOP) break;
        id request = type == RV_MEDIA_STOP ? @{@"schema":@1} : [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ((type == RV_MEDIA_STOP && data.length != 0) || !valid_request(request)) break;
        [capture stop]; capture = nil;
        // A packet already being written completes before the ACK on this TCP
        // stream. Only queued old media can be removed without corrupting it.
        [writer discardMedia];
        NSString *error = nil;
        if (fixture) {
            if ((request[@"cameraID"] && ![request[@"cameraID"] isEqual:@"fixture-camera"]) ||
                (request[@"microphoneID"] && ![request[@"microphoneID"] isEqual:@"fixture-microphone"])) error = @"device_missing";
        } else if (request[@"cameraID"] || request[@"microphoneID"]) {
            if ((request[@"cameraID"] && [permission(AVMediaTypeVideo) isEqual:@"notDetermined"]) ||
                (request[@"microphoneID"] && [permission(AVMediaTypeAudio) isEqual:@"notDetermined"]))
                [writer enqueue:RV_MEDIA_STATUS data:json(@{@"schema":@1,@"cameraActive":@NO,@"microphoneActive":@NO,@"error":@"permission_pending"})];
            capture = [RVCapture new]; capture.writer = writer; error = [capture configure:request];
        }
        lastCommand = monotonic();
        BOOL video = !error && request[@"cameraID"] != nil, audio = !error && request[@"microphoneID"] != nil;
        if (!fixture) dispatch_async(dispatch_get_main_queue(), ^{ [privacyMenu update:writer camera:video microphone:audio]; });
        if (![writer enqueue:RV_MEDIA_STATUS data:json(@{@"schema":@1, @"cameraActive":@(video), @"microphoneActive":@(audio), @"error":error ?: @""})]) break;
        if (!error) [capture publishAfterStatus];
        [writer enqueue:RV_MEDIA_REGISTRY data:json(registry(fixture))];
        fprintf(stderr, "[media] camera=%d microphone=%d error=%s\n", video, audio, (error ?: @"").UTF8String);
        if (fixture && audio) { uint8_t pcm[8 + 960] = {0}; [writer enqueue:RV_MEDIA_PCM data:[NSData dataWithBytes:pcm length:sizeof(pcm)]]; }
    } }
    [capture stop]; [writer close]; dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    if (!fixture) dispatch_async(dispatch_get_main_queue(), ^{ [privacyMenu update:nil camera:NO microphone:NO]; });
}
static void accept_clients(NSData *key, BOOL fixture, uint16_t port) {
    int listener = socket(AF_INET, SOCK_STREAM, 0); int yes = 1;
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in address = {.sin_len=sizeof(address), .sin_family=AF_INET, .sin_port=htons(port)};
    address.sin_addr.s_addr = htonl(fixture ? INADDR_LOOPBACK : INADDR_ANY);
    if (listener < 0 || bind(listener, (void *)&address, sizeof(address)) || listen(listener, 4)) {
        fprintf(stderr, "[media] cannot listen: %s\n", strerror(errno)); exit(71);
    }
    fprintf(stderr, "[media] listening on TCP %u; capture is off\n", port);
    while (running) {
        struct pollfd p = {.fd=listener, .events=POLLIN}; if (poll(&p, 1, 1000) <= 0) continue;
        int fd = accept(listener, NULL, NULL); if (fd < 0) continue;
        @autoreleasepool { serve(fd, key, fixture); } close(fd);
    }
    close(listener); exit(0);
}
int main(int argc, char **argv) {
    @autoreleasepool {
        BOOL fixture = NO; uint16_t port = RV_MEDIA_PORT;
        NSString *keyPath = rv_pairing_required()
            ? [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/TargetBridge Receiver/pairing.key"] : nil;
        for (int i = 1; i < argc; ++i) {
            if (strcmp(argv[i], "--fixture") == 0) fixture = YES;
            else if (strcmp(argv[i], "--pairing-key-path") == 0 && i + 1 < argc) keyPath = @(argv[++i]);
            else if (strcmp(argv[i], "--port") == 0 && i + 1 < argc) {
                char *end = NULL; long value = strtol(argv[++i], &end, 10);
                if (!end || *end || value < 1 || value > UINT16_MAX) return 64; port = (uint16_t)value;
            } else return 64;
        }
        NSData *key = keyPath ? load_key(keyPath)
            : [NSData dataWithBytes:rv_local_wire_key() length:64];
        if (!key) { fprintf(stderr, "[media] missing private pairing key\n"); return 78; }
        signal(SIGTERM, stop_service); signal(SIGINT, stop_service); signal(SIGPIPE, SIG_IGN);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ accept_clients(key, fixture, port); });
        if (fixture) CFRunLoopRun();
        else { [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory]; privacyMenu=[RVPrivacyMenu new]; [NSApp run]; }
    }
    return 0;
}
