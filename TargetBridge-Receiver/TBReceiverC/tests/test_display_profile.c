/* Real display implementation with all screen/backlight/SDL queries replaced.
 * No window, display configuration or physical brightness changes occur. */
#include <CoreGraphics/CoreGraphics.h>
#include <SDL.h>
#include <dlfcn.h>
#include <assert.h>
#include <math.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <IOKit/graphics/IOGraphicsTypes.h>
struct fake_mode { size_t w, h, lw, lh; uint32_t flags; double hz; };
static struct fake_mode current, native, scaled;
static CGError fake_active(uint32_t count, CGDirectDisplayID *ids, uint32_t *found) {
    assert(count >= 2); ids[0] = 99; ids[1] = 2; *found = 2; return kCGErrorSuccess;
}
static CGDirectDisplayID fake_main(void) { return 99; }
static boolean_t fake_builtin(CGDirectDisplayID id) { return id == 2; }
static CGDisplayModeRef fake_current(CGDirectDisplayID id) { assert(id == 2); return (CGDisplayModeRef)&current; }
static CFArrayRef fake_modes(CGDirectDisplayID id, CFDictionaryRef options) {
    assert(id == 2); (void)options;
    const void *items[] = {&scaled, &native};
    return CFArrayCreate(NULL, items, 2, NULL);
}
static size_t fake_pw(CGDisplayModeRef m) { return ((struct fake_mode *)m)->w; }
static size_t fake_ph(CGDisplayModeRef m) { return ((struct fake_mode *)m)->h; }
static size_t fake_lw(CGDisplayModeRef m) { return ((struct fake_mode *)m)->lw; }
static size_t fake_lh(CGDisplayModeRef m) { return ((struct fake_mode *)m)->lh; }
static double fake_hz(CGDisplayModeRef m) { return ((struct fake_mode *)m)->hz; }
static uint32_t fake_flags(CGDisplayModeRef m) { return ((struct fake_mode *)m)->flags; }
static void fake_release(CGDisplayModeRef m) { (void)m; }
static CGSize fake_mm(CGDirectDisplayID id) { assert(id == 2); return CGSizeMake(477, 268); }
static uint32_t fake_identity(CGDirectDisplayID id) { assert(id == 2); return 123; }
static int fake_index(SDL_Window *w) { (void)w; return 1; }
static const char *fake_name(int index) { assert(index == 1); return "iMac built-in"; }
static void fake_window(SDL_Window *w, int *x, int *y) { (void)w; *x = 980; *y = 620; }
static int drawable_width = 980;
static int fake_drawable(SDL_Renderer *r, int *x, int *y) { (void)r; *x = drawable_width; *y = 1080; return 0; }
static SDL_Event queued_events[16];
static unsigned event_count, event_index, texture_creates, texture_copies;
static int fake_poll(SDL_Event *event) {
    if (event_index == event_count) return 0;
    *event = queued_events[event_index++]; return 1;
}
static void queue_key(Uint32 type, SDL_Scancode code, SDL_Keycode sym, Uint16 mods, Uint8 repeat) {
    assert(event_count < 16);
    SDL_Event *event = &queued_events[event_count++]; memset(event, 0, sizeof(*event));
    event->type = type; event->key.repeat = repeat;
    event->key.keysym.scancode = code; event->key.keysym.sym = sym; event->key.keysym.mod = mods;
}
static SDL_Texture *fake_texture(SDL_Renderer *r, Uint32 format, int access, int w, int h) {
    (void)r; (void)access;
    assert(format == SDL_PIXELFORMAT_ARGB8888 && w == drawable_width && (h == 56 || h == 70));
    texture_creates++; return (SDL_Texture *)72;
}
static int fake_texture_blend(SDL_Texture *texture, SDL_BlendMode mode) { (void)texture; assert(mode == SDL_BLENDMODE_BLEND); return 0; }
static int fake_texture_update(SDL_Texture *texture, const SDL_Rect *rect, const void *pixels, int pitch) {
    (void)texture; assert(!rect && pixels && pitch == drawable_width * 4);
    const unsigned char *data = pixels;
    assert(data[3] > 200); /* Opaque enough to read over video. */
    const char *preview = getenv("TB_DEBUG_PREVIEW_PATH");
    if (preview) {
        FILE *file = fopen(preview, "wb"); assert(file);
        int h = drawable_width >= 1600 ? 70 : 56;
        fprintf(file, "P6\n%d %d\n255\n", drawable_width, h);
        for (int i = 0; i < drawable_width * h; ++i) {
            unsigned char rgb[] = {data[i*4+2], data[i*4+1], data[i*4]};
            assert(fwrite(rgb, 1, 3, file) == 3);
        }
        fclose(file);
    }
    return 0;
}
static int fake_texture_copy(SDL_Renderer *r, SDL_Texture *texture, const SDL_Rect *src, const SDL_Rect *dst) {
    (void)r; (void)texture; assert(!src && dst && dst->x == 0 && dst->y == 0 && dst->w == drawable_width);
    texture_copies++; return 0;
}
static void fake_texture_destroy(SDL_Texture *texture) { assert(texture == (SDL_Texture *)72); }
static int get_calls, set_calls, read_error, set_error;
static float backlight = 0.4f;
static int fake_get(CGDirectDisplayID id, float *value) { assert(id == 2); get_calls++; *value = backlight; return read_error; }
static int fake_set(CGDirectDisplayID id, float value) { assert(id == 2); set_calls++; if (!set_error) backlight = value; return set_error; }
static void *fake_open(const char *path, int flags) { (void)path; (void)flags; return (void *)1; }
static void *fake_symbol(void *lib, const char *name) {
    (void)lib; return strcmp(name, "DisplayServicesSetBrightness") == 0 ? (void *)fake_set : (void *)fake_get;
}
static int fake_close(void *lib) { (void)lib; return 0; }
#define CGGetActiveDisplayList fake_active
#define CGMainDisplayID fake_main
#define CGDisplayIsBuiltin fake_builtin
#define CGDisplayCopyDisplayMode fake_current
#define CGDisplayCopyAllDisplayModes fake_modes
#define CGDisplayModeGetPixelWidth fake_pw
#define CGDisplayModeGetPixelHeight fake_ph
#define CGDisplayModeGetWidth fake_lw
#define CGDisplayModeGetHeight fake_lh
#define CGDisplayModeGetRefreshRate fake_hz
#define CGDisplayModeGetIOFlags fake_flags
#define CGDisplayModeRelease fake_release
#define CGDisplayScreenSize fake_mm
#define CGDisplayVendorNumber fake_identity
#define CGDisplayModelNumber fake_identity
#define CGDisplaySerialNumber fake_identity
#define SDL_GetWindowDisplayIndex fake_index
#define SDL_GetDisplayName fake_name
#define SDL_GetWindowSize fake_window
#define SDL_GetRendererOutputSize fake_drawable
#define SDL_PollEvent fake_poll
#define SDL_CreateTexture fake_texture
#define SDL_SetTextureBlendMode fake_texture_blend
#define SDL_UpdateTexture fake_texture_update
#define SDL_RenderCopy fake_texture_copy
#define SDL_DestroyTexture fake_texture_destroy
#define dlopen fake_open
#define dlsym fake_symbol
#define dlclose fake_close
#include "../src/display.c"
int main(void) {
    assert(tb_disp_choose_target() == 2); /* Main display is external. */
    struct tb_display d = {.target_display=2, .win=(SDL_Window *)1, .ren=(SDL_Renderer *)1};
    current = (struct fake_mode){1920,1080,960,540,0,60};
    scaled = (struct fake_mode){3200,1800,1600,900,0,60};
    native = (struct fake_mode){1920,1080,1920,1080,kDisplayModeNativeFlag,60};
    struct tb_display_info info;
    assert(tb_disp_get_info(&d, &info) == 0);
    assert(info.active_w == 1920 && info.active_h == 1080 && !info.hi_dpi && info.native_mode_known);
    assert(info.mode_w == 1920 && info.mode_h == 1080 && info.drawable_w == 980 && info.width_mm == 477);
    assert(strstr(info.identity, "internal"));
    current = (struct fake_mode){3840,2160,1920,1080,0,60};
    native = (struct fake_mode){5120,2880,2560,1440,kDisplayModeNativeFlag,60};
    assert(tb_disp_get_info(&d, &info) == 0 && info.active_w == 5120 && info.mode_w == 2560 && info.hi_dpi);
    native.flags = 0;
    assert(tb_disp_get_info(&d, &info) == 0 && !info.native_mode_known && info.active_w == 3840);
    double actual = 0;
    for (int i = 0; i < 4; ++i) {
        double values[] = {NAN, INFINITY, -0.1, 1.1};
        assert(tb_disp_set_brightness(&d, values[i], &actual) < 0 && set_calls == 0);
    }
    assert(tb_disp_set_brightness(&d, 0.5, &actual) == 0 && set_calls == 1 && get_calls == 1 && actual == 0.5);
    set_error = -1;
    assert(tb_disp_set_brightness(&d, 0.6, &actual) < 0 && actual == 0.5);
    set_error = 0; read_error = -1;
    assert(tb_disp_set_brightness(&d, 0.6, &actual) < 0);
    read_error = 0; backlight = NAN;
    assert(tb_disp_read_brightness(&d, &actual) < 0);
    d.target_display = 99; int previous = set_calls;
    assert(tb_disp_set_brightness(&d, 0.7, &actual) < 0 && set_calls == previous);
    d.input_capture_active = 1;
    queue_key(SDL_KEYDOWN, SDL_SCANCODE_D, SDLK_d, 0, 0);
    queue_key(SDL_KEYDOWN, SDL_SCANCODE_D, SDLK_d, 0, 1);
    queue_key(SDL_KEYUP, SDL_SCANCODE_D, SDLK_d, KMOD_GUI, 0);
    assert(tb_disp_poll_actions(&d) == TB_DISP_ACTION_TOGGLE_DEBUG);
    struct tb_input_event input;
    assert(!tb_disp_pop_input_event(&d, &input));
    queue_key(SDL_KEYDOWN, SDL_SCANCODE_R, SDLK_r, 0, 0);
    queue_key(SDL_KEYUP, SDL_SCANCODE_R, SDLK_r, 0, 0);
    assert(tb_disp_poll_actions(&d) == TB_DISP_ACTION_TOGGLE_RESCUE);
    assert(!tb_disp_pop_input_event(&d, &input));
    queue_key(SDL_KEYDOWN, SDL_SCANCODE_D, SDLK_d, KMOD_GUI, 0);
    queue_key(SDL_KEYUP, SDL_SCANCODE_D, SDLK_d, KMOD_GUI, 0);
    assert(!tb_disp_poll_actions(&d));
    assert(tb_disp_pop_input_event(&d, &input) && input.kind == TB_INPUT_EVENT_KEY_DOWN && input.key_code == 2);
    assert(tb_disp_pop_input_event(&d, &input) && input.kind == TB_INPUT_EVENT_KEY_UP && input.key_code == 2);
    drawable_width = 1920;
    tb_disp_set_debug_overlay(&d, 1,
        "串流中 | 1920 x 1080 | H.264 · NV12 8位 4:2:0 · HW | 面板 60.0 Hz | D: 信息  R: Rescue",
        "接收 60.0 / 提交 60.0 fps | 接收→提交 1.25 ms | 带宽 50.00 Mbps | 丢包率: 未测量 (TCP) | 合帧 0.0% | 解码错误 0");
    tb_disp_draw_debug(&d); tb_disp_draw_debug(&d);
    assert(texture_creates == 1 && texture_copies == 2); /* Cache per-frame drawing. */
    tb_disp_set_debug_overlay(&d, 0, "", "");
    tb_disp_draw_debug(&d);
    assert(texture_copies == 2 && !d.debug_tex);
    assert(tb_disp_debug_font_size("long diagnostic text", 17, 30) < 17);
    puts("display profile: internal target, native 1080p/5K, 1x/2x, debug size, brightness validation/failure/readback passed (all screen operations stubbed)");
    puts("debug overlay: real SDL shortcut routing, top placement, cached rasterization and text fitting passed (no windows)");
}
