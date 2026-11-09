/* H.264 and HEVC header writers and the long-term-reference planner (see h26x.h). */
#include "h26x.h"

#include <string.h>

/* ---- Bit writer ------------------------------------------------------------- */

void h26x_bw_init(h26x_bw *w, uint8_t *buf, size_t cap) {
    w->buf = buf;
    w->cap = cap;
    w->bits = 0;
    w->overflow = 0;
    if (cap) memset(buf, 0, cap);
}

static void put_bit(h26x_bw *w, uint32_t b) {
    size_t byte = w->bits >> 3;
    if (byte >= w->cap) {
        w->overflow = 1;
        return;
    }
    if (b) w->buf[byte] |= (uint8_t)(0x80u >> (w->bits & 7));
    w->bits++;
}

void h26x_u(h26x_bw *w, uint32_t v, int n) {
    for (int i = n - 1; i >= 0; i--) put_bit(w, (v >> i) & 1u);
}

void h26x_ue(h26x_bw *w, uint32_t v) {
    uint64_t x = (uint64_t)v + 1;
    int len = 0;
    while ((x >> len) > 1) len++;
    for (int i = 0; i < len; i++) put_bit(w, 0);
    for (int i = len; i >= 0; i--) put_bit(w, (uint32_t)(x >> i) & 1u);
}

void h26x_se(h26x_bw *w, int32_t v) {
    h26x_ue(w, v > 0 ? (uint32_t)(2 * (int64_t)v - 1) : (uint32_t)(-2 * (int64_t)v));
}

void h26x_align_zero(h26x_bw *w) {
    while (w->bits & 7) put_bit(w, 0);
}

void h26x_trailing(h26x_bw *w) {
    put_bit(w, 1);
    h26x_align_zero(w);
}

size_t h26x_nal(uint8_t *out, size_t cap, const uint8_t *rbsp, size_t len) {
    size_t o = 0;
    if (cap < 4) return 0;
    out[o++] = 0;
    out[o++] = 0;
    out[o++] = 0;
    out[o++] = 1;
    int zeros = 0;
    for (size_t i = 0; i < len; i++) {
        /* The NAL header bytes never trip this (their first byte is nonzero). */
        if (zeros >= 2 && rbsp[i] <= 3) {
            if (o >= cap) return 0;
            out[o++] = 3;
            zeros = 0;
        }
        if (o >= cap) return 0;
        out[o++] = rbsp[i];
        zeros = rbsp[i] == 0 ? zeros + 1 : 0;
    }
    return o;
}

/* ---- Long-term reference planner ---------------------------------------------- */

void refs_reset(refs_state *s, int ltr) {
    memset(s, 0, sizeof *s);
    s->ltr = ltr;
    s->pending_lt = -1;
}

void refs_ack(refs_state *s, const uint64_t *tokens, uint32_t n) {
    for (uint32_t i = 0; i < n; i++)
        for (int d = 0; d < REFS_DPB; d++)
            if (s->dpb[d].used && s->dpb[d].token && s->dpb[d].token == tokens[i]) s->dpb[d].acked = 1;
}

static int newest_acked(const refs_state *s) {
    int best = -1;
    for (int d = 0; d < REFS_DPB; d++) {
        const refs_pic *p = &s->dpb[d];
        if (p->used && p->lt_slot >= 0 && p->acked && (best < 0 || p->token > s->dpb[best].token)) best = d;
    }
    return best;
}

static int newest(const refs_state *s) {
    int best = -1;
    for (int d = 0; d < REFS_DPB; d++)
        if (s->dpb[d].used && (best < 0 || s->dpb[d].count > s->dpb[best].count)) best = d;
    return best;
}

static int slot_entry(const refs_state *s, int slot) {
    for (int d = 0; d < REFS_DPB; d++)
        if (s->dpb[d].used && s->dpb[d].lt_slot == slot) return d;
    return -1;
}

