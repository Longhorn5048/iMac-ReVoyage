#ifndef REVOYAGE_SHELL_PRESENTATION_H
#define REVOYAGE_SHELL_PRESENTATION_H

#include <stdint.h>
#include "DisplaySignalState.h"

/* The Rescue process is the iMac's display shell. It owns the screen whenever
 * the network stream is not on it, so the iMac's own desktop is reachable only
 * through an explicit exit. */
enum rv_shell_view {
    RV_SHELL_VIEW_NETWORK,   /* Network Receiver window is in front. */
    RV_SHELL_VIEW_HDMI,      /* Shell covers the screen with HDMI/UVC video. */
    RV_SHELL_VIEW_NO_SIGNAL, /* Shell covers the screen with the no-signal page. */
    RV_SHELL_VIEW_DESKTOP    /* User explicitly left the shell. */
};

#define RV_SHELL_EXIT_CONFIRM_MS 1500ULL
#define RV_SHELL_NETWORK_HANDOFF_MS 800ULL

static inline enum rv_shell_view rv_shell_view_for(unsigned int sources, int hdmi_active,
                                                   int manual_rescue, int dismissed) {
    if (dismissed) return RV_SHELL_VIEW_DESKTOP;
    if ((sources & RV_DISPLAY_SIGNAL_NETWORK) && !manual_rescue) return RV_SHELL_VIEW_NETWORK;
    if (hdmi_active && (sources & RV_DISPLAY_SIGNAL_HDMI_FRAMES)) return RV_SHELL_VIEW_HDMI;
    return RV_SHELL_VIEW_NO_SIGNAL;
}

static inline int rv_shell_view_covers(enum rv_shell_view view) {
    return view == RV_SHELL_VIEW_HDMI || view == RV_SHELL_VIEW_NO_SIGNAL;
}

/* Leaving the shell takes two Esc presses so a stray key cannot expose the
 * desktop. Returns 1 when this press confirms the exit. */
static inline int rv_shell_exit_press(uint64_t *armed_ms, uint64_t now_ms) {
    if (*armed_ms && now_ms >= *armed_ms && now_ms - *armed_ms <= RV_SHELL_EXIT_CONFIRM_MS) {
        *armed_ms = 0;
        return 1;
    }
    *armed_ms = now_ms ? now_ms : 1;
    return 0;
}

/* Optional monitor-style standby. timeout_ms == 0 keeps the panel lit for as
 * long as there is no signal (the default). Local keyboard/mouse activity
 * restarts the countdown, so the page stays readable while someone is there. */
static inline int rv_shell_no_signal_should_sleep(uint64_t no_signal_since_ms, uint64_t now_ms,
                                                  uint64_t hid_idle_ms, uint64_t timeout_ms) {
    if (!timeout_ms || !no_signal_since_ms || now_ms < no_signal_since_ms) return 0;
    return now_ms - no_signal_since_ms >= timeout_ms && hid_idle_ms >= timeout_ms;
}

#endif
