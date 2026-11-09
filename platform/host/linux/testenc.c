/* Test encoders (mlh_enc.h): pictures built from PCM blocks and skipped blocks, written
 * with the h26x.c headers and reference planner that enc_vaapi.c uses. Skipped blocks
 * copy the reference the planner chose, so a decoder's output shows exactly which picture
 * a frame predicted from: the tests decode with libavcodec and compare every picture with
 * a model, through long-term marking, losses and recovery.
 *
 * H.264: Constrained Baseline, CAVLC, I_PCM macroblocks and P_Skip runs.
 * HEVC: Main, CABAC, 16x16 CTBs that are one CU each: pcm_flag CUs and cu_skip_flag CUs
 * (one merge candidate, temporal MVP off, so a skip copies the co-located block). */
#include <stdlib.h>
#include <string.h>

#include "enc_internal.h"
#include "h26x.h"

struct mlh_testenc {
    uint32_t codec;
    uint32_t width, height;
    refs_state refs;
    uint16_t idr_id;
    h264_params h264;
    hevc_params hevc;
    uint8_t *out;
    size_t out_cap;
    uint8_t *bits;
    size_t bits_cap;
};

int mlh_testenc_create(uint32_t codec, uint32_t width, uint32_t height, int ltr, mlh_testenc **out) {
    *out = NULL;
    if (width == 0 || height == 0 || width % 16 || height % 16) return mlh_fail(MLH_E_UNSUPPORTED, "testenc: size must be a multiple of 16");
    if (codec != MLH_CODEC_H264 && codec != MLH_CODEC_HEVC) return mlh_fail(MLH_E_UNSUPPORTED, "testenc: codec %u", codec);
    mlh_testenc *t = calloc(1, sizeof *t);
    if (!t) return MLH_E_NOMEM;
    t->codec = codec;
    t->width = width;
    t->height = height;
    refs_reset(&t->refs, ltr);
    t->h264 = (h264_params){
        .width = width, .height = height, .profile_idc = 66, .level_idc = 40, .cabac = 0,
        .max_num_ref_frames = REFS_SLOTS + 1, .pic_init_qp = 26, .fps = 60,
    };
    t->hevc = (hevc_params){
        .width = width, .height = height, .log2_min_cb = 4, .log2_ctb = 4, .log2_min_tb = 2, .log2_max_tb = 4,
        .max_transform_hierarchy_depth = 0, .pcm = 1, .pcm_log2_min = 4, .pcm_log2_max = 4, .level_idc = 120,
        .max_dec_pic_buffering = REFS_DPB, .init_qp = 26, .deblocking_disabled = 1, .fps = 60,
    };
    t->bits_cap = (size_t)width * height * 2 + 4096;
    t->out_cap = t->bits_cap * 2;
    t->bits = malloc(t->bits_cap);
    t->out = malloc(t->out_cap);
    if (!t->bits || !t->out) {
        mlh_testenc_destroy(t);
        return MLH_E_NOMEM;
    }
    *out = t;
    return MLH_OK;
}

void mlh_testenc_destroy(mlh_testenc *t) {
    if (!t) return;
    free(t->bits);
    free(t->out);
    free(t);
}

/* A 16x16 block's samples: 256 luma, then 64 Cb and 64 Cr, raster order. */
static void put_block(h26x_bw *w, const mlh_testenc *t, const uint8_t *y, const uint8_t *u, const uint8_t *v,
                      uint32_t bx, uint32_t by) {
    for (uint32_t r = 0; r < 16; r++)
        for (uint32_t c = 0; c < 16; c++) h26x_u(w, y[(by * 16 + r) * t->width + bx * 16 + c], 8);
    const uint32_t cw = t->width / 2;
    for (int plane = 0; plane < 2; plane++) {
        const uint8_t *p = plane ? v : u;
        for (uint32_t r = 0; r < 8; r++)
            for (uint32_t c = 0; c < 8; c++) h26x_u(w, p[(by * 8 + r) * cw + bx * 8 + c], 8);
    }
}

