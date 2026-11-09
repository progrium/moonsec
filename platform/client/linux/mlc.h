/*
 * The Linux client backend's C side, as Zig sees it (platform/client/linux/backend.zig).
 * No system headers here: Wayland, EGL, GLES, libavcodec, libva and PipeWire stay in the
 * .c files, and translate-c only ever reads this file.
 *
 *   mlc_window.c   Wayland (xdg-shell) window, EGL context, GLES 3 presenter: NV12 or
 *                  BGRA from memory, VAAPI surfaces through dma-buf EGLImages, the overlay.
 *   mlc_decode.c   libavcodec H.264/HEVC/AV1: VAAPI when a device opens, software otherwise.
 *   mlc_audio.c    PipeWire playback stream (f32, interleaved) fed from a ring.
 *
 * Every function returns 0 on success and a negative MLC_E_* code otherwise; the C side
 * prints the detail (mlc_last_error has the last message).
 */
#ifndef MLC_H
#define MLC_H

#include <stddef.h>
#include <stdint.h>

#define MLC_OK 0
#define MLC_E_FAIL (-1)
#define MLC_E_UNSUPPORTED (-2)
#define MLC_E_NOMEM (-3)
#define MLC_E_CLOSED (-4)
#define MLC_E_NODEVICE (-5)
#define MLC_E_CODEC (-6)
#define MLC_E_AGAIN (-7)

/* The last error message on this thread (empty when none). */
const char *mlc_last_error(void);

/* ------------------------------------------------------------------------ */
/* Frames: what the decoder hands the presenter. */

#define MLC_FRAME_NONE 0
/* Y plane then interleaved UV (planes[0], planes[1]). */
#define MLC_FRAME_NV12 1
/* Three planes, 4:2:0 (libavcodec's yuv420p). */
#define MLC_FRAME_I420 2
/* One plane of 8-bit B, G, R, A. */
#define MLC_FRAME_BGRA 3
/* A VASurfaceID on `va_display`; imported as dma-buf. */
#define MLC_FRAME_VAAPI 4
/* Three full-size planes, 4:4:4 (libavcodec's yuv444p). */
#define MLC_FRAME_I444 5
/* Y plane then interleaved UV, 16-bit words with the value in the top bits (P010). */
#define MLC_FRAME_P010 6

/* Transfer functions (mlc_frame.transfer). */
#define MLC_TRANSFER_SDR 0
/* SMPTE ST 2084: HDR10. The presenter tone-maps it to SDR. */
#define MLC_TRANSFER_PQ 1
#define MLC_TRANSFER_HLG 2

typedef struct mlc_frame {
    uint32_t kind;
    uint32_t width;
    uint32_t height;
    const uint8_t *planes[3];
    uint32_t strides[3];
    void *va_display;
    uint32_t va_surface;
    int64_t pts;
    /* YUV matrix and range: BT.709 (else BT.601), full range (else limited). */
    uint8_t bt709;
    uint8_t full_range;
    /* BT.2020 non-constant-luminance matrix and primaries (overrides bt709). */
    uint8_t bt2020;
    /* Bits per sample: 8, or 10 for I420/I444 planes of 16-bit words (yuv4xxp10le, value
     * in the low bits) and P010 (value in the high bits). */
    uint8_t bit_depth;
    /* MLC_TRANSFER_*. */
    uint8_t transfer;
    /* HDR static metadata the stream carried (SEI / metadata OBU), 0 when it had none:
     * mastering display max and min in 0.0001 cd/m², MaxCLL and MaxFALL in cd/m². */
    uint8_t has_mastering;
    uint32_t max_luminance;
    uint32_t min_luminance;
    uint16_t max_cll;
    uint16_t max_fall;
    /* Decoder-private (the AVFrame). */
    void *priv;
} mlc_frame;

/* ------------------------------------------------------------------------ */
/* Window and presenter (one object: the EGL surface belongs to the window). */

typedef struct mlc_window mlc_window;

#define MLC_PRESENT_LOWEST_LATENCY 0
#define MLC_PRESENT_SMOOTH 1

/* Connects to $WAYLAND_DISPLAY, opens an xdg_toplevel of width x height and an EGL
 * GLES 3 context on it. The context is released before returning, so the present thread
 * can make it current (mlc_window_* calls below that touch GL do that themselves).
 * MLC_E_NODEVICE when there is no Wayland display or EGL. */
int mlc_window_create(uint32_t width, uint32_t height, const char *title, mlc_window **out);
void mlc_window_destroy(mlc_window *w);

/* Reads and dispatches pending Wayland events without blocking. MLC_E_CLOSED once the
 * compositor asked the window to close (or the connection broke). */
int mlc_window_dispatch(mlc_window *w);

