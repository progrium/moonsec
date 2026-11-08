/* moonsec macOS client backend: the C ABI that Zig sees (platform/client/macos).
 *
 * Window and NSEvent input (macc_window.m), VideoToolbox decode (macc_decode.m),
 * CAMetalLayer or offscreen Metal present with the overlay copy (macc_present.m),
 * CoreAudio output (macc_audio.m).
 *
 * Rules, like platform/windows/msw.h: no Apple headers here (Zig translates this file
 * on any host), errors as OSStatus-style int32_t (0 = ok, negative = failure), opaque
 * objects, out-parameters last. The Objective-C side is compiled with ARC; every
 * object handed out is a retained Objective-C object behind an opaque pointer.
 */
#ifndef MACC_H
#define MACC_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef int32_t macc_status;

/* Our own codes, outside the ranges Apple uses. Everything else is an OSStatus from
 * the framework that failed (VideoToolbox -12xxx, CoreAudio, Metal as -1). */
enum {
    MACC_OK = 0,
    MACC_E_INVALID = -50,       /* paramErr */
    MACC_E_UNSUPPORTED = -4,    /* unimpErr: codec or format */
    MACC_E_NO_DEVICE = -69001,  /* no Metal device or no audio output device */
    MACC_E_NO_WINDOW = -69002,  /* no window server (headless session) */
    MACC_E_TIMEOUT = -69003,    /* no drawable in time */
    MACC_E_CLOSED = -69004,     /* window closed */
    MACC_E_BAD_STREAM = -69005, /* no parameter sets before the first slice, or a malformed NAL */
    MACC_E_METAL = -69006,      /* Metal pipeline or command buffer failed (logged) */
};

/* mach_absolute_time in nanoseconds: the clock every timestamp here uses. */
uint64_t macc_now_ns(void);

/* ---- Window and input ---------------------------------------------------------- */

typedef struct macc_window macc_window;

enum {
    MACC_EV_KEY_DOWN = 1,
    MACC_EV_KEY_UP = 2,
    MACC_EV_FLAGS_CHANGED = 3,
    MACC_EV_MOUSE_DOWN = 4,
    MACC_EV_MOUSE_UP = 5,
    MACC_EV_MOUSE_MOVE = 6,
    MACC_EV_SCROLL = 7,
    MACC_EV_QUIT = 8, /* the window was closed */
};

/* One NSEvent's fields (nsinput.zig maps them). */
typedef struct macc_event {
    uint32_t kind;
    uint16_t key_code;
    uint16_t button;
    uint64_t modifier_flags;
    double dx;
    double dy;
    uint8_t repeat;
    uint8_t precise;
    uint8_t inverted;
    uint8_t _pad[5];
    /* NSEvent.timestamp on the macc_now_ns clock. */
    uint64_t time_ns;
} macc_event;

enum {
    MACC_WINDOW_VISIBLE = 1u << 0,
};

/* Creates an NSWindow of content size w x h points (0: 1280 x 720) whose view is
 * backed by a CAMetalLayer. AppKit objects live on the main thread: called from
 * another thread this runs there with dispatch_sync, so the main thread must be
 * running its run loop (or calling macc_pump_events). MACC_E_NO_WINDOW when there is
 * no window server. Every function here may be called from any thread. */
macc_status macc_window_create(uint32_t w, uint32_t h, const char *title_utf8, uint32_t flags, macc_window **out);
void macc_window_destroy(macc_window *win);
/* 0 once the user closed the window (a MACC_EV_QUIT record is queued then). */
int macc_window_open(macc_window *win);
/* Native fullscreen on, or back to the window. */
void macc_window_set_fullscreen(macc_window *win, int on);
/* Pointer lock: hide the cursor and detach it from the mouse (deltas keep coming). */
void macc_window_set_mouse_captured(macc_window *win, int on);
/* Copies up to `max` queued event records into `out`, oldest first. The queue holds
 * 1024 records; beyond that the oldest are dropped and counted. */