/* Escapes the slice NAL in t->bits (start code first) onto out. */
static int emit(mlh_testenc *t, h26x_bw *w, size_t *len) {
    if (w->overflow) return mlh_fail(MLH_E_FAIL, "testenc: bit buffer overflow");
    size_t n = h26x_nal(t->out + *len, t->out_cap - *len, w->buf + 4, w->bits / 8 - 4);
    if (!n) return mlh_fail(MLH_E_FAIL, "testenc: output overflow");
    *len += n;
    return MLH_OK;
}

static int h264_frame(mlh_testenc *t, const refs_plan *plan, const uint8_t *y, const uint8_t *u, const uint8_t *v,
                      const uint8_t *changed, size_t *len) {
    if (plan->idr) {
        size_t n = h264_write_sps(t->out + *len, t->out_cap - *len, &t->h264);
        if (!n) return mlh_fail(MLH_E_FAIL, "testenc: SPS");
        *len += n;
        n = h264_write_pps(t->out + *len, t->out_cap - *len, &t->h264);
        if (!n) return mlh_fail(MLH_E_FAIL, "testenc: PPS");
        *len += n;
    }
    h264_slice s;
    h264_slice_from_plan(&s, &t->refs, plan, t->idr_id);
    s.disable_deblocking = 1; /* PCM next to skipped blocks would be filtered otherwise */
    h26x_bw w;
    h26x_bw_init(&w, t->bits, t->bits_cap);
    if (!h264_write_slice_header(&w, &t->h264, &s)) return mlh_fail(MLH_E_FAIL, "testenc: slice header");
    const uint32_t mbw = t->width / 16, mbh = t->height / 16;
    uint32_t run = 0;
    for (uint32_t by = 0; by < mbh; by++)
        for (uint32_t bx = 0; bx < mbw; bx++) {
            const int coded = plan->idr || changed[by * mbw + bx];
            if (!coded) {
                run++;
                continue;
            }
            if (!plan->idr) {
                h26x_ue(&w, run); /* mb_skip_run */
                run = 0;
                h26x_ue(&w, 5 + 25); /* mb_type I_PCM in a P slice */
            } else {
                h26x_ue(&w, 25); /* I_PCM */
            }
            h26x_align_zero(&w); /* pcm_alignment_zero_bit */
            put_block(&w, t, y, u, v, bx, by);
        }
    if (run) h26x_ue(&w, run);
    h26x_trailing(&w);
    return emit(t, &w, len);
}

/* ---- HEVC: a minimal CABAC encoder (H.265 9.3.4) ------------------------------ */

static const uint8_t range_lps[64][4] = {
    {128, 176, 208, 240}, {128, 167, 197, 227}, {128, 158, 187, 216}, {123, 150, 178, 205}, {116, 142, 169, 195},
    {111, 135, 160, 185}, {105, 128, 152, 175}, {100, 122, 144, 166}, {95, 116, 137, 158},  {90, 110, 130, 150},
    {85, 104, 123, 142},  {81, 99, 117, 135},   {77, 94, 111, 128},   {73, 89, 105, 122},   {69, 85, 100, 116},
    {66, 80, 95, 110},    {62, 76, 90, 104},    {59, 72, 86, 99},     {56, 69, 81, 94},     {53, 65, 77, 89},
    {51, 62, 73, 85},     {48, 59, 69, 80},     {46, 56, 66, 76},     {43, 53, 63, 72},     {41, 50, 59, 69},
    {39, 48, 56, 65},     {37, 45, 54, 62},     {35, 43, 51, 59},     {33, 41, 48, 56},     {32, 39, 46, 53},
    {30, 37, 43, 50},     {29, 35, 41, 48},     {27, 33, 39, 45},     {26, 31, 37, 43},     {24, 30, 35, 41},
    {23, 28, 33, 39},     {22, 27, 32, 37},     {21, 26, 30, 35},     {20, 24, 29, 33},     {19, 23, 27, 31},
    {18, 22, 26, 30},     {17, 21, 25, 28},     {16, 20, 23, 27},     {15, 19, 22, 25},     {14, 18, 21, 24},
    {14, 17, 20, 23},     {13, 16, 19, 22},     {12, 15, 18, 21},     {12, 14, 17, 20},     {11, 14, 16, 19},
    {11, 13, 15, 18},     {10, 12, 15, 17},     {10, 12, 14, 16},     {9, 11, 13, 15},      {9, 11, 12, 14},
    {8, 10, 12, 14},      {8, 9, 11, 13},       {7, 9, 11, 12},       {7, 9, 10, 12},       {7, 8, 10, 11},
    {6, 8, 9, 11},        {6, 7, 9, 10},        {6, 7, 8, 9},         {2, 2, 2, 2},
};
static const uint8_t trans_lps[64] = {0,  0,  1,  2,  2,  4,  4,  5,  6,  7,  8,  9,  9,  11, 11, 12,
                                      13, 13, 15, 15, 16, 16, 18, 18, 19, 19, 21, 21, 22, 22, 23, 24,
                                      24, 25, 26, 26, 27, 27, 28, 29, 29, 30, 30, 30, 31, 32, 32, 33,
                                      33, 33, 34, 34, 35, 35, 35, 36, 36, 36, 37, 37, 37, 38, 38, 63};