/* Thread-safe flags for the input thread. */
int mlc_window_closed(const mlc_window *w);
/* 1 while the window has keyboard focus; also 1 when the seat has no keyboard
 * (a headless compositor), so input is never gated on focus that cannot come. */
int mlc_window_focused(const mlc_window *w);

void mlc_window_set_fullscreen(mlc_window *w, int on);
/* Swap interval 0 and tearing allowed (lowest latency) or vsync (smooth). */
int mlc_window_set_mode(mlc_window *w, int mode);
/* The size the client wants; applied unless the compositor dictates one. */
void mlc_window_resize(mlc_window *w, uint32_t width, uint32_t height);
void mlc_window_size(const mlc_window *w, uint32_t *width, uint32_t *height);

/* Draws a frame letterboxed into the window (NULL: clear to black). */
int mlc_window_draw(mlc_window *w, const mlc_frame *f);
/* Draws the overlay (if one is set) over what mlc_window_draw drew. */
int mlc_window_draw_overlay(mlc_window *w);
/* The overlay image (straight-alpha 0xAARRGGBB words, `stride` words per row), drawn at
 * the top-left corner; NULL hides it. Copied. */
int mlc_window_set_overlay(mlc_window *w, const uint32_t *pixels, uint32_t width, uint32_t height, uint32_t stride);
/* eglSwapBuffers. */
int mlc_window_present(mlc_window *w);

/* Reads back the back buffer as drawn so far (before present): `width x height` BGRA pixels
 * from the top-left corner into `out` (`stride` bytes per row). For tests and the
 * end-to-end check. */
int mlc_window_read(mlc_window *w, uint32_t x, uint32_t y, uint32_t width, uint32_t height, uint8_t *out, uint32_t stride);

/* EGL_EXT_image_dma_buf_import is there (VAAPI frames can be shown without a copy). */
int mlc_window_has_dmabuf(const mlc_window *w);
/* GL_RENDERER, for logs. */
const char *mlc_window_renderer(const mlc_window *w);

/* ------------------------------------------------------------------------ */
/* Decoder */

typedef struct mlc_decoder mlc_decoder;

#define MLC_CODEC_H264 1
#define MLC_CODEC_HEVC 2
#define MLC_CODEC_AV1 3

/* 1 when libavcodec has a decoder for the codec. */
int mlc_decoder_supported(uint32_t codec);

/* Coded formats the software decoder handles for `codec`, and the presenter draws, as
 * platform/format.zig's Formats bits: */
#define MLC_FMT_420_8 0x01
#define MLC_FMT_420_10 0x02
#define MLC_FMT_444_8 0x04
#define MLC_FMT_444_10 0x08
#define MLC_FMT_HDR10 0x10
uint32_t mlc_decoder_formats(uint32_t codec);

/* `hardware`: try VAAPI on `device` (a DRM render node; NULL picks the first). Falls back
 * to software when VAAPI cannot open or cannot decode the codec. */
int mlc_decoder_create(uint32_t codec, int hardware, const char *device, mlc_decoder **out);
void mlc_decoder_destroy(mlc_decoder *d);
int mlc_decoder_is_hardware(const mlc_decoder *d);

/* Feeds one access unit and returns the picture it produced, if any (*got = 0: none).
 * MLC_E_CODEC when the decoder rejected it. The frame stays valid until
 * mlc_decoder_release_frame, which must come before the next decode. */
int mlc_decoder_decode(mlc_decoder *d, const uint8_t *data, size_t len, int64_t pts, mlc_frame *out, int *got);
void mlc_decoder_release_frame(mlc_decoder *d, mlc_frame *f);
/* Drops buffered state (after an error, before a recovery frame). */
int mlc_decoder_flush(mlc_decoder *d);

/* ------------------------------------------------------------------------ */
/* Audio */

typedef struct mlc_audio mlc_audio;

/* A PipeWire playback stream, f32 interleaved, at `rate` x `channels`, with a ring of
 * `ring_ms` and a requested graph quantum of `quantum` frames.
 * MLC_E_NODEVICE when there is no PipeWire daemon. */
int mlc_audio_open(uint32_t rate, uint32_t channels, uint32_t ring_ms, uint32_t quantum, const char *name, mlc_audio **out);
void mlc_audio_close(mlc_audio *a);
/* Queues up to `frames`; *written is how many fit. Never blocks. */
int mlc_audio_write(mlc_audio *a, const float *pcm, uint32_t frames, uint32_t *written);
/* Frames queued in the ring plus what the graph reports still ahead of the device. */
uint32_t mlc_audio_queued(mlc_audio *a);
/* Ring size in frames, the quantum the graph runs at (0 until it started), whether the
 * stream is linked and streaming, and the times the ring ran dry while streaming. */
void mlc_audio_info(mlc_audio *a, uint32_t *ring_frames, uint32_t *quantum, int *streaming, uint64_t *underruns);

#endif
