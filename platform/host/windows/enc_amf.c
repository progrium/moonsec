/* AMD AMF through amfrt64.dll, loaded at run time (no link-time AMD dependency).
 * Takes the BGRA D3D11 texture directly (AMF_SURFACE_BGRA: the encoder converts to NV12
 * on the GPU), synchronous use (QueryTimeout), ultra-low-latency usage, CBR with a
 * one-frame VBV, no periodic IDR, no B-frames, no pre-analysis, and long-term references
 * through MarkCurrentWithLTRIndex / ForceLTRReferenceBitfield.
 *
 * Untested on hardware so far (CI has no AMD GPU): only create's not-found path runs
 * there. Headers: third_party/amf (AMF SDK v1.5.3, MIT). */
#include "enc_internal.h"

#include <string.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-function"
#pragma clang diagnostic ignored "-Wunused-variable"
#pragma clang diagnostic ignored "-Wmissing-field-initializers"
#include "core/Factory.h"
#include "components/VideoEncoderVCE.h"
#include "components/VideoEncoderHEVC.h"
#pragma clang diagnostic pop

#define AMF_LTR_SLOTS 2
/* Mark a long-term reference this often (frames), as the NVENC backend does. */
#define AMF_LTR_INTERVAL 15
/* Oldest runtime we use: LTR, QueryTimeout and the ULL usage are all in 1.4.x. */
#define AMF_MIN_RUNTIME AMF_MAKE_FULL_VERSION(1, 4, 0, 0)
/* QueryOutput blocks up to this long per call; encode gives up after AMF_WAIT_MS. */
#define AMF_QUERY_MS 50
#define AMF_WAIT_MS 2000

/* GUID AMF reads from ID3D11Texture2D private data to pick an array slice (the value
 * FFmpeg and AMF's samples use). */
static const GUID amf_texture_array_index = {0x28115527, 0xe7c3, 0x4b66, {0x99, 0xd3, 0x4f, 0x2a, 0xe6, 0xb4, 0x7f, 0xaf}};

typedef struct amf_ltr {
    uint64_t token; /* 0 = empty */
    int acked;
} amf_ltr;

typedef struct amf_enc {
    msw_enc base;
    HMODULE dll;
    AMFFactory *factory;
    AMFContext *context;
    AMFComponent *enc;
    int h264, hevc, ltr_supported;
    int hevc_active;
    uint64_t bitrate;
    uint64_t frame;
    amf_ltr ltr[AMF_LTR_SLOTS];
    uint64_t since_mark;
} amf_enc;

/* AMF_RESULT as an HRESULT in FACILITY_ITF (0x8004_7Dxx); missing hardware maps to
 * not-found and unsupported settings to DXGI_ERROR_UNSUPPORTED. */
static HRESULT amf_hr(AMF_RESULT r) {
    switch (r) {
    case AMF_OK: return S_OK;
    case AMF_NO_DEVICE:
    case AMF_ENCODER_NOT_PRESENT: return MSW_E_NOTFOUND;
    case AMF_NOT_SUPPORTED:
    case AMF_CODEC_NOT_SUPPORTED:
    case AMF_SURFACE_FORMAT_NOT_SUPPORTED:
    case AMF_NOT_IMPLEMENTED: return MSW_DXGI_ERROR_UNSUPPORTED;
    case AMF_OUT_OF_MEMORY: return E_OUTOFMEMORY;
    case AMF_INVALID_ARG:
    case AMF_INVALID_POINTER: return E_INVALIDARG;
    default: return MAKE_HRESULT(1, FACILITY_ITF, 0x7D00 + (int)r);
    }
}

static AMF_RESULT set_i64(AMFComponent *c, const wchar_t *name, amf_int64 v) {
    AMFVariantStruct var;
    AMFVariantInit(&var);
    AMFVariantAssignInt64(&var, v);
    return c->pVtbl->SetProperty(c, name, var);
}

