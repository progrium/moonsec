/* The macOS host backend's C ABI: what host.zig sees of the Objective-C side
 * (capture.m, audio.m, encode.m, input.m, common.m). Plain C, no framework headers,
 * so `zig translate-c` handles it. Every Core Foundation object crosses as `void *`.
 *
 * Status codes: MH_OK (0), MH_TIMEOUT (1), or a negative MH_ERR_*. After an error,
 * mh_last_error() has a message for the calling thread. */
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    MH_OK = 0,
    MH_TIMEOUT = 1,
    MH_ERR = -1,
    /* Screen Recording or Accessibility (TCC) permission is missing. */
    MH_ERR_PERMISSION = -2,
    MH_ERR_UNSUPPORTED = -3,
    MH_ERR_CLOSED = -4,
    MH_ERR_NOMEM = -5,
    /* The stream stopped under us (display gone, permission revoked, sleep). */
    MH_ERR_DEVICE_LOST = -6,
    /* The encoder rejected the frame. */
    MH_ERR_CODEC = -7,
};

/* ---- common ---------------------------------------------------------------- */

/* mach_absolute_time in microseconds: the bundle's clock. */
int64_t mh_now_us(void);
/* mach_absolute_time ticks to microseconds on the same clock. */
int64_t mh_ticks_to_us(uint64_t ticks);
/* The last error on this thread ("" when none). */
const char *mh_last_error(void);

/* TCC checks that never prompt: CGPreflightScreenCaptureAccess and
 * CGPreflightPostEventAccess. 1 = allowed. */
int mh_screen_capture_allowed(void);
/* 1 when running in a virtual machine (kern.hv_vmm_present), like the CI runners. */
int mh_is_vm(void);
int mh_post_event_allowed(void);

/* Display `index` in CGGetActiveDisplayList order (0 = main display); 0 when out of range. */
uint32_t mh_display_id(uint32_t index);
/* Its bounds in global display coordinates (points) and its mode's size in pixels. */
int mh_display_bounds(uint32_t index, double *x, double *y, double *w, double *h);
int mh_display_pixels(uint32_t index, uint32_t *w, uint32_t *h);

/* CVPixelBuffer helpers (tests and the encoder's own scaling). Formats: */
enum { MH_FMT_BGRA = 1, MH_FMT_NV12 = 2 };
/* An IOSurface-backed CVPixelBuffer; release with mh_cf_release. */
void *mh_pixel_buffer_create(uint32_t width, uint32_t height, uint32_t format);
/* Fills a moving gradient (noise = 0) or random bytes (noise = 1). */
int mh_pixel_buffer_fill(void *pixel_buffer, uint32_t frame, int noise);
void mh_pixel_buffer_size(void *pixel_buffer, uint32_t *width, uint32_t *height, uint32_t *format);
void mh_cf_release(void *cf);
void *mh_cf_retain(void *cf);

/* ---- capture (ScreenCaptureKit, video) ------------------------------------- */

typedef struct mh_capture mh_capture;

typedef struct {
    uint32_t display; /* index, as mh_display_id */
    uint32_t fps;
    uint32_t width, height; /* 0 = the display's pixel size */
    uint32_t cursor;        /* draw the cursor into frames */
    uint32_t format;        /* MH_FMT_BGRA or MH_FMT_NV12 */
    uint32_t queue_depth;   /* SCStream queueDepth, 3..8 */
} mh_capture_config;

typedef struct {
    void *pixel_buffer; /* CVPixelBufferRef, retained: mh_cf_release it */
    uint32_t width, height, format;
    uint64_t seq;
    /* SCStreamFrameInfoDisplayTime, clamped to no later than arrived_us. */
    int64_t captured_us;
    /* When the sample handler got it. */
    int64_t arrived_us;
} mh_frame;

typedef struct {
    uint64_t complete;  /* complete frames delivered by SCK */
    uint64_t replaced;  /* complete frames replaced by a newer one before acquire */
    uint64_t stale;     /* frames whose display time was not after the last one's */
    uint64_t late;      /* frames that arrived more than two frame intervals after display time */
    uint64_t idle;      /* idle, blank or suspended status frames (no new content) */
    int64_t max_late_us;
} mh_capture_stats;

int mh_capture_create(mh_capture **out);
/* Starts a stream; on success *width and *height are the frame size it delivers. */
int mh_capture_start(mh_capture *c, const mh_capture_config *cfg, uint32_t *width, uint32_t *height);
/* Waits up to timeout_us for a frame newer than the last one acquired. MH_TIMEOUT when none. */
int mh_capture_acquire(mh_capture *c, int64_t timeout_us, mh_frame *out);
/* Changes size and rate on the running stream (SCStream updateConfiguration). */
int mh_capture_update(mh_capture *c, uint32_t width, uint32_t height, uint32_t fps);
void mh_capture_get_stats(mh_capture *c, mh_capture_stats *out);
void mh_capture_stop(mh_capture *c);
void mh_capture_destroy(mh_capture *c);

/* ---- audio (ScreenCaptureKit, system audio) -------------------------------- */

typedef struct mh_audio mh_audio;

int mh_audio_create(mh_audio **out);
/* 48 kHz f32; channels 1 or 2. Excludes this process's own audio. */
int mh_audio_start(mh_audio *a, uint32_t display, uint32_t channels);
/* Copies up to max_frames interleaved frames; waits up to timeout_us for the first.
 * *time_us is the clock time of the first frame copied. MH_TIMEOUT with *frames = 0. */
