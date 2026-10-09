#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreAudio/AudioHardwareBase.h>
#include <CoreAudio/AudioHardware.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <Security/Security.h>
#include <mach/mach_time.h>
#include <math.h>
#include <pthread.h>
#include "ring.h"

#ifndef RV_SIGNING_TEAM
#define RV_SIGNING_TEAM ""
#endif
enum { deviceID=2, streamID=3 };
static AudioServerPlugInHostRef host;
static _Atomic uint32_t references=1, ioUsers=0;
static _Atomic uint64_t anchor=0;
static _Atomic uint64_t clockSeed=1;
static double ticksPerFrame;
static RVMicRing ring;
static pthread_mutex_t stateLock=PTHREAD_MUTEX_INITIALIZER;
static uint64_t nextWrite=0;
static AudioServerPlugInDriverInterface interface;
static AudioServerPlugInDriverInterface *interfacePointer=&interface;
static AudioServerPlugInDriverRef driver=&interfacePointer;
static const AudioStreamBasicDescription format={48000,kAudioFormatLinearPCM,
    kAudioFormatFlagsNativeFloatPacked,4,1,4,1,32,0};
static Boolean validObject(AudioObjectID object) { return object==kAudioObjectPlugInObject||object==deviceID||object==streamID; }
static Boolean inputScope(const AudioObjectPropertyAddress *address) { return address->mScope!=kAudioObjectPropertyScopeOutput; }
static HRESULT query(void *self,REFIID uuid,LPVOID *out) {
    if(self!=driver||!out)return E_NOINTERFACE;
    CFUUIDRef id=CFUUIDCreateFromUUIDBytes(NULL,uuid);
    Boolean match=CFEqual(id,IUnknownUUID)||CFEqual(id,kAudioServerPlugInDriverInterfaceUUID); CFRelease(id);
    *out=match?driver:NULL; if(match)atomic_fetch_add(&references,1); return match?S_OK:E_NOINTERFACE;
}
static ULONG retain(void *self) { return self==driver?atomic_fetch_add(&references,1)+1:0; }
static ULONG release(void *self) { if(self!=driver)return 0; uint32_t value=atomic_load(&references);
    while(value>1&&!atomic_compare_exchange_weak(&references,&value,value-1)){} return atomic_load(&references); }
static OSStatus initialize(AudioServerPlugInDriverRef self,AudioServerPlugInHostRef newHost) {
    if(self!=driver)return kAudioHardwareBadObjectError; host=newHost;
    mach_timebase_info_data_t timebase; mach_timebase_info(&timebase);
    ticksPerFrame=1e9/48000.0*(double)timebase.denom/timebase.numer; rv_mic_clear(&ring); return noErr;
}
static OSStatus createDevice(AudioServerPlugInDriverRef self,CFDictionaryRef description,const AudioServerPlugInClientInfo *client,AudioObjectID *out) {
    (void)self;(void)description;(void)client;(void)out;return kAudioHardwareUnsupportedOperationError;
}
static OSStatus destroyDevice(AudioServerPlugInDriverRef self,AudioObjectID object) { (void)self;(void)object;return kAudioHardwareUnsupportedOperationError; }
static OSStatus clientChange(AudioServerPlugInDriverRef self,AudioObjectID object,const AudioServerPlugInClientInfo *client) {
    (void)client;return self==driver&&object==deviceID?noErr:kAudioHardwareBadObjectError;
}
static OSStatus configChange(AudioServerPlugInDriverRef self,AudioObjectID object,UInt64 action,void *info) {
    (void)action;(void)info;return self==driver&&object==deviceID?noErr:kAudioHardwareBadObjectError;
}

/* All property reads share one size-checked implementation. The device is
 * input-only: never publishes a speaker or changes the system output device. */