static AMF_RESULT set_bool(AMFComponent *c, const wchar_t *name, int v) {
    AMFVariantStruct var;
    AMFVariantInit(&var);
    AMFVariantAssignBool(&var, v ? 1 : 0);
    return c->pVtbl->SetProperty(c, name, var);
}

static AMF_RESULT set_rate(AMFComponent *c, const wchar_t *name, uint32_t fps) {
    AMFVariantStruct var;
    AMFVariantInit(&var);
    AMFRate r = {fps, 1};
    AMFVariantAssignRate(&var, &r);
    return c->pVtbl->SetProperty(c, name, var);
}

static AMF_RESULT surf_i64(AMFSurface *s, const wchar_t *name, amf_int64 v) {
    AMFVariantStruct var;
    AMFVariantInit(&var);
    AMFVariantAssignInt64(&var, v);
    return s->pVtbl->SetProperty(s, name, var);
}

static int get_i64(AMFData *d, const wchar_t *name, amf_int64 *out) {
    AMFVariantStruct var;
    AMFVariantInit(&var);
    if (d->pVtbl->GetProperty(d, name, &var) != AMF_OK) return 0;
    if (var.type == AMF_VARIANT_INT64) *out = var.int64Value;
    else if (var.type == AMF_VARIANT_BOOL) *out = var.boolValue;
    else return 0;
    return 1;
}

/* Property names that differ between the H.264 and HEVC components. */
typedef struct amf_names {
    const wchar_t *component, *usage, *profile, *rc, *target, *peak, *vbv, *vbv_fullness, *hrd, *filler,
        *framerate, *slices, *lowlatency, *preanalysis, *query_timeout, *max_ltr, *ltr_mode, *force_type, *mark_ltr,
        *use_ltr, *out_type, *out_marked;
    amf_int64 v_usage_ull, v_cbr, v_profile, v_type_idr, v_out_idr, v_ltr_keep;
} amf_names;

static const amf_names names_avc = {
    AMFVideoEncoderVCE_AVC,
    AMF_VIDEO_ENCODER_USAGE,
    AMF_VIDEO_ENCODER_PROFILE,
    AMF_VIDEO_ENCODER_RATE_CONTROL_METHOD,
    AMF_VIDEO_ENCODER_TARGET_BITRATE,
    AMF_VIDEO_ENCODER_PEAK_BITRATE,
    AMF_VIDEO_ENCODER_VBV_BUFFER_SIZE,
    AMF_VIDEO_ENCODER_INITIAL_VBV_BUFFER_FULLNESS,
    AMF_VIDEO_ENCODER_ENFORCE_HRD,
    AMF_VIDEO_ENCODER_FILLER_DATA_ENABLE,
    AMF_VIDEO_ENCODER_FRAMERATE,
    AMF_VIDEO_ENCODER_SLICES_PER_FRAME,
    AMF_VIDEO_ENCODER_LOWLATENCY_MODE,
    AMF_VIDEO_ENCODER_PRE_ANALYSIS_ENABLE,
    AMF_VIDEO_ENCODER_QUERY_TIMEOUT,
    AMF_VIDEO_ENCODER_MAX_LTR_FRAMES,
    AMF_VIDEO_ENCODER_LTR_MODE,
    AMF_VIDEO_ENCODER_FORCE_PICTURE_TYPE,
    AMF_VIDEO_ENCODER_MARK_CURRENT_WITH_LTR_INDEX,
    AMF_VIDEO_ENCODER_FORCE_LTR_REFERENCE_BITFIELD,
    AMF_VIDEO_ENCODER_OUTPUT_DATA_TYPE,
    AMF_VIDEO_ENCODER_OUTPUT_MARKED_LTR_INDEX,
    AMF_VIDEO_ENCODER_USAGE_ULTRA_LOW_LATENCY,
    AMF_VIDEO_ENCODER_RATE_CONTROL_METHOD_CBR,
    AMF_VIDEO_ENCODER_PROFILE_HIGH,
    AMF_VIDEO_ENCODER_PICTURE_TYPE_IDR,
    AMF_VIDEO_ENCODER_OUTPUT_DATA_TYPE_IDR,
    AMF_VIDEO_ENCODER_LTR_MODE_KEEP_UNUSED,
};

