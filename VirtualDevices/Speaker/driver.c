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
enum { deviceID=2, streamID=3, volumeID=4, muteID=5 };
static AudioServerPlugInHostRef host;
static _Atomic uint32_t references=1, ioUsers=0;
static _Atomic uint64_t anchor=0;
static _Atomic uint64_t clockSeed=1;
static double ticksPerFrame;
static RVSpeakerRing ring;
static _Atomic uint64_t lastWriteTime=0;
static _Atomic uint32_t gainBits=0x3f800000, muted=0;
static pthread_mutex_t stateLock=PTHREAD_MUTEX_INITIALIZER;

static AudioServerPlugInDriverInterface interface;
static AudioServerPlugInDriverInterface *interfacePointer=&interface;
static AudioServerPlugInDriverRef driver=&interfacePointer;
static const AudioStreamBasicDescription format={48000,kAudioFormatLinearPCM,
    kAudioFormatFlagsNativeFloatPacked,8,1,8,2,32,0};
static Boolean validObject(AudioObjectID object) { return object==kAudioObjectPlugInObject||object==deviceID||object==streamID||object==volumeID||object==muteID; }
static Boolean outputScope(const AudioObjectPropertyAddress *address) { return address->mScope!=kAudioObjectPropertyScopeInput; }
static Float32 currentGain(void) { uint32_t bits=atomic_load(&gainBits);Float32 gain;memcpy(&gain,&bits,4);return gain; }
static Float32 gainToDecibels(Float32 gain) { return gain<=0?-96:fmaxf(-96,20*log10f(gain)); }
static Float32 decibelsToGain(Float32 decibels) { return decibels<=-96?0:powf(10,decibels/20); }
static Boolean ownedClassMatches(AudioObjectID object,AudioClassID requested) {
    if(requested==kAudioObjectClassID)return true;
    if(object==streamID)return requested==kAudioStreamClassID;
    if(requested==kAudioControlClassID)return true;
    return object==volumeID?(requested==kAudioVolumeControlClassID||requested==kAudioLevelControlClassID):
        (requested==kAudioMuteControlClassID||requested==kAudioBooleanControlClassID);
}

/* HAL discovers system-volume support through owned AudioControl objects,
 * not just the legacy device scalar property. All values share one gain. */
static OSStatus controlValue(AudioObjectID object,const AudioObjectPropertyAddress *a,UInt32 capacity,UInt32 *size,void *out) {
    if(a->mScope!=kAudioObjectPropertyScopeGlobal||a->mElement!=kAudioObjectPropertyElementMain)return kAudioHardwareUnknownPropertyError;
    UInt32 integer=0,count=4;Float32 scalar=0;AudioValueRange range={-96,0};const void *bytes=&integer;
    switch(a->mSelector) {
        case kAudioObjectPropertyBaseClass:integer=object==volumeID?kAudioLevelControlClassID:kAudioBooleanControlClassID;break;
        case kAudioObjectPropertyClass:integer=object==volumeID?kAudioVolumeControlClassID:kAudioMuteControlClassID;break;
        case kAudioObjectPropertyOwner:integer=deviceID;break;
        case kAudioObjectPropertyOwnedObjects:count=0;break;
        case kAudioControlPropertyScope:integer=kAudioObjectPropertyScopeOutput;break;
        case kAudioControlPropertyElement:integer=kAudioObjectPropertyElementMain;break;
        case kAudioLevelControlPropertyScalarValue:
            if(object!=volumeID)return kAudioHardwareUnknownPropertyError;scalar=currentGain();bytes=&scalar;break;
        case kAudioLevelControlPropertyDecibelValue:
            if(object!=volumeID)return kAudioHardwareUnknownPropertyError;scalar=gainToDecibels(currentGain());bytes=&scalar;break;
        case kAudioLevelControlPropertyDecibelRange:
            if(object!=volumeID)return kAudioHardwareUnknownPropertyError;bytes=&range;count=sizeof(range);break;
        case kAudioLevelControlPropertyConvertScalarToDecibels:
        case kAudioLevelControlPropertyConvertDecibelsToScalar:
            if(object!=volumeID)return kAudioHardwareUnknownPropertyError;
            *size=4;if(!out)return noErr;if(capacity<4)return kAudioHardwareBadPropertySizeError;
            memcpy(&scalar,out,4);if(!isfinite(scalar))return kAudioHardwareIllegalOperationError;
            scalar=a->mSelector==kAudioLevelControlPropertyConvertScalarToDecibels
                ?gainToDecibels(fminf(1,fmaxf(0,scalar))):decibelsToGain(fminf(0,fmaxf(-96,scalar)));
            memcpy(out,&scalar,4);return noErr;
        case kAudioBooleanControlPropertyValue:
            if(object!=muteID)return kAudioHardwareUnknownPropertyError;integer=atomic_load(&muted);break;
        default:return kAudioHardwareUnknownPropertyError;
    }
    *size=count;if(!out)return noErr;if(capacity<count)return kAudioHardwareBadPropertySizeError;
    if(count)memcpy(out,bytes,count);return noErr;
}
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
    ticksPerFrame=1e9/48000.0*(double)timebase.denom/timebase.numer; rv_speaker_initialize(&ring); return noErr;
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