void refs_plan_frame(refs_state *s, int force, refs_plan *p) {
    memset(p, 0, sizeof *p);
    p->ref = -1;
    p->mark_slot = -1;
    p->cur = -1;
    const int acked = newest_acked(s);
    const int prev = newest(s);
    p->idr = s->frames == 0 || prev < 0 || force == REFS_FORCE_IDR ||
             (force == REFS_FORCE_LTR_REFRESH && (!s->ltr || acked < 0));
    if (p->idr) {
        p->count = 0;
        p->mark_slot = s->ltr ? 0 : -1;
        p->cur = 0;
        return;
    }
    p->count = s->count;
    p->refresh = force == REFS_FORCE_LTR_REFRESH;
    p->ref = p->refresh ? acked : prev;
    /* Every short-term picture goes after this frame: the next one predicts from this. */
    for (int d = 0; d < REFS_DPB; d++)
        if (s->dpb[d].used && s->dpb[d].lt_slot < 0) p->drop[p->ndrop++] = d;
    if (s->ltr && (p->refresh || s->since_mark + 1 >= REFS_INTERVAL)) {
        /* Into the slot that does not hold the newest acked reference, oldest first. */
        const int keep = acked >= 0 ? s->dpb[acked].lt_slot : -1;
        uint64_t oldest = UINT64_MAX;
        for (int slot = 0; slot < REFS_SLOTS; slot++) {
            if (slot == keep) continue;
            const int e = slot_entry(s, slot);
            const uint64_t t = e < 0 ? 0 : s->dpb[e].token;
            if (t < oldest) {
                oldest = t;
                p->mark_slot = slot;
            }
        }
    }
    /* A buffer no picture still in use holds, and not the reference. */
    for (int d = 0; d < REFS_DPB && p->cur < 0; d++) {
        const refs_pic *e = &s->dpb[d];
        if (d == p->ref) continue;
        if (e->used && e->lt_slot >= 0 && e->lt_slot != p->mark_slot) continue;
        p->cur = d;
    }
}

uint64_t refs_commit(refs_state *s, const refs_plan *p) {
    if (p->idr) {
        memset(s->dpb, 0, sizeof s->dpb);
        s->count = 0;
        s->since_mark = 0;
    } else {
        for (int i = 0; i < p->ndrop; i++) s->dpb[p->drop[i]].used = 0;
        if (p->mark_slot >= 0) {
            const int e = slot_entry(s, p->mark_slot);
            if (e >= 0) s->dpb[e].used = 0;
        }
    }
    refs_pic *c = &s->dpb[p->cur];
    memset(c, 0, sizeof *c);
    c->used = 1;
    c->count = p->count;
    c->lt_slot = p->mark_slot;
    c->surface = (uint32_t)p->cur;
    s->frames++;
    s->count = p->count + 1;
    if (p->mark_slot >= 0) {
        c->token = s->frames; /* frame number from 1 */
        s->since_mark = 0;
    } else {
        s->since_mark++;
    }
    return c->token;
}

/* ---- H.264 ---------------------------------------------------------------------- */

#define FRAME_NUM_MASK ((1u << H264_LOG2_MAX_FRAME_NUM) - 1)

void h264_slice_from_plan(h264_slice *s, const refs_state *st, const refs_plan *p, uint16_t idr_pic_id) {
    memset(s, 0, sizeof *s);
    s->idr = (uint8_t)p->idr;
    s->idr_pic_id = idr_pic_id;
    s->slice_type = p->idr ? 2 : 0;
    s->frame_num = p->count & FRAME_NUM_MASK;
    s->ref_lt = -1;
    s->mark_slot = p->mark_slot;
    if (p->idr) return;
    const refs_pic *r = &st->dpb[p->ref];
    if (r->lt_slot >= 0)
        s->ref_lt = r->lt_slot;
    else
        s->ref_diff = p->count - r->count;
    for (int i = 0; i < p->ndrop; i++) s->drop_diff[s->ndrop++] = p->count - st->dpb[p->drop[i]].count;
}

static void h264_nal_header(h26x_bw *w, int type) {
    h26x_u(w, 0, 1); /* forbidden_zero_bit */
    h26x_u(w, 3, 2); /* nal_ref_idc: every picture is a reference */
    h26x_u(w, (uint32_t)type, 5);
}

static uint32_t mbs(uint32_t px) { return (px + 15) / 16; }

