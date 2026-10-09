#include "stream_stats.h"
#include "../../../TargetBridge-Shared/ReceiverDebug.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

int main(void) {
    unsigned int held = 0, action;
    assert(rv_receiver_shortcut(&held, 2, 1, 0, 0, &action) && action == RV_RECEIVER_SHORTCUT_DEBUG);
    assert(rv_receiver_shortcut(&held, 2, 1, 1, 0, &action) && action == 0);
    assert(rv_receiver_shortcut(&held, 2, 0, 0, 1, &action) && action == 0 && held == 0);
    assert(!rv_receiver_shortcut(&held, 2, 1, 0, 1, &action)); /* Cmd/Option/Ctrl+D pass through. */
    assert(!rv_receiver_shortcut(&held, 2, 0, 0, 0, &action));
    assert(!rv_receiver_shortcut(&held, 1, 1, 0, 0, &action));
    assert(rv_receiver_shortcut(&held, 15, 1, 0, 0, &action) && action == RV_RECEIVER_SHORTCUT_RESCUE);
    assert(rv_receiver_shortcut(&held, 15, 0, 0, 0, &action));

    struct tb_stream_stats stats;
    tb_stream_stats_reset(&stats, 1000, 100, 10, 5, 6);
    tb_stream_stats_note_latency(&stats, 1000000000, 1002000000);
    tb_stream_stats_note_latency(&stats, 1000000000, 1004000000);
    assert(!tb_stream_stats_sample(&stats, 1999, 1000100, 70, 35, 66));
    assert(tb_stream_stats_sample(&stats, 3000, 1000100, 130, 65, 126));
    assert(fabs(stats.receive_fps - 60) < 0.001 && fabs(stats.submit_fps - 30) < 0.001);
    assert(fabs(stats.receive_mbps - 4) < 0.001 && fabs(stats.skipped_percent - 50) < 0.001);
    assert(stats.latency_valid && stats.latency_ms == 3);
    tb_stream_stats_note_latency(&stats, 2000, 1000); /* Reversed clock is not latency. */
    assert(tb_stream_stats_sample(&stats, 4000, 1000100, 130, 65, 126));
    assert(stats.receive_fps == 0 && stats.receive_mbps == 0 && !stats.latency_valid && stats.skipped_percent == 0);
    assert(!tb_stream_stats_sample(&stats, 5000, 0, 0, 0, 0)); /* Reconnect/counter reset. */
    assert(stats.sample_ms == 5000 && !stats.latency_valid);
    puts("Receiver debug: shortcut repeat/releases, modifiers, measured rates, coalescing, latency, idle and reset passed");
    return 0;
}
