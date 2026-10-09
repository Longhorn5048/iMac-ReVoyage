/* main.c — TBReceiver pure-C entry point.
 *
 * Single-threaded event loop:
 *   - SDL_PollEvent (non-blocking)  → quit detection
 *   - non-blocking socket read     → packet parser → decoder → renderer
 *   - 1ms sleep when idle           → CPU yield
 *
 * No ObjC. No Cocoa NSApplication. No autoreleasepool.
 * Crashes from objc_release/__CFAutoreleasePoolPop cannot happen here:
 * no Objective-C runtime objects are managed by us. SDL2 may use Cocoa
 * windowing internally on macOS, but with this minimal setup the OCLP-
 * triggered bug pattern (corrupt object in main-thread ARP) is dramatically
 * less likely than with SwiftUI / AppKit programmatic UIs.
 */

#include "net.h"
#include "audio_ring.h"
#include "control_send.h"
#include "session_auth.h"
#include "receiver_identity.h"
#include "input_permissions.h"
#include "stream_stats.h"
#include "decoder.h"
#include "display.h"
#include "proto.h"
#include "../../../TargetBridge-Shared/DisplayPower.h"
#include "../../../TargetBridge-Shared/LocalConnection.h"
#include "../../../TargetBridge-Shared/ReceiverDebug.h"
#include "../../../RescueReceiver/DisplaySignalState.h"
#include "tb_gesture_bridge.h"
#include "tb_i18n.h"

#include <SDL.h>
#include <ApplicationServices/ApplicationServices.h>
#include <dns_sd.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreAudio/CoreAudio.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <CommonCrypto/CommonHMAC.h>

/* kAudioObjectPropertyElementMain is the macOS 12+ SDK spelling; older SDKs
 * only define kAudioObjectPropertyElementMaster (both are numerically 0). */
#ifndef kAudioObjectPropertyElementMain
#define kAudioObjectPropertyElementMain kAudioObjectPropertyElementMaster
#endif

#include <errno.h>
#include <ctype.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <stdarg.h>
#include <time.h>
#include <unistd.h>


/* Reap a connected sender that has gone completely silent. The sender
 * heartbeats every 2s and streams frames continuously, so 10s of silence
 * (5 missed heartbeats) means it died without a FIN. */
#define TB_SENDER_IDLE_TIMEOUT_MS 10000

struct app {
    struct tb_display *disp;
    struct tb_decoder *dec;
    struct tb_parser   parser;

    int      server_fd;
    int      client_fd;
    struct tb_control_send control_send;

    uint64_t frames;
    uint64_t last_fps_tick_ms;
    uint64_t last_fps_count;
    uint64_t last_ip_check_ms;
    uint64_t last_recv_ms;      /* idle watchdog: last time the sender sent anything */
    uint64_t auth_started_ms;
    int      session_authenticated;
    struct rv_display_signal_state display_health;
    uint64_t received_video_frames, presented_batches, decode_errors;
    int raw_video_active;
    int stream_codec, stream_width, stream_height;
    int debug_visible, manual_rescue;
    unsigned int pending_local_actions, shortcut_held;
    struct tb_stream_stats stream_stats;
    uint64_t received_bytes, current_video_packet_ns, batch_frame_packet_ns;
    char debug_line1[768], debug_line2[768];
    uint64_t last_brightness_poll_ms;
    uint64_t last_video_frame_ms; /* rescue takes over when frames stop */
    uint64_t last_display_state_notify_ms;
    int      last_display_state_notify_active;
    int      display_state_notify_sent;
    int      close_requested;
    int      have_video_frame;
    int      batch_frame_width, batch_frame_height;
    /* A real streaming session has begun (the sender sent a session packet, not
     * just a transient probe like a UI-language push). Gates the fullscreen
     * "connecting" splash so a bare/short-lived connection doesn't flash it. */
    int      session_active;

    char     ip_text[64];
    char     tb_ip_text[64];
    char     net_ip_text[64];
    char     display_host[128]; /* short hostname (or hostname+IP), cached at startup */
    char     status_text[128];
    char     sender_text[128];
    char     panel_text[128];
    char     mode_text[128];
    char     language_pref[8];
    int      brightness_commands_only;
    double   settings_brightness;
    double   settings_volume;
    uint32_t sleep_after_no_signal_seconds;
    uint64_t settings_revision;
    uint64_t last_sender_settings_revision;
    uint8_t  settings_nonce[32];
    int      settings_nonce_valid;
    char     pairing_key[129];
    char     receiver_id[37];
    char     language_text[96];
    char     permissions_text[160];
    char     sender_ui_language[8];
    char     input_control_mode[32];
    int      last_input_monitoring_trusted;
    int      last_accessibility_trusted;
    uint64_t last_permissions_poll_ms;

    DNSServiceRef bonjour_ref;
    char     bonjour_name[128];
    CFMachPortRef input_tap;
    CFRunLoopSourceRef input_tap_source;
    int      input_tap_consumes_events;

    SDL_AudioDeviceID audio_device;

    uint8_t audio_buf[AUDIO_BUF_CAP];
    int     audio_buf_head;
    int     audio_buf_tail;
    int     audio_buf_size;

    uint64_t input_events_sent;
    uint64_t input_events_received;
    uint64_t last_target_switch_ms;
    uint64_t last_space_switch_ms;
    uint64_t last_space_gesture_ms;
    int      space_gesture_accum_x;
    int      sent_command_down;
    int      sent_shift_down;
    int      sent_option_down;
    int      sent_control_down;
    int      sent_caps_down;
    uint64_t last_clipboard_poll_ms;
    char     last_clipboard_text[4096];
    IOPMAssertionID display_assertion;
    int manual_display_off; /* Volatile user intent; survives transport loss only. */
    int sender_sleeping; /* Survives sleep-related socket loss; never persisted. */
    int power_is_sender_state;
    int power_effective_on;
    int power_has_waiter, power_waiter_sender_state, power_waiter_on;
    uint64_t power_waiter_id;
    int power_requested_on;
    uint64_t power_wire_request_id;
    uint64_t power_requested_ms;
    char power_request_id[129];
};

static int tb_should_log_input_event(uint64_t count) {
    return count <= 20 || (count % 100) == 0;
}

static void tb_receiver_input_log(const char *fmt, ...) {
    char message[1024];
    va_list args;
    va_start(args, fmt);
    vsnprintf(message, sizeof(message), fmt, args);
    va_end(args);

    fprintf(stderr, "%s\n", message);

    const char *home = getenv("HOME");
    if (!home || !*home) return;

    char dir[PATH_MAX];
    snprintf(dir, sizeof(dir), "%s/Library/Application Support/TargetBridge Receiver/Logs", home);
    mkdir(dir, 0755);

    char path[PATH_MAX];
    snprintf(path, sizeof(path), "%s/input-debug.log", dir);
    FILE *f = fopen(path, "a");
    if (!f) return;

    time_t now = time(NULL);
    struct tm tm_now;
    localtime_r(&now, &tm_now);
    char timestamp[64];
    strftime(timestamp, sizeof(timestamp), "%Y-%m-%dT%H:%M:%S%z", &tm_now);
    fprintf(f, "%s %s\n", timestamp, message);
    fclose(f);
}

static volatile sig_atomic_t g_term = 0;
static void on_sigint(int s) { (void)s; g_term = 1; }

static uint64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000ULL + ts.tv_nsec / 1000000ULL;
}

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static void tb_receiver_publish_display_state(struct app *a, uint64_t now) {
    const int active = !a->manual_rescue && a->session_authenticated && a->have_video_frame && now >= a->last_video_frame_ms &&
                       now - a->last_video_frame_ms < 2000;
    const int signal = !active ? 0 : a->display_health.rescue_locked ? 2 : 1;
    if (a->display_state_notify_sent &&
        signal == a->last_display_state_notify_active &&
        now - a->last_display_state_notify_ms < 1000) return;

    int64_t frame_ms = (int64_t)a->last_video_frame_ms;
    CFNumberRef frame = CFNumberCreate(NULL, kCFNumberSInt64Type, &frame_ms);
    CFStringRef line1 = CFStringCreateWithCString(NULL, a->debug_line1, kCFStringEncodingUTF8);
    CFStringRef line2 = CFStringCreateWithCString(NULL, a->debug_line2, kCFStringEncodingUTF8);
    const void *keys[] = { CFSTR("frameMs"), CFSTR("manualRescue"), CFSTR("debugVisible"), CFSTR("debugLine1"), CFSTR("debugLine2") };
    const void *values[] = { frame, a->manual_rescue ? kCFBooleanTrue : kCFBooleanFalse,
        a->debug_visible ? kCFBooleanTrue : kCFBooleanFalse, line1, line2 };
    CFDictionaryRef info = CFDictionaryCreate(NULL, keys, values, 5,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFNotificationCenterRef center = CFNotificationCenterGetDistributedCenter();
    CFNotificationCenterPostNotification(
        center,
        signal == 1 ? CFSTR("re.voyage.display.network-active") :
        signal == 2 ? CFSTR("re.voyage.display.network-recovering") :
                      CFSTR("re.voyage.display.network-inactive"),
        NULL, info, true);
    CFRelease(info);
    CFRelease(frame);
    CFRelease(line1); CFRelease(line2);
    a->display_state_notify_sent = 1;
    a->last_display_state_notify_active = signal;
    a->last_display_state_notify_ms = now;
}

static void tb_receiver_release_display_assertion(struct app *a) {
    if (!a || a->display_assertion == kIOPMNullAssertionID) return;
    IOPMAssertionRelease(a->display_assertion);
    a->display_assertion = kIOPMNullAssertionID;
}

static int send_control(struct app *a, const uint8_t *buf, size_t len);

/* Rescue owns pmset; the network renderer must release its independent LCD
 * assertion/screensaver suppression before forwarding an explicit off. */
static void tb_receiver_apply_display_intent(struct app *a) {
    if (a->manual_display_off || a->sender_sleeping || a->manual_rescue) {
        tb_receiver_release_display_assertion(a);
        SDL_EnableScreenSaver();
    } else if (a->have_video_frame && now_ms() >= a->last_video_frame_ms &&
               now_ms() - a->last_video_frame_ms < 2000 &&
               a->display_assertion == kIOPMNullAssertionID) {
        SDL_DisableScreenSaver();
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep,
            kIOPMAssertionLevelOn, CFSTR("ReVoyage network display input"), &a->display_assertion);
    }
}

static void tb_receiver_set_manual_display_off(struct app *a, int off) {
    a->manual_display_off = off;
    tb_receiver_apply_display_intent(a);
}

static void tb_receiver_send_power_ack(struct app *a, int on, int accepted, uint64_t request_id, int sender_state) {
    if (a->client_fd < 0 || !a->session_authenticated) return;
    uint8_t packet[15] = { 0, 0, 0, 11, TB_PKT_DISPLAY_POWER_ACK, (uint8_t)on, (uint8_t)accepted };
    if (sender_state) packet[4] = TB_PKT_SENDER_POWER_ACK;
    rv_display_power_write_id(packet + 7, request_id);
    (void)send_control(a, packet, sizeof(packet));
}

static void tb_receiver_post_power_request(const char *request_id, int on, uint64_t issued_ms) {
    CFStringRef id = CFStringCreateWithCString(NULL, request_id, kCFStringEncodingUTF8);
    int64_t issued = (int64_t)issued_ms;
    CFNumberRef time = CFNumberCreate(NULL, kCFNumberSInt64Type, &issued);
    const void *keys[] = { CFSTR("requestID"), CFSTR("displayOn"), CFSTR("issuedMs") };
    const void *values[] = { id, on ? kCFBooleanTrue : kCFBooleanFalse, time };
    CFDictionaryRef info = CFDictionaryCreate(NULL, keys, values, 3,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDistributedCenter(),
        CFSTR(RV_POWER_REQUEST_NOTIFICATION), NULL, info, true);
    CFRelease(info); CFRelease(time); CFRelease(id);
}

static void tb_receiver_cancel_pending_power(struct app *a, int send_ack) {
    if (!a->power_request_id[0]) return;
    char cancel_id[129];
    snprintf(cancel_id, sizeof(cancel_id), "cancel-%s", a->power_request_id);
    if (a->power_is_sender_state) a->sender_sleeping = 0;
    else a->manual_display_off = 0;
    if (a->power_has_waiter) {
        if (a->power_waiter_sender_state) a->sender_sleeping = 0;
        else a->manual_display_off = 0;
        if (send_ack) tb_receiver_send_power_ack(a, a->power_waiter_on, 0, a->power_waiter_id, a->power_waiter_sender_state);
        a->power_has_waiter = 0;
    }
    tb_receiver_apply_display_intent(a);
    tb_receiver_post_power_request(cancel_id, !a->manual_display_off && !a->sender_sleeping, now_ms());
    if (send_ack) tb_receiver_send_power_ack(a, a->power_requested_on, 0, a->power_wire_request_id, a->power_is_sender_state);
    a->power_request_id[0] = '\0';
}

static void tb_receiver_power_notification(CFNotificationCenterRef center, void *observer,
    CFStringRef name, const void *object, CFDictionaryRef info) {
    (void)center; (void)object;
    struct app *a = observer;
    if (CFEqual(name, CFSTR(RV_RESCUE_READY_NOTIFICATION))) {
        tb_receiver_cancel_pending_power(a, 1);
        a->sender_sleeping = 0;
        tb_receiver_set_manual_display_off(a, 0);
        return;
    }
    if (!info || !a->power_request_id[0]) return;
    CFTypeRef id = CFDictionaryGetValue(info, CFSTR("requestID"));
    CFTypeRef on = CFDictionaryGetValue(info, CFSTR("displayOn"));
    CFTypeRef accepted = CFDictionaryGetValue(info, CFSTR("accepted"));
    char text[129];
    if (!id || CFGetTypeID(id) != CFStringGetTypeID() ||
        !CFStringGetCString(id, text, sizeof(text), kCFStringEncodingUTF8) ||
        strcmp(text, a->power_request_id) || !on || !accepted ||
        CFGetTypeID(on) != CFBooleanGetTypeID() || CFGetTypeID(accepted) != CFBooleanGetTypeID() ||
        CFBooleanGetValue(on) != a->power_effective_on) return;
    int success = CFBooleanGetValue(accepted) && now_ms() - a->power_requested_ms < RV_POWER_REQUEST_TIMEOUT_MS;
    tb_receiver_send_power_ack(a, a->power_requested_on, success, a->power_wire_request_id, a->power_is_sender_state);
    if (a->power_has_waiter) {
        tb_receiver_send_power_ack(a, a->power_waiter_on, success, a->power_waiter_id, a->power_waiter_sender_state);
        if (success) a->power_has_waiter = 0;
    }
    if (!success) tb_receiver_cancel_pending_power(a, 0);
    a->power_request_id[0] = '\0';
}

