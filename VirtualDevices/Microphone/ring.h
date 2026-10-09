#ifndef RV_MICROPHONE_RING_H
#define RV_MICROPHONE_RING_H
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>
enum { RV_MIC_RING_FRAMES=8192, RV_MIC_MAX_FRAMES=4096, RV_MIC_PUSH='rvmp', RV_MIC_CLEAR='rvcl' };
typedef struct { _Atomic uint64_t stamp[RV_MIC_RING_FRAMES]; _Atomic uint32_t bits[RV_MIC_RING_FRAMES]; } RVMicRing;
static inline void rv_mic_clear(RVMicRing *ring) {
    for(size_t i=0;i<RV_MIC_RING_FRAMES;i++) atomic_store_explicit(&ring->stamp[i],UINT64_MAX,memory_order_release);
}
static inline void rv_mic_write(RVMicRing *ring,uint64_t position,float value) {
    size_t index=position%RV_MIC_RING_FRAMES; uint32_t bits; memcpy(&bits,&value,4);
    atomic_store_explicit(&ring->stamp[index],UINT64_MAX,memory_order_release);
    atomic_store_explicit(&ring->bits[index],bits,memory_order_release);
    atomic_store_explicit(&ring->stamp[index],position,memory_order_release);
}
static inline float rv_mic_read(RVMicRing *ring,uint64_t position) {
    size_t index=position%RV_MIC_RING_FRAMES;
    if(atomic_load_explicit(&ring->stamp[index],memory_order_acquire)!=position)return 0;
    uint32_t bits=atomic_load_explicit(&ring->bits[index],memory_order_acquire);
    if(atomic_load_explicit(&ring->stamp[index],memory_order_acquire)!=position)return 0;
    float value; memcpy(&value,&bits,4); return value;
}
#endif
