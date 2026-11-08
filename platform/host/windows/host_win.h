/* Windows host backends: the C ABI that host.zig sees. No <windows.h> here.
 * Every function returns an HRESULT (msw_hr) unless noted. */
#ifndef HOST_WIN_H
#define HOST_WIN_H

#include "msw.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ---- Desktop Duplication (capture.c) --------------------------------------- */

typedef struct msw_dup msw_dup;

typedef struct msw_dup_frame {
    /* ID3D11Texture2D* (BGRA) owned by the msw_dup: a copy of the desktop image,
     * valid until the next acquire. */
    void *texture;
    uint32_t width, height;
    /* QPC time (ns) of the most recent present in this frame; 0 when only the
     * pointer moved. */
    uint64_t present_ns;
    /* Presents folded into this frame since the previous acquire. */
    uint32_t accumulated_frames;
    /* Pointer position on the desktop image and whether it is visible. */
    int32_t pointer_x, pointer_y;
    uint32_t pointer_visible;
    /* A new pointer shape is available (msw_dup_pointer_shape). */
    uint32_t pointer_shape_changed;
} msw_dup_frame;

/* Duplicates output `output_index` of the device's adapter. The device must be a
 * hardware device on the adapter that owns the output (WARP has no outputs:
 * MSW_DXGI_ERROR_NOT_FOUND). */
msw_hr msw_dup_create(msw_d3d *d, uint32_t output_index, msw_dup **out);
void msw_dup_destroy(msw_dup *dup);
void msw_dup_size(const msw_dup *dup, uint32_t *w, uint32_t *h);
/* The output's rectangle in virtual-desktop pixels. */
void msw_dup_desktop_rect(const msw_dup *dup, int32_t *left, int32_t *top, int32_t *width, int32_t *height);
/* Waits up to timeout_ms for a desktop update. MSW_DXGI_ERROR_WAIT_TIMEOUT when nothing
 * changed. On S_OK `out` is filled; out->present_ns == 0 means only the pointer changed
 * and out->texture holds the previous image. MSW_DXGI_ERROR_ACCESS_LOST (mode change,
 * secure desktop) means destroy and create again. */
msw_hr msw_dup_acquire(msw_dup *dup, uint32_t timeout_ms, msw_dup_frame *out);
/* The last copied image (null before the first frame). */
void *msw_dup_last_texture(const msw_dup *dup);
/* Copies the current pointer shape (DXGI_OUTDUPL_POINTER_SHAPE_INFO type, size, pitch,
 * hotspot) into buf; *needed gets the size required. */
msw_hr msw_dup_pointer_shape(msw_dup *dup, void *buf, uint32_t len, uint32_t *needed, uint32_t *type,
                             uint32_t *width, uint32_t *height, uint32_t *pitch, int32_t *hot_x, int32_t *hot_y);

/* ---- Video encoders (enc_mf.c, enc_nvenc.c) -------------------------------- */

typedef enum msw_enc_kind {
    /* NVENC through nvEncodeAPI64.dll, loaded at run time; takes the BGRA texture. */
    MSW_ENC_NVENC = 1,
    /* Media Foundation's software H.264 encoder (sync MFT); converts to NV12 on the CPU.
     * The CI path, and the last fallback on any machine. */
    MSW_ENC_MF_SOFTWARE = 2,
} msw_enc_kind;

enum { MSW_CODEC_H264 = 1, MSW_CODEC_HEVC = 2 };
enum { MSW_FORCE_NONE = 0, MSW_FORCE_LTR_REFRESH = 1, MSW_FORCE_IDR = 2 };

typedef struct msw_enc_caps {
    uint32_t h264, hevc;
    uint32_t ltr;
    uint32_t max_slices;
    uint32_t gpu_input, cpu_input;
} msw_enc_caps;

typedef struct msw_enc_config {
    uint32_t codec;
    uint32_t width, height, fps;
    uint64_t bitrate_bps;
    uint32_t slices;
    uint32_t ltr;
} msw_enc_config;

