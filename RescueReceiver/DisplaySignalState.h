#ifndef REVOYAGE_DISPLAY_SIGNAL_STATE_H
#define REVOYAGE_DISPLAY_SIGNAL_STATE_H

#include <stdint.h>

#define RV_NETWORK_SIGNAL_TIMEOUT_MS 3500ULL
#define RV_HDMI_FRAME_TIMEOUT_MS 2000ULL
#define RV_NETWORK_RECOVERY_MS 2000ULL
#define RV_NETWORK_RECOVERY_MAX_GAP_MS 1500ULL
#define RV_NETWORK_RECOVERY_FRAME_AGE_MS 500ULL

enum rv_display_signal_source {
    RV_DISPLAY_SIGNAL_NONE = 0,
    RV_DISPLAY_SIGNAL_NETWORK = 1u << 0,
    RV_DISPLAY_SIGNAL_HDMI_FRAMES = 1u << 1
};

static inline int rv_display_signal_hdmi_audio_allowed(unsigned int sources) {
    return (sources & RV_DISPLAY_SIGNAL_HDMI_FRAMES) && !(sources & RV_DISPLAY_SIGNAL_NETWORK);
}

/* +1 hides once, -1 balances that hide, 0 leaves the cursor count alone. */
static inline int rv_display_cursor_action(int hidden, int active) {
    return !!active - !!hidden;
}

enum rv_display_power_mode { RV_POWER_NORMAL, RV_POWER_RESCUE_LOCK, RV_POWER_MANUAL_OFF };

struct rv_display_signal_state {
    uint64_t network_updated_ms;
    uint64_t network_frame_ms;
    uint64_t hdmi_frame_ms;
    uint64_t recovery_started_ms;
    int network_active;
    int recovering;
    int rescue_locked;
    int manual_off;
};

void rv_display_signal_init(struct rv_display_signal_state *state);
/* frame_ms is the Receiver's actual presented-frame monotonic timestamp,
 * not a heartbeat or the time that a notification happened to arrive. */
void rv_display_signal_set_network(struct rv_display_signal_state *state,
                                   int active, uint64_t frame_ms, uint64_t now_ms);
void rv_display_signal_note_hdmi_frame(struct rv_display_signal_state *state, uint64_t now_ms);
unsigned int rv_display_signal_active_sources(const struct rv_display_signal_state *state, uint64_t now_ms);
enum rv_display_power_mode rv_display_power_update(struct rv_display_signal_state *state, uint64_t now_ms);
void rv_display_power_set_manual_off(struct rv_display_signal_state *state, int off);

#endif