static void tb_receiver_handle_display_power(struct app *a, const uint8_t *payload, size_t len, int sender_state) {
    int on;
    uint64_t wire_id;
    if (!rv_display_power_decode(payload, len, &on, &wire_id)) { a->close_requested = 1; return; }
    if (a->power_request_id[0] && !sender_state && !a->power_is_sender_state) {
        tb_receiver_send_power_ack(a, on, 0, wire_id, 0); return;
    }
    int was_off = a->manual_display_off || a->sender_sleeping;
    if (sender_state) a->sender_sleeping = !on;
    else a->manual_display_off = !on;
    tb_receiver_apply_display_intent(a);
    int effective_on = !a->manual_display_off && !a->sender_sleeping;
    if (a->sender_sleeping && a->audio_device) {
        SDL_PauseAudioDevice(a->audio_device, 1);
        SDL_LockAudioDevice(a->audio_device);
        a->audio_buf_head = a->audio_buf_tail = a->audio_buf_size = 0;
        SDL_UnlockAudioDevice(a->audio_device);
    }
    /* Two independent intents may request the same physical state. Keep the
     * in-flight operation and its ACK identity; never clear a manual choice. */
    if (a->power_request_id[0] && effective_on == a->power_effective_on) {
        if (sender_state == a->power_is_sender_state) {
            tb_receiver_send_power_ack(a, a->power_requested_on, 0, a->power_wire_request_id, sender_state);
            a->power_requested_on = on;
            a->power_wire_request_id = wire_id;
        } else {
            if (a->power_has_waiter)
                tb_receiver_send_power_ack(a, a->power_waiter_on, 0, a->power_waiter_id, a->power_waiter_sender_state);
            a->power_has_waiter = 1;
            a->power_waiter_on = on;
            a->power_waiter_id = wire_id;
            a->power_waiter_sender_state = sender_state;
        }
        return;
    }
    int superseded = a->power_request_id[0] != 0;
    if (superseded) {
        tb_receiver_send_power_ack(a, a->power_requested_on, 0, a->power_wire_request_id, a->power_is_sender_state);
        if (a->power_has_waiter)
            tb_receiver_send_power_ack(a, a->power_waiter_on, 0, a->power_waiter_id, a->power_waiter_sender_state);
        a->power_has_waiter = 0;
        a->power_request_id[0] = '\0';
    }
    /* An awake retry must ask Rescue to declare user activity again. A previous
     * logical awake state alone does not prove that the LCD is lit. Manual off
     * still wins and must never be bypassed by an automatic retry. */
    if (sender_state && !superseded && was_off == !effective_on && !effective_on) {
        tb_receiver_send_power_ack(a, on, 1, wire_id, sender_state);
        return;
    }
    a->power_is_sender_state = sender_state;
    CFUUIDRef uuid = CFUUIDCreate(NULL);
    CFStringRef id = CFUUIDCreateString(NULL, uuid);
    CFStringGetCString(id, a->power_request_id, sizeof(a->power_request_id), kCFStringEncodingUTF8);
    CFRelease(id); CFRelease(uuid);
    a->power_requested_on = on;
    a->power_effective_on = effective_on;
    a->power_wire_request_id = wire_id;
    a->power_requested_ms = now_ms();
    tb_receiver_post_power_request(a->power_request_id, effective_on, a->power_requested_ms);
}

static void tb_copy_i18n(char *dest, size_t size, const char *key);
static void tb_format_i18n(char *dest,
                           size_t size,
                           const char *key,
                           const struct tb_i18n_pair *pairs,
                           size_t pair_count);
static void tb_set_receiver_mode_requested(char *dest,
                                           size_t size,
                                           int width,
                                           int height,
                                           const char *source,
                                           const char *preset,
                                           const char *codec);
static void tb_refresh_idle_localized_strings(struct app *a);
static void tb_receiver_load_language_preference(char *dest, size_t size);
static void tb_receiver_load_control_settings(struct app *a);
static int tb_receiver_save_settings(const char *language, double brightness,
                                     double volume, uint64_t revision,
                                     uint32_t sleep_after_no_signal_seconds);
static void tb_receiver_save_language_preference(struct app *a);
static void tb_receiver_load_pairing_key(struct app *a);
static int extract_json_int_field(const uint8_t *payload, size_t len, const char *key, int *out_value);
static int extract_json_u64_field(const uint8_t *payload, size_t len, const char *key, uint64_t *out_value);
static int extract_json_double_field(const uint8_t *payload, size_t len, const char *key, double *out_value);
static void tb_receiver_apply_language_preference(struct app *a);
static void tb_receiver_cycle_language_preference(struct app *a);
static void tb_receiver_refresh_language_text(struct app *a);
static void tb_receiver_refresh_permissions_text(struct app *a);
static void tb_receiver_poll_permissions(struct app *a);
static int tb_receiver_input_monitoring_trusted(void);
static int tb_receiver_accessibility_trusted(void);
static void send_receiver_info(struct app *a);
static void handle_session_auth(struct app *a, const uint8_t *payload, size_t len);
static void tb_receiver_apply_input_event(const uint8_t *payload, size_t len);
static void tb_receiver_apply_input_control_mode(struct app *a, const uint8_t *payload, size_t len);
static void tb_receiver_refresh_input_capture(struct app *a);
static void tb_receiver_set_clipboard_text(const char *text);
static int tb_receiver_get_clipboard_text(char *dest, size_t size);
static void tb_receiver_send_clipboard_if_changed(struct app *a);
static void write_be32(uint8_t *dst, uint32_t value);
static void send_settings_challenge(struct app *a);
static int send_settings_json(struct app *a, uint8_t type, const char *json);
static void send_brightness_state(struct app *a, int accepted, double requested, const char *reason) {
    if (!a || !a->session_authenticated) return;
    double actual = 0;
    int supported = tb_disp_read_brightness(a->disp, &actual) == 0;
    if (accepted == 1 && !supported) { accepted = 0; reason = "readback-failed"; }
    char actual_json[32] = "null", request_json[32] = "null", accepted_json[8] = "null";
    if (supported) snprintf(actual_json, sizeof(actual_json), "%.6f", actual);
    if (isfinite(requested) && requested >= 0 && requested <= 1) snprintf(request_json, sizeof(request_json), "%.6f", requested);
    if (accepted >= 0) snprintf(accepted_json, sizeof(accepted_json), "%s", accepted ? "true" : "false");
    char json[256];
    snprintf(json, sizeof(json), "{\"supported\":%s,\"actualLevel\":%s,\"requestedLevel\":%s,\"accepted\":%s,\"reason\":\"%s\"}",
        supported ? "true" : "false", actual_json, request_json, accepted_json, reason);
    (void)send_settings_json(a, TB_PKT_BRIGHTNESS_STATE, json);
}

static void handle_settings_sync(struct app *a, const uint8_t *payload, size_t len);

static int tb_receiver_is_valid_language_pref(const char *language_pref) {
    return language_pref &&
           (strcmp(language_pref, "auto") == 0 ||
            strcmp(language_pref, "it") == 0 ||
            strcmp(language_pref, "en") == 0 ||
            strcmp(language_pref, "de") == 0 ||
            strcmp(language_pref, "fr") == 0 ||
            strcmp(language_pref, "zh") == 0);
}

static void tb_receiver_settings_path(char *dest, size_t size) {
    const char *home = getenv("HOME");
    if (!dest || size == 0) return;
    dest[0] = '\0';
    if (!home || !*home) return;
    snprintf(dest, size, "%s/Library/Application Support/TargetBridge Receiver/settings.json", home);
}

static void tb_receiver_ensure_settings_dir(void) {
    const char *home = getenv("HOME");
    if (!home || !*home) return;

    char path[PATH_MAX];
    snprintf(path, sizeof(path), "%s/Library", home);
    mkdir(path, 0755);
    snprintf(path, sizeof(path), "%s/Library/Application Support", home);
    mkdir(path, 0755);
    snprintf(path, sizeof(path), "%s/Library/Application Support/TargetBridge Receiver", home);
    mkdir(path, 0700);
}

static void tb_receiver_load_language_preference(char *dest, size_t size) {
    if (!dest || size == 0) return;
    snprintf(dest, size, "%s", "auto");

    char path[PATH_MAX];
    tb_receiver_settings_path(path, sizeof(path));
    if (!path[0]) return;

    FILE *fp = fopen(path, "rb");
    if (!fp) return;

    char buf[256];
    size_t n = fread(buf, 1, sizeof(buf) - 1, fp);
    fclose(fp);
    buf[n] = '\0';

    int schema_version = 0;
    if (extract_json_int_field((const uint8_t *)buf, n, "\"schemaVersion\"", &schema_version) &&
        (schema_version != 1 && schema_version != 2)) return;

    const char *pos = strstr(buf, "\"language\"");
    if (!pos) return;
    pos = strchr(pos, ':');
    if (!pos) return;
    pos = strchr(pos, '"');
    if (!pos) return;
    pos++;

    char code[8];
    size_t i = 0;
    while (*pos && *pos != '"' && i + 1 < sizeof(code)) code[i++] = *pos++;
    code[i] = '\0';

    if (tb_receiver_is_valid_language_pref(code)) {
        snprintf(dest, size, "%s", code);
    }
}

static int tb_receiver_save_settings(const char *language,
                                    double brightness,
                                    double volume,
                                    uint64_t revision,
                                    uint32_t sleep_after_no_signal_seconds) {
    if (!tb_receiver_is_valid_language_pref(language) ||
        brightness < 0.0 || brightness > 1.0 ||
        volume < 0.0 || volume > 1.0 ||
        sleep_after_no_signal_seconds < 15 ||
        sleep_after_no_signal_seconds > 3600) return 0;
    tb_receiver_ensure_settings_dir();
    char path[PATH_MAX];
    tb_receiver_settings_path(path, sizeof(path));
    if (!path[0]) return 0;

    char temporary[PATH_MAX];
    if (snprintf(temporary, sizeof(temporary), "%s.tmp", path) >= (int)sizeof(temporary)) return 0;
    int fd = open(temporary, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) return 0;
    FILE *fp = fdopen(fd, "w");
    if (!fp) { close(fd); unlink(temporary); return 0; }
    int ok = fprintf(fp,
                     "{\n  \"schemaVersion\": 2,\n  \"revision\": %llu,\n"
                     "  \"brightness\": %.3f,\n  \"volume\": %.3f,\n"
                     "  \"language\": \"%s\",\n"
                     "  \"sleepAfterNoSignalSeconds\": %u\n}\n",
                     (unsigned long long)revision, brightness, volume, language,
                     sleep_after_no_signal_seconds) > 0;
    if (fflush(fp) != 0 || fsync(fileno(fp)) != 0) ok = 0;
    if (fclose(fp) != 0) ok = 0;
    if (ok && rename(temporary, path) == 0) return 1;
    unlink(temporary);
    return 0;
}

static void tb_receiver_save_language_preference(struct app *a) {
    if (!a || !tb_receiver_is_valid_language_pref(a->language_pref)) return;
    if (a->settings_revision == UINT64_MAX) return;
    uint64_t revision = a->settings_revision + 1;
    if (tb_receiver_save_settings(a->language_pref,
                                  a->settings_brightness,
                                  a->settings_volume,
                                  revision,
                                  a->sleep_after_no_signal_seconds)) {
        a->settings_revision = revision;
    }
}

static void tb_receiver_load_pairing_key(struct app *a) {
    if (!a) return;
    if (!rv_pairing_required()) {
        snprintf(a->pairing_key, sizeof(a->pairing_key), "%s", rv_local_wire_key());
        return;
    }
    a->pairing_key[0] = '\0';
    const char *home = getenv("HOME");
    if (!home || !*home) return;
    char path[PATH_MAX];
    snprintf(path, sizeof(path), "%s/Library/Application Support/TargetBridge Receiver/pairing.key", home);
    FILE *fp = fopen(path, "rb");
    if (!fp) return;
    size_t count = fread(a->pairing_key, 1, sizeof(a->pairing_key) - 1, fp);
    fclose(fp);
    while (count > 0 && (a->pairing_key[count - 1] == '\n' || a->pairing_key[count - 1] == '\r')) count--;
    a->pairing_key[count] = '\0';
    int valid = count == 64;
    for (size_t i = 0; valid && i < count; i++) {
        unsigned char ch = (unsigned char)a->pairing_key[i];
        if (!isxdigit(ch)) valid = 0;
        else a->pairing_key[i] = (char)tolower(ch);
    }
    if (!valid) {
        a->pairing_key[0] = '\0';
        fprintf(stderr, "[settings] pairing key missing or invalid; authenticated sync disabled\n");
    }
}

static const char *tb_receiver_language_display_name(const char *language_code) {
    if (!language_code || !*language_code) language_code = "en";
    if (strcmp(language_code, "it") == 0) return tb_i18n_get("common.language.italian");
    if (strcmp(language_code, "de") == 0) return tb_i18n_get("common.language.german");
    if (strcmp(language_code, "fr") == 0) return tb_i18n_get("common.language.french");
    if (strcmp(language_code, "zh") == 0) return tb_i18n_get("common.language.chinese");
    return tb_i18n_get("common.language.english");
}

static void tb_receiver_refresh_language_text(struct app *a) {
    if (!a) return;
    if (strcmp(a->language_pref, "auto") == 0) {
        snprintf(a->language_text,
                 sizeof(a->language_text),
                 "%s · %s",
                 tb_i18n_get("receiver.language.auto"),
                 tb_receiver_language_display_name(tb_i18n_current_language()));
    } else {
        snprintf(a->language_text,
                 sizeof(a->language_text),
                 "%s",
                 tb_receiver_language_display_name(a->language_pref));
    }
}

static void tb_receiver_refresh_permissions_text(struct app *a) {
    if (!a) return;

    const int input_monitoring = (a->last_input_monitoring_trusted >= 0)
        ? a->last_input_monitoring_trusted
        : tb_receiver_input_monitoring_trusted();
    const int accessibility = (a->last_accessibility_trusted >= 0)
        ? a->last_accessibility_trusted
        : tb_receiver_accessibility_trusted();
    const char *lang = tb_i18n_current_language();

    if (lang && strncmp(lang, "it", 2) == 0) {
        snprintf(
            a->permissions_text,
            sizeof(a->permissions_text),
            "Monitoraggio input: %s   Accessibilità: %s",
            input_monitoring ? "OK" : "Mancante",
            accessibility ? "OK" : "Mancante"
        );
    } else if (lang && strncmp(lang, "de", 2) == 0) {
        snprintf(
            a->permissions_text,
            sizeof(a->permissions_text),
            "Input-Monitoring: %s   Bedienungshilfen: %s",
            input_monitoring ? "OK" : "Fehlt",
            accessibility ? "OK" : "Fehlt"
        );
    } else if (lang && strncmp(lang, "zh", 2) == 0) {
        snprintf(
            a->permissions_text,
            sizeof(a->permissions_text),
            "输入监控：%s   辅助功能：%s",
            input_monitoring ? "正常" : "缺失",
            accessibility ? "正常" : "缺失"
        );
    } else {
        snprintf(
            a->permissions_text,
            sizeof(a->permissions_text),
            "Input Monitoring: %s   Accessibility: %s",
            input_monitoring ? "OK" : "Missing",
            accessibility ? "OK" : "Missing"
        );
    }
}

static void tb_receiver_poll_permissions(struct app *a) {
    if (!a) return;

    const int input_monitoring = tb_receiver_input_monitoring_trusted();
    const int accessibility = tb_receiver_accessibility_trusted();

    const int changed =
        input_monitoring != a->last_input_monitoring_trusted ||
        accessibility != a->last_accessibility_trusted;

    a->last_input_monitoring_trusted = input_monitoring;
    a->last_accessibility_trusted = accessibility;

    if (!changed) return;

    tb_receiver_refresh_permissions_text(a);
    tb_receiver_refresh_input_capture(a);
    if (a->client_fd >= 0) {
        send_receiver_info(a);
    }
    tb_receiver_input_log("[input] permission state changed inputMonitoring=%s accessibility=%s",
                          input_monitoring ? "true" : "false",
                          accessibility ? "true" : "false");
}

static void tb_receiver_apply_language_preference(struct app *a) {
    if (!a) return;

    if (strcmp(a->language_pref, "auto") == 0) {
        if (a->sender_ui_language[0] != '\0') {
            tb_i18n_set_runtime_language(a->sender_ui_language);
        } else {
            tb_i18n_set_runtime_language("auto");
        }
    } else {
        tb_i18n_set_runtime_language(a->language_pref);
    }

    tb_refresh_idle_localized_strings(a);
    tb_receiver_refresh_language_text(a);
    tb_receiver_refresh_permissions_text(a);
}

static int tb_receiver_input_monitoring_trusted(void) {
    return tb_input_monitoring_trusted();
}

static int tb_receiver_accessibility_trusted(void) {
    return AXIsProcessTrusted() ? 1 : 0;
}

