#import <Foundation/Foundation.h>
#import <CoreMediaIO/CoreMediaIO.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
#import "TBVirtualMediaOutput.h"
#include "../../VirtualDevices/Microphone/ring.h"

/* Called exclusively by the independent media transport's serial queue. */
static CMIODeviceID cameraDevice;
static CMIOStreamID cameraStream;
static CMSimpleQueueRef cameraQueue;
static CVPixelBufferPoolRef pixelPool;
static AudioDeviceID microphoneDevice;

static NSData *cmioProperty(CMIOObjectID object,UInt32 selector,UInt32 scope) {
    CMIOObjectPropertyAddress a={selector,scope,kCMIOObjectPropertyElementMain}; UInt32 size=0;
    if(CMIOObjectGetPropertyDataSize(object,&a,0,NULL,&size)!=noErr||size>8192)return nil;
    NSMutableData *data=[NSMutableData dataWithLength:size];
    return CMIOObjectGetPropertyData(object,&a,0,NULL,size,&size,data.mutableBytes)==noErr?data:nil;
}
int tb_virtual_camera_start(void) {
    @autoreleasepool {
    if(cameraDevice)return 0;
    NSData *devices=cmioProperty(kCMIOObjectSystemObject,kCMIOHardwarePropertyDevices,kCMIOObjectPropertyScopeGlobal);
    const CMIODeviceID *ids=devices.bytes;
    for(NSUInteger i=0;i<devices.length/sizeof(CMIODeviceID);i++) {
        CMIOObjectPropertyAddress a={kCMIODevicePropertyDeviceUID,kCMIOObjectPropertyScopeGlobal,kCMIOObjectPropertyElementMain};
        CFStringRef uid=NULL;UInt32 size=sizeof(uid);
        if(CMIOObjectGetPropertyData(ids[i],&a,0,NULL,size,&size,&uid)!=noErr||!uid)continue;
        BOOL match=CFEqual(uid,CFSTR("re.voyage.imac.camera"));CFRelease(uid);if(!match)continue;
        NSData *streams=cmioProperty(ids[i],kCMIODevicePropertyStreams,kCMIODevicePropertyScopeOutput);
        if(streams.length!=sizeof(CMIOStreamID))return -1;
        CMIOStreamID stream;memcpy(&stream,streams.bytes,sizeof(stream));
        CMSimpleQueueRef queue=NULL;OSStatus status=CMIOStreamCopyBufferQueue(stream,NULL,NULL,&queue);
        if(status!=noErr||!queue)return (int)(status?:-1);
        CVPixelBufferPoolRef pool=NULL;
        CVReturn result=CVPixelBufferPoolCreate(NULL,NULL,(__bridge CFDictionaryRef)@{
            (id)kCVPixelBufferWidthKey:@1280,(id)kCVPixelBufferHeightKey:@720,
            (id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferIOSurfacePropertiesKey:@{}},&pool);
        if(result!=kCVReturnSuccess){CFRelease(queue);return result;}
        status=CMIODeviceStartStream(ids[i],stream);
        if(status!=noErr){CFRelease(pool);CFRelease(queue);return (int)status;}
        cameraDevice=ids[i];cameraStream=stream;cameraQueue=queue;pixelPool=pool;return 0;
    }
    return -1;
    }
}
void tb_virtual_camera_stop(void) {
    if(cameraDevice)CMIODeviceStopStream(cameraDevice,cameraStream);
    cameraDevice=0;cameraStream=0;
    if(cameraQueue){const void *sample;while((sample=CMSimpleQueueDequeue(cameraQueue)))CFRelease(sample);CFRelease(cameraQueue);cameraQueue=NULL;}
    if(pixelPool){CFRelease(pixelPool);pixelPool=NULL;}
}
int tb_virtual_camera_push_jpeg(const uint8_t *bytes,size_t size) {
    @autoreleasepool {
    if(!cameraQueue||!bytes||size<4||size>262144)return -1;
    if(CMSimpleQueueGetFullness(cameraQueue)>=1)return 1;
    NSData *data=[NSData dataWithBytesNoCopy:(void *)bytes length:size freeWhenDone:NO];
    CGImageSourceRef source=CGImageSourceCreateWithData((__bridge CFDataRef)data,NULL);if(!source)return -1;
    if (!CGImageSourceGetType(source) || !CFEqual(CGImageSourceGetType(source),CFSTR("public.jpeg"))) { CFRelease(source); return -1; }
    NSDictionary *properties=CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source,0,NULL));
    if([properties[(id)kCGImagePropertyPixelWidth] integerValue]!=1280||
       [properties[(id)kCGImagePropertyPixelHeight] integerValue]!=720||CGImageSourceGetCount(source)!=1){CFRelease(source);return -1;}
    CGImageRef image=CGImageSourceCreateImageAtIndex(source,0,(__bridge CFDictionaryRef)@{(id)kCGImageSourceShouldCacheImmediately:@YES});
    CFRelease(source);if(!image)return -1;
    CVPixelBufferRef pixels=NULL;
    CVReturn result=CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(NULL,pixelPool,
        (__bridge CFDictionaryRef)@{(id)kCVPixelBufferPoolAllocationThresholdKey:@4},&pixels);
    if(result!=kCVReturnSuccess){CGImageRelease(image);return 1;}
    CVPixelBufferLockBaseAddress(pixels,0);CGColorSpaceRef color=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context=CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pixels),1280,720,8,CVPixelBufferGetBytesPerRow(pixels),
        color,(CGBitmapInfo)kCGBitmapByteOrder32Little|(CGBitmapInfo)kCGImageAlphaPremultipliedFirst);CGColorSpaceRelease(color);
    if(context){CGContextDrawImage(context,CGRectMake(0,0,1280,720),image);CGContextRelease(context);}
    CGImageRelease(image);CVPixelBufferUnlockBaseAddress(pixels,0);
    if(!context){CFRelease(pixels);return -1;}
    CMVideoFormatDescriptionRef format=NULL;CMSampleBufferRef sample=NULL;
    CMTime now=CMClockGetTime(CMClockGetHostTimeClock());CMSampleTimingInfo timing={CMTimeMake(1,20),now,kCMTimeInvalid};
    OSStatus status=CMVideoFormatDescriptionCreateForImageBuffer(NULL,pixels,&format);
    if(status==noErr)status=CMSampleBufferCreateReadyWithImageBuffer(NULL,pixels,format,&timing,&sample);
    CFRelease(pixels);if(format)CFRelease(format);if(status!=noErr||!sample)return -1;
    status=CMSimpleQueueEnqueue(cameraQueue,sample);if(status!=noErr)CFRelease(sample);return status==noErr?0:1;
    }
}
static AudioDeviceID findMicrophone(void) {
    AudioObjectPropertyAddress list={kAudioHardwarePropertyDevices,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};UInt32 size=0;
    if(AudioObjectGetPropertyDataSize(kAudioObjectSystemObject,&list,0,NULL,&size)!=noErr||size>8192)return 0;
    NSMutableData *data=[NSMutableData dataWithLength:size];
    if(AudioObjectGetPropertyData(kAudioObjectSystemObject,&list,0,NULL,&size,data.mutableBytes)!=noErr)return 0;
    const AudioDeviceID *ids=data.bytes;
    for(NSUInteger i=0;i<size/sizeof(AudioDeviceID);i++) {
        AudioObjectPropertyAddress a={kAudioDevicePropertyDeviceUID,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
        CFStringRef uid=NULL;UInt32 bytes=sizeof(uid);
        if(AudioObjectGetPropertyData(ids[i],&a,0,NULL,&bytes,&uid)!=noErr||!uid)continue;
        BOOL match=CFEqual(uid,CFSTR("re.voyage.imac.microphone"));CFRelease(uid);if(match)return ids[i];
    }
    return 0;
}
int tb_virtual_microphone_start(void) {
    @autoreleasepool {
    AudioDeviceID device=findMicrophone();if(!device)return -1;
    AudioObjectPropertyAddress a={RV_MIC_CLEAR,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};UInt32 clear=1;
    OSStatus status=AudioObjectSetPropertyData(device,&a,0,NULL,sizeof(clear),&clear);
    if(status==noErr)microphoneDevice=device;return (int)status;
    }
}
void tb_virtual_microphone_stop(void) {
    if(!microphoneDevice)return;
    AudioObjectPropertyAddress a={RV_MIC_CLEAR,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};UInt32 clear=1;
    AudioObjectSetPropertyData(microphoneDevice,&a,0,NULL,sizeof(clear),&clear);microphoneDevice=0;
}
int tb_virtual_microphone_push_pcm(const uint8_t *bytes,size_t size) {
    if(!microphoneDevice||!bytes||size==0||size>1920||size%2)return -1;
    float samples[960];for(size_t i=0;i<size/2;i++){int16_t value=(int16_t)((uint16_t)bytes[i*2]|((uint16_t)bytes[i*2+1]<<8));samples[i]=value/32768.0f;}
    AudioObjectPropertyAddress a={RV_MIC_PUSH,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
    return (int)AudioObjectSetPropertyData(microphoneDevice,&a,0,NULL,(UInt32)(size*2),samples);
}