typedef struct cabac_ctx {
    uint8_t state, mps;
} cabac_ctx;

typedef struct cabac {
    h26x_bw *w;
    uint32_t low, range;
    int first, outstanding;
} cabac;

static void cabac_init_ctx(cabac_ctx *c, int init_value, int qp) {
    const int m = (init_value >> 4) * 5 - 45, n = ((init_value & 15) << 3) - 16;
    int pre = ((m * qp) >> 4) + n;
    if (pre < 1) pre = 1;
    if (pre > 126) pre = 126;
    c->mps = pre > 63;
    c->state = (uint8_t)(c->mps ? pre - 64 : 63 - pre);
}

static void cabac_start(cabac *e, h26x_bw *w) {
    e->w = w;
    e->low = 0;
    e->range = 510;
    e->first = 1;
    e->outstanding = 0;
}

static void put_bit(cabac *e, uint32_t b) {
    if (e->first)
        e->first = 0;
    else
        h26x_u(e->w, b, 1);
    for (; e->outstanding > 0; e->outstanding--) h26x_u(e->w, 1 - b, 1);
}

static void renorm(cabac *e) {
    while (e->range < 256) {
        if (e->low < 256) {
            put_bit(e, 0);
        } else if (e->low >= 512) {
            e->low -= 512;
            put_bit(e, 1);
        } else {
            e->low -= 256;
            e->outstanding++;
        }
        e->range <<= 1;
        e->low <<= 1;
    }
}

static void cabac_bin(cabac *e, cabac_ctx *c, int bin) {
    const uint32_t lps = range_lps[c->state][(e->range >> 6) & 3];
    e->range -= lps;
    if (bin != c->mps) {
        e->low += e->range;
        e->range = lps;
        if (c->state == 0) c->mps = (uint8_t)(1 - c->mps);
        c->state = trans_lps[c->state];
    } else if (c->state < 62) {
        c->state++;
    }
    renorm(e);
}

/* Terminating bin; a 1 flushes (the last bit written is the stop or PCM bit). */
static void cabac_terminate(cabac *e, int bin) {
    e->range -= 2;
    if (bin) {
        e->low += e->range;
        e->range = 2;
        renorm(e);
        put_bit(e, (e->low >> 9) & 1);
        h26x_u(e->w, ((e->low >> 7) & 3) | 1, 2);
    } else {
        renorm(e);
    }
}