static const amf_names names_hevc = {
    AMFVideoEncoder_HEVC,
    AMF_VIDEO_ENCODER_HEVC_USAGE,
    AMF_VIDEO_ENCODER_HEVC_PROFILE,
    AMF_VIDEO_ENCODER_HEVC_RATE_CONTROL_METHOD,
    AMF_VIDEO_ENCODER_HEVC_TARGET_BITRATE,
    AMF_VIDEO_ENCODER_HEVC_PEAK_BITRATE,
    AMF_VIDEO_ENCODER_HEVC_VBV_BUFFER_SIZE,
    AMF_VIDEO_ENCODER_HEVC_INITIAL_VBV_BUFFER_FULLNESS,
    AMF_VIDEO_ENCODER_HEVC_ENFORCE_HRD,
    AMF_VIDEO_ENCODER_HEVC_FILLER_DATA_ENABLE,
    AMF_VIDEO_ENCODER_HEVC_FRAMERATE,
    AMF_VIDEO_ENCODER_HEVC_SLICES_PER_FRAME,
    AMF_VIDEO_ENCODER_HEVC_LOWLATENCY_MODE,
    AMF_VIDEO_ENCODER_HEVC_PRE_ANALYSIS_ENABLE,
    AMF_VIDEO_ENCODER_HEVC_QUERY_TIMEOUT,
    AMF_VIDEO_ENCODER_HEVC_MAX_LTR_FRAMES,
    AMF_VIDEO_ENCODER_HEVC_LTR_MODE,
    AMF_VIDEO_ENCODER_HEVC_FORCE_PICTURE_TYPE,
    AMF_VIDEO_ENCODER_HEVC_MARK_CURRENT_WITH_LTR_INDEX,
    AMF_VIDEO_ENCODER_HEVC_FORCE_LTR_REFERENCE_BITFIELD,
    AMF_VIDEO_ENCODER_HEVC_OUTPUT_DATA_TYPE,
    AMF_VIDEO_ENCODER_HEVC_OUTPUT_MARKED_LTR_INDEX,
    AMF_VIDEO_ENCODER_HEVC_USAGE_ULTRA_LOW_LATENCY,
    AMF_VIDEO_ENCODER_HEVC_RATE_CONTROL_METHOD_CBR,
    AMF_VIDEO_ENCODER_HEVC_PROFILE_MAIN,
    AMF_VIDEO_ENCODER_HEVC_PICTURE_TYPE_IDR,
    AMF_VIDEO_ENCODER_HEVC_OUTPUT_DATA_TYPE_IDR,
    AMF_VIDEO_ENCODER_HEVC_LTR_MODE_KEEP_UNUSED,
};

static void amf_close(amf_enc *a) {
    if (a->enc) {
        a->enc->pVtbl->Terminate(a->enc);
        a->enc->pVtbl->Release(a->enc);
        a->enc = NULL;
    }
}

/* Creates and initializes an encoder component for `codec` with the low-latency
 * settings. `ltr` asks for AMF_LTR_SLOTS long-term references. */
