/* H.264 and HEVC header writers and the long-term-reference planner, shared by the VAAPI
 * encoder (enc_vaapi.c) and the test encoders that check them through libavcodec
 * (testenc_h264.c, testenc_hevc.c). Pure C, no system headers beyond the C library.
 *
 * libva leaves the reference structure to the application: which pictures stay in the
 * decoded picture buffer, which one a frame predicts from, and which get marked long-term.
 * VAAPI drivers write the slice data; when they take packed headers, the parameter sets
 * and slice headers are ours (written here), so the marking and reference lists in the
 * bitstream are exactly what refs_* planned. */
#ifndef H26X_H
#define H26X_H

#include <stddef.h>
#include <stdint.h>

/* ---- Bit writer ------------------------------------------------------------- */

typedef struct h26x_bw {
    uint8_t *buf;
    size_t cap;  /* bytes */
    size_t bits; /* bits written */
    int overflow;
} h26x_bw;

void h26x_bw_init(h26x_bw *w, uint8_t *buf, size_t cap);
void h26x_u(h26x_bw *w, uint32_t v, int n); /* n <= 32 */
void h26x_ue(h26x_bw *w, uint32_t v);
void h26x_se(h26x_bw *w, int32_t v);
/* rbsp_trailing_bits: a one, then zeros to the byte boundary. */
void h26x_trailing(h26x_bw *w);
/* Zeros to the byte boundary. */
void h26x_align_zero(h26x_bw *w);
/* Copies an RBSP (`len` bytes) into `out` as a NAL unit payload with emulation
 * prevention, after a 4-byte start code. Returns the bytes written, 0 if `cap` is short. */
size_t h26x_nal(uint8_t *out, size_t cap, const uint8_t *rbsp, size_t len);

/* ---- Long-term reference planner ---------------------------------------------- */

/* Two long-term slots: one keeps the newest acked reference while the other takes the
 * next mark, as the Windows NVENC backend does. */
#define REFS_SLOTS 2
/* Mark a long-term reference this often (frames). */
#define REFS_INTERVAL 15
/* Decoded picture buffer: the long-term slots, the previous frame and the current one. */
#define REFS_DPB (REFS_SLOTS + 2)

typedef struct refs_pic {
    int used;
    uint32_t count;   /* frames since the IDR: H.264 FrameNum and HEVC POC (mod their range) */
    int lt_slot;      /* -1 short-term */
    uint64_t token;   /* long-term token handed to the session (frame number from 1); 0 = none */
    int acked;
    uint32_t surface; /* reconstructed-picture index the encoder keeps for it */
} refs_pic;

typedef struct refs_state {
    int ltr;            /* mark long-term references at all */
    refs_pic dpb[REFS_DPB];
    uint64_t frames;    /* frames encoded since configure (tokens are frames + 1) */
    uint32_t count;     /* this frame's count since the IDR */
    uint32_t since_mark;
    int pending_lt;     /* HEVC: dpb index marked on the previous frame, or -1 */
} refs_state;

enum { REFS_FORCE_NONE = 0, REFS_FORCE_LTR_REFRESH = 1, REFS_FORCE_IDR = 2 };

typedef struct refs_plan {
    int idr;
    int ref;          /* dpb index this frame predicts from, -1 on an IDR */
    int refresh;      /* predicts from an acked long-term reference only (Force.ltr_refresh) */
    int mark_slot;    /* long-term slot this frame is marked into, -1 none */
    uint32_t count;
    int cur;          /* dpb index the current picture takes */
    /* Short-term pictures this frame drops (H.264: MMCO 1; HEVC: left out of the RPS). */
    int drop[REFS_DPB];
    int ndrop;
} refs_plan;

void refs_reset(refs_state *s, int ltr);
/* Records acked tokens. */
void refs_ack(refs_state *s, const uint64_t *tokens, uint32_t n);
/* Plans the next frame. */
void refs_plan_frame(refs_state *s, int force, refs_plan *p);
/* Commits a planned frame after it was encoded; returns the frame's long-term token or 0. */
uint64_t refs_commit(refs_state *s, const refs_plan *p);
/* Uncommitted frame (the encoder dropped it): nothing changes. */

/* ---- H.264 ---------------------------------------------------------------------- */

#define H264_LOG2_MAX_FRAME_NUM 16

typedef struct h264_params {
    uint32_t width, height;   /* luma samples; coded size is rounded up to 16 */
    uint8_t profile_idc;      /* 66 constrained baseline, 77 main, 100 high */
    uint8_t level_idc;        /* e.g. 41 */
    uint8_t cabac;            /* entropy_coding_mode_flag */
    uint8_t transform_8x8;    /* High only */
    uint8_t max_num_ref_frames;
    int8_t pic_init_qp;       /* 26 + pic_init_qp_minus26 */
    uint32_t fps;             /* VUI timing; 0 = none */
    uint8_t full_range;       /* VUI video_full_range_flag */
} h264_params;

