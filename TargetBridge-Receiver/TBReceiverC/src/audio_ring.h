#ifndef TB_AUDIO_RING_H
#define TB_AUDIO_RING_H

#include <stdint.h>
#include <stddef.h>
#include <string.h>

#define AUDIO_BUF_CAP 192000 /* 1 second of 48 kHz stereo 16-bit PCM */
#define TB_AUDIO_BACKLOG_BYTES 28800 /* 150 ms */

/* Caller holds the SDL audio lock. Reject oversized or partial PCM frames
 * before changing ring state; only discard bytes that are actually queued. */
static inline int tb_audio_ring_write(uint8_t *buffer, int *head, int *tail,
                                     int *size, const uint8_t *payload, size_t len) {
    if (len > TB_AUDIO_BACKLOG_BYTES || len % 4 != 0) return -1;
    int count = (int)len;
    int excess = *size + count - TB_AUDIO_BACKLOG_BYTES;
    if (excess > 0) {
        *tail = (*tail + excess) % AUDIO_BUF_CAP;
        *size -= excess;
    }
    int first = AUDIO_BUF_CAP - *head;
    if (first >= count) {
        if (count > 0) memcpy(buffer + *head, payload, len);
    } else {
        memcpy(buffer + *head, payload, (size_t)first);
        memcpy(buffer, payload + first, len - (size_t)first);
    }
    *head = (*head + count) % AUDIO_BUF_CAP;
    *size += count;
    return 0;
}

#endif