typedef struct msw_enc_params {
    uint32_t force;
    uint64_t bitrate_bps; /* 0 = unchanged */
    const uint64_t *acked_ltr_tokens;
    uint32_t acked_ltr_count;
} msw_enc_params;

typedef struct msw_enc_output {
    /* Annex B access unit, owned by the encoder, valid until the next encode. */
    const uint8_t *data;
    size_t len;
    uint32_t keyframe;
    uint32_t dropped;
    uint32_t has_ltr_token;
    uint64_t ltr_token;
    uint32_t ltr_refresh;
} msw_enc_output;

typedef struct msw_enc msw_enc;

/* MSW_E_NOTFOUND when the backend is not on this machine (no NVIDIA driver, no Media
 * Foundation, no software H.264 MFT). */
msw_hr msw_enc_create(msw_d3d *d, msw_enc_kind kind, msw_enc **out);
void msw_enc_caps_get(const msw_enc *e, msw_enc_caps *out);
msw_hr msw_enc_configure(msw_enc *e, const msw_enc_config *cfg);
/* Encodes subresource `index` of a BGRA texture (ID3D11Texture2D* on the encoder's
 * device). Blocks until the access unit is out. */
msw_hr msw_enc_encode(msw_enc *e, void *texture, uint32_t index, uint64_t time_us, const msw_enc_params *p,
                      msw_enc_output *out);
void msw_enc_destroy(msw_enc *e);

/* ---- WASAPI loopback (audio.c) ---------------------------------------------- */

typedef struct msw_loopback msw_loopback;

/* Opens the default render endpoint in loopback mode, 48 kHz float, `channels` channels
 * (the audio engine converts with AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM). MSW_E_NOTFOUND
 * when there is no render device. */
msw_hr msw_loopback_create(uint32_t channels, msw_loopback **out);
msw_hr msw_loopback_start(msw_loopback *l);
/* Fills up to max_frames interleaved frames, waiting up to timeout_ms for the first.
 * *frames = 0 on timeout. *time_ns is the QPC time of the first frame. Silence the
 * engine flags is written as zeros. */
msw_hr msw_loopback_read(msw_loopback *l, float *out, uint32_t max_frames, uint32_t timeout_ms, uint32_t *frames,
                         uint64_t *time_ns);
void msw_loopback_stop(msw_loopback *l);
void msw_loopback_destroy(msw_loopback *l);

/* ---- SendInput (input.c) ---------------------------------------------------- */

/* USB HID usage (keyboard page) to a PC/AT set-1 scan code, with bit 8 set for E0
 * extended keys. 0 when unmapped. */
uint32_t msw_hid_to_scancode(uint16_t usage);
/* Each returns HRESULT_FROM_WIN32(GetLastError()) when SendInput injected nothing
 * (UIPI, secure desktop). */
msw_hr msw_input_key(uint16_t hid_usage, uint32_t down);
/* button: 1 left, 2 right, 3 middle, 4 back (X1), 5 forward (X2). */
msw_hr msw_input_button(uint32_t button, uint32_t down);
/* 120 per notch; positive dy scrolls up, positive dx right. */
msw_hr msw_input_scroll(int32_t dx, int32_t dy);
msw_hr msw_input_move_rel(int32_t dx, int32_t dy);
/* x, y in 0..65535 across the display rectangle (virtual-desktop pixels: left, top,
 * width, height), e.g. msw_dup_desktop_rect of the captured output. */
msw_hr msw_input_move_abs(uint16_t x, uint16_t y, int32_t left, int32_t top, int32_t width, int32_t height);
/* The primary display's rectangle in virtual-desktop pixels. */
void msw_input_primary_rect(int32_t *left, int32_t *top, int32_t *width, int32_t *height);

#ifdef __cplusplus
}
#endif

#endif