static void h264_vui(h26x_bw *w, const h264_params *p) {
    h26x_u(w, 0, 1); /* aspect_ratio_info_present_flag */
    h26x_u(w, 0, 1); /* overscan_info_present_flag */
    h26x_u(w, 1, 1); /* video_signal_type_present_flag */
    h26x_u(w, 5, 3); /* video_format: unspecified */
    h26x_u(w, p->full_range, 1);
    h26x_u(w, 1, 1); /* colour_description_present_flag */
    h26x_u(w, 1, 8); /* BT.709 primaries */
    h26x_u(w, 1, 8); /* transfer */
    h26x_u(w, 1, 8); /* matrix */
    h26x_u(w, 0, 1); /* chroma_loc_info_present_flag */
    h26x_u(w, p->fps ? 1 : 0, 1);
    if (p->fps) {
        h26x_u(w, 1, 32);          /* num_units_in_tick */
        h26x_u(w, 2 * p->fps, 32); /* time_scale */
        h26x_u(w, 0, 1);           /* fixed_frame_rate_flag */
    }
    h26x_u(w, 0, 1); /* nal_hrd_parameters_present_flag */
    h26x_u(w, 0, 1); /* vcl_hrd_parameters_present_flag */
    h26x_u(w, 0, 1); /* pic_struct_present_flag */
    h26x_u(w, 1, 1); /* bitstream_restriction_flag: no reordering, so decoders output at once */
    h26x_u(w, 1, 1); /* motion_vectors_over_pic_boundaries_flag */
    h26x_ue(w, 0);   /* max_bytes_per_pic_denom */
    h26x_ue(w, 0);   /* max_bits_per_mb_denom */
    h26x_ue(w, 15);  /* log2_max_mv_length_horizontal */
    h26x_ue(w, 15);  /* log2_max_mv_length_vertical */
    h26x_ue(w, 0);   /* max_num_reorder_frames */
    h26x_ue(w, p->max_num_ref_frames);
}

static size_t finish(uint8_t *out, size_t cap, h26x_bw *w) {
    if (w->overflow) return 0;
    return h26x_nal(out, cap, w->buf, w->bits / 8);
}

size_t h264_write_sps(uint8_t *out, size_t cap, const h264_params *p) {
    uint8_t rbsp[256];
    h26x_bw w;
    h26x_bw_init(&w, rbsp, sizeof rbsp);
    h264_nal_header(&w, 7);
    h26x_u(&w, p->profile_idc, 8);
    uint32_t constraints = 0;
    if (p->profile_idc == 66) constraints = 0xC0; /* constrained baseline: set0, set1 */
    if (p->profile_idc == 77) constraints = 0x40; /* main: set1 */
    h26x_u(&w, constraints, 8);
    h26x_u(&w, p->level_idc, 8);
    h26x_ue(&w, 0); /* seq_parameter_set_id */
    if (p->profile_idc == 100) {
        h26x_ue(&w, 1); /* chroma_format_idc 4:2:0 */
        h26x_ue(&w, 0); /* bit_depth_luma_minus8 */
        h26x_ue(&w, 0); /* bit_depth_chroma_minus8 */
        h26x_u(&w, 0, 1); /* qpprime_y_zero_transform_bypass_flag */
        h26x_u(&w, 0, 1); /* seq_scaling_matrix_present_flag */
    }
    h26x_ue(&w, H264_LOG2_MAX_FRAME_NUM - 4);
    h26x_ue(&w, 2); /* pic_order_cnt_type 2: output order is decode order */
    h26x_ue(&w, p->max_num_ref_frames);
    h26x_u(&w, 1, 1); /* gaps_in_frame_num_value_allowed_flag: a client that lost frames still decodes */
    h26x_ue(&w, mbs(p->width) - 1);
    h26x_ue(&w, mbs(p->height) - 1);
    h26x_u(&w, 1, 1); /* frame_mbs_only_flag */
    h26x_u(&w, 1, 1); /* direct_8x8_inference_flag */
    const uint32_t crop_r = (mbs(p->width) * 16 - p->width) / 2, crop_b = (mbs(p->height) * 16 - p->height) / 2;
    h26x_u(&w, crop_r || crop_b, 1);
    if (crop_r || crop_b) {
        h26x_ue(&w, 0);
        h26x_ue(&w, crop_r);
        h26x_ue(&w, 0);
        h26x_ue(&w, crop_b);
    }
    h26x_u(&w, 1, 1); /* vui_parameters_present_flag */
    h264_vui(&w, p);
    h26x_trailing(&w);
    return finish(out, cap, &w);
}