static void tb_receiver_cycle_language_preference(struct app *a) {
    if (!a) return;

    if (strcmp(a->language_pref, "auto") == 0) {
        snprintf(a->language_pref, sizeof(a->language_pref), "%s", "it");
    } else if (strcmp(a->language_pref, "it") == 0) {
        snprintf(a->language_pref, sizeof(a->language_pref), "%s", "en");
    } else if (strcmp(a->language_pref, "en") == 0) {
        snprintf(a->language_pref, sizeof(a->language_pref), "%s", "de");
    } else if (strcmp(a->language_pref, "de") == 0) {
        snprintf(a->language_pref, sizeof(a->language_pref), "%s", "fr");
    } else if (strcmp(a->language_pref, "fr") == 0) {
        snprintf(a->language_pref, sizeof(a->language_pref), "%s", "zh");
    } else {
        snprintf(a->language_pref, sizeof(a->language_pref), "%s", "auto");
    }

    tb_receiver_save_language_preference(a);
    tb_receiver_apply_language_preference(a);
}

static void tb_refresh_idle_localized_strings(struct app *a) {
    if (!a) return;
    tb_copy_i18n(a->status_text, sizeof(a->status_text), "receiver.status.waiting_for_sender");
    tb_copy_i18n(a->sender_text, sizeof(a->sender_text), "receiver.status.waiting");
    struct tb_display_info panel;
    if (tb_disp_get_info(a->disp, &panel) == 0)
        snprintf(a->mode_text, sizeof(a->mode_text), "%u x %u %s @ %.0f Hz", panel.mode_w, panel.mode_h, panel.hi_dpi ? "HiDPI" : "1x", panel.refresh_rate);
    else tb_copy_i18n(a->mode_text, sizeof(a->mode_text), "receiver.mode.default");
    tb_receiver_refresh_permissions_text(a);
    if (a->ip_text[0] == '\0') {
        tb_copy_i18n(a->ip_text, sizeof(a->ip_text), "receiver.network.not_detected");
    }
}

static void tb_copy_i18n(char *dest, size_t size, const char *key) {
    if (!dest || size == 0) return;
    snprintf(dest, size, "%s", tb_i18n_get(key));
}

static void tb_json_escape_string(const char *src, char *dest, size_t size) {
    if (!dest || size == 0) return;
    if (!src) {
        dest[0] = '\0';
        return;
    }

    size_t j = 0;
    for (size_t i = 0; src[i] != '\0' && j + 1 < size; i++) {
        char c = src[i];
        const char *escape = NULL;
        switch (c) {
        case '\\': escape = "\\\\"; break;
        case '"': escape = "\\\""; break;
        case '\n': escape = "\\n"; break;
        case '\r': escape = "\\r"; break;
        case '\t': escape = "\\t"; break;
        default: break;
        }

        if (escape) {
            for (size_t k = 0; escape[k] != '\0' && j + 1 < size; k++) {
                dest[j++] = escape[k];
            }
        } else {
            dest[j++] = c;
        }
    }
    dest[j] = '\0';
}

static void tb_receiver_set_clipboard_text(const char *text) {
    FILE *pipe = popen("pbcopy", "w");
    if (!pipe) return;
    if (text && *text) {
        fwrite(text, 1, strlen(text), pipe);
    }
    pclose(pipe);
}

static int tb_receiver_get_clipboard_text(char *dest, size_t size) {
    if (!dest || size == 0) return 0;
    dest[0] = '\0';

    FILE *pipe = popen("pbpaste", "r");
    if (!pipe) return 0;

    size_t total = 0;
    while (!feof(pipe) && total + 1 < size) {
        size_t n = fread(dest + total, 1, size - total - 1, pipe);
        total += n;
        if (n == 0) break;
    }
    dest[total] = '\0';
    pclose(pipe);
    return 1;
}

static void tb_receiver_send_clipboard_if_changed(struct app *a) {
    if (!a || strcmp(a->input_control_mode, "receiverMaster") != 0 || a->client_fd < 0) return;

    char text[4096];
    if (!tb_receiver_get_clipboard_text(text, sizeof(text))) return;
    if (strcmp(text, a->last_clipboard_text) == 0) return;

    snprintf(a->last_clipboard_text, sizeof(a->last_clipboard_text), "%s", text);

    char escaped[8192];
    tb_json_escape_string(text, escaped, sizeof(escaped));

    char json[8300];
    int len = snprintf(json, sizeof(json), "{\"text\":\"%s\"}", escaped);
    if (len <= 0 || (size_t)len >= sizeof(json)) return;

    uint8_t packet[TB_HDR_BYTES + sizeof(json)];
    write_be32(packet, (uint32_t)(1 + len));
    packet[4] = TB_PKT_CLIPBOARD;
    memcpy(packet + TB_HDR_BYTES, json, (size_t)len);
    (void)send_control(a, packet, TB_HDR_BYTES + (size_t)len);
}

static void tb_format_i18n(char *dest,
                           size_t size,
                           const char *key,
                           const struct tb_i18n_pair *pairs,
                           size_t pair_count) {
    tb_i18n_format(dest, size, key, pairs, pair_count);
}

static void tb_set_receiver_mode_requested(char *dest,
                                           size_t size,
                                           int width,
                                           int height,
                                           const char *source,
                                           const char *preset,
                                           const char *codec) {
    char width_text[16];
    char height_text[16];
    snprintf(width_text, sizeof(width_text), "%d", width);
    snprintf(height_text, sizeof(height_text), "%d", height);

    struct tb_i18n_pair pairs[] = {
        { "width", width_text },
        { "height", height_text },
        { "source", source ? source : "" },
        { "preset", preset ? preset : "" },
        { "codec", codec ? codec : "" }
    };

    if (width > 0 && height > 0 && source && *source && preset && *preset && codec && *codec) {
        tb_format_i18n(dest, size, "receiver.mode.requested_source_preset_codec", pairs, 5);
    } else if (width > 0 && height > 0 && preset && *preset && codec && *codec) {
        tb_format_i18n(dest, size, "receiver.mode.requested_preset_codec", pairs, 5);
    } else if (width > 0 && height > 0 && preset && *preset) {
        tb_format_i18n(dest, size, "receiver.mode.requested_preset", pairs, 5);
    } else if (width > 0 && height > 0 && codec && *codec) {
        tb_format_i18n(dest, size, "receiver.mode.requested_codec", pairs, 5);
    } else if (width > 0 && height > 0) {
        tb_format_i18n(dest, size, "receiver.mode.requested", pairs, 5);
    }
}

static void bonjour_deinit(struct app *a) {
    if (a->bonjour_ref) {
        DNSServiceRefDeallocate(a->bonjour_ref);
        a->bonjour_ref = NULL;
    }
}

static void on_bonjour_register(DNSServiceRef sdRef,
                                DNSServiceFlags flags,
                                DNSServiceErrorType errorCode,
                                const char *name,
                                const char *regtype,
                                const char *domain,
                                void *context) {
    (void)sdRef;
    (void)flags;
    (void)context;
    if (errorCode == kDNSServiceErr_NoError) {
        fprintf(stderr, "[bonjour] published %s.%s%s\n", name ? name : "TargetBridge Receiver", regtype ? regtype : "", domain ? domain : "");
    } else {
        fprintf(stderr, "[bonjour] register failed: %d\n", (int)errorCode);
    }
}

static void bonjour_update(struct app *a, uint16_t port) {
    bonjour_deinit(a);

    if (a->ip_text[0] == '\0' || strcmp(a->ip_text, tb_i18n_get("receiver.network.not_detected")) == 0) return;

    TXTRecordRef txt;
    TXTRecordCreate(&txt, 0, NULL);
    TXTRecordSetValue(&txt, "receiverID", (uint8_t)strlen(a->receiver_id), a->receiver_id);
    TXTRecordSetValue(&txt, "name", (uint8_t)strlen(a->bonjour_name), a->bonjour_name);
    TXTRecordSetValue(&txt, "ip", (uint8_t)strlen(a->ip_text), a->ip_text);
    if (a->tb_ip_text[0] != '\0') {
        TXTRecordSetValue(&txt, "tbIP", (uint8_t)strlen(a->tb_ip_text), a->tb_ip_text);
    }
    if (a->net_ip_text[0] != '\0') {
        TXTRecordSetValue(&txt, "netIP", (uint8_t)strlen(a->net_ip_text), a->net_ip_text);
    }
    TXTRecordSetValue(&txt, "panel", (uint8_t)strlen(a->panel_text), a->panel_text);
    TXTRecordSetValue(&txt, "version", (uint8_t)strlen(TB_RECEIVER_VERSION), TB_RECEIVER_VERSION);
    TXTRecordSetValue(&txt, "supportsHEVCDecode", 1, tb_dec_supports_hevc_hwdecode() ? "1" : "0");
    TXTRecordSetValue(&txt, "supportsRawNV12", 1, "1");

    struct tb_display_info info;
    if (tb_disp_get_info(a->disp, &info) == 0) {
        char panel_w[16];
        char panel_h[16];
        snprintf(panel_w, sizeof(panel_w), "%u", info.active_w);
        snprintf(panel_h, sizeof(panel_h), "%u", info.active_h);
        TXTRecordSetValue(&txt, "panelWidth", (uint8_t)strlen(panel_w), panel_w);
        TXTRecordSetValue(&txt, "panelHeight", (uint8_t)strlen(panel_h), panel_h);
    }

    DNSServiceErrorType err = DNSServiceRegister(
        &a->bonjour_ref,
        0,
        0,
        a->bonjour_name,
        "_targetbridge._tcp",
        "local.",
        NULL,
        htons(port),
        TXTRecordGetLength(&txt),
        TXTRecordGetBytesPtr(&txt),
        on_bonjour_register,
        a
    );
    TXTRecordDeallocate(&txt);

    if (err != kDNSServiceErr_NoError) {
        fprintf(stderr, "[bonjour] unable to publish receiver service: %d\n", (int)err);
        bonjour_deinit(a);
    }
}

static void extract_json_string_field(const uint8_t *payload,
                                      size_t len,
                                      const char *key,
                                      char *out,
                                      size_t out_size) {
    if (!out || out_size == 0) return;
    out[0] = '\0';
    if (!payload || !key) return;

    const char *text = (const char *)payload;
    const char *pos = strstr(text, key);
    if (!pos) return;

    pos = strchr(pos, ':');
    if (!pos) return;
    pos = strchr(pos, '"');
    if (!pos) return;
    pos++;

    size_t i = 0;
    while ((size_t)(pos - text) < len && *pos && *pos != '"' && i + 1 < out_size) {
        if (*pos == '\\' && (size_t)(pos - text + 1) < len && pos[1] != '\0') pos++;
        out[i++] = *pos++;
    }
    out[i] = '\0';
}

static int extract_json_int_field(const uint8_t *payload,
                                  size_t len,
                                  const char *key,
                                  int *out_value) {
    if (!payload || !key || !out_value) return 0;

    const char *text = (const char *)payload;
    const char *pos = strstr(text, key);
    if (!pos) return 0;

    pos = strchr(pos, ':');
    if (!pos) return 0;
    pos++;
    while ((size_t)(pos - text) < len && (*pos == ' ' || *pos == '\t')) pos++;
    if ((size_t)(pos - text) >= len) return 0;

    char *end = NULL;
    errno = 0;
    long value = strtol(pos, &end, 10);
    if (end == pos || errno == ERANGE || value < INT_MIN || value > INT_MAX) return 0;
    *out_value = (int)value;
    return 1;
}

static int extract_json_u64_field(const uint8_t *payload,
                                  size_t len,
                                  const char *key,
                                  uint64_t *out_value) {
    if (!payload || !key || !out_value) return 0;
    const char *text = (const char *)payload;
    const char *pos = strstr(text, key);
    if (!pos) return 0;
    pos = strchr(pos, ':');
    if (!pos) return 0;
    pos++;
    while ((size_t)(pos - text) < len && (*pos == ' ' || *pos == '\t')) pos++;
    if ((size_t)(pos - text) >= len || *pos == '-') return 0;
    errno = 0;
    char *end = NULL;
    unsigned long long value = strtoull(pos, &end, 10);
    if (end == pos || errno == ERANGE || (size_t)(end - text) > len) return 0;
    *out_value = (uint64_t)value;
    return 1;
}

static int extract_json_bool_field(const uint8_t *payload,
                                   size_t len,
                                   const char *key,
                                   int *out_value) {
    if (!payload || !key || !out_value) return 0;

    const char *text = (const char *)payload;
    const char *pos = strstr(text, key);
    if (!pos) return 0;

    pos = strchr(pos, ':');
    if (!pos) return 0;
    pos++;
    while ((size_t)(pos - text) < len && (*pos == ' ' || *pos == '\t')) pos++;
    if ((size_t)(pos - text) >= len) return 0;

    if (strncmp(pos, "true", 4) == 0) {
        *out_value = 1;
        return 1;
    }
    if (strncmp(pos, "false", 5) == 0) {
        *out_value = 0;
        return 1;
    }
    return extract_json_int_field(payload, len, key, out_value);
}

static int extract_json_double_field(const uint8_t *payload,
                                     size_t len,
                                     const char *key,
                                     double *out_value) {
    if (!payload || !key || !out_value) return 0;

    const char *text = (const char *)payload;
    const char *pos = strstr(text, key);
    if (!pos) return 0;

    pos = strchr(pos, ':');
    if (!pos) return 0;
    pos++;
    while ((size_t)(pos - text) < len && (*pos == ' ' || *pos == '\t')) pos++;
    if ((size_t)(pos - text) >= len) return 0;

    char *end = NULL;
    double value = strtod(pos, &end);
    if (end == pos) return 0;
    *out_value = value;
    return 1;
}

static void tb_receiver_load_control_settings(struct app *a) {
    if (!a) return;
    a->settings_brightness = 1.0;
    a->settings_volume = 0.5;
    a->sleep_after_no_signal_seconds = 30;
    a->settings_revision = 0;

    char path[PATH_MAX];
    tb_receiver_settings_path(path, sizeof(path));
    if (!path[0]) return;
    FILE *fp = fopen(path, "rb");
    if (!fp) return;
    uint8_t json[1024];
    size_t count = fread(json, 1, sizeof(json) - 1, fp);
    fclose(fp);
    json[count] = '\0';

    int schema_version = 0;
    if (extract_json_int_field(json, count, "\"schemaVersion\"", &schema_version) &&
        (schema_version != 1 && schema_version != 2)) return;

    double brightness = a->settings_brightness;
    double volume = a->settings_volume;
    uint64_t revision = 0;
    if (extract_json_double_field(json, count, "\"brightness\"", &brightness) &&
        brightness >= 0.0 && brightness <= 1.0) {
        a->settings_brightness = brightness;
    }
    if (extract_json_double_field(json, count, "\"volume\"", &volume) &&
        volume >= 0.0 && volume <= 1.0) {
        a->settings_volume = volume;
    }
    if (extract_json_u64_field(json, count, "\"revision\"", &revision)) {
        a->settings_revision = revision;
    }
    int sleep_seconds = 0;
    if (schema_version >= 2 &&
        extract_json_int_field(json, count, "\"sleepAfterNoSignalSeconds\"", &sleep_seconds) &&
        sleep_seconds >= 15 && sleep_seconds <= 3600) {
        a->sleep_after_no_signal_seconds = (uint32_t)sleep_seconds;
    }
}

static CGPoint tb_receiver_current_mouse_location(void) {
    CGPoint point = CGPointZero;
    CGEventRef event = CGEventCreate(NULL);
    if (event) {
        point = CGEventGetLocation(event);
        CFRelease(event);
    }
    return point;
}