typedef struct h264_slice {
    uint8_t idr;
    uint16_t idr_pic_id;
    uint8_t slice_type;       /* 0 P, 2 I (we write the +5 forms: all slices of a picture alike) */
    uint32_t first_mb;
    uint32_t frame_num;
    /* Reference list entry 0 (P slices): a short-term picture `ref_diff` frames back
     * (FrameNum difference, >= 1), or long-term slot `ref_lt`. */
    int ref_lt;               /* -1: short-term */
    uint32_t ref_diff;
    /* Marking (non-IDR): short-term pictures to drop (FrameNum differences, >= 1), then
     * mark the current picture long-term into `mark_slot` (-1 none). An IDR marks itself
     * long-term with long_term_reference_flag when mark_slot == 0. */
    uint32_t drop_diff[REFS_DPB];
    int ndrop;
    int mark_slot;
    int8_t slice_qp_delta;
    uint8_t disable_deblocking; /* disable_deblocking_filter_idc */
    uint8_t cabac_init_idc;
} h264_slice;

/* Fills `s` from a plan (frame_num, references, marking). */
void h264_slice_from_plan(h264_slice *s, const refs_state *st, const refs_plan *p, uint16_t idr_pic_id);

/* Whole NAL units (start code, NAL header, escaped), ready for the stream or a packed
 * header buffer. Return the bytes written, 0 when `cap` is short. */
size_t h264_write_sps(uint8_t *out, size_t cap, const h264_params *p);
size_t h264_write_pps(uint8_t *out, size_t cap, const h264_params *p);
/* Start code, NAL header and slice header, not escaped and not aligned: what a VAAPI
 * packed slice header takes (the driver appends the slice data). Returns the length in
 * bits, 0 when `cap` is short. The test encoders continue writing slice data after it. */
size_t h264_write_slice_header(h26x_bw *w, const h264_params *p, const h264_slice *s);

/* ---- HEVC ------------------------------------------------------------------------ */

#define HEVC_LOG2_MAX_POC_LSB 16

typedef struct hevc_params {
    uint32_t width, height;  /* luma samples; coded size is rounded up to the min CB size */
    uint8_t log2_min_cb;     /* 3 = 8x8 */
    uint8_t log2_ctb;        /* 4..6 */
    uint8_t log2_min_tb, log2_max_tb;
    uint8_t max_transform_hierarchy_depth;
    uint8_t amp, sao, pcm, strong_intra_smoothing;
    /* sps_temporal_mvp_enabled_flag (for drivers that require it); slices still turn it off. */
    uint8_t temporal_mvp;
    uint8_t pcm_log2_min, pcm_log2_max; /* when pcm */
    uint8_t level_idc;       /* general_level_idc, 30 x level (e.g. 120 for 4.0) */
    uint8_t max_dec_pic_buffering; /* sps_max_dec_pic_buffering_minus1 + 1 */
    int8_t init_qp;
    uint8_t cu_qp_delta;
    uint8_t transform_skip;
    uint8_t sign_data_hiding;
    uint8_t loop_filter_across_slices;
    uint8_t deblocking_disabled; /* pps_deblocking_filter_disabled_flag */
    uint32_t fps;           /* VUI timing; 0 = none */
    uint8_t full_range;
} hevc_params;

typedef struct hevc_slice {
    uint8_t idr;             /* IDR_W_RADL */
    uint8_t slice_type;      /* 1 P, 2 I */
    uint32_t address;        /* slice_segment_address in CTBs */
    uint32_t poc;
    /* Short-term RPS: pictures before the current one, as POC deltas (> 0, ascending),
     * each used by the current picture or kept for later. */
    uint32_t st_delta[REFS_DPB];
    uint8_t st_used[REFS_DPB];
    int nst;
    /* Long-term pictures by full POC (delta_poc_msb_present always set). */
    uint32_t lt_poc[REFS_DPB];
    uint8_t lt_used[REFS_DPB];
    int nlt;
    int8_t slice_qp_delta;
    uint8_t max_merge_cand;  /* 1..5 */
    uint8_t sao_luma, sao_chroma;
} hevc_slice;

void hevc_slice_from_plan(hevc_slice *s, const refs_state *st, const refs_plan *p);

size_t hevc_write_vps(uint8_t *out, size_t cap, const hevc_params *p);
size_t hevc_write_sps(uint8_t *out, size_t cap, const hevc_params *p);
size_t hevc_write_pps(uint8_t *out, size_t cap, const hevc_params *p);
/* Like h264_write_slice_header; ends with byte_alignment() written (HEVC's slice header
 * is byte aligned before slice data), so the result is a whole number of bytes. */
size_t hevc_write_slice_header(h26x_bw *w, const hevc_params *p, const hevc_slice *s);

#endif
