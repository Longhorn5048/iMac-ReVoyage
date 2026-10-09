/* Synthetic HAL host only: no driver installation, audio hardware or playback. */
#include <assert.h>
#include <stdio.h>
#include <unistd.h>
#include "driver.c"
static unsigned volumeNotifications,muteNotifications,legacyVolumeNotifications,legacyMuteNotifications;
static OSStatus notify(AudioServerPlugInHostRef h,AudioObjectID o,UInt32 n,const AudioObjectPropertyAddress *a) {
    (void)h;
    for(unsigned i=0;i<n;i++) {
        if(o==volumeID)volumeNotifications++;
        if(o==muteID)muteNotifications++;
        if(o==deviceID&&a[i].mSelector==kAudioDevicePropertyVolumeScalar)legacyVolumeNotifications++;
        if(o==deviceID&&a[i].mSelector==kAudioDevicePropertyMute)legacyMuteNotifications++;
    }
    return noErr;
}
/* Simulate the actual HAL process boundary: property metadata must allow
 * marshalling, and a returned CFData must survive property-list serialization. */
static OSStatus pcmGet(AudioServerPlugInDriverRef self,AudioObjectID object,pid_t pid,
    const AudioObjectPropertyAddress *a,UInt32 q,const void *qualifier,UInt32 capacity,UInt32 *size,void *out) {
    if(capacity%4)return kAudioHardwareBadPropertySizeError;
    AudioObjectPropertyAddress metadata={kAudioObjectPropertyCustomPropertyInfoList,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
    AudioServerPlugInCustomPropertyInfo properties[2];UInt32 metadataSize;
    assert(dataGet(self,object,pid,&metadata,0,NULL,sizeof(properties),&metadataSize,properties)==noErr);
    assert(properties[0].mSelector==RV_SPEAKER_PULL&&properties[0].mPropertyDataType==kAudioServerPlugInCustomPropertyDataTypeCFPropertyList);
    CFDataRef packet=NULL;UInt32 pointerSize=0;
    OSStatus status=dataGet(self,object,pid,a,q,qualifier,sizeof(packet),&pointerSize,&packet);
    if(status!=noErr)return status;
    assert(pointerSize==sizeof(packet)&&packet&&CFGetTypeID(packet)==CFDataGetTypeID());
    CFDataRef serialized=CFPropertyListCreateData(NULL,packet,kCFPropertyListBinaryFormat_v1_0,0,NULL);
    assert(serialized);CFDataRef received=CFPropertyListCreateWithData(NULL,serialized,0,NULL,NULL);
    assert(received&&CFGetTypeID(received)==CFDataGetTypeID());
    *size=(UInt32)CFDataGetLength(received);
    status=*size>capacity?kAudioHardwareBadPropertySizeError:noErr;
    if(status==noErr&&*size)memcpy(out,CFDataGetBytePtr(received),*size);
    CFRelease(received);CFRelease(serialized);CFRelease(packet);return status;
}
static void *produce(void *unused) {
    (void)unused;
    for(uint64_t frame=0;frame<500000;frame+=128) {
        float samples[256];
        for(unsigned i=0;i<128;i++){samples[2*i]=(float)((frame+i)%1000)/1000;samples[2*i+1]=-samples[2*i];}
        rv_speaker_write(&ring,samples,128,1);
    }
    return NULL;
}
int main(void) {
    AudioServerPlugInHostInterface mock={.PropertiesChanged=notify};
    assert(initialize(driver,&mock)==noErr);
    assert(atomic_is_lock_free(&ring.stamp[0])&&atomic_is_lock_free(&ring.samples[0]));
    UInt32 size=0,id=0;AudioObjectPropertyAddress a={kAudioDevicePropertyStreams,kAudioObjectPropertyScopeOutput,kAudioObjectPropertyElementMain};
    assert(dataGet(driver,deviceID,0,&a,0,NULL,4,&size,&id)==noErr&&id==streamID&&size==4);
    a.mScope=kAudioObjectPropertyScopeInput;assert(dataSize(driver,deviceID,0,&a,0,NULL,&size)==noErr&&size==0);
    a.mSelector=kAudioDevicePropertyStreamConfiguration;AudioBufferList configuration;
    assert(dataGet(driver,deviceID,0,&a,0,NULL,sizeof(configuration),&size,&configuration)==noErr&&configuration.mNumberBuffers==0);
    a.mScope=kAudioObjectPropertyScopeOutput;
    assert(dataGet(driver,deviceID,0,&a,0,NULL,sizeof(configuration),&size,&configuration)==noErr&&configuration.mNumberBuffers==1&&configuration.mBuffers[0].mNumberChannels==2);
    a.mSelector=kAudioDevicePropertyDeviceCanBeDefaultDevice;
    assert(dataGet(driver,deviceID,0,&a,0,NULL,4,&size,&id)==noErr&&id==1);
    a.mScope=kAudioObjectPropertyScopeInput;
    assert(dataGet(driver,deviceID,0,&a,0,NULL,4,&size,&id)==noErr&&id==0);
    a.mScope=kAudioObjectPropertyScopeOutput;a.mSelector=kAudioStreamPropertyDirection;
    assert(dataGet(driver,streamID,0,&a,0,NULL,4,&size,&id)==noErr&&id==0);
    a.mSelector=kAudioStreamPropertyVirtualFormat;AudioStreamBasicDescription formatOut;
    assert(dataGet(driver,streamID,0,&a,0,NULL,sizeof(formatOut),&size,&formatOut)==noErr&&formatOut.mChannelsPerFrame==2&&formatOut.mSampleRate==48000&&formatOut.mBytesPerFrame==8);
    a.mSelector=kAudioDevicePropertyDeviceUID;CFStringRef uid=NULL;
    assert(dataGet(driver,deviceID,0,&a,0,NULL,sizeof(uid),&size,&uid)==noErr&&CFEqual(uid,CFSTR("re.voyage.imac.speaker")));CFRelease(uid);
    // Discover controls the same way the macOS sound menu does, rather than
    // bypassing enumeration and setting a known device selector directly.
    AudioObjectID controls[3]={0};a.mSelector=kAudioObjectPropertyControlList;a.mScope=kAudioObjectPropertyScopeGlobal;
    assert(dataGet(driver,deviceID,0,&a,0,NULL,sizeof(controls),&size,controls)==noErr&&size==8&&controls[0]==volumeID&&controls[1]==muteID);
    a.mSelector=kAudioObjectPropertyOwnedObjects;
    assert(dataGet(driver,deviceID,0,&a,0,NULL,sizeof(controls),&size,controls)==noErr&&size==12&&controls[0]==streamID&&controls[1]==volumeID&&controls[2]==muteID);
    AudioClassID controlClass=kAudioControlClassID;
    assert(dataGet(driver,deviceID,0,&a,4,&controlClass,sizeof(controls),&size,controls)==noErr&&size==8&&controls[0]==volumeID&&controls[1]==muteID);
    a.mScope=kAudioObjectPropertyScopeInput;
    assert(dataSize(driver,deviceID,0,&a,0,NULL,&size)==noErr&&size==0);
    a.mScope=kAudioObjectPropertyScopeGlobal;a.mSelector=kAudioObjectPropertyClass;
    assert(dataGet(driver,volumeID,0,&a,0,NULL,4,&size,&id)==noErr&&id==kAudioVolumeControlClassID);
    assert(dataGet(driver,muteID,0,&a,0,NULL,4,&size,&id)==noErr&&id==kAudioMuteControlClassID);
    a.mSelector=kAudioControlPropertyScope;
    assert(dataGet(driver,volumeID,0,&a,0,NULL,4,&size,&id)==noErr&&id==kAudioObjectPropertyScopeOutput);
    a.mSelector=kAudioControlPropertyElement;
    assert(dataGet(driver,volumeID,0,&a,0,NULL,4,&size,&id)==noErr&&id==kAudioObjectPropertyElementMain);
    a.mSelector=kAudioObjectPropertyOwner;
    assert(dataGet(driver,volumeID,0,&a,0,NULL,4,&size,&id)==noErr&&id==deviceID);
    Boolean writable=false;a.mSelector=kAudioLevelControlPropertyScalarValue;
    assert(settable(driver,volumeID,0,&a,&writable)==noErr&&writable);
    assert(!has(driver,muteID,0,&a));
    a.mScope=kAudioObjectPropertyScopeInput;assert(!has(driver,volumeID,0,&a));
    a.mScope=kAudioObjectPropertyScopeGlobal;a.mSelector=kAudioLevelControlPropertyDecibelRange;AudioValueRange decibelRange;
    assert(dataGet(driver,volumeID,0,&a,0,NULL,sizeof(decibelRange),&size,&decibelRange)==noErr&&decibelRange.mMinimum== -96&&decibelRange.mMaximum==0);
    a.mSelector=kAudioLevelControlPropertyConvertScalarToDecibels;Float32 conversion=.5;
    assert(dataGet(driver,volumeID,0,&a,0,NULL,4,&size,&conversion)==noErr&&fabsf(conversion+6.0206f)<.0001f);
    a.mSelector=kAudioLevelControlPropertyConvertDecibelsToScalar;
    assert(dataGet(driver,volumeID,0,&a,0,NULL,4,&size,&conversion)==noErr&&fabsf(conversion-.5f)<.0001f);
    a.mSelector=RV_SPEAKER_PULL;a.mScope=kAudioObjectPropertyScopeGlobal;
    assert(dataSize(driver,deviceID,0,&a,0,NULL,&size)==noErr&&size==sizeof(CFDataRef));
    a.mSelector='rvsp';assert(!has(driver,deviceID,0,&a));
    assert(startIO(driver,deviceID,1)==noErr);
    Boolean will=false,inPlace=false;
    assert(willIO(driver,deviceID,1,kAudioServerPlugInIOOperationWriteMix,&will,&inPlace)==noErr&&will&&inPlace);
    assert(willIO(driver,deviceID,1,kAudioServerPlugInIOOperationReadInput,&will,&inPlace)==noErr&&!will);
    Float64 sample;UInt64 tick,seed;
    assert(timestamp(driver,deviceID,1,&sample,&tick,&seed)==noErr&&tick>0&&seed>1);
    float source[8192];for(unsigned i=0;i<4096;i++){source[2*i]=.25f;source[2*i+1]=-.5f;}
    AudioServerPlugInIOCycleInfo cycle={0};
    assert(performIO(driver,deviceID,streamID,1,kAudioServerPlugInIOOperationWriteMix,512,&cycle,source,NULL)==noErr);
    int16_t pcm[960];a.mSelector=RV_SPEAKER_PULL;a.mScope=kAudioObjectPropertyScopeGlobal;
    assert(pcmGet(driver,deviceID,1,&a,0,NULL,sizeof(pcm),&size,pcm)==kAudioHardwareIllegalOperationError);
    assert(pcmGet(driver,deviceID,getpid(),&a,0,NULL,sizeof(pcm),&size,pcm)==noErr&&size==1920&&pcm[0]==8192&&pcm[1]==-16384);
    assert(pcmGet(driver,deviceID,getpid(),&a,0,NULL,sizeof(pcm),&size,pcm)==noErr&&size==128);
    assert(pcmGet(driver,deviceID,getpid(),&a,0,NULL,sizeof(pcm),&size,pcm)==noErr&&size==0);
    assert(pcmGet(driver,deviceID,getpid(),&a,0,NULL,3,&size,pcm)==kAudioHardwareBadPropertySizeError);
    assert(performIO(driver,deviceID,streamID,1,kAudioServerPlugInIOOperationWriteMix,4097,&cycle,source,NULL)==kAudioHardwareIllegalOperationError);
    // Driver volume and mute apply to the remote PCM only.
    a.mSelector=kAudioLevelControlPropertyScalarValue;a.mScope=kAudioObjectPropertyScopeGlobal;float gain=.5;
    assert(dataSet(driver,volumeID,getpid(),&a,0,NULL,4,&gain)==noErr&&volumeNotifications==2&&legacyVolumeNotifications==1);
    Float32 actualGain=0;
    assert(dataGet(driver,volumeID,0,&a,0,NULL,4,&size,&actualGain)==noErr&&actualGain==.5f);
    a.mSelector=kAudioDevicePropertyVolumeScalar;a.mScope=kAudioObjectPropertyScopeOutput;
    assert(dataGet(driver,deviceID,0,&a,0,NULL,4,&size,&actualGain)==noErr&&actualGain==.5f);
    assert(performIO(driver,deviceID,streamID,1,kAudioServerPlugInIOOperationWriteMix,480,&cycle,source,NULL)==noErr);
    a.mSelector=RV_SPEAKER_PULL;
    assert(pcmGet(driver,deviceID,getpid(),&a,0,NULL,sizeof(pcm),&size,pcm)==noErr&&pcm[0]==4096&&pcm[1]==-8192);
    a.mSelector=kAudioBooleanControlPropertyValue;a.mScope=kAudioObjectPropertyScopeGlobal;UInt32 mute=1;
    assert(dataSet(driver,muteID,getpid(),&a,0,NULL,4,&mute)==noErr&&muteNotifications==1&&legacyMuteNotifications==1);
    assert(performIO(driver,deviceID,streamID,1,kAudioServerPlugInIOOperationWriteMix,480,&cycle,source,NULL)==noErr);
    a.mSelector=RV_SPEAKER_PULL;
    assert(pcmGet(driver,deviceID,getpid(),&a,0,NULL,sizeof(pcm),&size,pcm)==noErr&&size==1920);
    for(unsigned i=0;i<960;i++)assert(pcm[i]==0);
    // Decibel writes, zero volume, bounds and both legacy/control directions.
    a.mSelector=kAudioLevelControlPropertyDecibelValue;Float32 decibels=-6.0206f;
    assert(dataSet(driver,volumeID,getpid(),&a,0,NULL,4,&decibels)==noErr&&fabsf(currentGain()-.5f)<.0001f);
    decibels=-96;assert(dataSet(driver,volumeID,getpid(),&a,0,NULL,4,&decibels)==noErr&&currentGain()==0);
    decibels=-97;assert(dataSet(driver,volumeID,getpid(),&a,0,NULL,4,&decibels)==kAudioHardwareIllegalOperationError);
    a.mSelector=kAudioLevelControlPropertyScalarValue;gain=NAN;
    assert(dataSet(driver,volumeID,getpid(),&a,0,NULL,4,&gain)==kAudioHardwareIllegalOperationError);
    gain=1.1;assert(dataSet(driver,volumeID,getpid(),&a,0,NULL,4,&gain)==kAudioHardwareIllegalOperationError);
    gain=1;assert(dataSet(driver,volumeID,getpid(),&a,0,NULL,3,&gain)==kAudioHardwareBadPropertySizeError);
    a.mScope=kAudioObjectPropertyScopeOutput;a.mSelector=kAudioDevicePropertyVolumeScalar;
    assert(dataSet(driver,deviceID,getpid(),&a,0,NULL,4,&gain)==noErr);
    a.mScope=kAudioObjectPropertyScopeGlobal;a.mSelector=kAudioLevelControlPropertyScalarValue;
    assert(dataGet(driver,volumeID,0,&a,0,NULL,4,&size,&actualGain)==noErr&&actualGain==1);
    a.mScope=kAudioObjectPropertyScopeOutput;a.mSelector=kAudioDevicePropertyMute;mute=0;
    assert(dataSet(driver,deviceID,getpid(),&a,0,NULL,4,&mute)==noErr);
    a.mScope=kAudioObjectPropertyScopeGlobal;a.mSelector=kAudioBooleanControlPropertyValue;
    assert(dataGet(driver,muteID,0,&a,0,NULL,4,&size,&id)==noErr&&id==0);
    a.mSelector=kAudioDevicePropertyDeviceUID;assert(!has(driver,volumeID,0,&a));
    assert(!has(driver,99,0,&a));assert(!has(driver,deviceID,0,NULL));
    // Backlog skips stale samples; clearing never resets a live producer.
    rv_speaker_write(&ring,source,4096,1);
    assert(rv_speaker_pull(&ring,pcm,480)==480&&atomic_load(&ring.end)-ring.cursor==0);
    rv_speaker_write(&ring,source,512,1);a.mSelector=RV_SPEAKER_CLEAR;
    assert(dataSet(driver,deviceID,1,&a,0,NULL,0,NULL)==kAudioHardwareIllegalOperationError);
    assert(dataSet(driver,deviceID,getpid(),&a,0,NULL,0,NULL)==noErr&&rv_speaker_pull(&ring,pcm,480)==0);
    rv_speaker_write(&ring,source,512,1);atomic_store(&lastWriteTime,0);a.mSelector=RV_SPEAKER_PULL;
    assert(pcmGet(driver,deviceID,getpid(),&a,0,NULL,sizeof(pcm),&size,pcm)==noErr&&size==0);
    assert(startIO(driver,deviceID,2)==noErr&&stopIO(driver,deviceID,1)==noErr&&atomic_load(&anchor)>0);
    assert(stopIO(driver,deviceID,2)==noErr&&atomic_load(&anchor)==0);
    UInt64 previousSeed=seed;assert(startIO(driver,deviceID,1)==noErr);
    assert(timestamp(driver,deviceID,1,&sample,&tick,&seed)==noErr&&seed>previousSeed);assert(stopIO(driver,deviceID,1)==noErr);
    rv_speaker_initialize(&ring);pthread_t producer;assert(pthread_create(&producer,NULL,produce,NULL)==0);
    for(unsigned i=0;i<10000;i++) {
        unsigned count=rv_speaker_pull(&ring,pcm,480);
        for(unsigned frame=0;frame<count;frame++)assert(abs((int)pcm[2*frame]+pcm[2*frame+1])<=1);
    }
    assert(pthread_join(producer,NULL)==0);
    puts("Speaker CFData HAL marshalling, output-only properties, mixed PCM, bounds, volume/mute, trusted reader, backlog, clock and concurrent ring tests passed.");
}
