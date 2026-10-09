#include "../DisplaySignalState.h"
#include "../../TargetBridge-Shared/DisplayPower.h"
#include <assert.h>
#include <stdio.h>

static unsigned checks;
#define CHECK(x) do { assert(x); checks++; } while (0)
static void frame(struct rv_display_signal_state *s, uint64_t t) {
    rv_display_signal_set_network(s, 1, t, t);
}
int main(void) {
    struct rv_display_signal_state s;
    rv_display_signal_init(&s);
    CHECK(rv_display_power_update(&s, 1000) == RV_POWER_RESCUE_LOCK);
    CHECK(rv_display_power_update(&s, 3600000) == RV_POWER_RESCUE_LOCK); /* No no-signal sleep. */
    rv_display_signal_note_hdmi_frame(&s, 1000);
    CHECK(rv_display_power_update(&s, 1000) == RV_POWER_RESCUE_LOCK);
    CHECK(rv_display_signal_active_sources(&s, 3000) == RV_DISPLAY_SIGNAL_HDMI_FRAMES);
    CHECK(rv_display_signal_active_sources(&s, 3001) == RV_DISPLAY_SIGNAL_NONE);
    CHECK(rv_display_power_update(&s, 3001) == RV_POWER_RESCUE_LOCK);
    rv_display_signal_note_hdmi_frame(&s, 4000); /* HDMI reconnection never unlocks. */
    CHECK(rv_display_power_update(&s, 4000) == RV_POWER_RESCUE_LOCK);

    frame(&s, 5000);
    CHECK(rv_display_power_update(&s, 5000) == RV_POWER_RESCUE_LOCK);
    frame(&s, 6000);
    CHECK(rv_display_power_update(&s, 6000) == RV_POWER_RESCUE_LOCK);
    rv_display_signal_set_network(&s, 0, 0, 6500);
    frame(&s, 7000); frame(&s, 8000);
    CHECK(rv_display_power_update(&s, 8000) == RV_POWER_RESCUE_LOCK); /* Failed recovery resets. */
    frame(&s, 9000);
    CHECK(rv_display_power_update(&s, 9000) == RV_POWER_NORMAL);
    CHECK(rv_display_power_update(&s, 10999) == RV_POWER_NORMAL);
    CHECK(rv_display_power_update(&s, 11000) == RV_POWER_RESCUE_LOCK); /* Silent crash, even without inactive. */

    /* A single frame refreshed by repeated notifications cannot unlock. */
    rv_display_signal_init(&s);
    frame(&s, 1000);
    for (uint64_t t = 1100; t <= 4000; t += 100) {
        rv_display_signal_set_network(&s, 1, 1000, t);
        CHECK(rv_display_power_update(&s, t) == RV_POWER_RESCUE_LOCK);
    }
    rv_display_signal_set_network(&s, 1, 0, 5000); /* Legacy/heartbeat-only notification. */
    CHECK(rv_display_power_update(&s, 5000) == RV_POWER_RESCUE_LOCK);
    rv_display_signal_set_network(&s, 1, 6001, 6000); /* Future/out-of-order clock. */
    CHECK(rv_display_power_update(&s, 6000) == RV_POWER_RESCUE_LOCK);
    frame(&s, 7000); frame(&s, 8000);
    rv_display_signal_set_network(&s, 1, 7500, 8500); /* Stale/reordered frame. */
    frame(&s, 9000); frame(&s, 10000);
    CHECK(rv_display_power_update(&s, 10000) == RV_POWER_RESCUE_LOCK);
    frame(&s, 11000);
    CHECK(rv_display_power_update(&s, 11000) == RV_POWER_NORMAL);

    rv_display_signal_init(&s);
    frame(&s, 1000); frame(&s, 2000); frame(&s, 3600); /* Recovery gap > 1.5s. */
    CHECK(rv_display_power_update(&s, 3600) == RV_POWER_RESCUE_LOCK);
    frame(&s, 4600);
    CHECK(rv_display_power_update(&s, 4600) == RV_POWER_RESCUE_LOCK);
    frame(&s, 5600);
    CHECK(rv_display_power_update(&s, 5600) == RV_POWER_NORMAL);

    rv_display_power_set_manual_off(&s, 1);
    CHECK(rv_display_power_update(&s, 5600) == RV_POWER_MANUAL_OFF);
    rv_display_signal_set_network(&s, 0, 0, 6000);
    rv_display_signal_note_hdmi_frame(&s, 6000);
    CHECK(rv_display_power_update(&s, 6000) == RV_POWER_MANUAL_OFF);
    rv_display_power_set_manual_off(&s, 0);
    CHECK(rv_display_power_update(&s, 6000) == RV_POWER_RESCUE_LOCK);
    rv_display_power_set_manual_off(&s, 1);
    frame(&s, 7000); frame(&s, 8000); frame(&s, 9000);
    CHECK(rv_display_power_update(&s, 9000) == RV_POWER_MANUAL_OFF); /* Recovery never cancels explicit off. */
    rv_display_power_set_manual_off(&s, 0);
    CHECK(rv_display_power_update(&s, 9000) == RV_POWER_NORMAL);
    rv_display_power_set_manual_off(&s, 1);
    rv_display_signal_init(&s);
    CHECK(rv_display_power_update(&s, 10000) == RV_POWER_RESCUE_LOCK); /* Restart clears manual intent. */

    CHECK(!rv_display_signal_hdmi_audio_allowed(RV_DISPLAY_SIGNAL_NONE));
    CHECK(rv_display_signal_hdmi_audio_allowed(RV_DISPLAY_SIGNAL_HDMI_FRAMES));
    CHECK(!rv_display_signal_hdmi_audio_allowed(RV_DISPLAY_SIGNAL_NETWORK | RV_DISPLAY_SIGNAL_HDMI_FRAMES));
    CHECK(!rv_display_signal_hdmi_audio_allowed(RV_DISPLAY_SIGNAL_NETWORK));
    frame(&s, 11000); rv_display_signal_note_hdmi_frame(&s, 12999);
    CHECK(!rv_display_signal_hdmi_audio_allowed(rv_display_signal_active_sources(&s, 12999)));
    CHECK(rv_display_signal_hdmi_audio_allowed(rv_display_signal_active_sources(&s, 13000)));
    int hidden = 0, hides = 0, shows = 0;
    for (int tick = 0; tick < 120; tick++) {
        int action = rv_display_cursor_action(hidden, 1);
        if (action > 0) { hides++; hidden = 1; }
    }
    CHECK(hides == 1);
    int action = rv_display_cursor_action(hidden, 0);
    if (action < 0) { shows++; hidden = 0; }
    CHECK(shows == 1 && !hidden);
    CHECK(rv_display_cursor_action(hidden, 0) == 0);
    CHECK(rv_display_cursor_action(1, 0) == -1);

    int on = -1;
    uint64_t id = 0;
    uint8_t off[] = {0, 1, 2, 3, 4, 5, 6, 7, 8}, wake[] = {1, 1, 2, 3, 4, 5, 6, 7, 8};
    uint8_t invalid[] = {2, 1, 2, 3, 4, 5, 6, 7, 8}, zero_id[9] = {0}, long_payload[10] = {0};
    CHECK(rv_display_power_decode(off, 9, &on, &id) && on == 0 && id == 0x0102030405060708ULL);
    CHECK(rv_display_power_decode(wake, 9, &on, &id) && on == 1);
    CHECK(!rv_display_power_decode(invalid, 9, &on, &id));
    CHECK(!rv_display_power_decode(long_payload, 10, &on, &id));
    CHECK(!rv_display_power_decode(zero_id, 9, &on, &id));
    CHECK(!rv_display_power_decode(NULL, 0, &on, &id));
    CHECK(!rv_display_power_decode(wake, 9, NULL, &id));
    CHECK(!rv_display_power_decode(wake, 9, &on, NULL));
    uint8_t encoded[8];
    rv_display_power_write_id(encoded, UINT64_MAX);
    CHECK(rv_display_power_read_id(encoded) == UINT64_MAX);
    printf("Rescue Lock / manual power / audio / cursor: %u checks passed\n", checks);
    return 0;
}