static HRESULT amf_open(amf_enc *a, uint32_t codec, uint32_t w, uint32_t h, uint32_t fps, uint64_t bps,
                        uint32_t slices, int ltr, AMFComponent **out) {
    const amf_names *n = codec == MSW_CODEC_HEVC ? &names_hevc : &names_avc;
    AMFComponent *c = NULL;
    AMF_RESULT r = a->factory->pVtbl->CreateComponent(a->factory, a->context, n->component, &c);
    if (r != AMF_OK) return amf_hr(r);
    /* Usage first: it resets every other property to its defaults. */
    r = set_i64(c, n->usage, n->v_usage_ull);
    if (r == AMF_OK) r = set_i64(c, n->profile, n->v_profile);
    if (codec == MSW_CODEC_HEVC) {
        set_i64(c, AMF_VIDEO_ENCODER_HEVC_GOP_SIZE, 0);
        set_i64(c, AMF_VIDEO_ENCODER_HEVC_NUM_GOPS_PER_IDR, 0); /* no periodic IDR */
        set_i64(c, AMF_VIDEO_ENCODER_HEVC_HEADER_INSERTION_MODE, AMF_VIDEO_ENCODER_HEVC_HEADER_INSERTION_MODE_IDR_ALIGNED);
        AMFVariantStruct var;
        AMFVariantInit(&var);
        AMFSize sz = {(amf_int32)w, (amf_int32)h};
        AMFVariantAssignSize(&var, &sz);
        c->pVtbl->SetProperty(c, AMF_VIDEO_ENCODER_HEVC_FRAMESIZE, var);
    } else {
        set_i64(c, AMF_VIDEO_ENCODER_IDR_PERIOD, 0); /* no periodic IDR */
        set_i64(c, AMF_VIDEO_ENCODER_B_PIC_PATTERN, 0);
        set_i64(c, AMF_VIDEO_ENCODER_HEADER_INSERTION_SPACING, 0);
        set_i64(c, AMF_VIDEO_ENCODER_INPUT_COLOR_PROFILE, AMF_VIDEO_CONVERTER_COLOR_PROFILE_709);
        set_i64(c, AMF_VIDEO_ENCODER_OUTPUT_COLOR_PROFILE, AMF_VIDEO_CONVERTER_COLOR_PROFILE_709);
        AMFVariantStruct var;
        AMFVariantInit(&var);
        AMFSize sz = {(amf_int32)w, (amf_int32)h};
        AMFVariantAssignSize(&var, &sz);
        c->pVtbl->SetProperty(c, AMF_VIDEO_ENCODER_FRAMESIZE, var);
    }
    if (r == AMF_OK) r = set_i64(c, n->rc, n->v_cbr);
    if (r == AMF_OK) r = set_rate(c, n->framerate, fps);
    if (r == AMF_OK) r = set_i64(c, n->target, (amf_int64)bps);
    if (r == AMF_OK) r = set_i64(c, n->peak, (amf_int64)bps);
    if (r == AMF_OK) r = set_i64(c, n->vbv, (amf_int64)(bps / fps)); /* one frame */
    set_i64(c, n->vbv_fullness, 64);
    set_bool(c, n->hrd, 1);
    set_bool(c, n->filler, 0);
    set_bool(c, n->lowlatency, 1);
    set_bool(c, n->preanalysis, 0);
    set_i64(c, n->slices, slices ? slices : 1);
    set_i64(c, n->query_timeout, AMF_QUERY_MS);
    if (r == AMF_OK && ltr) {
        r = set_i64(c, n->max_ltr, AMF_LTR_SLOTS);
        if (r == AMF_OK) r = set_i64(c, n->ltr_mode, n->v_ltr_keep);
    }
    if (r == AMF_OK) r = c->pVtbl->Init(c, AMF_SURFACE_BGRA, (amf_int32)w, (amf_int32)h);
    if (r != AMF_OK) {
        c->pVtbl->Terminate(c);
        c->pVtbl->Release(c);
        return amf_hr(r);
    }
    *out = c;
    return S_OK;
}

