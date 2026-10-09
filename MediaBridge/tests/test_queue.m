#define main rv_media_service_main
#include "../main.m"
#undef main
#include <assert.h>
int main(void) {
    @autoreleasepool {
        int fds[2];assert(socketpair(AF_UNIX,SOCK_STREAM,0,fds)==0);
        RVWriter *writer=[[RVWriter alloc] initWithFD:fds[0]];
        NSData *large=[NSMutableData dataWithLength:262152];
        for(int i=0;i<100;i++)assert([writer enqueue:RV_MEDIA_JPEG data:large]);
        assert(writer.messages.count==1 && writer.queuedBytes==262157 && !writer.closed);
        NSData *audio=[NSMutableData dataWithLength:1928];
        for(int i=0;i<5;i++)assert([writer enqueue:RV_MEDIA_PCM data:audio]);
        assert(writer.queuedPCMBytes==9665 && writer.queuedBytes<RV_MEDIA_MAX_QUEUED);
        assert(![writer enqueue:RV_MEDIA_PCM data:audio] && writer.closed);
        close(fds[0]);close(fds[1]);
        int fresh[2];assert(socketpair(AF_UNIX,SOCK_STREAM,0,fresh)==0);
        // A delayed callback on the old writer must not shut down reused fds.
        [writer close];char sent='x',received=0;assert(send(fresh[0],&sent,1,0)==1 && recv(fresh[1],&received,1,0)==1 && received=='x');
        close(fresh[0]);close(fresh[1]);
        int pending[2];assert(socketpair(AF_UNIX,SOCK_STREAM,0,pending)==0);
        RVWriter *promptWriter=[[RVWriter alloc] initWithFD:pending[0]];
        NSData *heartbeat=packet(RV_MEDIA_HEARTBEAT,NSData.data);
        assert(send(pending[1],heartbeat.bytes,heartbeat.length,0)==(ssize_t)heartbeat.length);
        assert(permission_peer_alive(promptWriter));
        // Peer EOF behind buffered heartbeats must be detected before capture.
        for(int i=0;i<3;i++)assert(send(pending[1],heartbeat.bytes,heartbeat.length,0)==(ssize_t)heartbeat.length);
        shutdown(pending[1],SHUT_WR);assert(!permission_peer_alive(promptWriter)&&promptWriter.closed);
        close(pending[0]);close(pending[1]);
        int generation[2]; assert(socketpair(AF_UNIX, SOCK_STREAM, 0, generation) == 0);
        RVWriter *barrier = [[RVWriter alloc] initWithFD:generation[0]];
        assert([barrier enqueue:RV_MEDIA_PCM data:audio]);
        assert([barrier enqueue:RV_MEDIA_JPEG data:large]);
        assert([barrier enqueue:RV_MEDIA_HEARTBEAT data:NSData.data]);
        RVCapture *capture = [RVCapture new]; capture.writer = barrier;
        // Real delegate entry points discard even a sample arriving while the
        // newly started sessions are waiting for their final status ACK.
        CMSampleBufferRef emptySample = NULL;
        assert(CMSampleBufferCreate(kCFAllocatorDefault, NULL, YES, NULL, NULL, NULL, 0, 0, NULL, 0, NULL, &emptySample) == noErr);
        // This fixture has no physical input ports; the delegate does not use
        // its connection argument. Only suppress the inherited nonnull warning.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnonnull"
        [capture captureOutput:[AVCaptureAudioDataOutput new] didOutputSampleBuffer:emptySample fromConnection:nil];
        [capture captureOutput:[AVCaptureVideoDataOutput new] didOutputSampleBuffer:emptySample fromConnection:nil];
#pragma clang diagnostic pop
        CFRelease(emptySample);
        assert(barrier.messages.count == 3);
        [barrier discardMedia];
        assert(barrier.messages.count == 1 && barrier.queuedPCMBytes == 0 && barrier.queuedBytes == 5);
        assert([barrier enqueue:RV_MEDIA_STATUS data:json(@{@"schema":@1,@"cameraActive":@YES,@"microphoneActive":@YES,@"error":@""})]);
        [capture publishAfterStatus];
        assert(capture.videoPublishing && capture.audioPublishing);
        assert([barrier enqueue:RV_MEDIA_PCM data:audio]);
        assert([barrier.messages[1][@"type"] unsignedCharValue] == RV_MEDIA_STATUS);
        assert([barrier.messages[2][@"type"] unsignedCharValue] == RV_MEDIA_PCM);
        [capture stop]; assert(!capture.videoPublishing && !capture.audioPublishing);
        [capture publishAfterStatus]; assert(!capture.videoPublishing && !capture.audioPublishing);
        [barrier close]; close(generation[0]); close(generation[1]);
        assert(!valid_request(@{@"schema":@YES}));assert(valid_request(@{@"schema":@1}));
        struct rv_rate_limit rate = rv_rate_limit_create(1, 1000, 10);
        assert(rv_rate_limit_admit(&rate, 1000, 10));
        assert(!rv_rate_limit_admit(&rate, 1, 10));
        assert(rv_rate_limit_admit(&rate, 500, 10.00401));
        assert(!rv_rate_limit_admit(&rate, 501, 10.00401));
        assert(!rv_rate_limit_admit(&rate, 1, NAN));
        assert(!rv_rate_limit_admit(&rate, 1, 9));
        assert(!rv_rate_limit_admit(&rate, 1001, 20));
        assert(valid_request(@{@"schema":@1, @"cameraID":@"fixture-camera", @"cameraMbps":@1}));
        for (id value in @[@YES, @"25", @0, @(-1), @1001, @(NAN)])
            assert(!valid_request(@{@"schema":@1, @"cameraMbps":value}));
        puts("Media queue replacement, bounds, audio latency cap, closed-fd reuse and permission-wait disconnect tests passed.");
    }
    return 0;
}