size_t h264_write_pps(uint8_t *out, size_t cap, const h264_params *p) {
    uint8_t rbsp[64];
    h26x_bw w;
    h26x_bw_init(&w, rbsp, sizeof rbsp);
    h264_nal_header(&w, 8);
    h26x_ue(&w, 0); /* pic_parameter_set_id */
    h26x_ue(&w, 0); /* seq_parameter_set_id */
    h26x_u(&w, p->cabac, 1);
    h26x_u(&w, 0, 1); /* bottom_field_pic_order_in_frame_present_flag */
    h26x_ue(&w, 0);   /* num_slice_groups_minus1 */
    h26x_ue(&w, 0);   /* num_ref_idx_l0_default_active_minus1 */
    h26x_ue(&w, 0);   /* num_ref_idx_l1_default_active_minus1 */
    h26x_u(&w, 0, 1); /* weighted_pred_flag */
    h26x_u(&w, 0, 2); /* weighted_bipred_idc */
    h26x_se(&w, p->pic_init_qp - 26);
    h26x_se(&w, 0);   /* pic_init_qs_minus26 */
    h26x_se(&w, 0);   /* chroma_qp_index_offset */
    h26x_u(&w, 1, 1); /* deblocking_filter_control_present_flag */
    h26x_u(&w, 0, 1); /* constrained_intra_pred_flag */
    h26x_u(&w, 0, 1); /* redundant_pic_cnt_present_flag */
    if (p->profile_idc == 100) {
        h26x_u(&w, p->transform_8x8, 1);
        h26x_u(&w, 0, 1); /* pic_scaling_matrix_present_flag */
        h26x_se(&w, 0);   /* second_chroma_qp_index_offset */
    }
    h26x_trailing(&w);
    return finish(out, cap, &w);
}

size_t h264_write_slice_header(h26x_bw *w, const h264_params *p, const h264_slice *s) {
    h26x_u(w, 1, 32); /* start code */
    h264_nal_header(w, s->idr ? 5 : 1);
    h26x_ue(w, s->first_mb);
    h26x_ue(w, s->slice_type + 5u);
    h26x_ue(w, 0); /* pic_parameter_set_id */
    h26x_u(w, s->frame_num & FRAME_NUM_MASK, H264_LOG2_MAX_FRAME_NUM);
    if (s->idr) h26x_ue(w, s->idr_pic_id);
    /* pic_order_cnt_type 2: nothing. */
    if (s->slice_type == 0) {
        h26x_u(w, 1, 1); /* num_ref_idx_active_override_flag */
        h26x_ue(w, 0);   /* num_ref_idx_l0_active_minus1: one reference */
        /* ref_pic_list_modification: entry 0 is the picture the plan chose. */
        h26x_u(w, 1, 1);
        if (s->ref_lt >= 0) {
            h26x_ue(w, 2); /* long_term_pic_num */
            h26x_ue(w, (uint32_t)s->ref_lt);
        } else {
            h26x_ue(w, 0); /* subtract from CurrPicNum */
            h26x_ue(w, s->ref_diff - 1);
        }
        h26x_ue(w, 3);
    }
    /* dec_ref_pic_marking (nal_ref_idc != 0) */
    if (s->idr) {
        h26x_u(w, 0, 1);                   /* no_output_of_prior_pics_flag */
        h26x_u(w, s->mark_slot == 0, 1);   /* long_term_reference_flag: LongTermFrameIdx 0 */
    } else {
        h26x_u(w, 1, 1); /* adaptive_ref_pic_marking_mode_flag */
        for (int i = 0; i < s->ndrop; i++) {
            h26x_ue(w, 1); /* short-term unused */
            h26x_ue(w, s->drop_diff[i] - 1);
        }
        if (s->mark_slot >= 0) {
            h26x_ue(w, 4); /* MaxLongTermFrameIdx = REFS_SLOTS - 1 */
            h26x_ue(w, REFS_SLOTS);
            h26x_ue(w, 6); /* current picture long-term, replacing whatever held the slot */
            h26x_ue(w, (uint32_t)s->mark_slot);
        }
        h26x_ue(w, 0);
    }
    if (p->cabac && s->slice_type != 2) h26x_ue(w, s->cabac_init_idc);
    h26x_se(w, s->slice_qp_delta);
    h26x_ue(w, s->disable_deblocking);
    if (s->disable_deblocking != 1) {
        h26x_se(w, 0); /* slice_alpha_c0_offset_div2 */
        h26x_se(w, 0); /* slice_beta_offset_div2 */
    }
    return w->overflow ? 0 : w->bits;
}

