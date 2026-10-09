/* Exercise the real parser -> on_packet -> authentication path without SDL
 * initialization, windows, capture devices or input injection. */
#include <stdlib.h>
#include <string.h>
#include <CoreAudio/CoreAudio.h>
static char *test_settings_root;
static char *tb_test_getenv(const char *key) {
    return test_settings_root && strcmp(key, "HOME") == 0 ? test_settings_root : getenv(key);
}
static OSStatus tb_test_audio_get(AudioObjectID id, const AudioObjectPropertyAddress *addr,
    UInt32 qualifierSize, const void *qualifier, UInt32 *size, void *data) {
    (void)id; (void)addr; (void)qualifierSize; (void)qualifier; (void)size; (void)data;
    return kAudioHardwareUnspecifiedError;
}
#define getenv tb_test_getenv
#define AudioObjectGetPropertyData tb_test_audio_get
void tb_test_post_notification(CFNotificationCenterRef center, CFNotificationName name,
    const void *object, CFDictionaryRef info, Boolean deliver);
#define CFNotificationCenterPostNotification tb_test_post_notification
#define tb_disp_set_brightness tb_test_set_brightness
#define tb_disp_read_brightness tb_test_read_brightness
#define SDL_EnableScreenSaver tb_test_enable_screensaver
#define SDL_DisableScreenSaver tb_test_disable_screensaver
#define IOPMAssertionCreateWithName tb_test_assertion_create
#define IOPMAssertionDeclareUserActivity tb_test_user_activity
#define IOPMAssertionRelease tb_test_assertion_release
#define main tb_receiver_unused_main
#include "../src/main.c"
#undef main
#include <assert.h>
#include <sys/socket.h>

static unsigned power_requests, display_signal, brightness_calls;
static unsigned display_assertions, display_wakes;
void tb_test_enable_screensaver(void) {}
void tb_test_disable_screensaver(void) {}
IOReturn tb_test_assertion_create(CFStringRef type, IOPMAssertionLevel level, CFStringRef name, IOPMAssertionID *id) {
    (void)type; (void)level; (void)name; *id = ++display_assertions; return kIOReturnSuccess;
}
IOReturn tb_test_user_activity(CFStringRef name, IOPMUserActiveType type, IOPMAssertionID *id) {
    (void)name; (void)type; *id = ++display_wakes; return kIOReturnSuccess;
}
IOReturn tb_test_assertion_release(IOPMAssertionID id) { (void)id; return kIOReturnSuccess; }
static double fake_brightness = 0.4;
int tb_test_set_brightness(struct tb_display *d, double level, double *actual) {
    (void)d; brightness_calls++; fake_brightness = level; *actual = level; return 0;
}
int tb_test_read_brightness(struct tb_display *d, double *actual) { (void)d; *actual = fake_brightness; return 0; }
static void drain_brightness_state(int fd, int accepted) {
    unsigned char header[5], payload[512];
    assert(read(fd, header, 5) == 5 && header[4] == TB_PKT_BRIGHTNESS_STATE);
    size_t size = ((size_t)header[0]<<24) | ((size_t)header[1]<<16) | ((size_t)header[2]<<8) | header[3];
    assert(size > 1 && size < sizeof(payload));
    assert(read(fd, payload, size - 1) == (ssize_t)size - 1); payload[size-1] = 0;
    assert(strstr((char *)payload, accepted ? "\"accepted\":true" : "\"accepted\":false"));
}
static uint64_t notified_frame_ms;
static int notified_display_on;
void tb_test_post_notification(CFNotificationCenterRef center, CFNotificationName name,
    const void *object, CFDictionaryRef info, Boolean deliver) {
    (void)center; (void)object; (void)info; (void)deliver;
    if (CFEqual(name, CFSTR(RV_POWER_REQUEST_NOTIFICATION))) {
        power_requests++;
        notified_display_on = CFBooleanGetValue(CFDictionaryGetValue(info, CFSTR("displayOn")));
    }
    if (CFEqual(name, CFSTR("re.voyage.display.network-inactive"))) display_signal = 0;
    if (CFEqual(name, CFSTR("re.voyage.display.network-active"))) display_signal = 1;
    if (CFEqual(name, CFSTR("re.voyage.display.network-recovering"))) display_signal = 2;
    if (info && CFDictionaryContainsKey(info, CFSTR("frameMs"))) {
        int64_t time;
        assert(CFNumberGetValue(CFDictionaryGetValue(info, CFSTR("frameMs")), kCFNumberSInt64Type, &time));
        notified_frame_ms = (uint64_t)time;
    }
}