size_t macc_window_poll(macc_window *win, macc_event *out, size_t max);
uint64_t macc_window_dropped(macc_window *win);
/* The content view's drawable size in pixels (points times the backing scale). */
void macc_window_size(macc_window *win, uint32_t *w, uint32_t *h);
/* Dispatches pending AppKit events when called on the main thread (no-op otherwise).
 * Apps that don't run [NSApp run] call this from the main thread. */
void macc_pump_events(void);
/* Test hook: builds an NSEvent of `kind` (key down/up/flags changed with `key_code`
 * and `modifier_flags`, or a mouse move of dx, dy) and feeds it to the window's view
 * as AppKit would. Returns 1 when the view queued a record. */
int macc_window_inject(macc_window *win, uint32_t kind, uint16_t key_code, uint64_t modifier_flags, double dx,
                       double dy);

/* ---- Decode -------------------------------------------------------------------- */

enum {
    MACC_CODEC_H264 = 1,
    MACC_CODEC_HEVC = 2,
};

typedef struct macc_decoder macc_decoder;

/* A decoded picture: an IOSurface-backed CVPixelBuffer, NV12 ('420v' or '420f'),
 * Metal-compatible. Valid until macc_decoder_release_frame. */
typedef struct macc_frame {
    void *pixel_buffer; /* CVPixelBufferRef */
    uint32_t width;     /* display size */
    uint32_t height;
    int64_t pts;
    uint32_t full_range; /* 1: '420f' (0..255), 0: '420v' (16..235) */
    uint32_t matrix;     /* MACC_MATRIX_* from the buffer's attachments */
} macc_frame;

enum {
    MACC_MATRIX_BT709 = 0,
    MACC_MATRIX_BT601 = 1,
    MACC_MATRIX_BT2020 = 2,
};

/* A VTDecompressionSession for `codec`, real-time, decoding synchronously (one access
 * unit in, its picture out). `hardware` allows the hardware decoder (VideoToolbox
 * falls back to software when there is none); 0 asks for software. The session is
 * created on the first access unit that carries parameter sets, and recreated when
 * they change in a way the session can't take. */
macc_status macc_decoder_create(uint32_t codec, int hardware, macc_decoder **out);
void macc_decoder_destroy(macc_decoder *dec);
/* 1 when the current session decodes in hardware (kVTDecompressionPropertyKey_
 * UsingHardwareAcceleratedVideoDecoder), 0 otherwise or before the first session. */
int macc_decoder_is_hardware(macc_decoder *dec);
/* Decodes one access unit (Annex B). Sets *got = 1 and fills *frame when a picture
 * came out. At most one frame may be held: release it before the next call.
 * MACC_E_BAD_STREAM when no parameter sets were seen yet; a VideoToolbox status
 * when the frame did not decode. */
macc_status macc_decoder_decode(macc_decoder *dec, const uint8_t *data, size_t len, int64_t pts, macc_frame *frame,
                                int *got);
void macc_decoder_release_frame(macc_decoder *dec, macc_frame *frame);
/* Drops the session (the next access unit with parameter sets starts a fresh one). */
void macc_decoder_flush(macc_decoder *dec);
/* Test hook: reads the Y and UV sample at (x, y) of a frame (x, y even). */
macc_status macc_frame_read_nv12(const macc_frame *frame, uint32_t x, uint32_t y, uint8_t yuv[3]);

/* ---- Present ------------------------------------------------------------------- */

typedef struct macc_presenter macc_presenter;

enum {
    MACC_PRESENT_LOWEST_LATENCY = 0, /* displaySyncEnabled = NO */
    MACC_PRESENT_SMOOTH = 1,         /* displaySyncEnabled = YES, waits for the presented handler */
};

enum {
    /* Keep drawables readable (framebufferOnly = NO) so macc_presenter_read_pixel
     * works on the layer path. Tests use it. */
    MACC_PRESENTER_READBACK = 1u << 0,
    /* Without a window: draw into a CAMetalLayer that is in no window (drawables still
     * come and go) instead of an offscreen texture. */
    MACC_PRESENTER_DETACHED_LAYER = 1u << 1,
};