static int hevc_frame(mlh_testenc *t, const refs_plan *plan, const uint8_t *y, const uint8_t *u, const uint8_t *v,
                      const uint8_t *changed, size_t *len) {
    if (plan->idr) {
        size_t n = hevc_write_vps(t->out + *len, t->out_cap - *len, &t->hevc);
        if (!n) return mlh_fail(MLH_E_FAIL, "testenc: VPS");
        *len += n;
        n = hevc_write_sps(t->out + *len, t->out_cap - *len, &t->hevc);
        if (!n) return mlh_fail(MLH_E_FAIL, "testenc: SPS");
        *len += n;
        n = hevc_write_pps(t->out + *len, t->out_cap - *len, &t->hevc);
        if (!n) return mlh_fail(MLH_E_FAIL, "testenc: PPS");
        *len += n;
    }
    hevc_slice s;
    hevc_slice_from_plan(&s, &t->refs, plan);
    s.max_merge_cand = 1;
    h26x_bw w;
    h26x_bw_init(&w, t->bits, t->bits_cap);
    if (!hevc_write_slice_header(&w, &t->hevc, &s)) return mlh_fail(MLH_E_FAIL, "testenc: slice header");

    /* Contexts at SliceQpY 26. initType 0 for I slices, 1 for P (no cabac_init_flag). */
    const int qp = t->hevc.init_qp, p_slice = !plan->idr;
    cabac_ctx skip[3], pred_mode, part_mode;
    for (int i = 0; i < 3; i++) cabac_init_ctx(&skip[i], (const int[]){197, 185, 201}[i], qp);
    cabac_init_ctx(&pred_mode, 149, qp);
    cabac_init_ctx(&part_mode, p_slice ? 154 : 184, qp);

    const uint32_t bw = t->width / 16, bh = t->height / 16;
    uint8_t *skipped = calloc((size_t)bw * bh, 1);
    if (!skipped) return MLH_E_NOMEM;
    cabac e;
    cabac_start(&e, &w);
    for (uint32_t by = 0; by < bh; by++)
        for (uint32_t bx = 0; bx < bw; bx++) {
            const int coded = plan->idr || changed[by * bw + bx];
            if (p_slice) {
                const int inc = (bx > 0 && skipped[by * bw + bx - 1]) + (by > 0 && skipped[(by - 1) * bw + bx]);
                cabac_bin(&e, &skip[inc], !coded);
                skipped[by * bw + bx] = (uint8_t)!coded;
            }
            if (coded) {
                if (p_slice) cabac_bin(&e, &pred_mode, 1); /* MODE_INTRA */
                cabac_bin(&e, &part_mode, 1);              /* PART_2Nx2N */
                cabac_terminate(&e, 1);                    /* pcm_flag */
                h26x_align_zero(&w);                       /* pcm_alignment_zero_bit */
                put_block(&w, t, y, u, v, bx, by);
                cabac_start(&e, &w); /* the engine restarts after PCM samples; contexts stay */
            }
            cabac_terminate(&e, by == bh - 1 && bx == bw - 1); /* end_of_slice_segment_flag */
        }
    free(skipped);
    h26x_align_zero(&w); /* the flush wrote rbsp_stop_one_bit */
    return emit(t, &w, len);
}

int mlh_testenc_encode(mlh_testenc *t, const uint8_t *y, const uint8_t *u, const uint8_t *v, const uint8_t *changed,
                       const mlh_enc_params *p, mlh_enc_output *out) {
    memset(out, 0, sizeof *out);
    refs_ack(&t->refs, p->acked_ltr_tokens, p->acked_ltr_count);
    refs_plan plan;
    refs_plan_frame(&t->refs, (int)p->force, &plan);
    size_t len = 0;
    int rc = t->codec == MLH_CODEC_H264 ? h264_frame(t, &plan, y, u, v, changed, &len)
                                         : hevc_frame(t, &plan, y, u, v, changed, &len);
    if (rc) return rc;
    if (plan.idr) t->idr_id++;
    const uint64_t token = refs_commit(&t->refs, &plan);
    out->data = t->out;
    out->len = len;
    out->num_slices = 1;
    out->keyframe = (uint32_t)plan.idr;
    out->has_ltr_token = token != 0;
    out->ltr_token = token;
    out->ltr_refresh = (uint32_t)plan.refresh;
    return MLH_OK;
}
