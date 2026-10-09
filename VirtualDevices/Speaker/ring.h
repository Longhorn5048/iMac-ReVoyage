#ifndef RV_SPEAKER_RING_H
#define RV_SPEAKER_RING_H
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
enum { RV_SPEAKER_RING_FRAMES=8192, RV_SPEAKER_MAX_IO_FRAMES=4096,
       RV_SPEAKER_PULL_FRAMES=480, RV_SPEAKER_MAX_LAG=2400,
       RV_SPEAKER_PULL='rvsd', RV_SPEAKER_CLEAR='rvsc' };
/* One realtime producer, serialized non-realtime readers. Atomic slots allow
 * the producer to overwrite stale data without waiting for a network reader. */
typedef struct {
    _Atomic uint64_t stamp[RV_SPEAKER_RING_FRAMES];
    _Atomic uint64_t samples[RV_SPEAKER_RING_FRAMES];
    _Atomic uint64_t end;
    uint64_t cursor; // accessed only under the driver's property mutex
} RVSpeakerRing;
static inline void rv_speaker_initialize(RVSpeakerRing *r) {
    for(unsigned i=0;i<RV_SPEAKER_RING_FRAMES;i++)atomic_store(&r->stamp[i],UINT64_MAX);
    atomic_store(&r->end,0);r->cursor=0;
}
static inline void rv_speaker_discard(RVSpeakerRing *r) { r->cursor=atomic_load_explicit(&r->end,memory_order_acquire); }
static inline void rv_speaker_write(RVSpeakerRing *r,const float *samples,uint32_t frames,float gain) {
    uint64_t end=atomic_load_explicit(&r->end,memory_order_relaxed);
    for(uint32_t i=0;i<frames;i++) {
        float pair[2]={samples[2*i]*gain,samples[2*i+1]*gain};uint64_t bits;memcpy(&bits,pair,8);
        size_t slot=(end+i)%RV_SPEAKER_RING_FRAMES;
        atomic_store_explicit(&r->stamp[slot],UINT64_MAX,memory_order_seq_cst);
        atomic_store_explicit(&r->samples[slot],bits,memory_order_seq_cst);
        atomic_store_explicit(&r->stamp[slot],end+i,memory_order_seq_cst);
    }
    atomic_store_explicit(&r->end,end+frames,memory_order_release);
}
static inline uint32_t rv_speaker_pull(RVSpeakerRing *r,int16_t *out,uint32_t capacityFrames) {
    uint64_t end=atomic_load_explicit(&r->end,memory_order_acquire);
    if(r->cursor>end)r->cursor=end;
    // After an outage take only recent audio, never replay an old buffer.
    if(end-r->cursor>RV_SPEAKER_MAX_LAG)r->cursor=end-(end<capacityFrames?end:capacityFrames);
    uint32_t count=(uint32_t)(end-r->cursor);if(count>capacityFrames)count=capacityFrames;
    for(uint32_t i=0;i<count;i++) {
        uint64_t position=r->cursor+i;size_t slot=position%RV_SPEAKER_RING_FRAMES;
        uint64_t before=atomic_load_explicit(&r->stamp[slot],memory_order_seq_cst);
        uint64_t bits=atomic_load_explicit(&r->samples[slot],memory_order_seq_cst);
        uint64_t after=atomic_load_explicit(&r->stamp[slot],memory_order_seq_cst);
        float pair[2]={0,0};if(before==position&&after==position)memcpy(pair,&bits,8);
        for(unsigned channel=0;channel<2;channel++) {
            float value=isfinite(pair[channel])?fmaxf(-1,fminf(1,pair[channel])):0;
            out[2*i+channel]=(int16_t)lrintf(value*(value<0?32768:32767));
        }
    }
    r->cursor+=count;return count;
}
#endif