/* Whether `codec` opens at all, and with long-term references. */
static void amf_probe(amf_enc *a, uint32_t codec, int *have, int *ltr) {
    AMFComponent *c = NULL;
    *have = *ltr = 0;
    if (SUCCEEDED(amf_open(a, codec, 640, 360, 60, 2000000, 1, 1, &c))) {
        *have = *ltr = 1;
    } else if (SUCCEEDED(amf_open(a, codec, 640, 360, 60, 2000000, 1, 0, &c))) {
        *have = 1;
    }
    if (c) {
        c->pVtbl->Terminate(c);
        c->pVtbl->Release(c);
    }
}

static void amf_caps(const msw_enc *e, msw_enc_caps *out) {
    const amf_enc *a = (const amf_enc *)e;
    out->h264 = (uint32_t)a->h264;
    out->hevc = (uint32_t)a->hevc;
    out->ltr = (uint32_t)a->ltr_supported;
    out->max_slices = 4;
    out->gpu_input = 1;
}

static HRESULT amf_configure(msw_enc *e, const msw_enc_config *cfg) {
    amf_enc *a = (amf_enc *)e;
    if ((cfg->codec == MSW_CODEC_HEVC && !a->hevc) || (cfg->codec == MSW_CODEC_H264 && !a->h264) ||
        (cfg->codec != MSW_CODEC_H264 && cfg->codec != MSW_CODEC_HEVC))
        return MSW_DXGI_ERROR_UNSUPPORTED;
    amf_close(a);
    const int ltr = cfg->ltr && a->ltr_supported;
    HRESULT hr = amf_open(a, cfg->codec, cfg->width, cfg->height, cfg->fps, cfg->bitrate_bps, cfg->slices, ltr, &a->enc);
    if (FAILED(hr)) return hr;
    a->hevc_active = cfg->codec == MSW_CODEC_HEVC;
    a->bitrate = cfg->bitrate_bps;
    a->frame = 0;
    a->since_mark = 0;
    memset(a->ltr, 0, sizeof a->ltr);
    return S_OK;
}

/* Waits for the access unit of the frame just submitted and appends it to e->out. */
static HRESULT amf_drain_one(amf_enc *a, const amf_names *n, msw_enc_output *out, int *marked) {
    AMFData *data = NULL;
    const uint64_t deadline = msw_qpc_ns() + (uint64_t)AMF_WAIT_MS * 1000000ull;
    for (;;) {
        AMF_RESULT r = a->enc->pVtbl->QueryOutput(a->enc, &data);
        if (r == AMF_OK && data) break;
        if (r != AMF_OK && r != AMF_REPEAT) return amf_hr(r);
        if (msw_qpc_ns() > deadline) return HRESULT_FROM_WIN32(ERROR_TIMEOUT);
        if (r == AMF_REPEAT && !data) Sleep(0);
    }
    AMFBuffer *buf = NULL;
    AMFGuid iid = IID_AMFBuffer();
    HRESULT hr = amf_hr(data->pVtbl->QueryInterface(data, &iid, (void **)&buf));
    if (SUCCEEDED(hr)) {
        hr = msw_enc_append(&a->base, buf->pVtbl->GetNative(buf), buf->pVtbl->GetSize(buf));
        buf->pVtbl->Release(buf);
    }
    amf_int64 v = 0;
    if (get_i64(data, n->out_type, &v)) out->keyframe = v == n->v_out_idr;
    amf_int64 m = -1;
    if (get_i64(data, n->out_marked, &m)) *marked = (int)m;
    data->pVtbl->Release(data);
    return hr;
}