static OSStatus value(AudioObjectID object,const AudioObjectPropertyAddress *a,UInt32 qualifierSize,const void *qualifier,
                      UInt32 capacity,UInt32 *size,void *out) {
    if(!validObject(object)||!a||!size)return kAudioHardwareBadObjectError;
    UInt32 integer=0; Float64 rate=48000; CFStringRef string=NULL; const void *bytes=NULL; UInt32 count=4;
    AudioValueRange range={48000,48000}; AudioStreamRangedDescription ranged={format,{48000,48000}};
    AudioBufferList buffers={1,{{1,0,NULL}}};
    AudioServerPlugInCustomPropertyInfo custom[2]={{RV_MIC_PUSH,kAudioServerPlugInCustomPropertyDataTypeNone,kAudioServerPlugInCustomPropertyDataTypeNone},
        {RV_MIC_CLEAR,kAudioServerPlugInCustomPropertyDataTypeNone,kAudioServerPlugInCustomPropertyDataTypeNone}};
    switch(a->mSelector) {
        case kAudioObjectPropertyBaseClass: integer=object==kAudioObjectPlugInObject?kAudioObjectClassID:object==deviceID?kAudioObjectClassID:kAudioObjectClassID;break;
        case kAudioObjectPropertyClass:integer=object==kAudioObjectPlugInObject?kAudioPlugInClassID:object==deviceID?kAudioDeviceClassID:kAudioStreamClassID;break;
        case kAudioObjectPropertyOwner:integer=object==kAudioObjectPlugInObject?kAudioObjectUnknown:object==deviceID?kAudioObjectPlugInObject:deviceID;break;
        case kAudioObjectPropertyName:string=CFSTR("ReVoyage — iMac Microphone");break;
        case kAudioObjectPropertyManufacturer:string=CFSTR("iMac ReVoyage");break;
        case kAudioObjectPropertyOwnedObjects:integer=object==kAudioObjectPlugInObject?deviceID:streamID; count=object==streamID||!inputScope(a)?0:4;break;
        case kAudioPlugInPropertyBundleID:if(object!=kAudioObjectPlugInObject)return kAudioHardwareUnknownPropertyError;string=CFSTR("com.targetbridge.sender.microphone");break;
        case kAudioPlugInPropertyDeviceList:if(object!=kAudioObjectPlugInObject)return kAudioHardwareUnknownPropertyError;integer=deviceID;break;
        case kAudioPlugInPropertyTranslateUIDToDevice:
            if(object!=kAudioObjectPlugInObject||qualifierSize!=sizeof(CFStringRef)||!qualifier)return kAudioHardwareIllegalOperationError;
            integer=*(CFStringRef *)qualifier&&CFEqual(*(CFStringRef *)qualifier,CFSTR("re.voyage.imac.microphone"))?deviceID:kAudioObjectUnknown;break;
        case kAudioDevicePropertyDeviceUID:if(object!=deviceID)return kAudioHardwareUnknownPropertyError;string=CFSTR("re.voyage.imac.microphone");break;
        case kAudioDevicePropertyModelUID:string=CFSTR("re.voyage.imac.microphone.v1");break;
        case kAudioDevicePropertyTransportType:integer=kAudioDeviceTransportTypeVirtual;break;
        case kAudioDevicePropertyRelatedDevices:integer=deviceID;break;
        case kAudioDevicePropertyClockDomain:integer=0;break;
        case kAudioDevicePropertyDeviceIsAlive:integer=1;break;
        case kAudioDevicePropertyDeviceIsRunning:integer=atomic_load(&ioUsers)>0;break;
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:integer=inputScope(a);break;
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:integer=0;break;
        case kAudioDevicePropertyStreams:integer=streamID;count=inputScope(a)?4:0;break;
        case kAudioObjectPropertyControlList:count=0;break;
        case kAudioDevicePropertySafetyOffset:integer=0;break;
        case kAudioDevicePropertyLatency:integer=0;break;
        case kAudioDevicePropertyZeroTimeStampPeriod:integer=512;break;
        case kAudioDevicePropertyBufferFrameSize:integer=512;break;
        case kAudioDevicePropertyBufferFrameSizeRange:range=(AudioValueRange){512,512};bytes=&range;count=sizeof(range);break;
        case kAudioDevicePropertyNominalSampleRate:bytes=&rate;count=sizeof(rate);break;
        case kAudioDevicePropertyAvailableNominalSampleRates:bytes=&range;count=sizeof(range);break;
        case kAudioDevicePropertyStreamConfiguration:
            if(!inputScope(a))buffers.mNumberBuffers=0; bytes=&buffers;count=(UInt32)(offsetof(AudioBufferList,mBuffers)+buffers.mNumberBuffers*sizeof(AudioBuffer));break;
        case kAudioStreamPropertyIsActive:integer=1;break;
        case kAudioStreamPropertyDirection:integer=1;break;
        case kAudioStreamPropertyTerminalType:integer=kAudioStreamTerminalTypeMicrophone;break;
        case kAudioStreamPropertyStartingChannel:integer=1;break;
        case kAudioStreamPropertyVirtualFormat:case kAudioStreamPropertyPhysicalFormat:bytes=&format;count=sizeof(format);break;
        case kAudioStreamPropertyAvailableVirtualFormats:case kAudioStreamPropertyAvailablePhysicalFormats:bytes=&ranged;count=sizeof(ranged);break;
        case kAudioObjectPropertyCustomPropertyInfoList:if(object!=deviceID)return kAudioHardwareUnknownPropertyError;bytes=custom;count=sizeof(custom);break;
        case RV_MIC_PUSH:case RV_MIC_CLEAR:if(object!=deviceID)return kAudioHardwareUnknownPropertyError;count=0;break;
        default:return kAudioHardwareUnknownPropertyError;
    }
    if(string){bytes=&string;count=sizeof(string);}else if(!bytes)bytes=&integer;
    *size=count;if(!out)return noErr;if(capacity<count)return kAudioHardwareBadPropertySizeError;
    if(count)memcpy(out,bytes,count);if(string)CFRetain(string);return noErr;
}
static Boolean has(AudioServerPlugInDriverRef self,AudioObjectID object,pid_t pid,const AudioObjectPropertyAddress *a) {
    (void)pid;UInt32 size;return self==driver&&value(object,a,0,NULL,0,&size,NULL)!=kAudioHardwareUnknownPropertyError&&validObject(object);
}
static OSStatus settable(AudioServerPlugInDriverRef self,AudioObjectID object,pid_t pid,const AudioObjectPropertyAddress *a,Boolean *out) {
    if(!out||!has(self,object,pid,a))return kAudioHardwareUnknownPropertyError;*out=object==deviceID&&(a->mSelector==RV_MIC_PUSH||a->mSelector==RV_MIC_CLEAR);return noErr;
}
static OSStatus dataSize(AudioServerPlugInDriverRef self,AudioObjectID object,pid_t pid,const AudioObjectPropertyAddress *a,UInt32 q,const void *qualifier,UInt32 *out) {
    (void)pid;return self==driver?value(object,a,q,qualifier,0,out,NULL):kAudioHardwareBadObjectError;
}
static OSStatus dataGet(AudioServerPlugInDriverRef self,AudioObjectID object,pid_t pid,const AudioObjectPropertyAddress *a,UInt32 q,const void *qualifier,UInt32 capacity,UInt32 *size,void *out) {
    (void)pid;return self==driver?value(object,a,q,qualifier,capacity,size,out):kAudioHardwareBadObjectError;
}
static Boolean trustedSender(pid_t pid) {
    if(!strlen(RV_SIGNING_TEAM))return false;
    CFStringRef text=CFStringCreateWithFormat(NULL,NULL,CFSTR("identifier \"com.targetbridge.sender\" and anchor apple generic and certificate leaf[subject.OU] = \"%s\""),RV_SIGNING_TEAM);
    CFNumberRef number=CFNumberCreate(NULL,kCFNumberIntType,&pid);const void *key=kSecGuestAttributePid,*v=number;
    CFDictionaryRef attributes=CFDictionaryCreate(NULL,&key,&v,1,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    SecCodeRef code=NULL;SecRequirementRef requirement=NULL;
    Boolean valid=SecCodeCopyGuestWithAttributes(NULL,attributes,kSecCSDefaultFlags,&code)==errSecSuccess&&
        SecRequirementCreateWithString(text,kSecCSDefaultFlags,&requirement)==errSecSuccess&&SecCodeCheckValidity(code,kSecCSDefaultFlags,requirement)==errSecSuccess;
    if(code)CFRelease(code);if(requirement)CFRelease(requirement);CFRelease(attributes);CFRelease(number);CFRelease(text);return valid;
}
static OSStatus dataSet(AudioServerPlugInDriverRef self,AudioObjectID object,pid_t pid,const AudioObjectPropertyAddress *a,UInt32 q,const void *qualifier,UInt32 size,const void *data) {
    (void)q;(void)qualifier;
    if(self!=driver||object!=deviceID||!a)return kAudioHardwareBadObjectError;
    if(a->mSelector!=RV_MIC_PUSH&&a->mSelector!=RV_MIC_CLEAR)return kAudioHardwareUnknownPropertyError;
    if(!trustedSender(pid))return kAudioHardwareIllegalOperationError;
    pthread_mutex_lock(&stateLock);
    if(a->mSelector==RV_MIC_CLEAR){rv_mic_clear(&ring);nextWrite=0;pthread_mutex_unlock(&stateLock);return noErr;}
    if(!data||!size||size>960*sizeof(float)||size%sizeof(float)){pthread_mutex_unlock(&stateLock);return kAudioHardwareBadPropertySizeError;}
    uint64_t base=atomic_load(&anchor);if(!base){pthread_mutex_unlock(&stateLock);return noErr;}
    uint64_t now=mach_absolute_time();uint64_t target=(uint64_t)((now-base)/ticksPerFrame)+960;
    if(!nextWrite||nextWrite+960<target||nextWrite>target+1920)nextWrite=target;
    const float *samples=data;
    UInt32 inputFrames=size/4, outputFrames=inputFrames;
    // Correct small clock drift gently; reserve discontinuous resync for a
    // genuine outage. Network arrival jitter within 10 ms is absorbed.
    if(inputFrames>1){if(nextWrite+480<target)++outputFrames;else if(nextWrite>target+480)--outputFrames;}
    for(UInt32 i=0;i<outputFrames;i++) {
        double source=(double)i*inputFrames/outputFrames;UInt32 first=(UInt32)source;
        UInt32 second=first+1<inputFrames?first+1:first;float fraction=(float)(source-first);
        float sample=samples[first]*(1-fraction)+samples[second]*fraction;
        rv_mic_write(&ring,nextWrite++,isfinite(sample)?fmaxf(-1,fminf(1,sample)):0);
    }
    pthread_mutex_unlock(&stateLock);return noErr;
}
static OSStatus startIO(AudioServerPlugInDriverRef self,AudioObjectID object,UInt32 client) {
    (void)client;if(self!=driver||object!=deviceID)return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&stateLock);if(atomic_fetch_add(&ioUsers,1)==0){rv_mic_clear(&ring);nextWrite=0;atomic_fetch_add(&clockSeed,1);atomic_store(&anchor,mach_absolute_time());}
    pthread_mutex_unlock(&stateLock);AudioObjectPropertyAddress a={kAudioDevicePropertyDeviceIsRunning,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
    return host->PropertiesChanged(host,deviceID,1,&a);
}
static OSStatus stopIO(AudioServerPlugInDriverRef self,AudioObjectID object,UInt32 client) {
    (void)client;if(self!=driver||object!=deviceID)return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&stateLock);uint32_t users=atomic_load(&ioUsers);if(users&&atomic_fetch_sub(&ioUsers,1)==1){atomic_store(&anchor,0);rv_mic_clear(&ring);nextWrite=0;}
    pthread_mutex_unlock(&stateLock);AudioObjectPropertyAddress a={kAudioDevicePropertyDeviceIsRunning,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
    return host->PropertiesChanged(host,deviceID,1,&a);
}
static OSStatus timestamp(AudioServerPlugInDriverRef self,AudioObjectID object,UInt32 client,Float64 *sample,UInt64 *time,UInt64 *seed) {
    (void)client;if(self!=driver||object!=deviceID||!sample||!time||!seed)return kAudioHardwareBadObjectError;
    uint64_t base=atomic_load(&anchor),now=mach_absolute_time();if(!base)base=now;
    uint64_t frames=(uint64_t)((now-base)/ticksPerFrame/512)*512;*sample=(double)frames;*time=base+(uint64_t)(frames*ticksPerFrame);*seed=atomic_load(&clockSeed);return noErr;
}
static OSStatus willIO(AudioServerPlugInDriverRef self,AudioObjectID object,UInt32 client,UInt32 operation,Boolean *will,Boolean *inPlace) {
    (void)client;if(self!=driver||object!=deviceID||!will||!inPlace)return kAudioHardwareBadObjectError;*will=operation==kAudioServerPlugInIOOperationReadInput;*inPlace=true;return noErr;
}
static OSStatus boundaryIO(AudioServerPlugInDriverRef self,AudioObjectID object,UInt32 client,UInt32 operation,UInt32 frames,const AudioServerPlugInIOCycleInfo *cycle) {
    (void)client;(void)operation;(void)frames;(void)cycle;return self==driver&&object==deviceID?noErr:kAudioHardwareBadObjectError;
}
static OSStatus performIO(AudioServerPlugInDriverRef self,AudioObjectID object,AudioObjectID stream,UInt32 client,UInt32 operation,UInt32 frames,
                          const AudioServerPlugInIOCycleInfo *cycle,void *mainBuffer,void *secondaryBuffer) {
    (void)client;(void)secondaryBuffer;
    if(self!=driver||object!=deviceID||stream!=streamID||!cycle||!mainBuffer||frames>RV_MIC_MAX_FRAMES)return kAudioHardwareIllegalOperationError;
    if(operation!=kAudioServerPlugInIOOperationReadInput)return noErr;
    float *out=mainBuffer;double position=cycle->mInputTime.mSampleTime;
    if(!isfinite(position)||position<0||position>0x1p53){memset(out,0,frames*4);return noErr;}
    uint64_t first=(uint64_t)position;for(UInt32 i=0;i<frames;i++)out[i]=rv_mic_read(&ring,first+i);return noErr;
}
static AudioServerPlugInDriverInterface interface={.QueryInterface=query,.AddRef=retain,.Release=release,.Initialize=initialize,
    .CreateDevice=createDevice,.DestroyDevice=destroyDevice,.AddDeviceClient=clientChange,.RemoveDeviceClient=clientChange,
    .PerformDeviceConfigurationChange=configChange,.AbortDeviceConfigurationChange=configChange,.HasProperty=has,.IsPropertySettable=settable,
    .GetPropertyDataSize=dataSize,.GetPropertyData=dataGet,.SetPropertyData=dataSet,.StartIO=startIO,.StopIO=stopIO,.GetZeroTimeStamp=timestamp,
    .WillDoIOOperation=willIO,.BeginIOOperation=boundaryIO,.DoIOOperation=performIO,.EndIOOperation=boundaryIO};
__attribute__((visibility("default"))) void *ReVoyageMicrophoneFactory(CFAllocatorRef allocator,CFUUIDRef type) {
    (void)allocator;return CFEqual(type,kAudioServerPlugInTypeUUID)?driver:NULL;
}
