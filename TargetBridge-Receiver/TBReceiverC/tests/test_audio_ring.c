#include "audio_ring.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>

int main(void) {
    uint8_t buffer[AUDIO_BUF_CAP] = {0};
    uint8_t *payload = malloc(AUDIO_BUF_CAP * 2);
    assert(payload);
    memset(payload, 0xA5, AUDIO_BUF_CAP * 2);
    int head = 0, tail = 0, size = 0;

    assert(tb_audio_ring_write(buffer, &head, &tail, &size, payload, 4096) == 0);
    assert(head == 4096 && tail == 0 && size == 4096);
    /* Oversized packets used to make size negative, then write past buffer. */
    assert(tb_audio_ring_write(buffer, &head, &tail, &size, payload, AUDIO_BUF_CAP * 2) == -1);
    assert(head == 4096 && tail == 0 && size == 4096);
    assert(tb_audio_ring_write(buffer, &head, &tail, &size, payload, SIZE_MAX) == -1);
    assert(tb_audio_ring_write(buffer, &head, &tail, &size, payload, 3) == -1);
    assert(head == 4096 && tail == 0 && size == 4096);

    assert(tb_audio_ring_write(buffer, &head, &tail, &size, payload, TB_AUDIO_BACKLOG_BYTES) == 0);
    assert(size == TB_AUDIO_BACKLOG_BYTES && tail == 4096);
    /* Repeated writes wrap both ends and keep only the newest 150 ms. */
    for (int i = 0; i < 1000; i++) {
        memset(payload, i % 256, 4096);
        assert(tb_audio_ring_write(buffer, &head, &tail, &size, payload, 4096) == 0);
        assert(size == TB_AUDIO_BACKLOG_BYTES);
        assert((tail + size) % AUDIO_BUF_CAP == head);
        assert(buffer[(head + AUDIO_BUF_CAP - 1) % AUDIO_BUF_CAP] == (uint8_t)(i % 256));
    }
    free(payload);
    puts("audio ring: oversized, partial, backlog and wraparound checks passed");
    return 0;
}