static HRESULT amf_encode(msw_enc *e, ID3D11Texture2D *tex, UINT index, uint64_t time_us, const msw_enc_params *p,
                          msw_enc_output *out) {
    amf_enc *a = (amf_enc *)e;
    const amf_names *n = a->hevc_active ? &names_hevc : &names_avc;
    const int ltr = a->base.cfg.ltr && a->ltr_supported;
    HRESULT hr;

    /* Per-frame bitrate change: a dynamic property, applied without an IDR. */
    if (p->bitrate_bps && p->bitrate_bps != a->bitrate) {
        AMF_RESULT r = set_i64(a->enc, n->target, (amf_int64)p->bitrate_bps);
        if (r == AMF_OK) r = set_i64(a->enc, n->peak, (amf_int64)p->bitrate_bps);
        if (r == AMF_OK) r = set_i64(a->enc, n->vbv, (amf_int64)(p->bitrate_bps / a->base.cfg.fps));
        if (r != AMF_OK) return amf_hr(r);
        a->bitrate = p->bitrate_bps;
    }
    for (uint32_t i = 0; i < p->acked_ltr_count; i++)
        for (int s = 0; s < AMF_LTR_SLOTS; s++)
            if (a->ltr[s].token && a->ltr[s].token == p->acked_ltr_tokens[i]) a->ltr[s].acked = 1;

    int idx = (int)index;
    ID3D11Texture2D_SetPrivateData(tex, &amf_texture_array_index, sizeof idx, &idx);
    AMFSurface *surf = NULL;
    AMF_RESULT r = a->context->pVtbl->CreateSurfaceFromDX11Native(a->context, tex, &surf, NULL);
    if (r != AMF_OK) return amf_hr(r);
    surf->pVtbl->SetPts(surf, (amf_pts)(time_us * 10)); /* 100 ns units */

    /* The same reference choice as the NVENC backend: refresh against the newest acked
     * slot; mark every AMF_LTR_INTERVAL frames (and on IDRs and refreshes) into the slot
     * that is not the newest acked one. */
    int force = (int)p->force;
    int use_slot = -1;
    if (force == MSW_FORCE_LTR_REFRESH) {
        uint64_t best = 0;
        for (int s = 0; s < AMF_LTR_SLOTS; s++)
            if (a->ltr[s].acked && a->ltr[s].token > best) {
                best = a->ltr[s].token;
                use_slot = s;
            }
        if (!ltr || use_slot < 0) force = MSW_FORCE_IDR;
    }
    const int idr = force == MSW_FORCE_IDR || a->frame == 0;
    if (idr) {
        surf_i64(surf, n->force_type, n->v_type_idr);
        if (!a->hevc_active) {
            AMFVariantStruct t;
            AMFVariantInit(&t);
            AMFVariantAssignBool(&t, 1);
            surf->pVtbl->SetProperty(surf, AMF_VIDEO_ENCODER_INSERT_SPS, t);
            surf->pVtbl->SetProperty(surf, AMF_VIDEO_ENCODER_INSERT_PPS, t);
        }
        memset(a->ltr, 0, sizeof a->ltr);
        use_slot = -1;
    }
    int mark_slot = -1;
    if (ltr && (idr || use_slot >= 0 || a->since_mark + 1 >= AMF_LTR_INTERVAL)) {
        int keep = -1;
        uint64_t best = 0;
        for (int s = 0; s < AMF_LTR_SLOTS; s++)
            if (a->ltr[s].acked && a->ltr[s].token > best) {
                best = a->ltr[s].token;
                keep = s;
            }
        mark_slot = 0;
        for (int s = 0; s < AMF_LTR_SLOTS; s++) {
            if (s == keep) continue;
            if (mark_slot == keep || a->ltr[s].token < a->ltr[mark_slot].token) mark_slot = s;
        }
        if (mark_slot == keep) mark_slot = -1;
    }
    if (mark_slot >= 0) surf_i64(surf, n->mark_ltr, mark_slot);
    if (use_slot >= 0) surf_i64(surf, n->use_ltr, (amf_int64)1 << use_slot);

    r = a->enc->pVtbl->SubmitInput(a->enc, (AMFData *)surf);
    surf->pVtbl->Release(surf);
    if (r == AMF_INPUT_FULL) {
        /* One frame in flight at a time, so a full queue means the encoder is wedged. */
        return HRESULT_FROM_WIN32(ERROR_BUSY);
    }
    if (r != AMF_OK && r != AMF_NEED_MORE_INPUT) return amf_hr(r);

    int marked = -1;
    hr = amf_drain_one(a, n, out, &marked);
    if (FAILED(hr)) return hr;

    a->frame++;
    a->since_mark++;
    /* Trust what the encoder reports it marked, when it reports it. */
    if (marked >= 0 && marked < AMF_LTR_SLOTS) mark_slot = marked;
    if (ltr && mark_slot >= 0) {
        a->ltr[mark_slot].token = a->frame; /* frame number, from 1 */
        a->ltr[mark_slot].acked = 0;
        a->since_mark = 0;
        out->has_ltr_token = 1;
        out->ltr_token = a->frame;
    }
    out->ltr_refresh = use_slot >= 0 && !out->keyframe;
    return S_OK;
}