/* ---- HEVC ------------------------------------------------------------------------ */

#define POC_LSB_MASK ((1u << HEVC_LOG2_MAX_POC_LSB) - 1)

void hevc_slice_from_plan(hevc_slice *s, const refs_state *st, const refs_plan *p) {
    memset(s, 0, sizeof *s);
    s->idr = (uint8_t)p->idr;
    s->slice_type = p->idr ? 2 : 1;
    s->poc = p->count;
    s->max_merge_cand = 5;
    if (p->idr) return;
    /* The RPS is the planner's buffer: long-term pictures (the reference among them is
     * used), and the short-term reference. Short-term pictures that are not the
     * reference are left out, which drops them. */
    for (int d = 0; d < REFS_DPB; d++) {
        const refs_pic *e = &st->dpb[d];
        if (!e->used) continue;
        if (e->lt_slot >= 0) {
            s->lt_poc[s->nlt] = e->count;
            s->lt_used[s->nlt] = d == p->ref;
            s->nlt++;
        } else if (d == p->ref) {
            s->st_delta[s->nst] = p->count - e->count;
            s->st_used[s->nst] = 1;
            s->nst++;
        }
    }
    /* Short-term deltas ascending; long-term by POC descending (MSB cycles ascending). */
    for (int i = 1; i < s->nst; i++)
        for (int j = i; j > 0 && s->st_delta[j] < s->st_delta[j - 1]; j--) {
            uint32_t t = s->st_delta[j];
            s->st_delta[j] = s->st_delta[j - 1];
            s->st_delta[j - 1] = t;
            uint8_t u = s->st_used[j];
            s->st_used[j] = s->st_used[j - 1];
            s->st_used[j - 1] = u;
        }
    for (int i = 1; i < s->nlt; i++)
        for (int j = i; j > 0 && s->lt_poc[j] > s->lt_poc[j - 1]; j--) {
            uint32_t t = s->lt_poc[j];
            s->lt_poc[j] = s->lt_poc[j - 1];
            s->lt_poc[j - 1] = t;
            uint8_t u = s->lt_used[j];
            s->lt_used[j] = s->lt_used[j - 1];
            s->lt_used[j - 1] = u;
        }
}

static void hevc_nal_header(h26x_bw *w, int type) {
    h26x_u(w, 0, 1);
    h26x_u(w, (uint32_t)type, 6);
    h26x_u(w, 0, 6); /* nuh_layer_id */
    h26x_u(w, 1, 3); /* nuh_temporal_id_plus1 */
}

static void hevc_ptl(h26x_bw *w, const hevc_params *p) {
    h26x_u(w, 0, 2);          /* general_profile_space */
    h26x_u(w, 0, 1);          /* general_tier_flag */
    h26x_u(w, 1, 5);          /* general_profile_idc: Main */
    h26x_u(w, 0x60000000, 32); /* compatible with Main and Main 10 */
    h26x_u(w, 1, 1);          /* progressive_source */
    h26x_u(w, 0, 1);          /* interlaced_source */
    h26x_u(w, 0, 1);          /* non_packed_constraint */
    h26x_u(w, 1, 1);          /* frame_only_constraint */
    h26x_u(w, 0, 32);         /* 43 reserved bits and general_inbld_flag */
    h26x_u(w, 0, 12);
    h26x_u(w, p->level_idc, 8);
}

static uint32_t hevc_min_cb(const hevc_params *p) { return 1u << p->log2_min_cb; }
static uint32_t round_up(uint32_t v, uint32_t a) { return (v + a - 1) / a * a; }

