/* display.h — SDL2 fullscreen window + NV12 GPU texture renderer. */

#ifndef TB_DISPLAY_H
#define TB_DISPLAY_H

#include <stdint.h>
#include <stddef.h>

struct tb_display;

struct tb_display_info {
    uint32_t active_w;
    uint32_t active_h;
    uint32_t window_w;
    uint32_t window_h;
    uint32_t drawable_w;
    uint32_t drawable_h;
    char     name[128];
    uint32_t mode_w, mode_h;
    double refresh_rate, width_mm, height_mm;
    int hi_dpi, native_mode_known, built_in;
    char identity[96];
};

enum tb_display_action {
    TB_DISP_ACTION_NONE = 0,
    TB_DISP_ACTION_QUIT = 1 << 0,
    TB_DISP_ACTION_CYCLE_LANGUAGE = 1 << 1,
    TB_DISP_ACTION_TOGGLE_DEBUG = 1 << 2,
    TB_DISP_ACTION_TOGGLE_RESCUE = 1 << 3
};

enum tb_input_event_kind {
    TB_INPUT_EVENT_NONE = 0,
    TB_INPUT_EVENT_MOVE,
    TB_INPUT_EVENT_LEFT_DRAG,
    TB_INPUT_EVENT_RIGHT_DRAG,
    TB_INPUT_EVENT_OTHER_DRAG,
    TB_INPUT_EVENT_SCROLL,
    TB_INPUT_EVENT_LEFT_DOWN,
    TB_INPUT_EVENT_LEFT_UP,
    TB_INPUT_EVENT_RIGHT_DOWN,
    TB_INPUT_EVENT_RIGHT_UP,
    TB_INPUT_EVENT_OTHER_DOWN,
    TB_INPUT_EVENT_OTHER_UP,
    TB_INPUT_EVENT_KEY_DOWN,
    TB_INPUT_EVENT_KEY_UP,
    TB_INPUT_EVENT_SWITCH_PREV_TARGET,
    TB_INPUT_EVENT_SWITCH_NEXT_TARGET,
    TB_INPUT_EVENT_SWITCH_PREV_SPACE,
    TB_INPUT_EVENT_SWITCH_NEXT_SPACE,
    TB_INPUT_EVENT_DEACTIVATE_CONTROL
};

struct tb_input_event {
    enum tb_input_event_kind kind;
    int dx;
    int dy;
    int scroll_x;
    int scroll_y;
    uint16_t key_code;
};

struct tb_display *tb_disp_create(int fullscreen, int appliance);
void               tb_disp_destroy(struct tb_display *d);
/* Appliance mode keeps HDMI visible until authenticated frame recovery is stable. */
void tb_disp_set_recovery_pending(struct tb_display *d, int pending);
void tb_disp_set_rescue_override(struct tb_display *d, int active);
void tb_disp_set_debug_overlay(struct tb_display *d, int visible, const char *line1, const char *line2);
int tb_disp_has_keyboard_focus(struct tb_display *d);

void               tb_disp_set_connection_state(struct tb_display *d, int connected);
void               tb_disp_set_input_capture_active(struct tb_display *d, int active);
void               tb_disp_set_input_intercept_active(struct tb_display *d, int active);

/* Whether the receiver display window is on the active macOS Space. Used to
 * gate receiverMaster global-tap forwarding so input on other receiver Spaces
 * does not leak to the sender. */
int                tb_disp_window_on_active_space(struct tb_display *d);

/* Resize/recreate texture when frame dimensions change. */
int  tb_disp_ensure_texture(struct tb_display *d, int w, int h);

/* Group frames decoded during one nonblocking socket drain. Texture updates
 * still happen for every decoded frame, while only the newest is presented. */
void tb_disp_begin_frame_batch(struct tb_display *d);
/* Returns 1 only after the fresh texture was submitted to SDL presentation. */
int tb_disp_end_frame_batch(struct tb_display *d);

/* Upload NV12 planes and present immediately unless a frame batch is active. */
int tb_disp_render_nv12(struct tb_display *d,
                         const uint8_t *y, int y_stride,
                         const uint8_t *uv, int uv_stride,
                         int w, int h);

/* Update low-latency local cursor overlay in source-frame coordinates. */
void tb_disp_set_cursor(struct tb_display *d,
                        int x, int y,
                        int source_w, int source_h,
                        int visible,
                        int type);

/* Returns 0 only when the selected built-in panel accepts the value and a
 * finite actual value can be read back. Never changes other active displays. */
int tb_disp_set_brightness(struct tb_display *d, double level, double *actual);
int tb_disp_read_brightness(struct tb_display *d, double *actual);

/* Poll input actions while idle/connected. */
unsigned int tb_disp_poll_actions(struct tb_display *d);
int          tb_disp_pop_input_event(struct tb_display *d, struct tb_input_event *out);

/* Query active display/window/drawable information for UI/debug metadata. */
int  tb_disp_get_info(struct tb_display *d, struct tb_display_info *info);

/* Render a simple launcher/status UI before the video stream starts. */
void tb_disp_render_status(struct tb_display *d,
                           const char *ip,
                           const char *status,
                           const char *sender,
                           const char *panel,
                           const char *mode,
                           const char *language,
                           const char *permissions);
void tb_disp_render_connecting(struct tb_display *d);

#endif
