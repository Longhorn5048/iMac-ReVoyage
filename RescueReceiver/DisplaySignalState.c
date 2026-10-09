#include "DisplaySignalState.h"
#include <string.h>

static void latch_rescue(struct rv_display_signal_state *state) {
    state->rescue_locked = 1;
    state->recovering = 0;
    state->recovery_started_ms = 0;
}

void rv_display_signal_init(struct rv_display_signal_state *state) {
    if (!state) return;
    memset(state, 0, sizeof(*state));
    latch_rescue(state); /* Boot/service restart always chooses visibility. */
}

unsigned int rv_display_signal_active_sources(const struct rv_display_signal_state *state, uint64_t now_ms) {
    if (!state) return RV_DISPLAY_SIGNAL_NONE;
    unsigned int sources = RV_DISPLAY_SIGNAL_NONE;
    if (state->network_active && state->network_updated_ms > 0 && state->network_frame_ms > 0 &&
        now_ms >= state->network_updated_ms && now_ms >= state->network_frame_ms &&
        now_ms - state->network_updated_ms <= RV_NETWORK_SIGNAL_TIMEOUT_MS &&
        now_ms - state->network_frame_ms < RV_HDMI_FRAME_TIMEOUT_MS)
        sources |= RV_DISPLAY_SIGNAL_NETWORK;
    if (state->hdmi_frame_ms > 0 && now_ms >= state->hdmi_frame_ms &&
        now_ms - state->hdmi_frame_ms <= RV_HDMI_FRAME_TIMEOUT_MS)
        sources |= RV_DISPLAY_SIGNAL_HDMI_FRAMES;
    return sources;
}

enum rv_display_power_mode rv_display_power_update(struct rv_display_signal_state *state, uint64_t now_ms) {
    if (!state) return RV_POWER_RESCUE_LOCK;
    if (!(rv_display_signal_active_sources(state, now_ms) & RV_DISPLAY_SIGNAL_NETWORK)) latch_rescue(state);
    return state->manual_off ? RV_POWER_MANUAL_OFF :
           state->rescue_locked ? RV_POWER_RESCUE_LOCK : RV_POWER_NORMAL;
}

void rv_display_signal_set_network(struct rv_display_signal_state *state,
                                   int active, uint64_t frame_ms, uint64_t now_ms) {
    if (!state) return;
    (void)rv_display_power_update(state, now_ms);
    uint64_t previous_frame = state->network_frame_ms;
    state->network_active = active != 0;
    state->network_updated_ms = now_ms;
    state->network_frame_ms = frame_ms;
    if (!active || !frame_ms || now_ms < frame_ms ||
        now_ms - frame_ms > RV_NETWORK_RECOVERY_FRAME_AGE_MS ||
        (previous_frame && frame_ms <= previous_frame)) {
        latch_rescue(state);
        return;
    }
    if (previous_frame && frame_ms - previous_frame > RV_NETWORK_RECOVERY_MAX_GAP_MS) latch_rescue(state);
    if (state->rescue_locked) {
        if (!state->recovering) {
            state->recovering = 1;
            state->recovery_started_ms = frame_ms;
        } else if (frame_ms - state->recovery_started_ms >= RV_NETWORK_RECOVERY_MS) {
            state->rescue_locked = 0;
            state->recovering = 0;
        }
    }
}

void rv_display_signal_note_hdmi_frame(struct rv_display_signal_state *state, uint64_t now_ms) {
    if (state) state->hdmi_frame_ms = now_ms;
}

void rv_display_power_set_manual_off(struct rv_display_signal_state *state, int off) {
    if (state) state->manual_off = off != 0;
}