size_t hevc_write_vps(uint8_t *out, size_t cap, const hevc_params *p) {
    uint8_t rbsp[128];
    h26x_bw w;
    h26x_bw_init(&w, rbsp, sizeof rbsp);
    hevc_nal_header(&w, 32);
    h26x_u(&w, 0, 4);      /* vps_video_parameter_set_id */
    h26x_u(&w, 1, 1);      /* vps_base_layer_internal_flag */
    h26x_u(&w, 1, 1);      /* vps_base_layer_available_flag */
    h26x_u(&w, 0, 6);      /* vps_max_layers_minus1 */
    h26x_u(&w, 0, 3);      /* vps_max_sub_layers_minus1 */
    h26x_u(&w, 1, 1);      /* vps_temporal_id_nesting_flag */
    h26x_u(&w, 0xFFFF, 16);
    hevc_ptl(&w, p);
    h26x_u(&w, 1, 1); /* vps_sub_layer_ordering_info_present_flag */
    h26x_ue(&w, p->max_dec_pic_buffering - 1u);
    h26x_ue(&w, 0); /* vps_max_num_reorder_pics */
    h26x_ue(&w, 0); /* vps_max_latency_increase_plus1 */
    h26x_u(&w, 0, 6); /* vps_max_layer_id */
    h26x_ue(&w, 0);   /* vps_num_layer_sets_minus1 */
    h26x_u(&w, 0, 1); /* vps_timing_info_present_flag */
    h26x_u(&w, 0, 1); /* vps_extension_flag */
    h26x_trailing(&w);
    return finish(out, cap, &w);
}

size_t hevc_write_sps(uint8_t *out, size_t cap, const hevc_params *p) {
    uint8_t rbsp[256];
    h26x_bw w;
    h26x_bw_init(&w, rbsp, sizeof rbsp);
    hevc_nal_header(&w, 33);
    h26x_u(&w, 0, 4); /* sps_video_parameter_set_id */
    h26x_u(&w, 0, 3); /* sps_max_sub_layers_minus1 */
    h26x_u(&w, 1, 1); /* sps_temporal_id_nesting_flag */
    hevc_ptl(&w, p);
    h26x_ue(&w, 0); /* sps_seq_parameter_set_id */
    h26x_ue(&w, 1); /* chroma_format_idc 4:2:0 */
    const uint32_t cw = round_up(p->width, hevc_min_cb(p)), ch = round_up(p->height, hevc_min_cb(p));
    h26x_ue(&w, cw);
    h26x_ue(&w, ch);
    const uint32_t crop_r = (cw - p->width) / 2, crop_b = (ch - p->height) / 2;
    h26x_u(&w, crop_r || crop_b, 1);
    if (crop_r || crop_b) {
        h26x_ue(&w, 0);
        h26x_ue(&w, crop_r);
        h26x_ue(&w, 0);
        h26x_ue(&w, crop_b);
    }
    h26x_ue(&w, 0); /* bit_depth_luma_minus8 */
    h26x_ue(&w, 0); /* bit_depth_chroma_minus8 */
    h26x_ue(&w, HEVC_LOG2_MAX_POC_LSB - 4);
    h26x_u(&w, 1, 1); /* sps_sub_layer_ordering_info_present_flag */
    h26x_ue(&w, p->max_dec_pic_buffering - 1u);
    h26x_ue(&w, 0); /* sps_max_num_reorder_pics */
    h26x_ue(&w, 0); /* sps_max_latency_increase_plus1 */
    h26x_ue(&w, p->log2_min_cb - 3u);
    h26x_ue(&w, (uint32_t)(p->log2_ctb - p->log2_min_cb));
    h26x_ue(&w, p->log2_min_tb - 2u);
    h26x_ue(&w, (uint32_t)(p->log2_max_tb - p->log2_min_tb));
    h26x_ue(&w, p->max_transform_hierarchy_depth); /* inter */
    h26x_ue(&w, p->max_transform_hierarchy_depth); /* intra */
    h26x_u(&w, 0, 1); /* scaling_list_enabled_flag */
    h26x_u(&w, p->amp, 1);
    h26x_u(&w, p->sao, 1);
    h26x_u(&w, p->pcm, 1);
    if (p->pcm) {
        h26x_u(&w, 7, 4); /* pcm_sample_bit_depth_luma_minus1 */
        h26x_u(&w, 7, 4); /* pcm_sample_bit_depth_chroma_minus1 */
        h26x_ue(&w, p->pcm_log2_min - 3u);
        h26x_ue(&w, (uint32_t)(p->pcm_log2_max - p->pcm_log2_min));
        h26x_u(&w, 1, 1); /* pcm_loop_filter_disabled_flag */
    }
    h26x_ue(&w, 0);   /* num_short_term_ref_pic_sets: every slice carries its own */
    h26x_u(&w, 1, 1); /* long_term_ref_pics_present_flag */
    h26x_ue(&w, 0);   /* num_long_term_ref_pics_sps */
    h26x_u(&w, p->temporal_mvp, 1);
    h26x_u(&w, p->strong_intra_smoothing, 1);
    h26x_u(&w, 1, 1); /* vui_parameters_present_flag */
    h26x_u(&w, 0, 1); /* aspect_ratio_info_present_flag */
    h26x_u(&w, 0, 1); /* overscan_info_present_flag */
    h26x_u(&w, 1, 1); /* video_signal_type_present_flag */
    h26x_u(&w, 5, 3);
    h26x_u(&w, p->full_range, 1);
    h26x_u(&w, 1, 1);
    h26x_u(&w, 1, 8);
    h26x_u(&w, 1, 8);
    h26x_u(&w, 1, 8);
    h26x_u(&w, 0, 1); /* chroma_loc_info_present_flag */
    h26x_u(&w, 0, 1); /* neutral_chroma_indication_flag */
    h26x_u(&w, 0, 1); /* field_seq_flag */
    h26x_u(&w, 0, 1); /* frame_field_info_present_flag */
    h26x_u(&w, 0, 1); /* default_display_window_flag */
    h26x_u(&w, p->fps ? 1 : 0, 1);
    if (p->fps) {
        h26x_u(&w, 1, 32);
        h26x_u(&w, p->fps, 32);
        h26x_u(&w, 0, 1); /* vui_poc_proportional_to_timing_flag */
        h26x_u(&w, 0, 1); /* vui_hrd_parameters_present_flag */
    }
    h26x_u(&w, 1, 1); /* bitstream_restriction_flag */
    h26x_u(&w, 0, 1); /* tiles_fixed_structure_flag */
    h26x_u(&w, 1, 1); /* motion_vectors_over_pic_boundaries_flag */
    h26x_u(&w, 1, 1); /* restricted_ref_pic_lists_flag */
    h26x_ue(&w, 0);   /* min_spatial_segmentation_idc */
    h26x_ue(&w, 0);   /* max_bytes_per_pic_denom */
    h26x_ue(&w, 0);   /* max_bits_per_min_cu_denom */
    h26x_ue(&w, 15);
    h26x_ue(&w, 15);
    h26x_u(&w, 0, 1); /* sps_extension_present_flag */
    h26x_trailing(&w);
    return finish(out, cap, &w);
}