int mh_audio_read(mh_audio *a, float *out, uint32_t max_frames, int64_t timeout_us, uint32_t *frames, int64_t *time_us);
/* Frames dropped because the ring was full (reader too slow). */
uint64_t mh_audio_overruns(mh_audio *a);
void mh_audio_stop(mh_audio *a);
void mh_audio_destroy(mh_audio *a);

/* ---- encode (VideoToolbox) -------------------------------------------------- */

enum { MH_CODEC_H264 = 1, MH_CODEC_HEVC = 2 };

enum {
    /* EnableLowLatencyRateControl: the only VideoToolbox path with long-term references
     * (S8). RealTime on, ExpectedFrameRate 1000 (S7b). */
    MH_ENC_LOW_LATENCY = 1,
    /* The regular encoder, RealTime off (S7): faster, no LTR, IDR recovery only. */
    MH_ENC_REGULAR = 2,
};

typedef struct mh_enc mh_enc;

typedef struct {
    uint32_t mode;        /* MH_ENC_* */
    uint32_t require_hw;  /* RequireHardwareAcceleratedVideoEncoder */
    uint32_t expected_fps; /* ExpectedFrameRate on the low-latency path; 0 = 1000 */
} mh_enc_options;

typedef struct {
    uint32_t codec; /* MH_CODEC_* */
    uint32_t width, height, fps;
    uint64_t bitrate_bps;
    uint32_t ltr;
} mh_enc_config;

enum { MH_FORCE_NONE = 0, MH_FORCE_LTR_REFRESH = 1, MH_FORCE_IDR = 2 };

typedef struct {
    uint32_t force;
    uint64_t bitrate_bps; /* 0 = unchanged */
    const uint64_t *acked_ltr_tokens;
    uint32_t acked_ltr_count;
} mh_enc_params;

typedef struct {
    /* Annex B, parameter sets first on keyframes. Valid until the next encode. */
    const uint8_t *data;
    size_t len;
    uint32_t keyframe;
    uint32_t dropped;
    uint32_t has_ltr_token;
    uint32_t ltr_refresh;
    uint64_t ltr_token;
} mh_enc_output;

typedef struct {
    char encoder_id[128];
    uint32_t hardware;    /* UsingHardwareAcceleratedVideoEncoder */
    uint32_t low_latency; /* session created with EnableLowLatencyRateControl */
    uint32_t ltr;         /* EnableLTR accepted */
    uint32_t sessions;    /* sessions created so far (reconfigures that needed a new one) */
} mh_enc_info;

int mh_enc_create(const mh_enc_options *opts, mh_enc **out);
/* Whether a session for `codec` (and with LTR, when asked) can be made with these options,
 * at a small size. Fills *info from the probe session. */
int mh_enc_probe(const mh_enc_options *opts, uint32_t codec, uint32_t ltr, mh_enc_info *info);
/* Creates the session, or keeps it when only bitrate or frame rate changed. */
int mh_enc_configure(mh_enc *e, const mh_enc_config *cfg);
/* Encodes one CVPixelBuffer and waits for the output. Frames of another size are scaled
 * to the configured one. pts_us must increase. */
int mh_enc_encode(mh_enc *e, void *pixel_buffer, int64_t pts_us, const mh_enc_params *p, mh_enc_output *out);
void mh_enc_get_info(mh_enc *e, mh_enc_info *out);
/* The session's AverageBitRate as VideoToolbox reads it back (0 when unavailable). */
uint64_t mh_enc_bitrate(mh_enc *e);
void mh_enc_destroy(mh_enc *e);
/* Writes VTCopyVideoEncoderList (name, id, hardware flag), one per line. Returns the length. */
size_t mh_enc_list(char *buf, size_t cap);

/* ---- decode (tests: VideoToolbox decode of mh_enc output) ------------------ */

typedef struct mh_dec mh_dec;
/* Decodes an Annex B access unit (parameter sets needed on the first). 0 on success,
 * the OSStatus otherwise. *hash is an FNV-1a over a luma subsample. */
int mh_dec_create(uint32_t codec, mh_dec **out);
int mh_dec_decode(mh_dec *d, const uint8_t *data, size_t len, uint64_t *hash);
void mh_dec_destroy(mh_dec *d);

/* ---- input (CGEvent) -------------------------------------------------------- */

typedef struct mh_input mh_input;

int mh_input_create(mh_input **out);
/* Absolute moves land on this display (index, as mh_display_id). */
void mh_input_set_display(mh_input *in, uint32_t display);
/* A macOS virtual key code (kVK_*); modifiers update the flags later events carry. */
int mh_input_key(mh_input *in, uint16_t keycode, int down);
/* 1 left, 2 right, 3 middle, 4 and 5 back and forward. */
int mh_input_button(mh_input *in, uint32_t button, int down);
/* 120 per notch; dy > 0 scrolls up (away from the user), dx > 0 right. */
int mh_input_scroll(mh_input *in, int32_t dx, int32_t dy);
int mh_input_move_rel(mh_input *in, int32_t dx, int32_t dy);
/* 0..65535 across the display. */
int mh_input_move_abs(mh_input *in, uint16_t x, uint16_t y);
/* Where the cursor is, in global display coordinates. */
void mh_input_cursor(double *x, double *y);
void mh_input_destroy(mh_input *in);

#ifdef __cplusplus
}
#endif
