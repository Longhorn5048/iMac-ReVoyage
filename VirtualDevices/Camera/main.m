#import <Foundation/Foundation.h>
#import <CoreMediaIO/CoreMediaIO.h>
#import <CoreAudio/CoreAudio.h>
#import <Security/Security.h>

@class RVCamera;
@interface RVProvider : NSObject <CMIOExtensionProviderSource>
@property(nonatomic,weak) RVCamera *camera;
@end
@interface RVStream : NSObject <CMIOExtensionStreamSource>
@property(nonatomic,weak) RVCamera *camera;
@property(nonatomic,strong) CMIOExtensionStream *stream;
@property(nonatomic,strong) CMIOExtensionClient *client;
@property(nonatomic) BOOL sink;
@property(nonatomic) NSUInteger users;
@end
@interface RVCamera : NSObject <CMIOExtensionDeviceSource>
@property(nonatomic,strong) RVProvider *providerSource;
@property(nonatomic,strong) CMIOExtensionProvider *provider;
@property(nonatomic,strong) CMIOExtensionDevice *device;
@property(nonatomic,strong) RVStream *source, *sink;
@property(nonatomic,strong) NSArray<CMIOExtensionStreamFormat *> *formats;
@property(nonatomic,strong) dispatch_queue_t queue;
@property(nonatomic,strong) dispatch_source_t timer;
@property(nonatomic,strong) id latestSample; // ARC owns this toll-free bridged CMSampleBuffer.
@property(nonatomic) CVPixelBufferRef black;
@property(nonatomic) double latestTime;
@property(nonatomic) BOOL consuming;
@property(nonatomic) NSUInteger generation;
- (void)updateTimer;
- (void)tick;
@end

static BOOL senderClient(CMIOExtensionClient *client) {
    NSString *team = NSBundle.mainBundle.infoDictionary[@"ReVoyageSigningTeam"];
    if (!team.length) return NO; // Unsigned development builds cannot accept a sink producer.
    NSString *text = [NSString stringWithFormat:@"identifier \"com.targetbridge.sender\" and anchor apple generic and certificate leaf[subject.OU] = \"%@\"", team];
    SecCodeRef code = NULL; SecRequirementRef requirement = NULL;
    BOOL valid = SecCodeCopyGuestWithAttributes(NULL, (__bridge CFDictionaryRef)@{(__bridge id)kSecGuestAttributePid:@(client.pid)},
        kSecCSDefaultFlags, &code) == errSecSuccess &&
        SecRequirementCreateWithString((__bridge CFStringRef)text, kSecCSDefaultFlags, &requirement) == errSecSuccess &&
        SecCodeCheckValidity(code, kSecCSDefaultFlags, requirement) == errSecSuccess;
    if (requirement) CFRelease(requirement); if (code) CFRelease(code); return valid;
}
@implementation RVStream
- (NSArray *)formats { return _camera.formats; }
- (NSSet *)availableProperties {
    NSArray *properties = @[CMIOExtensionPropertyStreamActiveFormatIndex, CMIOExtensionPropertyStreamFrameDuration];
    if (_sink) properties = [properties arrayByAddingObjectsFromArray:@[CMIOExtensionPropertyStreamSinkBufferQueueSize,
        CMIOExtensionPropertyStreamSinkBuffersRequiredForStartup]];
    return [NSSet setWithArray:properties];
}
- (CMIOExtensionStreamProperties *)streamPropertiesForProperties:(NSSet *)properties error:(NSError **)error {
    (void)properties; (void)error;
    CMIOExtensionStreamProperties *result = [CMIOExtensionStreamProperties streamPropertiesWithDictionary:@{}];
    result.activeFormatIndex = @0; result.frameDuration = CFBridgingRelease(CMTimeCopyAsDictionary(CMTimeMake(1,20), NULL));
    if (_sink) { result.sinkBufferQueueSize = @2; result.sinkBuffersRequiredForStartup = @1; }
    return result;
}
- (BOOL)setStreamProperties:(CMIOExtensionStreamProperties *)properties error:(NSError **)error {
    BOOL valid = (!properties.activeFormatIndex || properties.activeFormatIndex.unsignedIntegerValue == 0) &&
        (!properties.frameDuration || CMTimeCompare(CMTimeMakeFromDictionary((__bridge CFDictionaryRef)properties.frameDuration), CMTimeMake(1,20)) == 0);
    if (!valid && error) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:kCMIOHardwareUnsupportedOperationError userInfo:nil];
    return valid;
}
- (BOOL)authorizedToStartStreamForClient:(CMIOExtensionClient *)client {
    if (!_sink) return YES; // CoreMediaIO enforces each consuming app's camera permission.
    if ((_client && _client.pid != client.pid) || !senderClient(client)) return NO;
    _client = client; return YES;
}
- (BOOL)startStreamAndReturnError:(NSError **)error { (void)error; ++_users; [_camera updateTimer]; return YES; }
- (BOOL)stopStreamAndReturnError:(NSError **)error {
    (void)error; if (_users) --_users;
    if (_sink && !_users) { _client = nil; ++_camera.generation; }
    [_camera updateTimer]; return YES;
}
@end