static void tb_receiver_post_mouse_move(int dx, int dy, CGEventType type, CGMouseButton button) {
    CGPoint current = tb_receiver_current_mouse_location();
    CGPoint target = CGPointMake(current.x + dx, current.y + dy);
    CGEventRef event = CGEventCreateMouseEvent(NULL, type, target, button);
    if (!event) return;
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

static void tb_receiver_post_mouse_button(CGEventType type, CGMouseButton button) {
    CGPoint current = tb_receiver_current_mouse_location();
    CGEventRef event = CGEventCreateMouseEvent(NULL, type, current, button);
    if (!event) return;
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

static void tb_receiver_post_scroll(int scroll_x, int scroll_y) {
    CGEventRef event = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitLine, 2, scroll_y, scroll_x);
    if (!event) return;
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

static void tb_receiver_post_key(uint16_t key_code, int is_down) {
    CGEventRef event = CGEventCreateKeyboardEvent(NULL, (CGKeyCode)key_code, is_down ? true : false);
    if (!event) return;
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

static void tb_receiver_apply_input_event(const uint8_t *payload, size_t len) {
    char kind[32];
    kind[0] = '\0';
    extract_json_string_field(payload, len, "\"kind\"", kind, sizeof(kind));
    if (kind[0] == '\0') return;
    tb_receiver_input_log("[input][sender->receiver] received kind=%s len=%zu", kind, len);

    if (strcmp(kind, "move") == 0) {
        int dx = 0;
        int dy = 0;
        (void)extract_json_int_field(payload, len, "\"dx\"", &dx);
        (void)extract_json_int_field(payload, len, "\"dy\"", &dy);
        tb_receiver_post_mouse_move(dx, dy, kCGEventMouseMoved, kCGMouseButtonLeft);
        return;
    }

    if (strcmp(kind, "leftDrag") == 0) {
        int dx = 0;
        int dy = 0;
        (void)extract_json_int_field(payload, len, "\"dx\"", &dx);
        (void)extract_json_int_field(payload, len, "\"dy\"", &dy);
        tb_receiver_post_mouse_move(dx, dy, kCGEventLeftMouseDragged, kCGMouseButtonLeft);
        return;
    }

    if (strcmp(kind, "rightDrag") == 0) {
        int dx = 0;
        int dy = 0;
        (void)extract_json_int_field(payload, len, "\"dx\"", &dx);
        (void)extract_json_int_field(payload, len, "\"dy\"", &dy);
        tb_receiver_post_mouse_move(dx, dy, kCGEventRightMouseDragged, kCGMouseButtonRight);
        return;
    }

    if (strcmp(kind, "otherDrag") == 0) {
        int dx = 0;
        int dy = 0;
        (void)extract_json_int_field(payload, len, "\"dx\"", &dx);
        (void)extract_json_int_field(payload, len, "\"dy\"", &dy);
        tb_receiver_post_mouse_move(dx, dy, kCGEventOtherMouseDragged, kCGMouseButtonCenter);
        return;
    }

    if (strcmp(kind, "leftDown") == 0) {
        tb_receiver_post_mouse_button(kCGEventLeftMouseDown, kCGMouseButtonLeft);
        return;
    }
    if (strcmp(kind, "leftUp") == 0) {
        tb_receiver_post_mouse_button(kCGEventLeftMouseUp, kCGMouseButtonLeft);
        return;
    }
    if (strcmp(kind, "rightDown") == 0) {
        tb_receiver_post_mouse_button(kCGEventRightMouseDown, kCGMouseButtonRight);
        return;
    }
    if (strcmp(kind, "rightUp") == 0) {
        tb_receiver_post_mouse_button(kCGEventRightMouseUp, kCGMouseButtonRight);
        return;
    }
    if (strcmp(kind, "otherDown") == 0) {
        tb_receiver_post_mouse_button(kCGEventOtherMouseDown, kCGMouseButtonCenter);
        return;
    }
    if (strcmp(kind, "otherUp") == 0) {
        tb_receiver_post_mouse_button(kCGEventOtherMouseUp, kCGMouseButtonCenter);
        return;
    }
    if (strcmp(kind, "scroll") == 0) {
        int scroll_x = 0;
        int scroll_y = 0;
        (void)extract_json_int_field(payload, len, "\"scrollX\"", &scroll_x);
        (void)extract_json_int_field(payload, len, "\"scrollY\"", &scroll_y);
        tb_receiver_post_scroll(scroll_x, scroll_y);
        return;
    }
    if (strcmp(kind, "keyDown") == 0 || strcmp(kind, "keyUp") == 0) {
        int key_code = 0;
        if (extract_json_int_field(payload, len, "\"keyCode\"", &key_code)) {
            tb_receiver_post_key((uint16_t)key_code, strcmp(kind, "keyDown") == 0);
        }
    }
}

static void tb_receiver_apply_input_control_mode(struct app *a, const uint8_t *payload, size_t len) {
    char mode[32];
    mode[0] = '\0';
    extract_json_string_field(payload, len, "\"mode\"", mode, sizeof(mode));
    if (mode[0] == '\0') {
        snprintf(a->input_control_mode, sizeof(a->input_control_mode), "off");
    } else {
        snprintf(a->input_control_mode, sizeof(a->input_control_mode), "%s", mode);
    }
    tb_receiver_input_log("[input] control mode updated to %s", a->input_control_mode);
    if (strcmp(a->input_control_mode, "receiverMaster") != 0) {
        a->sent_command_down = 0;
        a->sent_shift_down = 0;
        a->sent_option_down = 0;
        a->sent_control_down = 0;
        a->sent_caps_down = 0;
    }
    tb_receiver_refresh_input_capture(a);
}

/* ---- Callbacks: decoder → display ------------------------------------ */

static void tb_receiver_refresh_debug_text(struct app *a) {
    char size[48], hz[24], in_fps[24], out_fps[24], latency[24], mbps[24], skipped[24], errors[24];
    struct tb_display_info info;
    if (a->stream_width > 0) snprintf(size, sizeof(size), "%d x %d", a->stream_width, a->stream_height);
    else snprintf(size, sizeof(size), "—");
    if (tb_disp_get_info(a->disp, &info) == 0 && info.refresh_rate > 0)
        snprintf(hz, sizeof(hz), "%.1f", info.refresh_rate);
    else snprintf(hz, sizeof(hz), "—");
    snprintf(in_fps, sizeof(in_fps), "%.1f", a->stream_stats.receive_fps);
    snprintf(out_fps, sizeof(out_fps), "%.1f", a->stream_stats.submit_fps);
    if (a->stream_stats.latency_valid && a->have_video_frame)
        snprintf(latency, sizeof(latency), "%.2f", a->stream_stats.latency_ms);
    else snprintf(latency, sizeof(latency), "—");
    snprintf(mbps, sizeof(mbps), "%.2f", a->stream_stats.receive_mbps);
    snprintf(skipped, sizeof(skipped), "%.1f", a->stream_stats.skipped_percent);
    snprintf(errors, sizeof(errors), "%llu", (unsigned long long)a->decode_errors);
    const char *codec = a->raw_video_active ? "RAW" : a->stream_codec == 1 ? "H.264" : a->stream_codec == 2 ? "HEVC" : "—";
    int hardware = tb_dec_observed_hardware(a->dec);
    const char *decode = a->raw_video_active ? "RAW" : hardware == 1 ? "HW" : hardware == 0 ? "SW" : "—";
    const char *state = tb_i18n_get(a->manual_rescue ? "receiver.debug.rescue" :
        a->sender_sleeping ? "receiver.debug.sleeping" : a->have_video_frame ? "receiver.debug.streaming" : "receiver.debug.waiting");
    struct tb_i18n_pair pairs[] = {
        {"state", state}, {"size", size}, {"codec", codec}, {"decode", decode}, {"hz", hz},
        {"inFps", in_fps}, {"outFps", out_fps}, {"latency", latency}, {"mbps", mbps}, {"skipped", skipped}, {"errors", errors}
    };
    tb_format_i18n(a->debug_line1, sizeof(a->debug_line1), "receiver.debug.line1", pairs, 11);
    tb_format_i18n(a->debug_line2, sizeof(a->debug_line2), "receiver.debug.line2", pairs, 11);
    tb_disp_set_debug_overlay(a->disp, a->debug_visible, a->debug_line1, a->debug_line2);
}

static void note_presented_video_frame(struct app *a, int w, int h) {
    if (!a->have_video_frame) {
        if (!a->manual_display_off && !a->sender_sleeping && !a->manual_rescue) SDL_DisableScreenSaver();
        if (a->audio_device != 0) {
            SDL_LockAudioDevice(a->audio_device);
            a->audio_buf_head = a->audio_buf_tail = a->audio_buf_size = 0;
            SDL_UnlockAudioDevice(a->audio_device);
            SDL_PauseAudioDevice(a->audio_device, 1);
        }
        if (!a->manual_display_off && !a->sender_sleeping && !a->manual_rescue) {
            IOPMAssertionID activity = kIOPMNullAssertionID;
            IOPMAssertionDeclareUserActivity(CFSTR("iMac ReVoyage network video"),
                                             kIOPMUserActiveLocal, &activity);
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep,
                                        kIOPMAssertionLevelOn,
                                        CFSTR("ReVoyage network display input"),
                                        &a->display_assertion);
        }
    }
    a->have_video_frame = 1;
    a->last_video_frame_ms = now_ms();
    a->presented_batches++;
    a->stream_width = w; a->stream_height = h;
    int was_locked = a->display_health.rescue_locked;
    rv_display_signal_set_network(&a->display_health, 1, a->last_video_frame_ms, a->last_video_frame_ms);
    tb_disp_set_recovery_pending(a->disp, a->display_health.rescue_locked);
    if (a->audio_device && (was_locked != a->display_health.rescue_locked))
        SDL_PauseAudioDevice(a->audio_device, a->display_health.rescue_locked || a->sender_sleeping || a->manual_rescue ? 1 : 0);
    tb_copy_i18n(a->status_text, sizeof(a->status_text), "receiver.status.stream_active");
    {
        char width_text[16];
        char height_text[16];
        struct tb_i18n_pair pairs[] = {
            { "width", width_text },
            { "height", height_text }
        };
        snprintf(width_text, sizeof(width_text), "%d", w);
        snprintf(height_text, sizeof(height_text), "%d", h);
        tb_format_i18n(a->mode_text, sizeof(a->mode_text), "receiver.mode.receiving", pairs, 2);
    }
}

static void on_frame(const uint8_t *y, int y_stride,
                     const uint8_t *uv, int uv_stride,
                     int w, int h, void *ud) {
    struct app *a = (struct app *)ud;
    if (tb_disp_render_nv12(a->disp, y, y_stride, uv, uv_stride, w, h) < 0) return;
    a->batch_frame_width = w; a->batch_frame_height = h;
    a->batch_frame_packet_ns = a->current_video_packet_ns;
    a->frames++;
}

/* Raw passthrough: render received NV12 planes directly, bypassing the decoder.
 * Payload: [1: format=1(NV12)][BE32 w][BE32 h][BE32 yStride][BE32 uvStride]
 *          [Y plane: yStride*h][CbCr plane: uvStride*(h/2)] */
static void handle_raw_frame(struct app *a, const uint8_t *p, size_t len) {
    if (len < 17) return;
    if (p[0] != 1) return; /* only NV12 is supported */
    uint32_t w  = ((uint32_t)p[1]  << 24) | ((uint32_t)p[2]  << 16) | ((uint32_t)p[3]  << 8) | (uint32_t)p[4];
    uint32_t h  = ((uint32_t)p[5]  << 24) | ((uint32_t)p[6]  << 16) | ((uint32_t)p[7]  << 8) | (uint32_t)p[8];
    uint32_t ys = ((uint32_t)p[9]  << 24) | ((uint32_t)p[10] << 16) | ((uint32_t)p[11] << 8) | (uint32_t)p[12];
    uint32_t us = ((uint32_t)p[13] << 24) | ((uint32_t)p[14] << 16) | ((uint32_t)p[15] << 8) | (uint32_t)p[16];
    /* Keep malformed peer data from turning into oversized stride arithmetic or
     * an out-of-bounds render. TargetBridge RAW is intentionally limited to
     * practical 4:2:0 display sizes and the protocol packet cap. */
    if (w == 0 || h == 0 || (w & 1) || (h & 1) ||
        w > 8192 || h > 8192 || ys < w || us < w ||
        ys > 16384 || us > 16384) return;
    size_t y_size  = (size_t)ys * h;
    size_t uv_size = (size_t)us * (h / 2);
    size_t payload_size = len - 17;
    if (y_size > payload_size || uv_size > payload_size - y_size) return;
    const uint8_t *y  = p + 17;
    const uint8_t *uv = y + y_size;

    if (tb_disp_render_nv12(a->disp, y, (int)ys, uv, (int)us, (int)w, (int)h) < 0) return;
    a->batch_frame_width = (int)w; a->batch_frame_height = (int)h;
    a->batch_frame_packet_ns = a->current_video_packet_ns;
    a->frames++;
}

static void ring_read(struct app *a, Uint8 *dst, int len) {
    int first = AUDIO_BUF_CAP - a->audio_buf_tail;
    if (first >= len) {
        memcpy(dst, a->audio_buf + a->audio_buf_tail, len);
    } else {
        memcpy(dst, a->audio_buf + a->audio_buf_tail, first);
        memcpy(dst + first, a->audio_buf, len - first);
    }
    a->audio_buf_tail = (a->audio_buf_tail + len) % AUDIO_BUF_CAP;
    a->audio_buf_size -= len;
}

static void audio_callback(void *userdata, Uint8 *stream, int len) {
    struct app *a = (struct app *)userdata;
    if (a->audio_buf_size >= len) {
        ring_read(a, stream, len);
    } else {
        int available = a->audio_buf_size;
        if (available > 0) ring_read(a, stream, available);
        memset(stream + available, 0, len - available);
    }
}

/* Drive the receiver's master output volume knob (with the system volume HUD).
 * level is clamped to 0.0..1.0. Sets the default output device's scalar volume,
 * preferring the master element and falling back to per-channel when a device
 * has no master volume control. Safe to call from the network/parser thread. */
static void tb_set_system_volume(double level) {
    if (level < 0.0) level = 0.0;
    if (level > 1.0) level = 1.0;
    Float32 vol = (Float32)level;

    AudioObjectPropertyAddress dev_addr = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioDeviceID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &dev_addr, 0, NULL,
                                   &size, &device) != noErr ||
        device == kAudioObjectUnknown) {
        return;
    }

    AudioObjectPropertyAddress vol_addr = {
        kAudioDevicePropertyVolumeScalar,
        kAudioDevicePropertyScopeOutput,
        kAudioObjectPropertyElementMain   /* element 0 = master */
    };
    Boolean settable = false;
    if (AudioObjectHasProperty(device, &vol_addr) &&
        AudioObjectIsPropertySettable(device, &vol_addr, &settable) == noErr &&
        settable) {
        AudioObjectSetPropertyData(device, &vol_addr, 0, NULL, sizeof(vol), &vol);
        return;
    }

    /* No master element — set the left/right channels individually. */
    for (UInt32 ch = 1; ch <= 2; ch++) {
        vol_addr.mElement = ch;
        settable = false;
        if (AudioObjectHasProperty(device, &vol_addr) &&
            AudioObjectIsPropertySettable(device, &vol_addr, &settable) == noErr &&
            settable) {
            AudioObjectSetPropertyData(device, &vol_addr, 0, NULL, sizeof(vol), &vol);
        }
    }
}

/* ---- Callbacks: parser → decoder ------------------------------------- */

