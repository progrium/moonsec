/* moonsec Windows client backend: the C ABI that Zig sees (platform/client/windows).
 *
 * Window and Raw Input (mswc_window.c), Media Foundation decode backed by D3D11VA or
 * software (mswc_decode.c), flip-model swapchain with a video-processor blit and the
 * overlay copy (mswc_present.c), WASAPI output (mswc_audio.c).
 *
 * Same rules as platform/windows/msw.h: no <windows.h> here, HRESULTs as int32_t,
 * opaque objects, out-parameters last.
 */
#ifndef MSWC_H
#define MSWC_H

#include "msw.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ---- Window and Raw Input ---------------------------------------------------- */

typedef struct mswc_window mswc_window;

enum {
    MSWC_RAW_KEYBOARD = 1,
    MSWC_RAW_MOUSE = 2,
    MSWC_RAW_QUIT = 3, /* WM_CLOSE / WM_QUIT seen */
};

/* One WM_INPUT record, fields copied from RAWKEYBOARD / RAWMOUSE. */
typedef struct mswc_raw {
    uint32_t kind;
    uint16_t kb_make_code;
    uint16_t kb_flags;
    uint16_t mouse_flags;
    uint16_t mouse_button_flags;
    uint16_t mouse_button_data;
    uint16_t _pad;
    int32_t mouse_last_x;
    int32_t mouse_last_y;
    /* QueryPerformanceCounter, in ns (msw_qpc_ns), when the message was read. */
    uint64_t time_ns;
} mswc_raw;

enum {
    MSWC_WINDOW_VISIBLE = 1u << 0,
    /* Raw Input even when the window is not in the foreground (RIDEV_INPUTSINK). */
    MSWC_WINDOW_INPUT_SINK = 1u << 1,
    /* Register for Raw Input at all. */
    MSWC_WINDOW_RAW_INPUT = 1u << 2,
};

/* Creates a window of client size w x h (0: 1280 x 720) on a thread of its own, which
 * pumps its messages until mswc_window_destroy. Every function here may be called
 * from any thread. */
msw_hr mswc_window_create(uint32_t w, uint32_t h, const char *title_utf8, uint32_t flags, mswc_window **out);
void mswc_window_destroy(mswc_window *win);
/* 0 once the user closed the window (a MSWC_RAW_QUIT record is queued then). */
int mswc_window_open(const mswc_window *win);
/* Borderless fullscreen on the window's monitor, or back to the windowed placement. */
void mswc_window_set_fullscreen(mswc_window *win, int on);
/* Copies up to `max` queued Raw Input records into `out`, oldest first. The queue holds
 * 1024 records; beyond that the oldest are dropped and counted. */
size_t mswc_window_poll_raw(mswc_window *win, mswc_raw *out, size_t max);
uint64_t mswc_window_raw_dropped(mswc_window *win);
/* Current client-area size. */
void mswc_window_size(const mswc_window *win, uint32_t *w, uint32_t *h);
/* Borrowed HWND. */
void *mswc_window_hwnd(const mswc_window *win);
/* Test hook: injects a key with SendInput (KEYEVENTF_SCANCODE), which Raw Input
 * reports like a real key. Returns the number of events inserted. */
uint32_t mswc_send_key(uint16_t scan_code, int extended, int up);

/* ---- Decode -------------------------------------------------------------------- */

enum {
    MSWC_CODEC_H264 = 1,
    MSWC_CODEC_HEVC = 2,
    /* Probed only (mswc_decoder_hw_formats); the decoder MFT path takes H.264 and HEVC. */
    MSWC_CODEC_AV1 = 3,
};

/* Coded formats, as platform/format.zig's Formats bits. */
enum {
    MSWC_FMT_420_8 = 0x01,
    MSWC_FMT_420_10 = 0x02,
    MSWC_FMT_444_8 = 0x04,
    MSWC_FMT_444_10 = 0x08,
    MSWC_FMT_HDR10 = 0x10,
};

/* What the GPU's D3D11VA decoder has for `codec` (decoder profile plus output format),
 * as MSWC_FMT_* bits; 0 without a video device (WARP). A probe for the hardware check:
 * the MFT decode path and the presenter take 8-bit 4:2:0 only (see mswc_formats.c). */
uint32_t mswc_decoder_hw_formats(msw_d3d *d3d, uint32_t codec);

typedef struct mswc_decoder mswc_decoder;

/* A decoded NV12 picture on the GPU. With hardware decode the texture is the
 * decoder's array texture (`index` = slice); with software decode it is a texture
 * the decoder uploaded into. Valid until mswc_decoder_release_frame. */
typedef struct mswc_frame {
    void *texture; /* ID3D11Texture2D*, DXGI_FORMAT_NV12 */
    uint32_t index;
    uint32_t width; /* display size (the cropped picture) */
    uint32_t height;
    int64_t pts;
    void *_sample; /* IMFSample* holding the picture */
} mswc_frame;

/* Creates a Media Foundation decoder MFT for `codec` in low-latency mode (one frame
 * in, one frame out, no reordering delay). `hardware` asks for D3D11VA through a DXGI
 * device manager on `d3d` (which must be created with MSW_D3D_VIDEO); without it, or
 * when the MFT is not D3D11-aware, the MFT decodes in software and frames are
 * uploaded to `d3d`. MF_E_TOPO_CODEC_NOT_FOUND (0xC00D5212) when no decoder exists. */
