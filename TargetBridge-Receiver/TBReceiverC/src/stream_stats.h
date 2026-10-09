#ifndef TB_STREAM_STATS_H
#define TB_STREAM_STATS_H
#include <stdint.h>
#include <string.h>

struct tb_stream_stats {
    uint64_t sample_ms, bytes, received, submitted, uploaded;
    uint64_t latency_count;
    double latency_sum_ms;
    double receive_fps, submit_fps, receive_mbps, skipped_percent, latency_ms;
    int latency_valid;
};

static inline void tb_stream_stats_reset(struct tb_stream_stats *s, uint64_t now,
    uint64_t bytes, uint64_t received, uint64_t submitted, uint64_t uploaded) {
    memset(s, 0, sizeof(*s));
    s->sample_ms = now; s->bytes = bytes; s->received = received;
    s->submitted = submitted; s->uploaded = uploaded;
}

static inline void tb_stream_stats_note_latency(struct tb_stream_stats *s,
    uint64_t packet_ns, uint64_t submit_ns) {
    if (!packet_ns || submit_ns < packet_ns) return;
    s->latency_sum_ms += (double)(submit_ns - packet_ns) / 1000000.0;
    s->latency_count++;
}

static inline int tb_stream_stats_sample(struct tb_stream_stats *s, uint64_t now,
    uint64_t bytes, uint64_t received, uint64_t submitted, uint64_t uploaded) {
    if (now < s->sample_ms || bytes < s->bytes || received < s->received ||
        submitted < s->submitted || uploaded < s->uploaded) {
        tb_stream_stats_reset(s, now, bytes, received, submitted, uploaded);
        return 0;
    }
    uint64_t elapsed = now - s->sample_ms;
    if (elapsed < 1000) return 0;
    double seconds = (double)elapsed / 1000.0;
    uint64_t uploads = uploaded - s->uploaded, presents = submitted - s->submitted;
    s->receive_fps = (double)(received - s->received) / seconds;
    s->submit_fps = (double)presents / seconds;
    s->receive_mbps = (double)(bytes - s->bytes) * 8.0 / seconds / 1000000.0;
    s->skipped_percent = uploads > presents ? (double)(uploads - presents) * 100.0 / (double)uploads : 0;
    s->latency_valid = s->latency_count > 0;
    s->latency_ms = s->latency_valid ? s->latency_sum_ms / (double)s->latency_count : 0;
    s->latency_sum_ms = 0; s->latency_count = 0;
    s->sample_ms = now; s->bytes = bytes; s->received = received;
    s->submitted = submitted; s->uploaded = uploaded;
    return 1;
}
#endif