static void on_packet(uint8_t type, const uint8_t *payload, size_t len, void *ud) {
    struct app *a = (struct app *)ud;
    if (!a || a->close_requested) return;
    if (!tb_session_packet_allowed(a->session_authenticated, type)) {
        fprintf(stderr, "[auth] rejected packet before pairing authentication\n");
        a->close_requested = 1;
        return;
    }
    switch (type) {
    case TB_PKT_SESSION_AUTH:
        handle_session_auth(a, payload, len);
        break;
    case TB_PKT_UI_LANGUAGE:
        {
            char ui_language[16];
            ui_language[0] = '\0';
            extract_json_string_field(payload, len, "\"uiLanguage\"", ui_language, sizeof(ui_language));
            if (ui_language[0] != '\0') {
                snprintf(a->sender_ui_language, sizeof(a->sender_ui_language), "%s", ui_language);
                if (strcmp(a->language_pref, "auto") == 0) {
                    tb_i18n_set_runtime_language(ui_language);
                }
                if (a->client_fd < 0 || !a->have_video_frame) {
                    tb_refresh_idle_localized_strings(a);
                }
            }
        }
        break;
    case TB_PKT_HELLO_RECEIVER:
        a->brightness_commands_only = 0;
        (void)extract_json_bool_field(payload, len, "\"brightnessCommandsOnly\"", &a->brightness_commands_only);
        extract_json_string_field(payload, len, "\"senderName\"", a->sender_text, sizeof(a->sender_text));
        {
            char ui_language[16];
            ui_language[0] = '\0';
            extract_json_string_field(payload, len, "\"uiLanguage\"", ui_language, sizeof(ui_language));
            if (ui_language[0] != '\0') {
                snprintf(a->sender_ui_language, sizeof(a->sender_ui_language), "%s", ui_language);
                if (strcmp(a->language_pref, "auto") == 0) {
                    tb_i18n_set_runtime_language(ui_language);
                }
            }
        }
        if (a->sender_text[0] == '\0') {
            tb_copy_i18n(a->sender_text, sizeof(a->sender_text), "receiver.status.sender_connected");
        }
        {
            char preset[64];
            char source[64];
            char codec[64];
            int capture_w = 0;
            int capture_h = 0;
            preset[0] = '\0';
            source[0] = '\0';
            codec[0] = '\0';
            extract_json_string_field(payload, len, "\"capturePreset\"", preset, sizeof(preset));
            extract_json_string_field(payload, len, "\"captureSource\"", source, sizeof(source));
            extract_json_string_field(payload, len, "\"codec\"", codec, sizeof(codec));
            (void)extract_json_int_field(payload, len, "\"captureWidth\"", &capture_w);
            (void)extract_json_int_field(payload, len, "\"captureHeight\"", &capture_h);

            tb_set_receiver_mode_requested(a->mode_text, sizeof(a->mode_text), capture_w, capture_h, source, preset, codec);
        }
        a->session_active = 1;
        fprintf(stderr, "[main] hello from sender\n");
        tb_copy_i18n(a->status_text, sizeof(a->status_text), "receiver.status.sender_connected_profile_sent");
        break;
    case TB_PKT_CREATE_SESSION_ACK:
        a->session_active = 1;
        fprintf(stderr, "[main] sender session ack: %.*s\n", (int)len, (const char *)payload);
        tb_copy_i18n(a->status_text, sizeof(a->status_text), "receiver.status.session_accepted_waiting_frames");
        break;
    case TB_PKT_PARAM_SETS:
        a->session_active = 1;
        /* tb_dec_set_param_sets is now a no-op if the sets are unchanged,
         * so we don't spam a log line per keyframe. */
        if (tb_dec_set_param_sets(a->dec, payload, len) == 0 && len > 0)
            a->stream_codec = payload[0];
        break;
    case TB_PKT_FRAME:
        a->session_active = 1;
        a->current_video_packet_ns = now_ns();
        a->received_video_frames++; a->raw_video_active = 0;
        if (tb_dec_feed_frame(a->dec, payload, len) < 0) a->decode_errors++;
        break;
    case TB_PKT_RAW_FRAME:
        a->session_active = 1;
        a->current_video_packet_ns = now_ns();
        a->received_video_frames++; a->raw_video_active = 1;
        handle_raw_frame(a, payload, len);
        break;
    case TB_PKT_CURSOR:
        {
            int x = 0;
            int y = 0;
            int w = 0;
            int h = 0;
            int visible = 0;
            int type = 0;
            (void)extract_json_int_field(payload, len, "\"x\"", &x);
            (void)extract_json_int_field(payload, len, "\"y\"", &y);
            (void)extract_json_int_field(payload, len, "\"width\"", &w);
            (void)extract_json_int_field(payload, len, "\"height\"", &h);
            (void)extract_json_bool_field(payload, len, "\"visible\"", &visible);
            (void)extract_json_int_field(payload, len, "\"type\"", &type);
            tb_disp_set_cursor(a->disp, x, y, w, h, visible, type);
        }
        break;
    case TB_PKT_DISPLAY_POWER:
        tb_receiver_handle_display_power(a, payload, len, 0);
        break;
    case TB_PKT_SENDER_POWER:
        tb_receiver_handle_display_power(a, payload, len, 1);
        break;
    case TB_PKT_BRIGHTNESS:
        {
            double level = NAN, actual = 0;
            if (!tb_receiver_parse_brightness(payload, len, &level)) {
                send_brightness_state(a, 0, NAN, "invalid-payload");
                break;
            }
            int accepted = tb_disp_set_brightness(a->disp, level, &actual) == 0;
            if (accepted) a->settings_brightness = actual;
            send_brightness_state(a, accepted, level, accepted ? "" : "backlight-failed");
        }
        break;
    case TB_PKT_CLIPBOARD:
        {
            char text[4096];
            extract_json_string_field(payload, len, "\"text\"", text, sizeof(text));
            tb_receiver_set_clipboard_text(text);
        }
        break;
    case TB_PKT_VOLUME:
        {
            double level = 1.0;
            (void)extract_json_double_field(payload, len, "\"level\"", &level);
            if (level < 0.0) level = 0.0;
            if (level > 1.0) level = 1.0;
            tb_set_system_volume(level);
        }
        break;
    case TB_PKT_SETTINGS_SYNC:
        handle_settings_sync(a, payload, len);
        break;
    case TB_PKT_AUDIO_FRAME:
        if (a->audio_device != 0 && !a->sender_sleeping && !a->manual_rescue) {
            SDL_LockAudioDevice(a->audio_device);

            (void)tb_audio_ring_write(a->audio_buf, &a->audio_buf_head,
                                      &a->audio_buf_tail, &a->audio_buf_size,
                                      payload, len);

            SDL_UnlockAudioDevice(a->audio_device);
        }
        break;
    case TB_PKT_INPUT_EVENT:
        tb_receiver_apply_input_event(payload, len);
        break;
    case TB_PKT_INPUT_CONTROL:
        tb_receiver_apply_input_control_mode(a, payload, len);
        break;
    case TB_PKT_HEARTBEAT:
        break;
    case TB_PKT_TEST_DATA:
        /* Performance test data; discard */
        break;
    case TB_PKT_TEARDOWN:
        fprintf(stderr, "[main] teardown requested by sender\n");
        tb_copy_i18n(a->status_text, sizeof(a->status_text), "receiver.status.session_closed_by_sender");
        a->close_requested = 1;
        break;
    default:
        fprintf(stderr, "[main] unknown pkt type=0x%02x\n", type);
        break;
    }
}

/* ---- Networking helpers ---------------------------------------------- */

static int drain_socket(struct app *a) {
    uint8_t buf[1024 * 1024];
    int saw_data = 0;
    int result = 0;
    a->batch_frame_width = a->batch_frame_height = 0;
    a->batch_frame_packet_ns = 0;
    tb_disp_begin_frame_batch(a->disp);
    for (int reads = 0; reads < 8; reads++) {
        ssize_t n = read(a->client_fd, buf, sizeof(buf));
        if (n > 0) {
            a->received_bytes += (uint64_t)n;
            saw_data = 1;
            result = 1;
            if (tb_parser_feed(&a->parser, buf, (size_t)n) < 0) {
                result = -1;
                break;
            }
            if (a->close_requested || (!a->session_authenticated && a->parser.len > 1024)) {
                result = -1;
                break;
            }
        } else if (n == 0) {
            result = -1;  /* peer closed */
            break;
        } else {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                result = saw_data;
                break;
            }
            perror("[main] read");
            result = -1;
            break;
        }
    }
    /* If several complete frames arrived together, their texture uploads have
     * overwritten one another; present only the newest decoded image. */
    int presented = tb_disp_end_frame_batch(a->disp);
    if (presented && a->batch_frame_width > 0 && !a->close_requested && result >= 0) {
        tb_stream_stats_note_latency(&a->stream_stats, a->batch_frame_packet_ns, now_ns());
        note_presented_video_frame(a, a->batch_frame_width, a->batch_frame_height);
    }
    return result;
}

static void write_be32(uint8_t *dst, uint32_t value) {
    dst[0] = (uint8_t)((value >> 24) & 0xff);
    dst[1] = (uint8_t)((value >> 16) & 0xff);
    dst[2] = (uint8_t)((value >> 8) & 0xff);
    dst[3] = (uint8_t)(value & 0xff);
}

static int send_control(struct app *a, const uint8_t *buf, size_t len) {
    if (!a || a->client_fd < 0 || a->close_requested) return -1;
    uint64_t now = now_ms();
    if (tb_control_enqueue(&a->control_send, buf, len, now) != 0 ||
        tb_control_flush(&a->control_send, a->client_fd, now) != 0) {
        fprintf(stderr, "[net] control send failed or congested; closing session\n");
        a->close_requested = 1;
        return -1;
    }
    return 0;
}

static void write_be64(uint8_t *dst, uint64_t value) {
    for (int i = 7; i >= 0; i--) {
        dst[i] = (uint8_t)(value & 0xff);
        value >>= 8;
    }
}

static uint16_t settings_level_quantized(double value) {
    if (value < 0.0) value = 0.0;
    if (value > 1.0) value = 1.0;
    return (uint16_t)(value * 1000.0 + 0.5);
}

static int decode_hex(const char *text, uint8_t *out, size_t out_size) {
    if (!text || !out || strlen(text) != out_size * 2) return 0;
    for (size_t i = 0; i < out_size; i++) {
        int nibbles[2];
        for (size_t j = 0; j < 2; j++) {
            unsigned char ch = (unsigned char)text[i * 2 + j];
            if (ch >= '0' && ch <= '9') nibbles[j] = ch - '0';
            else if (ch >= 'a' && ch <= 'f') nibbles[j] = ch - 'a' + 10;
            else if (ch >= 'A' && ch <= 'F') nibbles[j] = ch - 'A' + 10;
            else return 0;
        }
        out[i] = (uint8_t)((nibbles[0] << 4) | nibbles[1]);
    }
    return 1;
}

static int send_settings_json(struct app *a, uint8_t type, const char *json) {
    if (!a || a->client_fd < 0 || !json) return -1;
    size_t json_len = strlen(json);
    uint8_t packet[512];
    if (json_len + 1 > sizeof(packet) - 4) return -1;
    write_be32(packet, (uint32_t)(json_len + 1));
    packet[4] = type;
    memcpy(packet + 5, json, json_len);
    return send_control(a, packet, json_len + 5);
}

static void send_settings_challenge(struct app *a) {
    if (!a || a->client_fd < 0 || !a->pairing_key[0]) return;
    arc4random_buf(a->settings_nonce, sizeof(a->settings_nonce));
    a->settings_nonce_valid = 1;
    a->last_sender_settings_revision = 0;

    char nonce_hex[65];
    for (size_t i = 0; i < sizeof(a->settings_nonce); i++) {
        snprintf(nonce_hex + i * 2, sizeof(nonce_hex) - i * 2, "%02x", a->settings_nonce[i]);
    }
    uint8_t digest[32]; char proof_hex[65];
    tb_receiver_identity_digest(a->settings_nonce, a->pairing_key, a->receiver_id, digest);
    for (size_t i = 0; i < sizeof(digest); i++) snprintf(proof_hex + i * 2, 3, "%02x", digest[i]);
    char json[384];
    snprintf(json, sizeof(json),
             "{\"schemaVersion\":1,\"supportedSchemaVersion\":2,\"requiresSessionAuthentication\":true,\"nonce\":\"%s\",\"receiverID\":\"%s\",\"identityProof\":\"%s\"}",
             nonce_hex, a->receiver_id, proof_hex);
    if (send_settings_json(a, TB_PKT_SETTINGS_CHALLENGE, json) != 0) {
        a->settings_nonce_valid = 0;
    }
}

static void handle_session_auth(struct app *a, const uint8_t *payload, size_t len) {
    if (a->session_authenticated || !a->settings_nonce_valid ||
        !(len == 64 ? tb_session_auth_verify_v2(a->settings_nonce, a->pairing_key, a->receiver_id, payload, len)
                    : tb_session_auth_verify(a->settings_nonce, a->pairing_key, payload, len))) {
        fprintf(stderr, "[auth] rejected invalid session proof\n");
        a->close_requested = 1;
        return;
    }
    uint8_t packet[37];
    write_be32(packet, 33);
    packet[4] = TB_PKT_SESSION_AUTH_ACK;
    if (len == 64) tb_session_auth_digest_v2(a->settings_nonce, payload, a->pairing_key, a->receiver_id, 1, packet + 5);
    else tb_session_auth_digest(a->settings_nonce, a->pairing_key, 1, packet + 5);
    if (send_control(a, packet, sizeof(packet)) != 0) {
        a->close_requested = 1;
        return;
    }
    a->session_authenticated = 1;
    send_receiver_info(a);
    fprintf(stderr, "[auth] session pairing authenticated\n");
}

static void send_settings_ack(struct app *a, int accepted, uint64_t revision, const char *reason) {
    char json[256];
    if (!reason) reason = "";
    snprintf(json, sizeof(json),
             "{\"accepted\":%s,\"revision\":%llu,\"reason\":\"%s\"}",
             accepted ? "true" : "false", (unsigned long long)revision, reason);
    (void)send_settings_json(a, TB_PKT_SETTINGS_ACK, json);
}

static void handle_settings_sync(struct app *a, const uint8_t *payload, size_t len) {
    if (!a || !a->settings_nonce_valid || !a->pairing_key[0]) {
        send_settings_ack(a, 0, a ? a->settings_revision : 0, "not-paired");
        return;
    }

    int schema = 0;
    uint64_t sender_revision = 0;
    double brightness = 1.0;
    double volume = 0.5;
    uint32_t sleep_after_no_signal_seconds = a->sleep_after_no_signal_seconds;
    if (sleep_after_no_signal_seconds == 0) sleep_after_no_signal_seconds = 30;
    char language[16] = {0};
    char hmac_hex[80] = {0};
    uint8_t supplied_hmac[CC_SHA256_DIGEST_LENGTH];
    extract_json_string_field(payload, len, "\"language\"", language, sizeof(language));
    extract_json_string_field(payload, len, "\"hmac\"", hmac_hex, sizeof(hmac_hex));
    if (!extract_json_int_field(payload, len, "\"schemaVersion\"", &schema) ||
        (schema != 1 && schema != 2) ||
        !extract_json_u64_field(payload, len, "\"revision\"", &sender_revision) ||
        sender_revision <= a->last_sender_settings_revision ||
        !extract_json_double_field(payload, len, "\"brightness\"", &brightness) ||
        !extract_json_double_field(payload, len, "\"volume\"", &volume) ||
        !isfinite(brightness) || !isfinite(volume) ||
        brightness < 0.0 || brightness > 1.0 ||
        volume < 0.0 || volume > 1.0 ||
        language[0] == '\0' ||
        !tb_receiver_is_valid_language_pref(language) ||
        hmac_hex[0] == '\0' ||
        !decode_hex(hmac_hex, supplied_hmac, sizeof(supplied_hmac))) {
        send_settings_ack(a, 0, a->settings_revision, "invalid-payload");
        return;
    }

    if (schema == 2) {
        int sleep_seconds = 0;
        if (!extract_json_int_field(payload, len, "\"sleepAfterNoSignalSeconds\"", &sleep_seconds) ||
            sleep_seconds < 15 || sleep_seconds > 3600) {
            send_settings_ack(a, 0, a->settings_revision, "invalid-sleep-timeout");
            return;
        }
        sleep_after_no_signal_seconds = (uint32_t)sleep_seconds;
    }

    uint8_t message[60] = {0};
    memcpy(message, a->settings_nonce, sizeof(a->settings_nonce));
    write_be32(message + 32, (uint32_t)schema);
    write_be64(message + 36, sender_revision);
    uint16_t brightness_q = settings_level_quantized(brightness);
    uint16_t volume_q = settings_level_quantized(volume);
    message[44] = (uint8_t)(brightness_q >> 8);
    message[45] = (uint8_t)brightness_q;
    message[46] = (uint8_t)(volume_q >> 8);
    message[47] = (uint8_t)volume_q;
    memcpy(message + 48, language, strlen(language));
    if (schema == 2) write_be32(message + 56, sleep_after_no_signal_seconds);

    uint8_t expected_hmac[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256,
           a->pairing_key, strlen(a->pairing_key),
           message, schema == 2 ? sizeof(message) : 56, expected_hmac);
    unsigned int mismatch = 0;
    for (size_t i = 0; i < sizeof(expected_hmac); i++) mismatch |= expected_hmac[i] ^ supplied_hmac[i];
    if (mismatch != 0) {
        fprintf(stderr, "[settings] rejected unauthenticated settings update\n");
        send_settings_ack(a, 0, a->settings_revision, "authentication-failed");
        return;
    }

    if (a->settings_revision == UINT64_MAX) {
        send_settings_ack(a, 0, a->settings_revision, "revision-exhausted");
        return;
    }
    uint64_t local_revision = a->settings_revision + 1;
    if (!tb_receiver_save_settings(language, brightness, volume, local_revision,
                                   sleep_after_no_signal_seconds)) {
        send_settings_ack(a, 0, a->settings_revision, "local-save-failed");
        return;
    }

    a->last_sender_settings_revision = sender_revision;
    a->settings_revision = local_revision;
    int brightness_changed = fabs(a->settings_brightness - brightness) > 0.0005;
    a->settings_brightness = brightness;
    a->settings_volume = volume;
    a->sleep_after_no_signal_seconds = sleep_after_no_signal_seconds;
    snprintf(a->language_pref, sizeof(a->language_pref), "%s", language);
    if (brightness_changed && !a->brightness_commands_only) {
        double actual = 0;
        int applied = tb_disp_set_brightness(a->disp, brightness, &actual) == 0;
        send_brightness_state(a, applied, brightness, applied ? "" : "backlight-failed");
    }
    tb_set_system_volume(volume);
    tb_receiver_apply_language_preference(a);
    send_settings_ack(a, 1, local_revision, "");
    fprintf(stderr, "[settings] applied authenticated Sender settings revision %llu\n",
            (unsigned long long)sender_revision);
}