/* A Metal presenter on the system default device. With `win`, it draws into the
 * window's CAMetalLayer (BGRA8, two drawables). Without one, into an offscreen BGRA8
 * texture of w x h, or into a detached CAMetalLayer of that size with
 * MACC_PRESENTER_DETACHED_LAYER: the headless paths CI tests on. NV12 frames are
 * converted in a fragment shader (CVMetalTextureCache, no copy) and letterboxed.
 * MACC_E_NO_DEVICE when there is no Metal device. */
macc_status macc_presenter_create(macc_window *win, uint32_t w, uint32_t h, uint32_t flags, macc_presenter **out);
void macc_presenter_destroy(macc_presenter *p);
/* The Metal device's name (borrowed, valid while p lives). */
const char *macc_presenter_device_name(macc_presenter *p);
/* 1 when drawing into a CAMetalLayer. */
int macc_presenter_uses_layer(macc_presenter *p);
/* Follows the window's size: resizes the drawables when it changed. */
void macc_presenter_sync_size(macc_presenter *p);
void macc_presenter_set_mode(macc_presenter *p, uint32_t mode);
/* Takes the next drawable (waiting up to `timeout_ms`; MACC_E_TIMEOUT) if none is
 * held, then draws `frame` (NULL: clear to black) and the overlay, if one was set,
 * into it and commits the GPU work. Does not present. */
macc_status macc_presenter_draw(macc_presenter *p, const macc_frame *frame, uint32_t timeout_ms);
/* Presents what draw drew (layer path; the offscreen path just finishes the work).
 * Smooth mode waits for the drawable's presented handler (up to 100 ms). *presented_ns
 * is when the frame reached the screen when Core Animation says, else when the GPU
 * work was scheduled. */
macc_status macc_presenter_present(macc_presenter *p, uint64_t *presented_ns);
/* The overlay image: `pixels` (BGRA, `stride` in pixels) of w x h is drawn over the
 * top-left corner of every frame drawn after this call, one image pixel per drawable
 * pixel; w = 0 or h = 0 hides it. Clipped to 1024 x 512. */
macc_status macc_presenter_set_overlay(macc_presenter *p, const uint32_t *pixels, uint32_t w, uint32_t h,
                                       uint32_t stride);
/* Test hook: the drawn target's pixel at (x, y) as 0xAARRGGBB (after draw, before
 * present; the layer path needs MACC_PRESENTER_READBACK). */
macc_status macc_presenter_read_pixel(macc_presenter *p, uint32_t x, uint32_t y, uint32_t *out);
void macc_presenter_size(macc_presenter *p, uint32_t *w, uint32_t *h);

/* ---- Audio out ----------------------------------------------------------------- */

typedef struct macc_audio macc_audio;

/* Opens the default output device through an AUHAL output unit for 32-bit float at
 * `rate` and `channels` (CoreAudio converts to the device's format), asks the device
 * for a small I/O buffer, and starts playing (silence until written). Samples go
 * through a lock-free ring of `ring_frames` (0: 1024) that the render callback
 * drains. MACC_E_NO_DEVICE when there is no output device. */
macc_status macc_audio_open(uint32_t rate, uint32_t channels, uint32_t ring_frames, macc_audio **out);
void macc_audio_close(macc_audio *a);
/* Queues up to `frames` interleaved frames; *written is how many fit. Never blocks. */
macc_status macc_audio_write(macc_audio *a, const float *pcm, uint32_t frames, uint32_t *written);
/* Frames queued in the ring and not yet handed to the device. */
uint32_t macc_audio_queued(macc_audio *a);
/* Ring size, the device's I/O buffer, and its output latency (frames at its rate,
 * safety offset included). */
void macc_audio_info(macc_audio *a, uint32_t *ring_frames, uint32_t *io_frames, uint32_t *device_latency_frames);
/* Frames the render callback had to fill with silence (underruns). */
uint64_t macc_audio_underrun_frames(macc_audio *a);

#ifdef __cplusplus
}
#endif

#endif
