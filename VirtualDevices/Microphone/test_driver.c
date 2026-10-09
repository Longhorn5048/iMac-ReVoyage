/* No HAL installation or hardware calls: exercise the plug-in interface and
 * lock-free ring directly with an in-process synthetic host. */
#include <assert.h>
#include <stdio.h>
#include "driver.c"

static OSStatus notify(AudioServerPlugInHostRef context,AudioObjectID object,UInt32 count,const AudioObjectPropertyAddress *addresses) {
    (void)context;(void)object;(void)count;(void)addresses;return noErr;
}
static void *produce(void *unused) {
    (void)unused;for(uint64_t i=0;i<500000;i++)rv_mic_write(&ring,i,(float)(i%1000)/1000.0f);return NULL;
}
int main(void) {
    AudioServerPlugInHostInterface mock={.PropertiesChanged=notify};
    assert(initialize(driver,&mock)==noErr);
    assert(atomic_is_lock_free(&ring.stamp[0])&&atomic_is_lock_free(&ring.bits[0]));
    UInt32 size=0,integer=0;AudioObjectPropertyAddress a={kAudioDevicePropertyStreams,kAudioObjectPropertyScopeInput,kAudioObjectPropertyElementMain};
    assert(dataGet(driver,deviceID,0,&a,0,NULL,4,&size,&integer)==noErr&&integer==streamID&&size==4);
    a.mScope=kAudioObjectPropertyScopeOutput;assert(dataSize(driver,deviceID,0,&a,0,NULL,&size)==noErr&&size==0);
    a.mSelector=kAudioDevicePropertyStreamConfiguration;UInt32 bufferSize=0;assert(dataSize(driver,deviceID,0,&a,0,NULL,&bufferSize)==noErr);
    AudioBufferList configuration;assert(dataGet(driver,deviceID,0,&a,0,NULL,sizeof(configuration),&size,&configuration)==noErr&&configuration.mNumberBuffers==0);
    a.mScope=kAudioObjectPropertyScopeInput;assert(dataGet(driver,deviceID,0,&a,0,NULL,sizeof(configuration),&size,&configuration)==noErr&&configuration.mNumberBuffers==1&&configuration.mBuffers[0].mNumberChannels==1);
    a.mSelector=kAudioDevicePropertyNominalSampleRate;Float64 rate=0;assert(dataGet(driver,deviceID,0,&a,0,NULL,sizeof(rate),&size,&rate)==noErr&&rate==48000);
    assert(dataGet(driver,deviceID,0,&a,0,NULL,1,&size,&integer)==kAudioHardwareBadPropertySizeError);
    a.mSelector=RV_MIC_PUSH;float input[480]={0};assert(dataSet(driver,deviceID,getpid(),&a,0,NULL,sizeof(input),input)==kAudioHardwareIllegalOperationError);
    assert(startIO(driver,deviceID,1)==noErr);Float64 sample;UInt64 tick,seed;
    assert(timestamp(driver,deviceID,1,&sample,&tick,&seed)==noErr&&tick>0&&seed>1);
    rv_mic_write(&ring,100,.25f);assert(rv_mic_read(&ring,100)==.25f&&rv_mic_read(&ring,101)==0);
    rv_mic_write(&ring,100+RV_MIC_RING_FRAMES,.5f);assert(rv_mic_read(&ring,100)==0);
    rv_mic_clear(&ring);for(int i=0;i<512;i++)rv_mic_write(&ring,i,.125f);
    AudioServerPlugInIOCycleInfo cycle={0};cycle.mInputTime.mSampleTime=0;float first[512],second[512];
    assert(performIO(driver,deviceID,streamID,1,kAudioServerPlugInIOOperationReadInput,512,&cycle,first,NULL)==noErr);
    assert(performIO(driver,deviceID,streamID,2,kAudioServerPlugInIOOperationReadInput,512,&cycle,second,NULL)==noErr);
    assert(memcmp(first,second,sizeof(first))==0&&first[0]==.125f);
    rv_mic_clear(&ring);assert(performIO(driver,deviceID,streamID,1,kAudioServerPlugInIOOperationReadInput,512,&cycle,first,NULL)==noErr);
    for(int i=0;i<512;i++)assert(first[i]==0);
    cycle.mInputTime.mSampleTime=NAN;assert(performIO(driver,deviceID,streamID,1,kAudioServerPlugInIOOperationReadInput,512,&cycle,first,NULL)==noErr);
    assert(performIO(driver,deviceID,streamID,1,kAudioServerPlugInIOOperationReadInput,RV_MIC_MAX_FRAMES+1,&cycle,first,NULL)==kAudioHardwareIllegalOperationError);
    assert(stopIO(driver,deviceID,1)==noErr&&atomic_load(&anchor)==0);
    UInt64 previousSeed=seed;assert(startIO(driver,deviceID,1)==noErr);assert(timestamp(driver,deviceID,1,&sample,&tick,&seed)==noErr&&seed>previousSeed);assert(stopIO(driver,deviceID,1)==noErr);
    pthread_t producer;assert(pthread_create(&producer,NULL,produce,NULL)==0);
    for(uint64_t i=0;i<500000;i++){float result=rv_mic_read(&ring,i);assert(result==0||result==(float)(i%1000)/1000.0f);}
    assert(pthread_join(producer,NULL)==0);
    puts("Microphone properties, bounds, silence, clock restart, multi-client and concurrent ring tests passed.");return 0;
}