static void tb_receiver_send_input_event(struct app *a,
                                         const char *kind,
                                         int has_dx, int dx,
                                         int has_dy, int dy,
                                         int has_scroll_x, int scroll_x,
                                         int has_scroll_y, int scroll_y,
                                         int has_key_code, uint16_t key_code) {
    if (!a || a->client_fd < 0) return;
    if (strcmp(a->input_control_mode, "receiverMaster") != 0) return;

    char json[256];
    int len = snprintf(json, sizeof(json), "{\"kind\":\"%s\"", kind ? kind : "");
    if (len <= 0 || (size_t)len >= sizeof(json)) return;

    if (has_dx) len += snprintf(json + len, sizeof(json) - (size_t)len, ",\"dx\":%d", dx);
    if (has_dy) len += snprintf(json + len, sizeof(json) - (size_t)len, ",\"dy\":%d", dy);
    if (has_scroll_x) len += snprintf(json + len, sizeof(json) - (size_t)len, ",\"scrollX\":%d", scroll_x);
    if (has_scroll_y) len += snprintf(json + len, sizeof(json) - (size_t)len, ",\"scrollY\":%d", scroll_y);
    if (has_key_code) len += snprintf(json + len, sizeof(json) - (size_t)len, ",\"keyCode\":%u", (unsigned int)key_code);
    len += snprintf(json + len, sizeof(json) - (size_t)len, "}");
    if (len <= 0 || (size_t)len >= sizeof(json)) return;

    uint8_t pkt[4 + 1 + sizeof(json)];
    write_be32(pkt, (uint32_t)(1 + len));
    pkt[4] = TB_PKT_INPUT_EVENT;
    memcpy(pkt + 5, json, (size_t)len);
    a->input_events_sent += 1;
    if (tb_should_log_input_event(a->input_events_sent)) {
        tb_receiver_input_log("[input][receiver->sender] send #%llu kind=%s dx=%d dy=%d sx=%d sy=%d key=%u mode=%s",
                              (unsigned long long)a->input_events_sent,
                              kind ? kind : "?",
                              has_dx ? dx : 0,
                              has_dy ? dy : 0,
                              has_scroll_x ? scroll_x : 0,
                              has_scroll_y ? scroll_y : 0,
                              has_key_code ? (unsigned int)key_code : 0,
                              a->input_control_mode);
    }
    (void)send_control(a, pkt, 5 + (size_t)len);
}

