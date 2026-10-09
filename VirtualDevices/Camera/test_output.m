/* Synthetic images and a local sample queue only: never opens or registers a device. */
#include <assert.h>
#include <stdio.h>
#import "../../TargetBridge-Sender/TBDisplayShared/TBVirtualMediaOutput.m"

static NSData *imageData(size_t width, size_t height, CFStringRef type) {
    NSMutableData *raw = [NSMutableData dataWithLength:width*height*4];
    uint8_t *pixels = raw.mutableBytes;
    for (size_t y=0;y<height;y++) for(size_t x=0;x<width;x++) {
        size_t i=(y*width+x)*4; pixels[i]=y<height/2?0:255;
        pixels[i+2]=y<height/2?255:0; pixels[i+3]=255;
    }
    CGColorSpaceRef color=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context=CGBitmapContextCreate(pixels,width,height,8,width*4,color,
        (CGBitmapInfo)kCGBitmapByteOrder32Little|(CGBitmapInfo)kCGImageAlphaPremultipliedFirst);
    assert(context); CGImageRef image=CGBitmapContextCreateImage(context);
    NSMutableData *data=[NSMutableData data];
    CGImageDestinationRef destination=CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data,type,1,NULL);
    assert(destination); CGImageDestinationAddImage(destination,image,NULL);assert(CGImageDestinationFinalize(destination));
    CFRelease(destination);CGImageRelease(image);CGContextRelease(context);CGColorSpaceRelease(color);
    return data;
}
static int push(NSData *data) { return tb_virtual_camera_push_jpeg(data.bytes,data.length); }
int main(void) {
    @autoreleasepool {
        assert(CMSimpleQueueCreate(NULL,2,&cameraQueue)==noErr);
        assert(CVPixelBufferPoolCreate(NULL,NULL,(__bridge CFDictionaryRef)@{
            (id)kCVPixelBufferWidthKey:@1280,(id)kCVPixelBufferHeightKey:@720,
            (id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferIOSurfacePropertiesKey:@{}},&pixelPool)==kCVReturnSuccess);
        assert(tb_virtual_camera_push_jpeg(NULL,0)<0);
        assert(push(imageData(64,64,CFSTR("public.jpeg")))<0);
        assert(push(imageData(1280,720,CFSTR("public.png")))<0);
        assert(push([NSData dataWithBytes:"garbage" length:7])<0);
        NSData *jpeg=imageData(1280,720,CFSTR("public.jpeg"));
        assert(jpeg.length<=262144&&push(jpeg)==0);
        CMSampleBufferRef sample=(CMSampleBufferRef)CMSimpleQueueDequeue(cameraQueue);assert(sample);
        CVPixelBufferRef pixels=CMSampleBufferGetImageBuffer(sample);assert(pixels);
        assert(CVPixelBufferGetWidth(pixels)==1280&&CVPixelBufferGetHeight(pixels)==720);
        assert(CVPixelBufferLockBaseAddress(pixels,kCVPixelBufferLock_ReadOnly)==kCVReturnSuccess);
        const uint8_t *top=CVPixelBufferGetBaseAddress(pixels);
        const uint8_t *bottom=top+719*CVPixelBufferGetBytesPerRow(pixels);
        assert(top[2]>240&&top[0]<15&&bottom[0]>240&&bottom[2]<15); // Orientation and BGRA channels.
        CVPixelBufferUnlockBaseAddress(pixels,kCVPixelBufferLock_ReadOnly);CFRelease(sample);
        assert(push(jpeg)==0&&push(jpeg)==0&&push(jpeg)==1); // Backpressure stays bounded.
        tb_virtual_camera_stop();assert(!cameraQueue&&!pixelPool);
        puts("Camera JPEG type/dimensions, orientation, BGRA, bounded queue and cleanup tests passed.");
    }
    return 0;
}