size_t hevc_write_pps(uint8_t *out, size_t cap, const hevc_params *p) {
    uint8_t rbsp[64];
    h26x_bw w;
    h26x_bw_init(&w, rbsp, sizeof rbsp);
    hevc_nal_header(&w, 34);
    h26x_ue(&w, 0);   /* pps_pic_parameter_set_id */
    h26x_ue(&w, 0);   /* pps_seq_parameter_set_id */
    h26x_u(&w, 0, 1); /* dependent_slice_segments_enabled_flag */
    h26x_u(&w, 0, 1); /* output_flag_present_flag */
    h26x_u(&w, 0, 3); /* num_extra_slice_header_bits */
    h26x_u(&w, p->sign_data_hiding, 1);
    h26x_u(&w, 0, 1); /* cabac_init_present_flag */
    h26x_ue(&w, 0);   /* num_ref_idx_l0_default_active_minus1 */
    h26x_ue(&w, 0);   /* num_ref_idx_l1_default_active_minus1 */
    h26x_se(&w, p->init_qp - 26);
    h26x_u(&w, 0, 1); /* constrained_intra_pred_flag */
    h26x_u(&w, p->transform_skip, 1);
    h26x_u(&w, p->cu_qp_delta, 1);
    if (p->cu_qp_delta) h26x_ue(&w, 0); /* diff_cu_qp_delta_depth */
    h26x_se(&w, 0);   /* pps_cb_qp_offset */
    h26x_se(&w, 0);   /* pps_cr_qp_offset */
    h26x_u(&w, 0, 1); /* pps_slice_chroma_qp_offsets_present_flag */
    h26x_u(&w, 0, 1); /* weighted_pred_flag */
    h26x_u(&w, 0, 1); /* weighted_bipred_flag */
    h26x_u(&w, 0, 1); /* transquant_bypass_enabled_flag */
    h26x_u(&w, 0, 1); /* tiles_enabled_flag */
    h26x_u(&w, 0, 1); /* entropy_coding_sync_enabled_flag */
    h26x_u(&w, p->loop_filter_across_slices, 1);
    h26x_u(&w, 1, 1); /* deblocking_filter_control_present_flag */
    h26x_u(&w, 0, 1); /* deblocking_filter_override_enabled_flag */
    h26x_u(&w, p->deblocking_disabled, 1);
    h26x_u(&w, 0, 1); /* pps_scaling_list_data_present_flag */
    h26x_u(&w, 0, 1); /* lists_modification_present_flag */
    h26x_ue(&w, 0);   /* log2_parallel_merge_level_minus2 */
    h26x_u(&w, 0, 1); /* slice_segment_header_extension_present_flag */
    h26x_u(&w, 0, 1); /* pps_extension_present_flag */
    h26x_trailing(&w);
    return finish(out, cap, &w);
}