/* Output-only device. Installing never changes the default output. */
static OSStatus value(AudioObjectID object,const AudioObjectPropertyAddress *a,UInt32 qualifierSize,const void *qualifier,
                      UInt32 capacity,UInt32 *size,void *out) {
    if(!validObject(object)||!a||!size)return kAudioHardwareBadObjectError;
    if(object==volumeID||object==muteID)return controlValue(object,a,capacity,size,out);
    UInt32 integer=0; Float64 rate=48000; CFStringRef string=NULL; const void *bytes=NULL; UInt32 count=4;
    AudioValueRange range={48000,48000}; AudioStreamRangedDescription ranged={format,{48000,48000}};
    AudioBufferList buffers={1,{{2,0,NULL}}};
    AudioObjectID filteredOwned[3];
    AudioServerPlugInCustomPropertyInfo custom[2]={{RV_SPEAKER_PULL,kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,kAudioServerPlugInCustomPropertyDataTypeNone},
        {RV_SPEAKER_CLEAR,kAudioServerPlugInCustomPropertyDataTypeNone,kAudioServerPlugInCustomPropertyDataTypeNone}};
    switch(a->mSelector) {
        case kAudioObjectPropertyBaseClass: integer=object==kAudioObjectPlugInObject?kAudioObjectClassID:object==deviceID?kAudioObjectClassID:kAudioObjectClassID;break;
        case kAudioObjectPropertyClass:integer=object==kAudioObjectPlugInObject?kAudioPlugInClassID:object==deviceID?kAudioDeviceClassID:kAudioStreamClassID;break;
        case kAudioObjectPropertyOwner:integer=object==kAudioObjectPlugInObject?kAudioObjectUnknown:object==deviceID?kAudioObjectPlugInObject:deviceID;break;
        case kAudioObjectPropertyName:string=CFSTR("ReVoyage — iMac Speakers");break;
        case kAudioObjectPropertyManufacturer:string=CFSTR("iMac ReVoyage");break;
        case kAudioObjectPropertyOwnedObjects:{
            static const AudioObjectID owned[]={streamID,volumeID,muteID};
            integer=deviceID;count=object==kAudioObjectPlugInObject?4:0;
            if(object==deviceID&&outputScope(a)) {
                bytes=owned;count=sizeof(owned);
                if(qualifierSize) {
                    if(!qualifier||qualifierSize%sizeof(AudioClassID))return kAudioHardwareBadPropertySizeError;
                    count=0;const AudioClassID *classes=qualifier;
                    for(unsigned i=0;i<3;i++)for(unsigned j=0;j<qualifierSize/sizeof(AudioClassID);j++) {
                        if(ownedClassMatches(owned[i],classes[j])){filteredOwned[count/4]=owned[i];count+=4;break;}
                    }
                    bytes=filteredOwned;
                }
            }break;
        }
        case kAudioPlugInPropertyBundleID:if(object!=kAudioObjectPlugInObject)return kAudioHardwareUnknownPropertyError;string=CFSTR("com.targetbridge.sender.speaker");break;
        case kAudioPlugInPropertyDeviceList:if(object!=kAudioObjectPlugInObject)return kAudioHardwareUnknownPropertyError;integer=deviceID;break;
        case kAudioPlugInPropertyTranslateUIDToDevice:
            if(object!=kAudioObjectPlugInObject||qualifierSize!=sizeof(CFStringRef)||!qualifier)return kAudioHardwareIllegalOperationError;
            integer=*(CFStringRef *)qualifier&&CFEqual(*(CFStringRef *)qualifier,CFSTR("re.voyage.imac.speaker"))?deviceID:kAudioObjectUnknown;break;
        case kAudioDevicePropertyDeviceUID:if(object!=deviceID)return kAudioHardwareUnknownPropertyError;string=CFSTR("re.voyage.imac.speaker");break;
        case kAudioDevicePropertyModelUID:string=CFSTR("re.voyage.imac.speaker.v1");break;
        case kAudioDevicePropertyTransportType:integer=kAudioDeviceTransportTypeVirtual;break;
        case kAudioDevicePropertyRelatedDevices:integer=deviceID;break;
        case kAudioDevicePropertyClockDomain:integer=0;break;
        case kAudioDevicePropertyDeviceIsAlive:integer=1;break;
        case kAudioDevicePropertyDeviceIsRunning:integer=atomic_load(&ioUsers)>0;break;
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:integer=outputScope(a);break;
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:integer=outputScope(a);break;
        case kAudioDevicePropertyIsHidden:integer=0;break;
        case kAudioDevicePropertyPreferredChannelsForStereo:{static const UInt32 channels[2]={1,2};bytes=channels;count=sizeof(channels);break;}
        case kAudioDevicePropertyVolumeScalar:{
            if(object!=deviceID||a->mScope!=kAudioObjectPropertyScopeOutput||a->mElement!=kAudioObjectPropertyElementMain)return kAudioHardwareUnknownPropertyError;
            static _Thread_local Float32 gain;gain=currentGain();bytes=&gain;count=4;break;
        }
        case kAudioDevicePropertyMute:
            if(object!=deviceID||a->mScope!=kAudioObjectPropertyScopeOutput||a->mElement!=kAudioObjectPropertyElementMain)return kAudioHardwareUnknownPropertyError;
            integer=atomic_load(&muted);break;
        case kAudioDevicePropertyStreams:integer=streamID;count=outputScope(a)?4:0;break;
        case kAudioObjectPropertyControlList:{
            static const AudioObjectID controls[]={volumeID,muteID};count=0;
            if(object==deviceID&&outputScope(a)){bytes=controls;count=sizeof(controls);}break;
        }
        case kAudioDevicePropertySafetyOffset:integer=0;break;
        case kAudioDevicePropertyLatency:integer=0;break;
        case kAudioDevicePropertyZeroTimeStampPeriod:integer=512;break;
        case kAudioDevicePropertyBufferFrameSize:integer=512;break;
        case kAudioDevicePropertyBufferFrameSizeRange:range=(AudioValueRange){512,512};bytes=&range;count=sizeof(range);break;
        case kAudioDevicePropertyNominalSampleRate:bytes=&rate;count=sizeof(rate);break;
        case kAudioDevicePropertyAvailableNominalSampleRates:bytes=&range;count=sizeof(range);break;
        case kAudioDevicePropertyStreamConfiguration:
            if(!outputScope(a))buffers.mNumberBuffers=0; bytes=&buffers;count=(UInt32)(offsetof(AudioBufferList,mBuffers)+buffers.mNumberBuffers*sizeof(AudioBuffer));break;
        case kAudioStreamPropertyIsActive:integer=1;break;
        case kAudioStreamPropertyDirection:integer=0;break;
        case kAudioStreamPropertyTerminalType:integer=kAudioStreamTerminalTypeSpeaker;break;
        case kAudioStreamPropertyStartingChannel:integer=1;break;
        case kAudioStreamPropertyVirtualFormat:case kAudioStreamPropertyPhysicalFormat:bytes=&format;count=sizeof(format);break;
        case kAudioStreamPropertyAvailableVirtualFormats:case kAudioStreamPropertyAvailablePhysicalFormats:bytes=&ranged;count=sizeof(ranged);break;
        case kAudioObjectPropertyCustomPropertyInfoList:if(object!=deviceID)return kAudioHardwareUnknownPropertyError;bytes=custom;count=sizeof(custom);break;
        case RV_SPEAKER_PULL:if(object!=deviceID)return kAudioHardwareUnknownPropertyError;count=sizeof(CFDataRef);break;
        case RV_SPEAKER_CLEAR:if(object!=deviceID)return kAudioHardwareUnknownPropertyError;count=0;break;
        default:return kAudioHardwareUnknownPropertyError;
    }
    if(string){bytes=&string;count=sizeof(string);}else if(!bytes)bytes=&integer;
    *size=count;if(!out)return noErr;if(a->mSelector==RV_SPEAKER_PULL)return kAudioHardwareIllegalOperationError;if(capacity<count)return kAudioHardwareBadPropertySizeError;
    if(count)memcpy(out,bytes,count);if(string)CFRetain(string);return noErr;
}
static Boolean has(AudioServerPlugInDriverRef self,AudioObjectID object,pid_t pid,const AudioObjectPropertyAddress *a) {
    (void)pid;UInt32 size;return self==driver&&a&&validObject(object)&&value(object,a,0,NULL,0,&size,NULL)==noErr;
}
static OSStatus settable(AudioServerPlugInDriverRef self,AudioObjectID object,pid_t pid,const AudioObjectPropertyAddress *a,Boolean *out) {
    if(!out||!has(self,object,pid,a))return kAudioHardwareUnknownPropertyError;
    *out=(object==deviceID&&(a->mSelector==RV_SPEAKER_CLEAR||a->mSelector==kAudioDevicePropertyVolumeScalar||a->mSelector==kAudioDevicePropertyMute))||
        (object==volumeID&&(a->mSelector==kAudioLevelControlPropertyScalarValue||a->mSelector==kAudioLevelControlPropertyDecibelValue))||
        (object==muteID&&a->mSelector==kAudioBooleanControlPropertyValue);return noErr;
}
static OSStatus dataSize(AudioServerPlugInDriverRef self,AudioObjectID object,pid_t pid,const AudioObjectPropertyAddress *a,UInt32 q,const void *qualifier,UInt32 *out) {
    (void)pid;return self==driver?value(object,a,q,qualifier,0,out,NULL):kAudioHardwareBadObjectError;
}
static Boolean trustedSender(pid_t pid);
static OSStatus dataGet(AudioServerPlugInDriverRef self,AudioObjectID object,pid_t pid,const AudioObjectPropertyAddress *a,UInt32 q,const void *qualifier,UInt32 capacity,UInt32 *size,void *out) {
    if(self!=driver)return kAudioHardwareBadObjectError;
    if(a&&a->mSelector==RV_SPEAKER_PULL&&object==deviceID) {
        if(!size||!out||capacity!=sizeof(CFDataRef))return kAudioHardwareBadPropertySizeError;
        // Verification is off the realtime thread. Cache briefly for the same
        // process while polling; a changed PID always gets a new signature check.
        static pid_t verifiedPID=0;static uint64_t verifiedAt=0;
        pthread_mutex_lock(&stateLock);
        uint64_t now=mach_absolute_time();
        if(pid!=verifiedPID||!verifiedAt||now-verifiedAt>(uint64_t)(ticksPerFrame*48000*2)) {
            if(!trustedSender(pid)){pthread_mutex_unlock(&stateLock);return kAudioHardwareIllegalOperationError;}
            verifiedPID=pid;verifiedAt=now;
        }
        uint64_t last=atomic_load_explicit(&lastWriteTime,memory_order_acquire);
        if(!last||now<last||now-last>(uint64_t)(ticksPerFrame*7200))rv_speaker_discard(&ring);
        int16_t pcm[RV_SPEAKER_PULL_FRAMES*2];
        uint32_t frames=rv_speaker_pull(&ring,pcm,RV_SPEAKER_PULL_FRAMES);
        // Only CFString/CFPropertyList custom values cross the HAL process
        // boundary. CFData is a property-list value; raw bytes declared as
        // DataTypeNone are not transported by the actual host.
        CFDataRef packet=CFDataCreate(NULL,(const UInt8 *)pcm,frames*4);
        pthread_mutex_unlock(&stateLock);
        if(!packet)return kAudioHardwareUnspecifiedError;
        *size=sizeof(packet);memcpy(out,&packet,sizeof(packet));return noErr;
    }
    return value(object,a,q,qualifier,capacity,size,out);
}
static Boolean trustedSender(pid_t pid) {
    CFStringRef text=strlen(RV_SIGNING_TEAM)?
        CFStringCreateWithFormat(NULL,NULL,CFSTR("identifier \"com.targetbridge.sender\" and anchor apple generic and certificate leaf[subject.OU] = \"%s\""),RV_SIGNING_TEAM):
        CFRetain(CFSTR("identifier \"com.targetbridge.sender\""));
    CFNumberRef number=CFNumberCreate(NULL,kCFNumberIntType,&pid);const void *key=kSecGuestAttributePid,*v=number;
    CFDictionaryRef attributes=CFDictionaryCreate(NULL,&key,&v,1,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    SecCodeRef code=NULL;SecRequirementRef requirement=NULL;
    Boolean valid=SecCodeCopyGuestWithAttributes(NULL,attributes,kSecCSDefaultFlags,&code)==errSecSuccess&&
        SecRequirementCreateWithString(text,kSecCSDefaultFlags,&requirement)==errSecSuccess&&SecCodeCheckValidity(code,kSecCSDefaultFlags,requirement)==errSecSuccess;
    if(code)CFRelease(code);if(requirement)CFRelease(requirement);CFRelease(attributes);CFRelease(number);CFRelease(text);return valid;
}
static OSStatus dataSet(AudioServerPlugInDriverRef self,AudioObjectID object,pid_t pid,const AudioObjectPropertyAddress *a,UInt32 q,const void *qualifier,UInt32 size,const void *data) {
    (void)q;(void)qualifier;
    if(self!=driver||!validObject(object)||!a)return kAudioHardwareBadObjectError;
    Boolean writable=false;OSStatus status=settable(self,object,pid,a,&writable);
    if(status!=noErr)return status;if(!writable)return kAudioHardwareUnknownPropertyError;
    Boolean volumeChange=(object==deviceID&&a->mSelector==kAudioDevicePropertyVolumeScalar)||object==volumeID;
    Boolean muteChange=(object==deviceID&&a->mSelector==kAudioDevicePropertyMute)||object==muteID;
    if(volumeChange) {
        if(!data||size!=4)return kAudioHardwareBadPropertySizeError;
        float gain;memcpy(&gain,data,4);if(!isfinite(gain))return kAudioHardwareIllegalOperationError;
        // The decibel selector uses the same gain, with a finite silent floor.
        if(object==volumeID&&a->mSelector==kAudioLevelControlPropertyDecibelValue) {
            if(gain< -96||gain>0)return kAudioHardwareIllegalOperationError;gain=decibelsToGain(gain);
        } else if(gain<0||gain>1)return kAudioHardwareIllegalOperationError;
        uint32_t bits;memcpy(&bits,&gain,4);atomic_store(&gainBits,bits);
    } else if(muteChange) {
        if(!data||size!=4)return kAudioHardwareBadPropertySizeError;
        uint32_t mute;memcpy(&mute,data,4);if(mute>1)return kAudioHardwareIllegalOperationError;atomic_store(&muted,mute);
    } else if(a->mSelector==RV_SPEAKER_CLEAR) {
        if(!trustedSender(pid))return kAudioHardwareIllegalOperationError;
        pthread_mutex_lock(&stateLock);rv_speaker_discard(&ring);pthread_mutex_unlock(&stateLock);return noErr;
    } else return kAudioHardwareUnknownPropertyError;
    if(volumeChange) {
        AudioObjectPropertyAddress properties[]={{kAudioLevelControlPropertyScalarValue,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain},
            {kAudioLevelControlPropertyDecibelValue,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain}};
        host->PropertiesChanged(host,volumeID,2,properties);
        AudioObjectPropertyAddress legacy={kAudioDevicePropertyVolumeScalar,kAudioObjectPropertyScopeOutput,kAudioObjectPropertyElementMain};
        host->PropertiesChanged(host,deviceID,1,&legacy);
    } else if(muteChange) {
        AudioObjectPropertyAddress property={kAudioBooleanControlPropertyValue,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
        host->PropertiesChanged(host,muteID,1,&property);
        AudioObjectPropertyAddress legacy={kAudioDevicePropertyMute,kAudioObjectPropertyScopeOutput,kAudioObjectPropertyElementMain};
        host->PropertiesChanged(host,deviceID,1,&legacy);
    }
    return noErr;
}
static OSStatus startIO(AudioServerPlugInDriverRef self,AudioObjectID object,UInt32 client) {
    (void)client;if(self!=driver||object!=deviceID)return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&stateLock);if(atomic_fetch_add(&ioUsers,1)==0){rv_speaker_discard(&ring);atomic_store(&lastWriteTime,0);atomic_fetch_add(&clockSeed,1);atomic_store(&anchor,mach_absolute_time());}
    pthread_mutex_unlock(&stateLock);AudioObjectPropertyAddress a={kAudioDevicePropertyDeviceIsRunning,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
    return host->PropertiesChanged(host,deviceID,1,&a);
}
static OSStatus stopIO(AudioServerPlugInDriverRef self,AudioObjectID object,UInt32 client) {
    (void)client;if(self!=driver||object!=deviceID)return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&stateLock);uint32_t users=atomic_load(&ioUsers);if(users&&atomic_fetch_sub(&ioUsers,1)==1){atomic_store(&anchor,0);rv_speaker_discard(&ring);atomic_store(&lastWriteTime,0);}
    pthread_mutex_unlock(&stateLock);AudioObjectPropertyAddress a={kAudioDevicePropertyDeviceIsRunning,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
    return host->PropertiesChanged(host,deviceID,1,&a);
}
static OSStatus timestamp(AudioServerPlugInDriverRef self,AudioObjectID object,UInt32 client,Float64 *sample,UInt64 *time,UInt64 *seed) {
    (void)client;if(self!=driver||object!=deviceID||!sample||!time||!seed)return kAudioHardwareBadObjectError;
    uint64_t base=atomic_load(&anchor),now=mach_absolute_time();if(!base)base=now;
    uint64_t frames=(uint64_t)((now-base)/ticksPerFrame/512)*512;*sample=(double)frames;*time=base+(uint64_t)(frames*ticksPerFrame);*seed=atomic_load(&clockSeed);return noErr;
}
static OSStatus willIO(AudioServerPlugInDriverRef self,AudioObjectID object,UInt32 client,UInt32 operation,Boolean *will,Boolean *inPlace) {
    (void)client;if(self!=driver||object!=deviceID||!will||!inPlace)return kAudioHardwareBadObjectError;*will=operation==kAudioServerPlugInIOOperationWriteMix;*inPlace=true;return noErr;
}
static OSStatus boundaryIO(AudioServerPlugInDriverRef self,AudioObjectID object,UInt32 client,UInt32 operation,UInt32 frames,const AudioServerPlugInIOCycleInfo *cycle) {
    (void)client;(void)operation;(void)frames;(void)cycle;return self==driver&&object==deviceID?noErr:kAudioHardwareBadObjectError;
}
static OSStatus performIO(AudioServerPlugInDriverRef self,AudioObjectID object,AudioObjectID stream,UInt32 client,UInt32 operation,UInt32 frames,
                          const AudioServerPlugInIOCycleInfo *cycle,void *mainBuffer,void *secondaryBuffer) {
    (void)client;(void)secondaryBuffer;
    if(self!=driver||object!=deviceID||stream!=streamID||!cycle||!mainBuffer||frames>RV_SPEAKER_MAX_IO_FRAMES)return kAudioHardwareIllegalOperationError;
    if(operation!=kAudioServerPlugInIOOperationWriteMix)return noErr;
    uint32_t bits=atomic_load(&gainBits);float gain;memcpy(&gain,&bits,4);
    if(atomic_load(&muted))gain=0;
    rv_speaker_write(&ring,mainBuffer,frames,gain);
    atomic_store_explicit(&lastWriteTime,mach_absolute_time(),memory_order_release);
    return noErr;
}
static AudioServerPlugInDriverInterface interface={.QueryInterface=query,.AddRef=retain,.Release=release,.Initialize=initialize,
    .CreateDevice=createDevice,.DestroyDevice=destroyDevice,.AddDeviceClient=clientChange,.RemoveDeviceClient=clientChange,
    .PerformDeviceConfigurationChange=configChange,.AbortDeviceConfigurationChange=configChange,.HasProperty=has,.IsPropertySettable=settable,
    .GetPropertyDataSize=dataSize,.GetPropertyData=dataGet,.SetPropertyData=dataSet,.StartIO=startIO,.StopIO=stopIO,.GetZeroTimeStamp=timestamp,
    .WillDoIOOperation=willIO,.BeginIOOperation=boundaryIO,.DoIOOperation=performIO,.EndIOOperation=boundaryIO};
__attribute__((visibility("default"))) void *ReVoyageSpeakerFactory(CFAllocatorRef allocator,CFUUIDRef type) {
    (void)allocator;return CFEqual(type,kAudioServerPlugInTypeUUID)?driver:NULL;
}