static void amf_destroy(msw_enc *e) {
    amf_enc *a = (amf_enc *)e;
    amf_close(a);
    if (a->context) {
        a->context->pVtbl->Terminate(a->context);
        a->context->pVtbl->Release(a->context);
    }
    if (a->dll) FreeLibrary(a->dll);
    free(a);
}

static const msw_enc_ops amf_ops = {amf_caps, amf_configure, amf_encode, amf_destroy};

HRESULT msw_enc_amf_create(msw_d3d *d, msw_enc **out) {
    msw_adapter_info info;
    msw_d3d_info(d, &info);
    if (info.vendor_id != 0x1002) return MSW_E_NOTFOUND; /* not an AMD adapter */
    amf_enc *a = (amf_enc *)calloc(1, sizeof *a);
    if (!a) return E_OUTOFMEMORY;
    a->base.ops = &amf_ops;
    a->base.d = d;
    HRESULT hr;
    a->dll = LoadLibraryExW(AMF_DLL_NAME, NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!a->dll) {
        hr = MSW_E_NOTFOUND; /* no AMD driver */
        goto fail;
    }
    AMFQueryVersion_Fn query = (AMFQueryVersion_Fn)(void *)GetProcAddress(a->dll, AMF_QUERY_VERSION_FUNCTION_NAME);
    AMFInit_Fn init = (AMFInit_Fn)(void *)GetProcAddress(a->dll, AMF_INIT_FUNCTION_NAME);
    if (!query || !init) {
        hr = MSW_E_NOTFOUND;
        goto fail;
    }
    amf_uint64 v = 0;
    if (query(&v) != AMF_OK || v < AMF_MIN_RUNTIME) {
        hr = MSW_DXGI_ERROR_UNSUPPORTED; /* driver too old */
        goto fail;
    }
    MSW_TRY(amf_hr(init(v < AMF_FULL_VERSION ? v : AMF_FULL_VERSION, &a->factory)), fail);
    MSW_TRY(amf_hr(a->factory->pVtbl->CreateContext(a->factory, &a->context)), fail);
    /* MSW_E_NOTFOUND when the device is not on an AMD adapter. */
    AMF_RESULT r = a->context->pVtbl->InitDX11(a->context, d->device, AMF_DX11_1);
    if (r != AMF_OK) {
        hr = r == AMF_NOT_SUPPORTED ? MSW_E_NOTFOUND : amf_hr(r);
        goto fail;
    }
    int ltr_avc = 0, ltr_hevc = 0;
    amf_probe(a, MSW_CODEC_H264, &a->h264, &ltr_avc);
    amf_probe(a, MSW_CODEC_HEVC, &a->hevc, &ltr_hevc);
    if (!a->h264 && !a->hevc) {
        hr = MSW_E_NOTFOUND;
        goto fail;
    }
    /* One flag for both codecs: only claim LTR when every available codec takes it. */
    a->ltr_supported = (!a->h264 || ltr_avc) && (!a->hevc || ltr_hevc);
    *out = &a->base;
    return S_OK;
fail:
    amf_destroy(&a->base);
    return hr;
}