static void reply_power(struct app *a, int accepted) {
    CFStringRef id = CFStringCreateWithCString(NULL, a->power_request_id, kCFStringEncodingUTF8);
    const void *keys[] = {CFSTR("requestID"), CFSTR("displayOn"), CFSTR("accepted")};
    const void *values[] = {id, a->power_effective_on ? kCFBooleanTrue : kCFBooleanFalse,
        accepted ? kCFBooleanTrue : kCFBooleanFalse};
    CFDictionaryRef info = CFDictionaryCreate(NULL, keys, values, 3,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    tb_receiver_power_notification(NULL, a, CFSTR(RV_POWER_RESULT_NOTIFICATION), NULL, info);
    CFRelease(info); CFRelease(id);
}

static void expect_power_ack(int fd, uint8_t type, int on, int accepted, uint64_t id) {
    uint8_t ack[15];
    assert(read(fd, ack, sizeof(ack)) == sizeof(ack));
    assert(ack[4] == type && ack[5] == on && ack[6] == accepted && rv_display_power_read_id(ack + 7) == id);
}

int main(void) {
    char text[8];
    extract_json_string_field(NULL, 0, "\"text\"", text, sizeof(text));
    assert(text[0] == '\0');
    int value = 42;
    const char *too_large = "{\"x\":2147483648}";
    assert(!extract_json_int_field((const uint8_t *)too_large, strlen(too_large), "\"x\"", &value));
    assert(value == 42);
    int sockets[2];
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
    struct app app = {0};
    test_settings_root = "/nonexistent-revoyage-no-pairing-fixture";
    tb_receiver_load_pairing_key(&app);
    assert(!rv_pairing_required());
    assert(strcmp(app.pairing_key, rv_local_wire_key()) == 0);
    test_settings_root = NULL;
    app.client_fd = sockets[0];
    app.settings_nonce_valid = 1;
    memset(app.pairing_key, 'a', 64);
    for (int i = 0; i < 32; i++) app.settings_nonce[i] = (uint8_t)i;
    tb_parser_init(&app.parser, on_packet, &app);

    on_packet(TB_PKT_INPUT_EVENT, (const uint8_t *)"{}", 2, &app);
    assert(app.close_requested && !app.session_authenticated);
    app.close_requested = 0;
    on_packet(TB_PKT_CLIPBOARD, (const uint8_t *)"{}", 2, &app);
    assert(app.close_requested && !app.session_authenticated);
    app.close_requested = 0;

    uint8_t off[] = {0, 1, 2, 3, 4, 5, 6, 7, 8};
    on_packet(TB_PKT_DISPLAY_POWER, off, sizeof(off), &app);
    assert(app.close_requested && !app.manual_display_off && power_requests == 0);
    app.close_requested = 0;
    on_packet(TB_PKT_SENDER_POWER, off, sizeof(off), &app);
    assert(app.close_requested && !app.sender_sleeping && power_requests == 0);
    app.close_requested = 0;

    uint8_t auth[37] = {0, 0, 0, 33, TB_PKT_SESSION_AUTH};
    tb_session_auth_digest(app.settings_nonce, app.pairing_key, 0, auth + 5);
    auth[5] ^= 1;
    assert(tb_parser_feed(&app.parser, auth, sizeof(auth)) == 0);
    assert(app.close_requested && !app.session_authenticated);
    app.close_requested = 0;
    auth[5] ^= 1;
    for (size_t i = 0; i < sizeof(auth); i++) {
        assert(tb_parser_feed(&app.parser, auth + i, 1) == 0);
        assert(app.session_authenticated == (i == sizeof(auth) - 1));
    }
    assert(!app.close_requested);
    uint8_t response[37], expected[32];
    assert(read(sockets[1], response, sizeof(response)) == sizeof(response));
    assert(response[3] == 33 && response[4] == TB_PKT_SESSION_AUTH_ACK);
    tb_session_auth_digest(app.settings_nonce, app.pairing_key, 1, expected);
    assert(memcmp(expected, response + 5, 32) == 0);
    const char *bad_brightness[] = {"{}", "{\"level\":\"0.5\"}", "{\"level\":true}", "{\"level\":null}", "{\"level\":-0.1}", "{\"level\":1.1}", "{\"level\":NaN}", "{\"level\":0.5} trailing", "[]"};
    for (size_t i = 0; i < sizeof(bad_brightness)/sizeof(bad_brightness[0]); ++i) {
        on_packet(TB_PKT_BRIGHTNESS, (const uint8_t *)bad_brightness[i], strlen(bad_brightness[i]), &app);
        assert(brightness_calls == 0 && fake_brightness == 0.4);
        drain_brightness_state(sockets[1], 0);
    }
    const char *good_brightness = "{\"level\":0.5}";
    on_packet(TB_PKT_BRIGHTNESS, (const uint8_t *)good_brightness, strlen(good_brightness), &app);
    assert(brightness_calls == 1 && fake_brightness == 0.5);
    drain_brightness_state(sockets[1], 1);
    char test_directory[] = "/tmp/revoyage-settings-regression.XXXXXX";
    test_settings_root = mkdtemp(test_directory); assert(test_settings_root);
    for (unsigned revision = 1; revision <= 2; ++revision) {
        app.brightness_commands_only = revision == 1;
        double level = revision == 1 ? 0.9 : 0.8;
        uint8_t message[56] = {0}, digest[32]; char hex[65], body[512];
        memcpy(message, app.settings_nonce, 32); write_be32(message + 32, 1); write_be64(message + 36, revision);
        uint16_t quantized = settings_level_quantized(level);
        message[44] = quantized >> 8; message[45] = quantized;
        message[46] = 600 >> 8; message[47] = 600 & 255; memcpy(message + 48, "en", 2);
        CCHmac(kCCHmacAlgSHA256, app.pairing_key, strlen(app.pairing_key), message, sizeof(message), digest);
        for (int i = 0; i < 32; ++i) sprintf(hex + i * 2, "%02x", digest[i]);
        int length = snprintf(body, sizeof(body), "{\"schemaVersion\":1,\"revision\":%u,\"brightness\":%.1f,\"volume\":0.6,\"language\":\"en\",\"hmac\":\"%s\"}", revision, level, hex);
        on_packet(TB_PKT_SETTINGS_SYNC, (const uint8_t *)body, length, &app);
        assert(brightness_calls == revision && app.settings_revision == revision);
        if (revision == 2) drain_brightness_state(sockets[1], 1); // legacy setting still applies
        unsigned char header[5], ack_body[256]; assert(read(sockets[1], header, 5) == 5 && header[4] == TB_PKT_SETTINGS_ACK);
        size_t count = ((size_t)header[0]<<24)|((size_t)header[1]<<16)|((size_t)header[2]<<8)|header[3];
        assert(count > 1 && count < sizeof(ack_body));
        assert(read(sockets[1], ack_body, count-1) == (ssize_t)count-1); ack_body[count-1] = 0;
        assert(strstr((char *)ack_body, "\"accepted\":true"));
    }
    char settings_path[PATH_MAX]; tb_receiver_settings_path(settings_path, sizeof(settings_path)); assert(unlink(settings_path) == 0);
    char folder[PATH_MAX]; snprintf(folder, sizeof(folder), "%s/Library/Application Support/TargetBridge Receiver", test_settings_root); assert(rmdir(folder) == 0);
    snprintf(folder, sizeof(folder), "%s/Library/Application Support", test_settings_root); assert(rmdir(folder) == 0);
    snprintf(folder, sizeof(folder), "%s/Library", test_settings_root); assert(rmdir(folder) == 0);
    assert(rmdir(test_settings_root) == 0); test_settings_root = NULL;
    uint8_t invalid_power[] = {2, 1, 2, 3, 4, 5, 6, 7, 8};
    on_packet(TB_PKT_DISPLAY_POWER, invalid_power, sizeof(invalid_power), &app);
    assert(app.close_requested && power_requests == 0);
    app.close_requested = 0;
    on_packet(TB_PKT_DISPLAY_POWER, off, 0, &app);
    assert(app.close_requested && power_requests == 0);
    app.close_requested = 0;
    on_packet(TB_PKT_DISPLAY_POWER, off, sizeof(off), &app);
    assert(app.manual_display_off && app.power_request_id[0] && power_requests == 1);
    /* The notification transport is stubbed: no real service/display is touched. */
    CFStringRef request_id = CFStringCreateWithCString(NULL, app.power_request_id, kCFStringEncodingUTF8);
    const void *keys[] = {CFSTR("requestID"), CFSTR("displayOn"), CFSTR("accepted")};
    const void *values[] = {request_id, kCFBooleanFalse, kCFBooleanTrue};
    CFDictionaryRef info = CFDictionaryCreate(NULL, keys, values, 3,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    tb_receiver_power_notification(NULL, &app, CFSTR(RV_POWER_RESULT_NOTIFICATION), NULL, info);
    assert(!app.power_request_id[0] && app.manual_display_off);
    uint8_t ack[15];
    assert(read(sockets[1], ack, sizeof(ack)) == sizeof(ack));
    assert(ack[4] == TB_PKT_DISPLAY_POWER_ACK && ack[5] == 0 && ack[6] == 1 && rv_display_power_read_id(ack + 7) == 0x0102030405060708ULL);
    CFRelease(info); CFRelease(request_id);
    tb_receiver_power_notification(NULL, &app, CFSTR(RV_RESCUE_READY_NOTIFICATION), NULL, NULL);
    assert(!app.manual_display_off); /* Rescue restart chooses awake. */
    /* Unrelated ACKs cannot change the current request; expiration restores
     * awake intent and emits a correlated negative ACK plus a wake request. */
    on_packet(TB_PKT_DISPLAY_POWER, off, sizeof(off), &app);
    const void *bad_values[] = {CFSTR("unrelated"), kCFBooleanFalse, kCFBooleanTrue};
    info = CFDictionaryCreate(NULL, keys, bad_values, 3,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    tb_receiver_power_notification(NULL, &app, CFSTR(RV_POWER_RESULT_NOTIFICATION), NULL, info);
    assert(app.power_request_id[0] && app.manual_display_off);
    CFRelease(info);
    request_id = CFStringCreateWithCString(NULL, app.power_request_id, kCFStringEncodingUTF8);
    const void *expired_values[] = {request_id, kCFBooleanFalse, kCFBooleanTrue};
    info = CFDictionaryCreate(NULL, keys, expired_values, 3,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    app.power_requested_ms = now_ms() - RV_POWER_REQUEST_TIMEOUT_MS;
    tb_receiver_power_notification(NULL, &app, CFSTR(RV_POWER_RESULT_NOTIFICATION), NULL, info);
    assert(!app.power_request_id[0] && !app.manual_display_off);
    assert(read(sockets[1], ack, sizeof(ack)) == sizeof(ack));
    assert(ack[6] == 0 && rv_display_power_read_id(ack + 7) == 0x0102030405060708ULL);
    CFRelease(info); CFRelease(request_id);
    /* Sender sleep must retain the session/process, survive socket loss, and
     * not allow trailing video to wake the LCD. Power APIs are all stubs. */
    uint8_t sleep[] = {0, 0, 0, 0, 0, 0, 0, 0, 2};
    uint8_t wake[] = {1, 0, 0, 0, 0, 0, 0, 0, 3};
    unsigned before = power_requests;
    on_packet(TB_PKT_SENDER_POWER, invalid_power, sizeof(invalid_power), &app);
    assert(app.close_requested && !app.sender_sleeping && power_requests == before);
    app.close_requested = 0;
    on_packet(TB_PKT_SENDER_POWER, sleep, sizeof(sleep), &app);
    assert(app.sender_sleeping && !app.manual_display_off && app.session_authenticated);
    assert(app.client_fd == sockets[0] && !app.close_requested && notified_display_on == 0);
    unsigned wake_count = display_wakes, assertion_count = display_assertions;
    note_presented_video_frame(&app, 1920, 1080);
    assert(display_wakes == wake_count && display_assertions == assertion_count);
    /* Simulate transport closure before the local operation completes. */
    test_settings_root = "/nonexistent-revoyage-sleep-fixture";
    close_client(&app);
    test_settings_root = NULL;
    assert(app.sender_sleeping && app.power_request_id[0]);
    reply_power(&app, 1);
    assert(app.sender_sleeping && !app.power_request_id[0]);
    close(sockets[1]);
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
    app.client_fd = sockets[0]; app.session_authenticated = 1;
    on_packet(TB_PKT_SENDER_POWER, wake, sizeof(wake), &app);
    assert(!app.sender_sleeping && notified_display_on == 1);
    reply_power(&app, 1);
    expect_power_ack(sockets[1], TB_PKT_SENDER_POWER_ACK, 1, 1, 3);

    /* Logical awake does not prove the physical display woke. Retried awake
     * commands must reach Rescue, then wait for its correlated result. */
    before = power_requests;
    on_packet(TB_PKT_SENDER_POWER, wake, sizeof(wake), &app);
    assert(power_requests == before + 1 && app.power_request_id[0] && notified_display_on == 1);
    reply_power(&app, 1);
    expect_power_ack(sockets[1], TB_PKT_SENDER_POWER_ACK, 1, 1, 3);

    /* A wake supersedes pending off; its late result must be ignored. */
    on_packet(TB_PKT_SENDER_POWER, sleep, sizeof(sleep), &app);
    char stale_id[129]; strcpy(stale_id, app.power_request_id);
    on_packet(TB_PKT_SENDER_POWER, wake, sizeof(wake), &app);
    expect_power_ack(sockets[1], TB_PKT_SENDER_POWER_ACK, 0, 0, 2);
    assert(!app.sender_sleeping && notified_display_on == 1);
    request_id = CFStringCreateWithCString(NULL, stale_id, kCFStringEncodingUTF8);
    const void *stale_values[] = {request_id, kCFBooleanFalse, kCFBooleanTrue};
    info = CFDictionaryCreate(NULL, keys, stale_values, 3, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    tb_receiver_power_notification(NULL, &app, CFSTR(RV_POWER_RESULT_NOTIFICATION), NULL, info);
    assert(!app.sender_sleeping && app.power_request_id[0]);
    CFRelease(info); CFRelease(request_id);
    reply_power(&app, 1);
    expect_power_ack(sockets[1], TB_PKT_SENDER_POWER_ACK, 1, 1, 3);

    /* Manual off remains authoritative, including an in-flight manual off. */
    on_packet(TB_PKT_DISPLAY_POWER, off, sizeof(off), &app);
    before = power_requests;
    on_packet(TB_PKT_SENDER_POWER, sleep, sizeof(sleep), &app);
    assert(app.power_has_waiter && app.power_waiter_id == 2);
    on_packet(TB_PKT_SENDER_POWER, wake, sizeof(wake), &app);
    expect_power_ack(sockets[1], TB_PKT_SENDER_POWER_ACK, 0, 0, 2);
    assert(app.manual_display_off && !app.sender_sleeping && power_requests == before);
    reply_power(&app, 1);
    expect_power_ack(sockets[1], TB_PKT_DISPLAY_POWER_ACK, 0, 1, 0x0102030405060708ULL);
    expect_power_ack(sockets[1], TB_PKT_SENDER_POWER_ACK, 1, 1, 3);
    tb_receiver_set_manual_display_off(&app, 0);
    app.have_video_frame = 0;
    on_packet(TB_PKT_SENDER_POWER, sleep, sizeof(sleep), &app);
    reply_power(&app, 0);
    expect_power_ack(sockets[1], TB_PKT_SENDER_POWER_ACK, 0, 0, 2);
    assert(!app.sender_sleeping && notified_display_on == 1);

    app.have_video_frame = 1;
    app.last_video_frame_ms = 1000;
    rv_display_signal_init(&app.display_health);
    tb_receiver_publish_display_state(&app, 1000);
    assert(display_signal == 2 && notified_frame_ms == 1000); /* Recovering stays behind HDMI. */
    app.display_health.rescue_locked = 0;
    app.last_video_frame_ms = 2000;
    tb_receiver_publish_display_state(&app, 2000);
    assert(display_signal == 1 && notified_frame_ms == 2000);
    tb_receiver_publish_display_state(&app, 4000);
    assert(display_signal == 0); /* Heartbeats cannot keep a stopped frame active. */
    app.have_video_frame = 0;
    assert(tb_parser_feed(&app.parser, auth, sizeof(auth)) == 0);
    assert(app.close_requested); /* A duplicate proof cannot reopen the session. */
    tb_parser_free(&app.parser);
    close(sockets[0]);
    close(sockets[1]);
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
    memset(&app, 0, sizeof(app)); app.client_fd = sockets[0]; app.settings_nonce_valid = 1;
    memset(app.pairing_key, 'a', 64);
    strcpy(app.receiver_id, "12345678-1234-4234-8234-123456789abc");
    uint8_t auth_v2[69] = {0, 0, 0, 65, TB_PKT_SESSION_AUTH};
    for (int i = 0; i < 32; i++) { app.settings_nonce[i] = i; auth_v2[i + 5] = i + 32; }
    tb_session_auth_digest_v2(app.settings_nonce, auth_v2 + 5, app.pairing_key, app.receiver_id, 0, auth_v2 + 37);
    tb_parser_init(&app.parser, on_packet, &app);
    auth_v2[5] ^= 1; assert(tb_parser_feed(&app.parser, auth_v2, sizeof(auth_v2)) == 0);
    assert(app.close_requested && !app.session_authenticated);
    app.close_requested = 0; auth_v2[5] ^= 1;
    for (size_t i = 0; i < sizeof(auth_v2); i++) {
        assert(tb_parser_feed(&app.parser, auth_v2 + i, 1) == 0);
        assert(app.session_authenticated == (i == sizeof(auth_v2) - 1));
    }
    assert(read(sockets[1], response, sizeof(response)) == sizeof(response));
    tb_session_auth_digest_v2(app.settings_nonce, auth_v2 + 5, app.pairing_key, app.receiver_id, 1, expected);
    assert(memcmp(expected, response + 5, 32) == 0);
    tb_parser_free(&app.parser); close(sockets[0]); close(sockets[1]);
    /* Local controls keep the listener alive across teardown and allow a new
     * session without restarting the process. No window/power API is invoked. */
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
    memset(&app, 0, sizeof(app));
    app.server_fd = tb_net_listen(0);
    assert(app.server_fd >= 0);
    app.client_fd = sockets[0]; app.session_authenticated = 1;
    app.have_video_frame = 1; app.last_video_frame_ms = now_ms();
    app.display_health.rescue_locked = 0;
    strcpy(app.input_control_mode, "off");
    tb_receiver_apply_local_actions(&app, TB_DISP_ACTION_TOGGLE_DEBUG | TB_DISP_ACTION_TOGGLE_RESCUE);
    assert(app.debug_visible && app.manual_rescue && app.client_fd == sockets[0] && !app.close_requested);
    assert(display_signal == 0);
    note_presented_video_frame(&app, 1920, 1080);
    assert(app.manual_rescue && app.session_authenticated); /* New frames cannot cancel R. */
    tb_receiver_control_notification(NULL, &app, CFSTR(RV_RECEIVER_RESCUE_TOGGLE_NOTIFICATION), NULL, NULL);
    assert(app.pending_local_actions == TB_DISP_ACTION_TOGGLE_RESCUE);
    tb_receiver_apply_local_actions(&app, app.pending_local_actions);
    app.pending_local_actions = 0;
    assert(!app.manual_rescue && app.debug_visible && app.client_fd == sockets[0]);
    tb_receiver_apply_local_actions(&app, TB_DISP_ACTION_TOGGLE_DEBUG);
    assert(!app.debug_visible);
    tb_receiver_apply_local_actions(&app, TB_DISP_ACTION_TOGGLE_RESCUE);
    on_packet(TB_PKT_TEARDOWN, (const uint8_t *)"{}", 2, &app);
    assert(app.close_requested);
    test_settings_root = "/nonexistent-revoyage-debug-fixture";
    close_client(&app);
    test_settings_root = NULL;
    assert(app.client_fd == -1 && !app.close_requested && !app.session_active && app.manual_rescue);
    assert(fcntl(app.server_fd, F_GETFD) >= 0 && !g_term);
    close(sockets[1]);
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) == 0);
    app.client_fd = sockets[0]; app.session_authenticated = 1;
    note_presented_video_frame(&app, 1920, 1080);
    assert(app.have_video_frame && app.manual_rescue && !app.close_requested);
    tb_receiver_apply_local_actions(&app, TB_DISP_ACTION_TOGGLE_RESCUE);
    assert(!app.manual_rescue && app.have_video_frame && app.client_fd == sockets[0]);
    tb_parser_free(&app.parser); close(sockets[0]); close(sockets[1]); close(app.server_fd);
    puts("session gate: auth, sleep/wake, manual Rescue/debug, teardown/reconnect and restart safety passed (power calls stubbed)");
    return 0;
}