static int ceil_log2(uint32_t v) {
    int n = 0;
    while ((1u << n) < v) n++;
    return n;
}

size_t hevc_write_slice_header(h26x_bw *w, const hevc_params *p, const hevc_slice *s) {
    h26x_u(w, 1, 32);
    hevc_nal_header(w, s->idr ? 19 : 1); /* IDR_W_RADL, TRAIL_R */
    h26x_u(w, s->address == 0, 1);       /* first_slice_segment_in_pic_flag */
    if (s->idr) h26x_u(w, 0, 1);         /* no_output_of_prior_pics_flag */
    h26x_ue(w, 0);                       /* slice_pic_parameter_set_id */
    if (s->address) {
        const uint32_t ctb = 1u << p->log2_ctb;
        const uint32_t ctbs = ((p->width + ctb - 1) / ctb) * ((p->height + ctb - 1) / ctb);
        h26x_u(w, s->address, ceil_log2(ctbs));
    }
    h26x_ue(w, s->slice_type);
    if (!s->idr) {
        h26x_u(w, s->poc & POC_LSB_MASK, HEVC_LOG2_MAX_POC_LSB);
        h26x_u(w, 0, 1); /* short_term_ref_pic_set_sps_flag */
        /* st_ref_pic_set(0): no inter-RPS prediction for index 0. */
        h26x_ue(w, (uint32_t)s->nst); /* num_negative_pics */
        h26x_ue(w, 0);                /* num_positive_pics */
        uint32_t prev = 0;
        for (int i = 0; i < s->nst; i++) {
            h26x_ue(w, s->st_delta[i] - prev - 1);
            h26x_u(w, s->st_used[i], 1);
            prev = s->st_delta[i];
        }
        h26x_ue(w, (uint32_t)s->nlt); /* num_long_term_pics */
        const uint32_t cur_msb = s->poc & ~POC_LSB_MASK;
        uint32_t prev_cycle = 0;
        for (int i = 0; i < s->nlt; i++) {
            const uint32_t lsb = s->lt_poc[i] & POC_LSB_MASK;
            const uint32_t cycle = (cur_msb - (s->lt_poc[i] & ~POC_LSB_MASK)) >> HEVC_LOG2_MAX_POC_LSB;
            h26x_u(w, lsb, HEVC_LOG2_MAX_POC_LSB); /* poc_lsb_lt */
            h26x_u(w, s->lt_used[i], 1);
            h26x_u(w, 1, 1); /* delta_poc_msb_present_flag */
            h26x_ue(w, cycle - prev_cycle);
            prev_cycle = cycle;
        }
        if (p->temporal_mvp) h26x_u(w, 0, 1); /* slice_temporal_mvp_enabled_flag */
    }
    if (p->sao) {
        h26x_u(w, s->sao_luma, 1);
        h26x_u(w, s->sao_chroma, 1);
    }
    if (s->slice_type == 1) {
        h26x_u(w, 1, 1); /* num_ref_idx_active_override_flag */
        h26x_ue(w, 0);   /* one reference */
        h26x_ue(w, 5u - s->max_merge_cand);
    }
    h26x_se(w, s->slice_qp_delta);
    if (p->loop_filter_across_slices && (s->sao_luma || s->sao_chroma || !p->deblocking_disabled))
        h26x_u(w, 1, 1); /* slice_loop_filter_across_slices_enabled_flag */
    h26x_trailing(w); /* byte_alignment(): a one, then zeros */
    return w->overflow ? 0 : w->bits;
}