static void tb_receiver_send_target_switch(struct app *a, int direction) {
    tb_receiver_send_input_event(a,
                                 direction < 0 ? "switchPrevTarget" : "switchNextTarget",
                                 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
}

static void tb_receiver_sync_modifier_state(struct app *a,
                                            int command_down,
                                            int shift_down,
                                            int option_down,
                                            int control_down,
                                            int caps_down) {
    if (!a) return;

    struct {
        int *state;
        int desired;
        uint16_t key_code;
    } modifiers[] = {
        { &a->sent_command_down, command_down, 55 },
        { &a->sent_shift_down,   shift_down,   56 },
        { &a->sent_option_down,  option_down,  58 },
        { &a->sent_control_down, control_down, 59 },
        { &a->sent_caps_down,    caps_down,    57 }
    };

    for (size_t i = 0; i < sizeof(modifiers) / sizeof(modifiers[0]); i++) {
        if (*modifiers[i].state == modifiers[i].desired) continue;
        tb_receiver_send_input_event(a,
                                     modifiers[i].desired ? "keyDown" : "keyUp",
                                     0, 0, 0, 0, 0, 0, 0, 0, 1, modifiers[i].key_code);
        *modifiers[i].state = modifiers[i].desired;
    }
}

static void tb_receiver_send_space_switch(struct app *a, int direction) {
    tb_receiver_send_input_event(a,
                                 direction < 0 ? "switchPrevSpace" : "switchNextSpace",
                                 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
}

static void tb_receiver_space_switch_callback(int direction, void *context) {
    struct app *a = (struct app *)context;
    if (!a || strcmp(a->input_control_mode, "receiverMaster") != 0 || a->client_fd < 0) return;
    tb_receiver_send_space_switch(a, direction);
}

static void tb_receiver_send_deactivate_control(struct app *a) {
    tb_receiver_send_input_event(a,
                                 "deactivateInputControl",
                                 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
}

static CGEventRef tb_receiver_input_tap_callback(CGEventTapProxy proxy,
                                                 CGEventType type,
                                                 CGEventRef event,
                                                 void *user_info) {
    (void)proxy;
    struct app *a = (struct app *)user_info;
    if (!a) return event;

    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (a->input_tap) CGEventTapEnable(a->input_tap, true);
        return event;
    }

    if (strcmp(a->input_control_mode, "receiverMaster") != 0) return event;

    /* Only drive the sender while the user is actually on the shared display
     * window's Space. The global tap also sees events from other receiver
     * Spaces; forwarding those would make the sender's cursor jump while the
     * user is doing local work on the receiver. When the window is on a
     * different Space, pass the event through untouched and forward nothing. */
    if (!tb_disp_window_on_active_space(a->disp)) return event;

    if ((type == kCGEventKeyDown || type == kCGEventKeyUp) && tb_disp_has_keyboard_focus(a->disp)) {
        unsigned int shortcut = 0;
        CGEventFlags flags = CGEventGetFlags(event);
        if (rv_receiver_shortcut(&a->shortcut_held,
            (unsigned int)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode),
            type == kCGEventKeyDown, (int)CGEventGetIntegerValueField(event, kCGKeyboardEventAutorepeat),
            (flags & (kCGEventFlagMaskCommand | kCGEventFlagMaskAlternate | kCGEventFlagMaskControl)) != 0, &shortcut)) {
            if (shortcut == RV_RECEIVER_SHORTCUT_DEBUG) a->pending_local_actions ^= TB_DISP_ACTION_TOGGLE_DEBUG;
            if (shortcut == RV_RECEIVER_SHORTCUT_RESCUE) a->pending_local_actions ^= TB_DISP_ACTION_TOGGLE_RESCUE;
            return a->input_tap_consumes_events ? NULL : event;
        }
    }

    int should_consume = 0;

    switch (type) {
    case kCGEventMouseMoved:
    case kCGEventLeftMouseDragged:
    case kCGEventRightMouseDragged:
    case kCGEventOtherMouseDragged: {
        int dx = (int)CGEventGetIntegerValueField(event, kCGMouseEventDeltaX);
        int dy = (int)CGEventGetIntegerValueField(event, kCGMouseEventDeltaY);
        CGPoint location = CGEventGetLocation(event);
        CGRect bounds = CGDisplayBounds(CGMainDisplayID());
        uint64_t now = now_ms();
        if (now - a->last_target_switch_ms > 450) {
            if (location.x <= CGRectGetMinX(bounds) + 2.0 && dx < 0) {
                a->last_target_switch_ms = now;
                tb_receiver_send_target_switch(a, -1);
                should_consume = a->input_tap_consumes_events;
                break;
            }
            if (location.x >= CGRectGetMaxX(bounds) - 2.0 && dx > 0) {
                a->last_target_switch_ms = now;
                tb_receiver_send_target_switch(a, 1);
                should_consume = a->input_tap_consumes_events;
                break;
            }
        }
        const char *kind = "move";
        if (type == kCGEventLeftMouseDragged) kind = "leftDrag";
        else if (type == kCGEventRightMouseDragged) kind = "rightDrag";
        else if (type == kCGEventOtherMouseDragged) kind = "otherDrag";
        tb_receiver_send_input_event(a, kind, 1, dx, 1, dy, 0, 0, 0, 0, 0, 0);
        should_consume = a->input_tap_consumes_events;
        break;
    }
    case kCGEventLeftMouseDown:
        tb_receiver_send_input_event(a, "leftDown", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        should_consume = a->input_tap_consumes_events;
        break;
    case kCGEventLeftMouseUp:
        tb_receiver_send_input_event(a, "leftUp", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        should_consume = a->input_tap_consumes_events;
        break;
    case kCGEventRightMouseDown:
        tb_receiver_send_input_event(a, "rightDown", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        should_consume = a->input_tap_consumes_events;
        break;
    case kCGEventRightMouseUp:
        tb_receiver_send_input_event(a, "rightUp", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        should_consume = a->input_tap_consumes_events;
        break;
    case kCGEventOtherMouseDown:
        tb_receiver_send_input_event(a, "otherDown", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        should_consume = a->input_tap_consumes_events;
        break;
    case kCGEventOtherMouseUp:
        tb_receiver_send_input_event(a, "otherUp", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
        should_consume = a->input_tap_consumes_events;
        break;
    case kCGEventScrollWheel: {
        int sx = (int)CGEventGetIntegerValueField(event, kCGScrollWheelEventDeltaAxis2);
        int sy = (int)CGEventGetIntegerValueField(event, kCGScrollWheelEventDeltaAxis1);
        int point_sx = (int)CGEventGetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis2);
        int point_sy = (int)CGEventGetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis1);
        int is_continuous = (int)CGEventGetIntegerValueField(event, kCGScrollWheelEventIsContinuous);
        CGEventFlags flags = CGEventGetFlags(event);
        const CGEventFlags effective_flags = flags & ~kCGEventFlagMaskSecondaryFn;
        uint64_t now = now_ms();
        if ((effective_flags & kCGEventFlagMaskAlternate) &&
            (llabs((long long)point_sx) > llabs((long long)point_sy) * 2 || llabs((long long)sx) > llabs((long long)sy) * 2) &&
            now - a->last_space_switch_ms > 300) {
            int direction = 0;
            if (point_sx != 0) direction = point_sx > 0 ? 1 : -1;
            else if (sx != 0) direction = sx > 0 ? 1 : -1;
            if (direction != 0) {
                a->last_space_switch_ms = now;
                a->space_gesture_accum_x = 0;
                tb_receiver_send_space_switch(a, direction);
                should_consume = a->input_tap_consumes_events;
                break;
            }
        }
        if (is_continuous &&
            (point_sx != 0 || point_sy != 0) &&
            llabs((long long)point_sx) > llabs((long long)point_sy) * 2) {
            if (now - a->last_space_gesture_ms > 250) {
                a->space_gesture_accum_x = 0;
            }
            a->last_space_gesture_ms = now;
            a->space_gesture_accum_x += point_sx;
            if (llabs((long long)a->space_gesture_accum_x) >= 45 &&
                now - a->last_space_switch_ms > 450) {
                a->last_space_switch_ms = now;
                tb_receiver_send_space_switch(a, a->space_gesture_accum_x > 0 ? 1 : -1);
                a->space_gesture_accum_x = 0;
            }
            should_consume = a->input_tap_consumes_events;
            break;
        }
        if (now - a->last_space_gesture_ms > 250) {
            a->space_gesture_accum_x = 0;
        }
        tb_receiver_send_input_event(a, "scroll", 0, 0, 0, 0, 1, sx, 1, sy, 0, 0);
        should_consume = a->input_tap_consumes_events;
        break;
    }
    case kCGEventKeyDown: {
        uint16_t key_code = (uint16_t)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        CGEventFlags flags = CGEventGetFlags(event);
        const CGEventFlags effective_flags = flags & ~kCGEventFlagMaskSecondaryFn;
        tb_receiver_sync_modifier_state(a,
                                        (effective_flags & kCGEventFlagMaskCommand) != 0,
                                        (effective_flags & kCGEventFlagMaskShift) != 0,
                                        (effective_flags & kCGEventFlagMaskAlternate) != 0,
                                        (effective_flags & kCGEventFlagMaskControl) != 0,
                                        (effective_flags & kCGEventFlagMaskAlphaShift) != 0);
        if ((flags & kCGEventFlagMaskControl) &&
            (flags & kCGEventFlagMaskAlternate) &&
            (flags & kCGEventFlagMaskCommand) &&
            key_code == 40) {
            tb_receiver_send_deactivate_control(a);
            should_consume = a->input_tap_consumes_events;
            break;
        }
        if ((effective_flags & kCGEventFlagMaskControl) && (effective_flags & kCGEventFlagMaskCommand)) {
            if (key_code == 123) {
                tb_receiver_send_target_switch(a, -1);
                should_consume = a->input_tap_consumes_events;
                break;
            }
            if (key_code == 124) {
                tb_receiver_send_target_switch(a, 1);
                should_consume = a->input_tap_consumes_events;
                break;
            }
        }
        tb_receiver_send_input_event(a, "keyDown", 0, 0, 0, 0, 0, 0, 0, 0, 1, key_code);
        should_consume = a->input_tap_consumes_events;
        break;
    }
    case kCGEventKeyUp:
    {
        uint16_t key_code = (uint16_t)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        CGEventFlags flags = CGEventGetFlags(event);
        const CGEventFlags effective_flags = flags & ~kCGEventFlagMaskSecondaryFn;
        tb_receiver_sync_modifier_state(a,
                                        (effective_flags & kCGEventFlagMaskCommand) != 0,
                                        (effective_flags & kCGEventFlagMaskShift) != 0,
                                        (effective_flags & kCGEventFlagMaskAlternate) != 0,
                                        (effective_flags & kCGEventFlagMaskControl) != 0,
                                        (effective_flags & kCGEventFlagMaskAlphaShift) != 0);
        if ((flags & kCGEventFlagMaskControl) &&
            (flags & kCGEventFlagMaskAlternate) &&
            (flags & kCGEventFlagMaskCommand) &&
            key_code == 40) {
            should_consume = a->input_tap_consumes_events;
            break;
        }
        if ((effective_flags & kCGEventFlagMaskControl) && (effective_flags & kCGEventFlagMaskCommand) &&
            (key_code == 123 || key_code == 124)) {
            should_consume = a->input_tap_consumes_events;
            break;
        }
        tb_receiver_send_input_event(a, "keyUp", 0, 0, 0, 0, 0, 0, 0, 0, 1, key_code);
        should_consume = a->input_tap_consumes_events;
        break;
    }
    case kCGEventFlagsChanged: {
        CGEventFlags flags = CGEventGetFlags(event);
        const CGEventFlags effective_flags = flags & ~kCGEventFlagMaskSecondaryFn;
        should_consume = a->input_tap_consumes_events;
        tb_receiver_sync_modifier_state(a,
                                        (effective_flags & kCGEventFlagMaskCommand) != 0,
                                        (effective_flags & kCGEventFlagMaskShift) != 0,
                                        (effective_flags & kCGEventFlagMaskAlternate) != 0,
                                        (effective_flags & kCGEventFlagMaskControl) != 0,
                                        (effective_flags & kCGEventFlagMaskAlphaShift) != 0);
        break;
    }
    default:
        break;
    }

    return should_consume ? NULL : event;
}

static void tb_receiver_stop_input_tap(struct app *a) {
    if (!a) return;
    if (a->input_tap_source) {
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), a->input_tap_source, kCFRunLoopCommonModes);
        CFRelease(a->input_tap_source);
        a->input_tap_source = NULL;
    }
    if (a->input_tap) {
        CFMachPortInvalidate(a->input_tap);
        CFRelease(a->input_tap);
        a->input_tap = NULL;
    }
    a->input_tap_consumes_events = 0;
}

static void tb_receiver_start_input_tap(struct app *a) {
    if (!a || a->input_tap) return;

    if (!tb_receiver_input_monitoring_trusted()) {
        return;
    }

    const int can_consume = tb_receiver_accessibility_trusted() ? 1 : 0;
    CGEventTapOptions tap_options = can_consume ? kCGEventTapOptionDefault : kCGEventTapOptionListenOnly;

    CGEventMask mask =
        CGEventMaskBit(kCGEventMouseMoved) |
        CGEventMaskBit(kCGEventLeftMouseDragged) |
        CGEventMaskBit(kCGEventRightMouseDragged) |
        CGEventMaskBit(kCGEventOtherMouseDragged) |
        CGEventMaskBit(kCGEventLeftMouseDown) |
        CGEventMaskBit(kCGEventLeftMouseUp) |
        CGEventMaskBit(kCGEventRightMouseDown) |
        CGEventMaskBit(kCGEventRightMouseUp) |
        CGEventMaskBit(kCGEventOtherMouseDown) |
        CGEventMaskBit(kCGEventOtherMouseUp) |
        CGEventMaskBit(kCGEventScrollWheel) |
        CGEventMaskBit(kCGEventKeyDown) |
        CGEventMaskBit(kCGEventKeyUp) |
        CGEventMaskBit(kCGEventFlagsChanged);

    a->input_tap = CGEventTapCreate(
        kCGHIDEventTap,
        kCGHeadInsertEventTap,
        tap_options,
        mask,
        tb_receiver_input_tap_callback,
        a
    );
    if (!a->input_tap) {
        tb_receiver_input_log("[input] global event tap unavailable; will fall back to SDL window input");
        return;
    }

    a->input_tap_source = CFMachPortCreateRunLoopSource(NULL, a->input_tap, 0);
    if (!a->input_tap_source) {
        tb_receiver_stop_input_tap(a);
        tb_receiver_input_log("[input] failed to create runloop source for event tap; using SDL fallback");
        return;
    }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), a->input_tap_source, kCFRunLoopCommonModes);
    CGEventTapEnable(a->input_tap, true);
    a->input_tap_consumes_events = can_consume;
    tb_receiver_input_log("[input] global event tap enabled for receiverMaster mode (consume=%s)",
                          can_consume ? "true" : "false");
}

static void tb_receiver_refresh_input_capture(struct app *a) {
    if (!a) return;
    if (!a->manual_rescue && strcmp(a->input_control_mode, "receiverMaster") == 0 && a->client_fd >= 0) {
        const int wants_global_tap = tb_receiver_input_monitoring_trusted() ? 1 : 0;
        const int wants_consume = tb_receiver_accessibility_trusted() ? 1 : 0;
        if (a->input_tap && (!wants_global_tap || a->input_tap_consumes_events != wants_consume)) {
            tb_receiver_stop_input_tap(a);
        }
        tb_receiver_start_input_tap(a);
        tb_disp_set_input_intercept_active(a->disp, 1);
        tb_disp_set_input_capture_active(a->disp, a->input_tap == NULL ? 1 : 0);
        tb_gesture_bridge_set_active(1);
        tb_receiver_input_log("[input] receiverMaster capture path = %s",
                              a->input_tap ? "global-tap" : "sdl-fallback");
    } else {
        tb_receiver_stop_input_tap(a);
        tb_disp_set_input_intercept_active(a->disp, 0);
        tb_disp_set_input_capture_active(a->disp, 0);
        tb_gesture_bridge_set_active(0);
        tb_receiver_input_log("[input] input capture disabled");
    }
}

static void tb_receiver_control_notification(CFNotificationCenterRef center, void *observer,
    CFStringRef name, const void *object, CFDictionaryRef info) {
    (void)center; (void)object; (void)info;
    struct app *a = observer;
    if (CFEqual(name, CFSTR(RV_RECEIVER_DEBUG_TOGGLE_NOTIFICATION)))
        a->pending_local_actions ^= TB_DISP_ACTION_TOGGLE_DEBUG;
    if (CFEqual(name, CFSTR(RV_RECEIVER_RESCUE_TOGGLE_NOTIFICATION)))
        a->pending_local_actions ^= TB_DISP_ACTION_TOGGLE_RESCUE;
}

static void tb_receiver_apply_local_actions(struct app *a, unsigned int actions) {
    if (actions & TB_DISP_ACTION_TOGGLE_RESCUE) {
        tb_receiver_sync_modifier_state(a, 0, 0, 0, 0, 0);
        a->manual_rescue = !a->manual_rescue;
        tb_disp_set_rescue_override(a->disp, a->manual_rescue);
        tb_receiver_refresh_input_capture(a);
        struct tb_input_event stale;
        while (tb_disp_pop_input_event(a->disp, &stale)) {}
        tb_receiver_apply_display_intent(a);
        if (a->audio_device) {
            SDL_LockAudioDevice(a->audio_device);
            a->audio_buf_head = a->audio_buf_tail = a->audio_buf_size = 0;
            SDL_UnlockAudioDevice(a->audio_device);
            SDL_PauseAudioDevice(a->audio_device,
                a->manual_rescue || a->sender_sleeping || !a->have_video_frame || a->display_health.rescue_locked ? 1 : 0);
        }
        fprintf(stderr, "[debug] manual Rescue %s; listener and stream retained\n", a->manual_rescue ? "on" : "off");
    }
    if (actions & TB_DISP_ACTION_TOGGLE_DEBUG) a->debug_visible = !a->debug_visible;
    if (actions & (TB_DISP_ACTION_TOGGLE_DEBUG | TB_DISP_ACTION_TOGGLE_RESCUE)) {
        tb_receiver_refresh_debug_text(a);
        a->display_state_notify_sent = 0;
        tb_receiver_publish_display_state(a, now_ms());
    }
}

static void send_receiver_info(struct app *a) {
    if (!a || !a->session_authenticated) return;
    struct tb_display_info info;
    if (tb_disp_get_info(a->disp, &info) < 0) return;

    const uint32_t panel_w = info.active_w, panel_h = info.active_h;
    const uint32_t mode_w = info.mode_w, mode_h = info.mode_h;
    const uint32_t capture_w = panel_w, capture_h = panel_h;
    double actual_brightness = 0;
    const int supports_brightness = tb_disp_read_brightness(a->disp, &actual_brightness) == 0;

    char escaped_name[256];
    size_t out = 0;
    for (size_t i = 0; info.name[i] != '\0' && out + 2 < sizeof(escaped_name); i++) {
        unsigned char c = (unsigned char)info.name[i];
        if (c == '"' || c == '\\') {
            escaped_name[out++] = '\\';
            escaped_name[out++] = (char)c;
        } else if (c >= 0x20) {
            escaped_name[out++] = (char)c;
        }
    }
    escaped_name[out] = '\0';

    char json[1200];
    int json_len = snprintf(
        json,
        sizeof(json),
        "{\"receiverName\":\"%s\",\"panelWidth\":%u,\"panelHeight\":%u,"
        "\"modeWidth\":%u,\"modeHeight\":%u,\"refreshRate\":%.3f,"
        "\"hiDPI\":%s,\"captureWidth\":%u,\"captureHeight\":%u,"
        "\"widthMillimeters\":%.3f,\"heightMillimeters\":%.3f,\"displayIdentity\":\"%s\","
        "\"nativeModeKnown\":%s,\"supportsBrightness\":%s,\"supportsBrightnessState\":true,\"supportsAutomaticBrightnessControl\":false,"
        "\"supportsHEVCDecode\":%s,\"supportsRawNV12\":true,\"supportsDisplayPower\":true,\"supportsSenderPower\":true,\"inputMonitoringTrusted\":%s,\"accessibilityTrusted\":%s}",
        escaped_name,
        panel_w,
        panel_h,
        mode_w,
        mode_h,
        info.refresh_rate, info.hi_dpi ? "true" : "false",
        capture_w,
        capture_h,
        info.width_mm, info.height_mm, info.identity,
        info.native_mode_known ? "true" : "false", supports_brightness ? "true" : "false",
        tb_dec_supports_hevc_hwdecode() ? "true" : "false",
        tb_receiver_input_monitoring_trusted() ? "true" : "false",
        tb_receiver_accessibility_trusted() ? "true" : "false"
    );
    if (json_len <= 0 || (size_t)json_len >= sizeof(json)) return;

    const size_t packet_len = 4 + 1 + (size_t)json_len;
    uint8_t *pkt = (uint8_t *)calloc(1, packet_len);
    if (!pkt) return;

    write_be32(pkt, (uint32_t)(1 + json_len));
    pkt[4] = TB_PKT_DISPLAY_PROFILE;
    memcpy(pkt + 5, json, (size_t)json_len);

    if (send_control(a, pkt, packet_len) == 0) {
        fprintf(stderr,
                "[main] sent display profile: panel=%ux%u mode=%ux%u hidpi name=%s\n",
                panel_w, panel_h, mode_w, mode_h, info.name);
    }
    free(pkt);
    send_brightness_state(a, -1, NAN, "");
}

static void close_client(struct app *a) {
    /* A sleeping host may close TCP before Rescue replies. Complete that
     * local operation even without a socket, and retain its sleep intent. */
    if (!a->power_is_sender_state && !(a->power_has_waiter && a->power_waiter_sender_state))
        tb_receiver_cancel_pending_power(a, 0);
    tb_control_clear(&a->control_send);
    if (a->client_fd >= 0) close(a->client_fd);
    a->client_fd = -1;
    a->session_active = 0;
    a->brightness_commands_only = 0;
    a->close_requested = 0;
    a->have_video_frame = 0;
    a->stream_width = a->stream_height = a->stream_codec = a->raw_video_active = 0;
    tb_stream_stats_reset(&a->stream_stats, now_ms(), a->received_bytes, a->received_video_frames, a->presented_batches, a->frames);
    rv_display_signal_init(&a->display_health);
    tb_disp_set_recovery_pending(a->disp, 1);
    a->settings_nonce_valid = 0;
    a->session_authenticated = 0;
    a->last_sender_settings_revision = 0;
    snprintf(a->input_control_mode, sizeof(a->input_control_mode), "off");
    SDL_EnableScreenSaver();
    if (a->audio_device != 0) SDL_PauseAudioDevice(a->audio_device, 1);
    tb_receiver_release_display_assertion(a);
    tb_receiver_refresh_input_capture(a);
    tb_disp_set_connection_state(a->disp, 0);
    tb_disp_set_cursor(a->disp, 0, 0, 1, 1, 0, 0);
    tb_refresh_idle_localized_strings(a);
    a->last_clipboard_text[0] = '\0';
    tb_parser_free(&a->parser);
    tb_parser_init(&a->parser, on_packet, a);
    tb_dec_reset(a->dec);   /* fresh decoder for next session */
    if (a->audio_device != 0) {
        SDL_LockAudioDevice(a->audio_device);
        a->audio_buf_head = 0;
        a->audio_buf_tail = 0;
        a->audio_buf_size = 0;
        SDL_UnlockAudioDevice(a->audio_device);
    }
    fprintf(stderr, "[main] client disconnected\n");
    if (a->debug_visible) tb_receiver_refresh_debug_text(a);
}

/* Build the display string for the host/IP line of the status screen.
 * have_ip: non-zero if ip_fallback is a real IP, zero if no IP is available.
 * Called once at startup (and when the IP changes) to cache the result in
 * a.display_host — do NOT call gethostname() in the render loop. */
static void build_display_host(char *buf, size_t bufsz, const char *ip_fallback, int have_ip) {
    if (!buf || bufsz == 0) return;
    char host[96] = {0};
    if (gethostname(host, sizeof(host)) == 0 && host[0] != '\0' && strcmp(host, "localhost") != 0) {
        char short_host[96] = {0};
        size_t i = 0;
        for (; host[i] != '\0' && host[i] != '.' && i + 1 < sizeof(short_host); i++) {
            short_host[i] = host[i];
        }
        short_host[i] = '\0';
        if (short_host[0] != '\0') {
            if (have_ip && ip_fallback && ip_fallback[0] != '\0') {
                snprintf(buf, bufsz, "%s (%s)", short_host, ip_fallback);
            } else {
                snprintf(buf, bufsz, "%s", short_host);
            }
            return;
        }
    }
    snprintf(buf, bufsz, "%s", (have_ip && ip_fallback && ip_fallback[0] != '\0')
             ? ip_fallback : tb_i18n_get("receiver.network.not_detected"));
}

/* ---- Main ------------------------------------------------------------ */

int main(int argc, char **argv) {
    int fullscreen = 1;
    int appliance = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--windowed") == 0) fullscreen = 0;
        if (strcmp(argv[i], "--appliance") == 0) appliance = 1;
    }

    char startup_language_pref[8];
    tb_receiver_load_language_preference(startup_language_pref, sizeof(startup_language_pref));
    if (strcmp(startup_language_pref, "auto") != 0) {
        tb_i18n_set_runtime_language(startup_language_pref);
    }
    (void)tb_i18n_init();

    signal(SIGINT,  on_sigint);
    signal(SIGTERM, on_sigint);
    signal(SIGPIPE, SIG_IGN);

    char tb_ip[64] = {0};
    char net_ip[64] = {0};
    if (tb_net_get_tb_ip(tb_ip, sizeof(tb_ip)) == 0) {
        printf("TBReceiver: Thunderbolt Bridge IP = %s\n", tb_ip);
    } else {
        printf("TBReceiver: warning, no bridge IP detected (169.254.x.x)\n");
    }
    if (tb_net_get_lan_ip(net_ip, sizeof(net_ip)) == 0) {
        printf("TBReceiver: Local network IP = %s\n", net_ip);
    } else {
        printf("TBReceiver: warning, no LAN IP detected (RFC1918 IPv4)\n");
    }
    printf("TBReceiver: listening on TCP port %d\n", TB_PORT);

    struct app a;
    memset(&a, 0, sizeof(a));
    rv_display_signal_init(&a.display_health);
    a.server_fd = -1;
    a.client_fd = -1;
    {
        char host[96] = {0};
        if (gethostname(host, sizeof(host)) != 0 || host[0] == '\0') {
            snprintf(host, sizeof(host), "%s", "Receiver");
        }
        snprintf(a.bonjour_name, sizeof(a.bonjour_name), "TargetBridge %s", host);
    }
    snprintf(a.tb_ip_text, sizeof(a.tb_ip_text), "%s", tb_ip);
    snprintf(a.net_ip_text, sizeof(a.net_ip_text), "%s", net_ip);
    snprintf(a.ip_text, sizeof(a.ip_text), "%s", tb_ip[0] ? tb_ip : (net_ip[0] ? net_ip : tb_i18n_get("receiver.network.not_detected")));
    snprintf(a.language_pref, sizeof(a.language_pref), "%s", startup_language_pref);
    tb_receiver_load_control_settings(&a);
    tb_receiver_load_pairing_key(&a);
    tb_receiver_ensure_settings_dir();
    const char *identity_home = getenv("HOME");
    char identity_path[PATH_MAX];
    if (!identity_home || snprintf(identity_path, sizeof(identity_path),
        "%s/Library/Application Support/TargetBridge Receiver/receiver.id", identity_home) >= (int)sizeof(identity_path) ||
        !tb_receiver_id_load(identity_path, a.receiver_id)) {
        fprintf(stderr, "[identity] could not load persistent receiver identity; refusing connections\n");
        return 1;
    }
    snprintf(a.input_control_mode, sizeof(a.input_control_mode), "%s", "off");
    a.last_input_monitoring_trusted = -1;
    a.last_accessibility_trusted = -1;
    tb_refresh_idle_localized_strings(&a);
    build_display_host(a.display_host, sizeof(a.display_host), a.ip_text, tb_ip[0] || net_ip[0]);
    tb_receiver_apply_language_preference(&a);
    tb_gesture_bridge_install(tb_receiver_space_switch_callback, &a);
    tb_gesture_bridge_set_active(0);

    a.disp = tb_disp_create(fullscreen, appliance);
    if (!a.disp) { fprintf(stderr, "tb_disp_create failed\n"); return 1; }
    tb_receiver_install_lifecycle_menu();
    /* Leave local macOS/ambient backlight unchanged on launch. */

    /* Open SDL Audio Device */
    SDL_AudioSpec spec;
    SDL_zero(spec);
    spec.freq = 48000;
    spec.format = AUDIO_S16LSB; // 16-bit signed, little-endian PCM
    spec.channels = 2;          // Stereo
    spec.samples = 1024;        // Buffer size (approx 21.3ms)
    spec.callback = audio_callback;
    spec.userdata = &a;
    SDL_AudioSpec obtained;
    a.audio_device = SDL_OpenAudioDevice(NULL, 0, &spec, &obtained, 0);
    if (a.audio_device != 0) {
        SDL_PauseAudioDevice(a.audio_device, 1); // Play only with valid network video.
        fprintf(stderr, "[main] SDL audio device opened: 48000Hz stereo 16-bit PCM (obtained %d samples)\n", obtained.samples);
    } else {
        fprintf(stderr, "[main] warning: SDL_OpenAudioDevice failed: %s\n", SDL_GetError());
    }
    tb_set_system_volume(a.settings_volume);

    struct tb_display_info boot_info;
    if (tb_disp_get_info(a.disp, &boot_info) == 0) {
        snprintf(a.panel_text, sizeof(a.panel_text), "%u x %u px (%s)",
                 boot_info.active_w, boot_info.active_h, boot_info.name);
    } else {
        tb_copy_i18n(a.panel_text, sizeof(a.panel_text), "receiver.panel.default");
    }
    bonjour_update(&a, TB_PORT);

    a.dec = tb_dec_create(on_frame, &a);
    if (!a.dec) { fprintf(stderr, "tb_dec_create failed\n"); tb_disp_destroy(a.disp); return 1; }

    tb_parser_init(&a.parser, on_packet, &a);

    a.server_fd = tb_net_listen(TB_PORT);
    if (a.server_fd < 0) { fprintf(stderr, "tb_net_listen failed\n"); return 1; }

    CFNotificationCenterRef power_center = CFNotificationCenterGetDistributedCenter();
    CFNotificationCenterAddObserver(power_center, &a, tb_receiver_power_notification,
        CFSTR(RV_POWER_RESULT_NOTIFICATION), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(power_center, &a, tb_receiver_power_notification,
        CFSTR(RV_RESCUE_READY_NOTIFICATION), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(power_center, &a, tb_receiver_control_notification,
        CFSTR(RV_RECEIVER_DEBUG_TOGGLE_NOTIFICATION), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(power_center, &a, tb_receiver_control_notification,
        CFSTR(RV_RECEIVER_RESCUE_TOGGLE_NOTIFICATION), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterPostNotification(power_center, CFSTR(RV_RECEIVER_RESTART_NOTIFICATION), NULL, NULL, true);

    a.last_fps_tick_ms = now_ms();
    tb_stream_stats_reset(&a.stream_stats, a.last_fps_tick_ms, 0, 0, 0, 0);
    a.last_ip_check_ms = 0;

    while (!g_term) {
        unsigned int disp_actions = tb_disp_poll_actions(a.disp);
        int socket_activity = 0;
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.0, true);
        disp_actions ^= a.pending_local_actions;
        a.pending_local_actions = 0;
        if (disp_actions & TB_DISP_ACTION_QUIT) break;
        tb_receiver_apply_local_actions(&a, disp_actions);
        if ((disp_actions & TB_DISP_ACTION_CYCLE_LANGUAGE) && a.client_fd < 0) {
            tb_receiver_cycle_language_preference(&a);
        }

        uint64_t t = now_ms();
        if (a.power_request_id[0] && t - a.power_requested_ms >= RV_POWER_REQUEST_TIMEOUT_MS)
            tb_receiver_cancel_pending_power(&a, 1);

        if (t - a.last_ip_check_ms >= 1000) {
            char refreshed_tb_ip[64] = {0};
            char refreshed_net_ip[64] = {0};
            a.last_ip_check_ms = t;
            (void)tb_net_get_tb_ip(refreshed_tb_ip, sizeof(refreshed_tb_ip));
            (void)tb_net_get_lan_ip(refreshed_net_ip, sizeof(refreshed_net_ip));

            const int have_refreshed_ip = refreshed_tb_ip[0] || refreshed_net_ip[0];
            const char *preferred_ip = refreshed_tb_ip[0] ? refreshed_tb_ip
                                     : (refreshed_net_ip[0] ? refreshed_net_ip
                                     : tb_i18n_get("receiver.network.not_detected"));
            if (strcmp(a.tb_ip_text, refreshed_tb_ip) != 0 ||
                strcmp(a.net_ip_text, refreshed_net_ip) != 0 ||
                strcmp(a.ip_text, preferred_ip) != 0) {
                snprintf(a.tb_ip_text, sizeof(a.tb_ip_text), "%s", refreshed_tb_ip);
                snprintf(a.net_ip_text, sizeof(a.net_ip_text), "%s", refreshed_net_ip);
                snprintf(a.ip_text, sizeof(a.ip_text), "%s", preferred_ip);
                build_display_host(a.display_host, sizeof(a.display_host), preferred_ip, have_refreshed_ip);
                if (refreshed_tb_ip[0] != '\0') {
                    fprintf(stderr, "[main] Thunderbolt Bridge IP = %s\n", refreshed_tb_ip);
                }
                if (refreshed_net_ip[0] != '\0') {
                    fprintf(stderr, "[main] Local network IP = %s\n", refreshed_net_ip);
                }
                bonjour_update(&a, TB_PORT);
            }
        }

        if (a.client_fd >= 0 && (a.close_requested ||
            tb_control_flush(&a.control_send, a.client_fd, t) != 0)) close_client(&a);

        /* Accept new client */
        if (a.client_fd < 0) {
            int c = tb_net_accept(a.server_fd);
            if (c >= 0) {
                a.client_fd = c;
                a.have_video_frame = 0;
                a.session_active = 0;
                a.settings_nonce_valid = 0;
                a.session_authenticated = 0;
                a.auth_started_ms = t;
                a.last_sender_settings_revision = 0;
                a.last_recv_ms = t;
                fprintf(stderr, "[main] client connected\n");
                tb_parser_free(&a.parser);
                tb_parser_init(&a.parser, on_packet, &a);
                tb_receiver_refresh_input_capture(&a);
                send_settings_challenge(&a);
                if (!a.settings_nonce_valid) a.close_requested = 1;
            }
        } else {
            int drain_result = drain_socket(&a);
            if (drain_result < 0) {
                close_client(&a);
            } else {
                socket_activity = drain_result;
                if (drain_result > 0) a.last_recv_ms = t;
                if (a.close_requested ||
                    (!a.session_authenticated && t - a.auth_started_ms >= TB_SENDER_IDLE_TIMEOUT_MS)) {
                    close_client(&a);
                } else if (t - a.last_recv_ms >= TB_SENDER_IDLE_TIMEOUT_MS) {
                    /* The sender streams frames continuously and heartbeats
                     * every 2s. Total silence means it died without a FIN
                     * (crash, pulled cable, force sleep). Without this reap,
                     * the dead fd is held forever and — because the receiver
                     * is single-client — every future connect is locked out
                     * until the app is restarted. */
                    fprintf(stderr, "[main] no data from sender for %llu ms; closing stale session\n",
                            (unsigned long long)(t - a.last_recv_ms));
                    close_client(&a);
                }
            }
        }

        /* Decode/present can advance the clock. Never subtract a fresh frame
         * timestamp from the pre-drain time (uint64_t would underflow). */
        t = now_ms();
        if (a.have_video_frame && t - a.last_video_frame_ms >= 2000) {
            /* A live heartbeat without video is not a usable primary input. */
            a.have_video_frame = 0;
            rv_display_signal_init(&a.display_health);
            tb_disp_set_recovery_pending(a.disp, 1);
            SDL_EnableScreenSaver();
            if (a.audio_device != 0) SDL_PauseAudioDevice(a.audio_device, 1);
            tb_disp_set_connection_state(a.disp, 0);
            tb_receiver_release_display_assertion(&a);
        }

        if (tb_stream_stats_sample(&a.stream_stats, t, a.received_bytes,
            a.received_video_frames, a.presented_batches, a.frames) && a.debug_visible)
            tb_receiver_refresh_debug_text(&a);

        /* Rescue owns power arbitration; a stale heartbeat expires if this
         * process crashes, so Network Receiver is never a Rescue dependency. */
        tb_receiver_publish_display_state(&a, t);

        if (a.session_authenticated && t - a.last_brightness_poll_ms >= 1000) {
            a.last_brightness_poll_ms = t;
            send_brightness_state(&a, -1, NAN, "");
            int audio_bytes = 0;
            if (a.audio_device) { SDL_LockAudioDevice(a.audio_device); audio_bytes = a.audio_buf_size; SDL_UnlockAudioDevice(a.audio_device); }
            char metrics[320];
            snprintf(metrics, sizeof(metrics), "{\"hardwareDecode\":%d,\"raw\":%s,\"received\":%llu,\"uploaded\":%llu,\"submitted\":%llu,\"sinceSubmitMs\":%llu,\"audioBytes\":%d,\"decodeErrors\":%llu}",
                tb_dec_observed_hardware(a.dec), a.raw_video_active ? "true" : "false",
                (unsigned long long)a.received_video_frames, (unsigned long long)a.frames,
                (unsigned long long)a.presented_batches, (unsigned long long)(a.last_video_frame_ms ? t - a.last_video_frame_ms : 0),
                audio_bytes, (unsigned long long)a.decode_errors);
            (void)send_settings_json(&a, TB_PKT_RECEIVER_METRICS, metrics);
        }
        if (t - a.last_permissions_poll_ms >= 250) {
            a.last_permissions_poll_ms = t;
            tb_receiver_poll_permissions(&a);
        }

        if (a.client_fd < 0 || !a.session_active) {
            /* No client, or a connection that hasn't started a real streaming
             * session (e.g. a transient UI-language push during discovery):
             * stay on the windowed waiting screen, don't flash fullscreen. */
            tb_disp_render_status(a.disp, a.display_host, a.status_text, a.sender_text, a.panel_text, a.mode_text, a.language_text, a.permissions_text);
        } else if (!a.have_video_frame) {
            tb_disp_render_connecting(a.disp);
        }

        if (!a.manual_rescue && strcmp(a.input_control_mode, "receiverMaster") == 0 && a.client_fd >= 0) {
            if (t - a.last_clipboard_poll_ms >= 100) {
                a.last_clipboard_poll_ms = t;
                tb_receiver_send_clipboard_if_changed(&a);
            }
            struct tb_input_event input_event;
            while (!a.close_requested && tb_disp_pop_input_event(a.disp, &input_event)) {
                switch (input_event.kind) {
                case TB_INPUT_EVENT_MOVE:
                    tb_receiver_send_input_event(&a, "move", 1, input_event.dx, 1, input_event.dy, 0, 0, 0, 0, 0, 0);
                    break;
                case TB_INPUT_EVENT_LEFT_DRAG:
                    tb_receiver_send_input_event(&a, "leftDrag", 1, input_event.dx, 1, input_event.dy, 0, 0, 0, 0, 0, 0);
                    break;
                case TB_INPUT_EVENT_RIGHT_DRAG:
                    tb_receiver_send_input_event(&a, "rightDrag", 1, input_event.dx, 1, input_event.dy, 0, 0, 0, 0, 0, 0);
                    break;
                case TB_INPUT_EVENT_OTHER_DRAG:
                    tb_receiver_send_input_event(&a, "otherDrag", 1, input_event.dx, 1, input_event.dy, 0, 0, 0, 0, 0, 0);
                    break;
                case TB_INPUT_EVENT_SCROLL:
                    tb_receiver_send_input_event(&a, "scroll", 0, 0, 0, 0, 1, input_event.scroll_x, 1, input_event.scroll_y, 0, 0);
                    break;
                case TB_INPUT_EVENT_LEFT_DOWN:
                    tb_receiver_send_input_event(&a, "leftDown", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
                    break;
                case TB_INPUT_EVENT_LEFT_UP:
                    tb_receiver_send_input_event(&a, "leftUp", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
                    break;
                case TB_INPUT_EVENT_RIGHT_DOWN:
                    tb_receiver_send_input_event(&a, "rightDown", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
                    break;
                case TB_INPUT_EVENT_RIGHT_UP:
                    tb_receiver_send_input_event(&a, "rightUp", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
                    break;
                case TB_INPUT_EVENT_OTHER_DOWN:
                    tb_receiver_send_input_event(&a, "otherDown", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
                    break;
                case TB_INPUT_EVENT_OTHER_UP:
                    tb_receiver_send_input_event(&a, "otherUp", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
                    break;
                case TB_INPUT_EVENT_KEY_DOWN:
                    tb_receiver_send_input_event(&a, "keyDown", 0, 0, 0, 0, 0, 0, 0, 0, 1, input_event.key_code);
                    break;
                case TB_INPUT_EVENT_KEY_UP:
                    tb_receiver_send_input_event(&a, "keyUp", 0, 0, 0, 0, 0, 0, 0, 0, 1, input_event.key_code);
                    break;
                case TB_INPUT_EVENT_SWITCH_PREV_TARGET:
                    tb_receiver_send_target_switch(&a, -1);
                    break;
                case TB_INPUT_EVENT_SWITCH_NEXT_TARGET:
                    tb_receiver_send_target_switch(&a, 1);
                    break;
                case TB_INPUT_EVENT_SWITCH_PREV_SPACE:
                    tb_receiver_send_space_switch(&a, -1);
                    break;
                case TB_INPUT_EVENT_SWITCH_NEXT_SPACE:
                    tb_receiver_send_space_switch(&a, 1);
                    break;
                case TB_INPUT_EVENT_DEACTIVATE_CONTROL:
                    tb_receiver_send_deactivate_control(&a);
                    break;
                case TB_INPUT_EVENT_NONE:
                default:
                    break;
                }
            }
        }

        if (a.close_requested) close_client(&a);

        /* FPS log */
        if (t - a.last_fps_tick_ms >= 1000) {
            uint64_t df = a.frames - a.last_fps_count;
            a.last_fps_count   = a.frames;
            a.last_fps_tick_ms = t;
            if (df > 0) fprintf(stderr, "[main] %llu fps\n", (unsigned long long)df);
        }

        /* Yield when idle or when a nonblocking active socket had no data,
         * otherwise the receiver can busy-spin between incoming frame packets. */
        if (a.client_fd < 0 || !a.have_video_frame || socket_activity == 0) {
            SDL_Delay(1);
        }
    }

    tb_receiver_cancel_pending_power(&a, 0);
    CFNotificationCenterRemoveEveryObserver(power_center, &a);
    tb_control_clear(&a.control_send);
    if (a.client_fd >= 0) close(a.client_fd);
    tb_receiver_release_display_assertion(&a);
    tb_receiver_stop_input_tap(&a);
    if (a.server_fd >= 0) close(a.server_fd);
    bonjour_deinit(&a);
    tb_parser_free(&a.parser);
    tb_dec_destroy(a.dec);
    if (a.audio_device != 0) {
        SDL_CloseAudioDevice(a.audio_device);
    }
    tb_disp_destroy(a.disp);
    fprintf(stderr, "[main] bye\n");
    return 0;
}