@implementation RVProvider
- (NSSet *)availableProperties { return [NSSet setWithObject:CMIOExtensionPropertyProviderManufacturer]; }
- (BOOL)connectClient:(CMIOExtensionClient *)client error:(NSError **)error { (void)client;(void)error;return YES; }
- (void)disconnectClient:(CMIOExtensionClient *)client {
    if (_camera.sink.client.pid == client.pid) { _camera.sink.client=nil; _camera.sink.users=0; ++_camera.generation; [_camera updateTimer]; }
}
- (CMIOExtensionProviderProperties *)providerPropertiesForProperties:(NSSet *)properties error:(NSError **)error {
    (void)properties;(void)error; CMIOExtensionProviderProperties *result=[CMIOExtensionProviderProperties providerPropertiesWithDictionary:@{}];
    result.manufacturer=@"iMac ReVoyage"; return result;
}
- (BOOL)setProviderProperties:(CMIOExtensionProviderProperties *)properties error:(NSError **)error { (void)properties;(void)error;return NO; }
@end

@implementation RVCamera
- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("re.voyage.camera.extension", DISPATCH_QUEUE_SERIAL);
        _providerSource = [RVProvider new]; _providerSource.camera = self;
        _provider = [CMIOExtensionProvider providerWithSource:_providerSource clientQueue:_queue];
        _device = [[CMIOExtensionDevice alloc] initWithLocalizedName:@"ReVoyage — iMac Camera"
            deviceID:[[NSUUID alloc] initWithUUIDString:@"F184CD79-9C61-47CA-9C1C-E8A7B02E64DD"] legacyDeviceID:@"re.voyage.imac.camera" source:self];
        CMVideoFormatDescriptionRef description = NULL;
        CMVideoFormatDescriptionCreate(NULL, kCVPixelFormatType_32BGRA, 1280, 720, NULL, &description);
        _formats = @[[CMIOExtensionStreamFormat streamFormatWithFormatDescription:description maxFrameDuration:CMTimeMake(1,20)
            minFrameDuration:CMTimeMake(1,20) validFrameDurations:nil]]; CFRelease(description);
        _source = [RVStream new]; _source.camera = self;
        _source.stream = [CMIOExtensionStream streamWithLocalizedName:@"iMac Camera"
            streamID:[[NSUUID alloc] initWithUUIDString:@"60C8AA59-E660-499F-BB1B-3803055C6A2A"]
            direction:CMIOExtensionStreamDirectionSource clockType:CMIOExtensionStreamClockTypeHostTime source:_source];
        _sink = [RVStream new]; _sink.camera = self; _sink.sink = YES;
        _sink.stream = [CMIOExtensionStream streamWithLocalizedName:@"ReVoyage Camera Input"
            streamID:[[NSUUID alloc] initWithUUIDString:@"D973A6F2-452D-47A7-89D8-330B94195E4C"]
            direction:CMIOExtensionStreamDirectionSink clockType:CMIOExtensionStreamClockTypeHostTime source:_sink];
        NSError *error = nil;
        if (![_device addStream:_source.stream error:&error] || ![_device addStream:_sink.stream error:&error] ||
            ![_provider addDevice:_device error:&error]) { NSLog(@"Camera registration failed: %@",error); return nil; }
        if (CVPixelBufferCreate(NULL,1280,720,kCVPixelFormatType_32BGRA,
            (__bridge CFDictionaryRef)@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{}},&_black) != kCVReturnSuccess) return nil;
        CVPixelBufferLockBaseAddress(_black,0); uint8_t *base=CVPixelBufferGetBaseAddress(_black);
        size_t stride=CVPixelBufferGetBytesPerRow(_black);
        for (size_t y=0;y<720;y++) { memset(base+y*stride,0,stride); for(size_t x=0;x<1280;x++) base[y*stride+x*4+3]=255; }
        CVPixelBufferUnlockBaseAddress(_black,0);
    }
    return self;
}
- (void)dealloc { if (_black) CFRelease(_black); }
- (NSSet *)availableProperties { return [NSSet setWithArray:@[CMIOExtensionPropertyDeviceModel,CMIOExtensionPropertyDeviceTransportType]]; }
- (CMIOExtensionDeviceProperties *)devicePropertiesForProperties:(NSSet *)properties error:(NSError **)error {
    (void)properties;(void)error; CMIOExtensionDeviceProperties *result=[CMIOExtensionDeviceProperties devicePropertiesWithDictionary:@{}];
    result.model=@"iMac Camera Bridge"; result.transportType=@(kAudioDeviceTransportTypeVirtual); return result;
}
- (BOOL)setDeviceProperties:(CMIOExtensionDeviceProperties *)properties error:(NSError **)error { (void)properties;(void)error;return NO; }
- (void)updateTimer {
    if (!_sink.users) _latestSample=nil;
    if (_source.users && !_timer) {
        _timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,_queue);
        dispatch_source_set_timer(_timer,dispatch_time(DISPATCH_TIME_NOW,0),NSEC_PER_SEC/20,NSEC_PER_MSEC);
        __weak RVCamera *weak=self; dispatch_source_set_event_handler(_timer,^{[weak tick];}); dispatch_resume(_timer);
    } else if (!_source.users && _timer) {
        dispatch_source_cancel(_timer); _timer=nil; ++_generation;
        _latestSample=nil;
    }
}
- (void)tick {
    @autoreleasepool {
    if (_sink.users && _sink.client && !_consuming) {
        _consuming=YES; NSUInteger generation=_generation;
        [_sink.stream consumeSampleBufferFromClient:_sink.client completionHandler:^(CMSampleBufferRef sample,uint64_t sequence,
            CMIOExtensionStreamDiscontinuityFlags flags,BOOL more,NSError *error) {
            (void)flags;(void)more;(void)error;
            if(sample) CFRetain(sample);
            dispatch_async(self.queue,^{ @autoreleasepool {
                self.consuming=NO;
                CVPixelBufferRef pixels=sample ? CMSampleBufferGetImageBuffer(sample) : NULL;
                if(generation==self.generation && self.sink.users && pixels && CVPixelBufferGetWidth(pixels)==1280 &&
                    CVPixelBufferGetHeight(pixels)==720 && CVPixelBufferGetPixelFormatType(pixels)==kCVPixelFormatType_32BGRA) {
                    self.latestSample=(__bridge id)sample;
                    self.latestTime=NSProcessInfo.processInfo.systemUptime;
                    CMIOExtensionScheduledOutput *scheduled=[CMIOExtensionScheduledOutput scheduledOutputWithSequenceNumber:sequence
                        hostTimeInNanoseconds:(uint64_t)(CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))*1e9)];
                    [self.sink.stream notifyScheduledOutputChanged:scheduled];
                }
                if(sample) CFRelease(sample);
            } });
        }];
    }
    CMTime now=CMClockGetTime(CMClockGetHostTimeClock()); CMSampleTimingInfo timing={CMTimeMake(1,20),now,kCMTimeInvalid};
    CMSampleBufferRef result=NULL;
    if(_latestSample && NSProcessInfo.processInfo.systemUptime-_latestTime<0.25) CMSampleBufferCreateCopyWithNewTiming(NULL,(__bridge CMSampleBufferRef)_latestSample,1,&timing,&result);
    else {
        CMVideoFormatDescriptionRef description=NULL; CMVideoFormatDescriptionCreateForImageBuffer(NULL,_black,&description);
        CMSampleBufferCreateReadyWithImageBuffer(NULL,_black,description,&timing,&result); if(description)CFRelease(description);
    }
    if(result) { [_source.stream sendSampleBuffer:result discontinuity:CMIOExtensionStreamDiscontinuityFlagNone
        hostTimeInNanoseconds:(uint64_t)(CMTimeGetSeconds(now)*1e9)]; CFRelease(result); }
    }
}
@end
int main(void) {
    @autoreleasepool { static RVCamera *camera; camera=[RVCamera new]; if(!camera)return 70;
        [CMIOExtensionProvider startServiceWithProvider:camera.provider]; CFRunLoopRun(); }
    return 0;
}