msw_hr mswc_decoder_create(msw_d3d *d3d, uint32_t codec, int hardware, mswc_decoder **out);
void mswc_decoder_destroy(mswc_decoder *dec);
/* 1 when decoding through D3D11VA. */
int mswc_decoder_is_hardware(const mswc_decoder *dec);
/* Decodes one access unit (Annex B). Sets *got = 1 and fills *frame when a picture
 * came out. At most one frame may be held: release it before the next call. */
msw_hr mswc_decoder_decode(mswc_decoder *dec, const uint8_t *data, size_t len, int64_t pts, mswc_frame *frame,
                           int *got);
void mswc_decoder_release_frame(mswc_decoder *dec, mswc_frame *frame);
/* Drops queued input and output (after a gap, before the recovery frame). */
msw_hr mswc_decoder_flush(mswc_decoder *dec);
/* Test hook: reads the Y and UV sample at (x, y) of a frame (x, y even). */
msw_hr mswc_frame_read_nv12(msw_d3d *d3d, const mswc_frame *frame, uint32_t x, uint32_t y, uint8_t yuv[3]);

/* ---- Present ------------------------------------------------------------------- */

typedef struct mswc_presenter mswc_presenter;

enum {
    MSWC_PRESENT_LOWEST_LATENCY = 0, /* Present(0, ALLOW_TEARING when supported) */
    MSWC_PRESENT_SMOOTH = 1,         /* Present(1, 0) */
};

enum {
    /* Convert with the pixel shader even when the device has a video processor. */
    MSWC_PRESENTER_SHADER = 1u << 0,
};

/* Flip-model swapchain (FLIP_DISCARD, 2 buffers, BGRA8) on the window with a frame
 * latency waitable object and a maximum frame latency of 1; ALLOW_TEARING when the
 * factory supports it. NV12 frames are scaled and converted by the D3D11 video
 * processor, or by a pixel shader when the device has none (WARP), letterboxed into
 * the back buffer. The shader path needs the frame texture to allow shader resource
 * views. */
msw_hr mswc_presenter_create(msw_d3d *d3d, mswc_window *win, uint32_t flags, mswc_presenter **out);
void mswc_presenter_destroy(mswc_presenter *p);
int mswc_presenter_tearing(const mswc_presenter *p);
/* 1 when colour conversion runs in the pixel shader, 0 for the video processor. */
int mswc_presenter_uses_shader(const mswc_presenter *p);
/* Waits on the frame latency waitable object: returns once DXGI can take another
 * frame without queueing. MSW_DXGI_ERROR_WAIT_TIMEOUT after `timeout_ms`. */
msw_hr mswc_presenter_wait(mswc_presenter *p, uint32_t timeout_ms);
/* Resizes the back buffers to the window's client size if it changed. */
msw_hr mswc_presenter_sync_size(mswc_presenter *p);
/* Draws `frame` (NULL: clear to black) and the overlay, if one was set, into the
 * back buffer. Does not present. */
msw_hr mswc_presenter_draw(mswc_presenter *p, const mswc_frame *frame);
/* Presents the back buffer. */
msw_hr mswc_presenter_present(mswc_presenter *p, uint32_t mode);
/* The overlay image: `pixels` (BGRA, `stride` in pixels) of w x h is copied over the
 * top-left corner of every frame drawn after this call; w = 0 or h = 0 hides it.
 * Clipped to 1024 x 512. */
msw_hr mswc_presenter_set_overlay(mswc_presenter *p, const uint32_t *pixels, uint32_t w, uint32_t h,
                                  uint32_t stride);
/* Test hook: the back buffer's pixel at (x, y) as 0xAARRGGBB. */
msw_hr mswc_presenter_read_pixel(mswc_presenter *p, uint32_t x, uint32_t y, uint32_t *out);
void mswc_presenter_size(const mswc_presenter *p, uint32_t *w, uint32_t *h);

/* ---- Audio out ----------------------------------------------------------------- */

typedef struct mswc_audio mswc_audio;

/* Opens the default render endpoint in shared mode for 32-bit float at `rate` and
 * `channels`. Uses IAudioClient3's smallest engine period when the mix format matches,
 * otherwise IAudioClient with AUTOCONVERTPCM and a 20 ms buffer. E_NOTFOUND when
 * there is no endpoint. Starts playing immediately (silence until written). */
msw_hr mswc_audio_open(uint32_t rate, uint32_t channels, mswc_audio **out);
void mswc_audio_close(mswc_audio *a);
/* Queues up to `frames` interleaved frames; *written is how many fit. Never blocks. */
msw_hr mswc_audio_write(mswc_audio *a, const float *pcm, uint32_t frames, uint32_t *written);
/* Frames queued and not yet played (GetCurrentPadding). */
msw_hr mswc_audio_queued(mswc_audio *a, uint32_t *frames);
/* Buffer size in frames and the period it was opened with (100 ns units). */
void mswc_audio_info(const mswc_audio *a, uint32_t *buffer_frames, int64_t *period_hns, int *low_latency);

#ifdef __cplusplus
}
#endif

#endif
