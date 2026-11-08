/* Intel oneVPL (Quick Sync), loaded at run time (no link-time Intel dependency): the
 * dispatcher libvpl.dll when it is next to the program or on the DLL search path, else
 * the GPU runtime libmfx64-gen.dll directly (MFXInitialize). Both export the same MFX*
 * functions, so one table serves either. Needs a 2.x runtime (Xe / 11th-gen Core and
 * newer) for MFXMemory_GetSurfaceForEncode.
 *
 * Settings: VDEnc (LowPower) with LowDelayBRC, CBR with a one-frame buffer, AsyncDepth 1,
 * no B-frames, one IDR then none (GopPicSize at its maximum), RGB4 (BGRA) input that the
 * hardware converts, bitrate changes through MFXVideoENCODE_Reset without a new sequence,
 * and long-term references through mfxExtAVCRefListCtrl (H.264 and HEVC).
 *
 * Input: the encoder's own D3D11 surface (GetSurfaceForEncode) is filled by a GPU copy
 * from our texture when it is a plain texture on our device; otherwise by mapping it and
 * writing from a CPU readback.
 *
 * Untested on hardware so far (CI has no Intel GPU): only create's not-found path runs
 * there. Headers: third_party/vpl (oneVPL API 2.17, MIT). */
#include "enc_internal.h"

#include <string.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-function"
#pragma clang diagnostic ignored "-Wmissing-field-initializers"
#include "mfx.h"
#pragma clang diagnostic pop

#define VPL_LTR_SLOTS 2
#define VPL_LTR_INTERVAL 15
#define VPL_WAIT_MS 2000

typedef struct vpl_fn {
    __typeof__(MFXLoad) *Load;
    __typeof__(MFXUnload) *Unload;
    __typeof__(MFXCreateConfig) *CreateConfig;
    __typeof__(MFXSetConfigFilterProperty) *SetConfigFilterProperty;
    __typeof__(MFXCreateSession) *CreateSession;
    __typeof__(MFXInitialize) *Initialize;
    __typeof__(MFXClose) *Close;
    __typeof__(MFXQueryVersion) *QueryVersion;
    __typeof__(MFXVideoCORE_SetHandle) *SetHandle;
    __typeof__(MFXVideoCORE_SyncOperation) *SyncOperation;
    __typeof__(MFXVideoENCODE_Query) *Query;
    __typeof__(MFXVideoENCODE_Init) *Init;
    __typeof__(MFXVideoENCODE_Reset) *Reset;
    __typeof__(MFXVideoENCODE_Close) *EncClose;
    __typeof__(MFXVideoENCODE_GetVideoParam) *GetVideoParam;
    __typeof__(MFXVideoENCODE_EncodeFrameAsync) *EncodeFrameAsync;
    __typeof__(MFXMemory_GetSurfaceForEncode) *GetSurfaceForEncode;
} vpl_fn;

typedef struct vpl_ltr {
    uint64_t token; /* 0 = empty; else frame order + 1 */
    int acked;
} vpl_ltr;

typedef struct vpl_enc {
    msw_enc base;
    HMODULE dll;
    vpl_fn fn;
    mfxLoader loader;
    mfxSession session;
    int h264, hevc, ltr_supported;
    int initialized;
    /* Init parameters, kept for Reset. */
    mfxVideoParam par;
    mfxExtCodingOption2 co2;
    mfxExtCodingOption3 co3;
    mfxExtBuffer *ext[2];
    mfxExtEncoderResetOption reset_opt;
    mfxExtBuffer *reset_ext[3];
    uint8_t *bs_buf;
    uint32_t bs_cap;
    uint8_t *cpu; /* readback for the mapped-surface path */
    size_t cpu_len;
    uint64_t bitrate;
    uint32_t frame; /* FrameOrder of the next frame */
    vpl_ltr ltr[VPL_LTR_SLOTS];
    uint64_t since_mark;
} vpl_enc;

/* mfxStatus as an HRESULT in FACILITY_ITF (0x8004_7Cxx); a missing device maps to
 * not-found and unsupported settings to DXGI_ERROR_UNSUPPORTED. */
static HRESULT vpl_hr(mfxStatus s) {
    if (s >= MFX_ERR_NONE) return S_OK; /* warnings are positive */
    switch (s) {
    case MFX_ERR_NOT_FOUND:
    case MFX_ERR_NOT_IMPLEMENTED: return MSW_E_NOTFOUND;
    case MFX_ERR_UNSUPPORTED:
    case MFX_ERR_INVALID_VIDEO_PARAM:
    case MFX_ERR_INCOMPATIBLE_VIDEO_PARAM: return MSW_DXGI_ERROR_UNSUPPORTED;
    case MFX_ERR_MEMORY_ALLOC: return E_OUTOFMEMORY;
    case MFX_ERR_DEVICE_LOST:
    case MFX_ERR_DEVICE_FAILED: return MSW_DXGI_ERROR_DEVICE_REMOVED;
    case MFX_ERR_NULL_PTR: return E_POINTER;
    default: return MAKE_HRESULT(1, FACILITY_ITF, 0x7C00 + ((-(int)s) & 0xFF));
    }
}

static void *sym(HMODULE m, const char *name) {
    return (void *)GetProcAddress(m, name);
}

static int vpl_resolve(vpl_enc *v) {
    HMODULE m = v->dll;
#define R(field, name) v->fn.field = (__typeof__(v->fn.field))sym(m, name)
    R(Load, "MFXLoad");
    R(Unload, "MFXUnload");
    R(CreateConfig, "MFXCreateConfig");
    R(SetConfigFilterProperty, "MFXSetConfigFilterProperty");
    R(CreateSession, "MFXCreateSession");
    R(Initialize, "MFXInitialize");
    R(Close, "MFXClose");
    R(QueryVersion, "MFXQueryVersion");
    R(SetHandle, "MFXVideoCORE_SetHandle");
    R(SyncOperation, "MFXVideoCORE_SyncOperation");
    R(Query, "MFXVideoENCODE_Query");
    R(Init, "MFXVideoENCODE_Init");
    R(Reset, "MFXVideoENCODE_Reset");
    R(EncClose, "MFXVideoENCODE_Close");
    R(GetVideoParam, "MFXVideoENCODE_GetVideoParam");
    R(EncodeFrameAsync, "MFXVideoENCODE_EncodeFrameAsync");
    R(GetSurfaceForEncode, "MFXMemory_GetSurfaceForEncode");
#undef R
    return v->fn.Close && v->fn.QueryVersion && v->fn.SetHandle && v->fn.SyncOperation && v->fn.Query &&
           v->fn.Init && v->fn.Reset && v->fn.EncClose && v->fn.GetVideoParam && v->fn.EncodeFrameAsync &&
           v->fn.GetSurfaceForEncode && ((v->fn.Load && v->fn.CreateConfig && v->fn.SetConfigFilterProperty &&
                                          v->fn.CreateSession && v->fn.Unload) ||
                                         v->fn.Initialize);
}

static mfxStatus filter_u32(vpl_enc *v, const char *name, mfxU32 value) {
    mfxConfig cfg = v->fn.CreateConfig(v->loader);
    if (!cfg) return MFX_ERR_NULL_PTR;
    mfxVariant var;
    memset(&var, 0, sizeof var);
    var.Version.Version = MFX_VARIANT_VERSION;
    var.Type = MFX_VARIANT_TYPE_U32;
    var.Data.U32 = value;
    return v->fn.SetConfigFilterProperty(cfg, (const mfxU8 *)name, var);
}

/* A hardware D3D11 session on the Intel adapter, through the dispatcher when it was
 * loaded, else straight from the runtime. */
static HRESULT vpl_session(vpl_enc *v, int dispatcher) {
    mfxStatus s;
    if (dispatcher) {
        v->loader = v->fn.Load();
        if (!v->loader) return MSW_E_NOTFOUND;
        s = filter_u32(v, "mfxImplDescription.Impl", MFX_IMPL_TYPE_HARDWARE);
        if (s == MFX_ERR_NONE) s = filter_u32(v, "mfxImplDescription.AccelerationMode", MFX_ACCEL_MODE_VIA_D3D11);
        if (s == MFX_ERR_NONE) s = filter_u32(v, "mfxImplDescription.VendorID", 0x8086);
        if (s == MFX_ERR_NONE) s = filter_u32(v, "mfxImplDescription.ApiVersion.Version", (2u << 16) | 0u);
        if (s == MFX_ERR_NONE) s = v->fn.CreateSession(v->loader, 0, &v->session);
    } else {
        mfxInitializationParam ip;
        memset(&ip, 0, sizeof ip);
        ip.AccelerationMode = MFX_ACCEL_MODE_VIA_D3D11;
        s = v->fn.Initialize(ip, &v->session);
    }
    if (s != MFX_ERR_NONE) return s == MFX_ERR_NOT_FOUND || s == MFX_ERR_UNSUPPORTED ? MSW_E_NOTFOUND : vpl_hr(s);
    mfxVersion ver;
    if (v->fn.QueryVersion(v->session, &ver) != MFX_ERR_NONE || ver.Major < 2) return MSW_DXGI_ERROR_UNSUPPORTED;
    return vpl_hr(v->fn.SetHandle(v->session, MFX_HANDLE_D3D11_DEVICE, v->base.d->device));
}

/* Fills par with the low-latency settings. The ext buffers live in v. */
static void vpl_params(vpl_enc *v, uint32_t codec, uint32_t w, uint32_t h, uint32_t fps, uint64_t bps,
                       uint32_t slices, int ltr) {
    mfxVideoParam *p = &v->par;
    memset(p, 0, sizeof *p);
    p->AsyncDepth = 1;
    p->IOPattern = MFX_IOPATTERN_IN_VIDEO_MEMORY;
    mfxInfoMFX *m = &p->mfx;
    m->CodecId = codec == MSW_CODEC_HEVC ? MFX_CODEC_HEVC : MFX_CODEC_AVC;
    m->CodecProfile = codec == MSW_CODEC_HEVC ? MFX_PROFILE_HEVC_MAIN : MFX_PROFILE_AVC_HIGH;
    m->TargetUsage = MFX_TARGETUSAGE_BEST_SPEED;
    m->LowPower = MFX_CODINGOPTION_ON; /* VDEnc: needed for LowDelayBRC */
    m->GopPicSize = 0xFFFF;            /* one IDR, then (practically) none */
    m->GopRefDist = 1;                 /* no B-frames */
    m->IdrInterval = 0;
    m->NumSlice = (mfxU16)(slices ? slices : 1);
    m->NumRefFrame = ltr ? VPL_LTR_SLOTS + 1 : 1;
    m->RateControlMethod = MFX_RATECONTROL_CBR;
    const uint64_t kbps = bps / 1000;
    const uint64_t buf_kb = bps / fps / 8 / 1000 + 1; /* one frame */
    uint64_t mult = 1;
    while (kbps / mult > 0xFFFF || buf_kb / mult > 0xFFFF) mult++;
    m->BRCParamMultiplier = (mfxU16)mult;
    m->TargetKbps = (mfxU16)(kbps / mult);
    m->MaxKbps = (mfxU16)(kbps / mult);
    m->BufferSizeInKB = (mfxU16)(buf_kb / mult);
    m->InitialDelayInKB = (mfxU16)(buf_kb / mult);
    mfxFrameInfo *fi = &m->FrameInfo;
    fi->FourCC = MFX_FOURCC_RGB4;
    fi->ChromaFormat = MFX_CHROMAFORMAT_YUV444;
    fi->Width = (mfxU16)((w + 15) & ~15u);
    fi->Height = (mfxU16)((h + 15) & ~15u);
    fi->CropW = (mfxU16)w;
    fi->CropH = (mfxU16)h;
    fi->FrameRateExtN = fps;
    fi->FrameRateExtD = 1;
    fi->PicStruct = MFX_PICSTRUCT_PROGRESSIVE;

    memset(&v->co2, 0, sizeof v->co2);
    v->co2.Header.BufferId = MFX_EXTBUFF_CODING_OPTION2;
    v->co2.Header.BufferSz = sizeof v->co2;
    v->co2.AdaptiveI = MFX_CODINGOPTION_OFF;
    v->co2.AdaptiveB = MFX_CODINGOPTION_OFF;
    v->co2.RepeatPPS = MFX_CODINGOPTION_OFF;
    memset(&v->co3, 0, sizeof v->co3);
    v->co3.Header.BufferId = MFX_EXTBUFF_CODING_OPTION3;
    v->co3.Header.BufferSz = sizeof v->co3;
    v->co3.LowDelayBRC = MFX_CODINGOPTION_ON;
    v->ext[0] = &v->co2.Header;
    v->ext[1] = &v->co3.Header;
    p->ExtParam = v->ext;
    p->NumExtParam = 2;
}

/* Query mode 1 (in = NULL: the runtime sets every field it can configure to non-zero)
 * with mfxExtAVCRefListCtrl attached, as its documentation says to check LongTermIdx and
 * ApplyLongTermIdx support. */
static int vpl_ltr_query(vpl_enc *v, uint32_t codec) {
    mfxExtAVCRefListCtrl rl;
    memset(&rl, 0, sizeof rl);
    rl.Header.BufferId = MFX_EXTBUFF_AVC_REFLIST_CTRL;
    rl.Header.BufferSz = sizeof rl;
    mfxVideoParam out;
    memset(&out, 0, sizeof out);
    out.mfx.CodecId = codec == MSW_CODEC_HEVC ? MFX_CODEC_HEVC : MFX_CODEC_AVC;
    mfxExtBuffer *oe[1] = {&rl.Header};
    out.ExtParam = oe;
    out.NumExtParam = 1;
    mfxStatus s = v->fn.Query(v->session, NULL, &out);
    return s == MFX_ERR_NONE && rl.ApplyLongTermIdx != 0;
}

/* Whether `codec` initializes at a small size with these settings. */
static int vpl_codec_works(vpl_enc *v, uint32_t codec) {
    vpl_params(v, codec, 640, 368, 60, 2000000, 1, 0);
    mfxStatus s = v->fn.Init(v->session, &v->par);
    if (s < MFX_ERR_NONE) return 0;
    v->fn.EncClose(v->session);
    return 1;
}

static void vpl_caps(const msw_enc *e, msw_enc_caps *out) {
    const vpl_enc *v = (const vpl_enc *)e;
    out->h264 = (uint32_t)v->h264;
    out->hevc = (uint32_t)v->hevc;
    out->ltr = (uint32_t)v->ltr_supported;
    out->max_slices = 4;
    out->gpu_input = 1;
}

static HRESULT vpl_configure(msw_enc *e, const msw_enc_config *cfg) {
    vpl_enc *v = (vpl_enc *)e;
    if ((cfg->codec == MSW_CODEC_HEVC && !v->hevc) || (cfg->codec == MSW_CODEC_H264 && !v->h264) ||
        (cfg->codec != MSW_CODEC_H264 && cfg->codec != MSW_CODEC_HEVC))
        return MSW_DXGI_ERROR_UNSUPPORTED;
    if (v->initialized) {
        v->fn.EncClose(v->session);
        v->initialized = 0;
    }
    const int ltr = cfg->ltr && v->ltr_supported;
    vpl_params(v, cfg->codec, cfg->width, cfg->height, cfg->fps, cfg->bitrate_bps, cfg->slices, ltr);
    mfxStatus s = v->fn.Init(v->session, &v->par);
    if (s < MFX_ERR_NONE) return vpl_hr(s);
    v->initialized = 1;
    /* Bitstream buffer: the encoder's own bound, but never under a raw 4:2:0 frame. */
    mfxVideoParam got;
    memset(&got, 0, sizeof got);
    uint64_t need = (uint64_t)cfg->width * cfg->height * 3 / 2;
    if (v->fn.GetVideoParam(v->session, &got) == MFX_ERR_NONE) {
        const uint64_t b = (uint64_t)got.mfx.BufferSizeInKB * 1000 * (got.mfx.BRCParamMultiplier ? got.mfx.BRCParamMultiplier : 1);
        if (b > need) need = b;
    }
    if (need > v->bs_cap) {
        uint8_t *n = (uint8_t *)realloc(v->bs_buf, need);
        if (!n) return E_OUTOFMEMORY;
        v->bs_buf = n;
        v->bs_cap = (uint32_t)need;
    }
    v->bitrate = cfg->bitrate_bps;
    v->frame = 0;
    v->since_mark = 0;
    memset(v->ltr, 0, sizeof v->ltr);
    return S_OK;
}

static HRESULT vpl_set_bitrate(vpl_enc *v, uint64_t bps) {
    mfxInfoMFX *m = &v->par.mfx;
    const uint32_t fps = v->base.cfg.fps;
    const uint64_t kbps = bps / 1000;
    const uint64_t buf_kb = bps / fps / 8 / 1000 + 1;
    uint64_t mult = 1;
    while (kbps / mult > 0xFFFF || buf_kb / mult > 0xFFFF) mult++;
    m->BRCParamMultiplier = (mfxU16)mult;
    m->TargetKbps = m->MaxKbps = (mfxU16)(kbps / mult);
    m->BufferSizeInKB = m->InitialDelayInKB = (mfxU16)(buf_kb / mult);
    memset(&v->reset_opt, 0, sizeof v->reset_opt);
    v->reset_opt.Header.BufferId = MFX_EXTBUFF_ENCODER_RESET_OPTION;
    v->reset_opt.Header.BufferSz = sizeof v->reset_opt;
    v->reset_opt.StartNewSequence = MFX_CODINGOPTION_OFF; /* no IDR */
    v->reset_ext[0] = &v->co2.Header;
    v->reset_ext[1] = &v->co3.Header;
    v->reset_ext[2] = &v->reset_opt.Header;
    v->par.ExtParam = v->reset_ext;
    v->par.NumExtParam = 3;
    mfxStatus s = v->fn.Reset(v->session, &v->par);
    v->par.ExtParam = v->ext;
    v->par.NumExtParam = 2;
    return vpl_hr(s);
}

/* Fills the encoder's surface from subresource `index` of our BGRA texture. */
static HRESULT vpl_fill(vpl_enc *v, mfxFrameSurface1 *surf, ID3D11Texture2D *tex, UINT index) {
    mfxHDL res = NULL;
    mfxResourceType type = 0;
    if (surf->FrameInterface->GetNativeHandle(surf, &res, &type) == MFX_ERR_NONE && type == MFX_RESOURCE_DX11_TEXTURE && res) {
        ID3D11Texture2D *dst = (ID3D11Texture2D *)res;
        D3D11_TEXTURE2D_DESC dd;
        ID3D11Texture2D_GetDesc(dst, &dd);
        ID3D11Device *dev = NULL;
        ID3D11Texture2D_GetDevice(dst, &dev);
        const int same_device = dev == v->base.d->device;
        if (dev) ID3D11Device_Release(dev);
        /* A single texture on our device: copy on the GPU. (An array slice we cannot
         * name, so those go through the CPU.) */
        if (same_device && dd.ArraySize == 1 && dd.Format == DXGI_FORMAT_B8G8R8A8_UNORM) {
            D3D11_BOX box = {0, 0, 0, v->base.cfg.width, v->base.cfg.height, 1};
            ID3D11DeviceContext_CopySubresourceRegion(v->base.d->context, (ID3D11Resource *)dst, 0, 0, 0, 0,
                                                      (ID3D11Resource *)tex, index, &box);
            return S_OK;
        }
    }
    const uint32_t w = v->base.cfg.width, h = v->base.cfg.height;
    const size_t len = (size_t)w * h * 4;
    if (v->cpu_len < len) {
        uint8_t *n = (uint8_t *)realloc(v->cpu, len);
        if (!n) return E_OUTOFMEMORY;
        v->cpu = n;
        v->cpu_len = len;
    }
    HRESULT hr = msw_texture_read(v->base.d, tex, index, v->cpu, w * 4);
    if (FAILED(hr)) return hr;
    mfxStatus s = surf->FrameInterface->Map(surf, MFX_MAP_WRITE);
    if (s != MFX_ERR_NONE) return vpl_hr(s);
    const uint32_t pitch = ((uint32_t)surf->Data.PitchHigh << 16) | surf->Data.PitchLow;
    uint8_t *base = surf->Data.B; /* RGB4: B is the first byte of each pixel */
    if (!base) {
        surf->FrameInterface->Unmap(surf);
        return E_POINTER;
    }
    for (uint32_t y = 0; y < h; y++) memcpy(base + (size_t)y * pitch, v->cpu + (size_t)y * w * 4, (size_t)w * 4);
    surf->FrameInterface->Unmap(surf);
    return S_OK;
}

static void reflist_clear(mfxExtAVCRefListCtrl *rl) {
    memset(rl, 0, sizeof *rl);
    rl->Header.BufferId = MFX_EXTBUFF_AVC_REFLIST_CTRL;
    rl->Header.BufferSz = sizeof *rl;
    for (int i = 0; i < 32; i++) rl->PreferredRefList[i].FrameOrder = (mfxU32)MFX_FRAMEORDER_UNKNOWN;
    for (int i = 0; i < 16; i++) {
        rl->RejectedRefList[i].FrameOrder = (mfxU32)MFX_FRAMEORDER_UNKNOWN;
        rl->LongTermRefList[i].FrameOrder = (mfxU32)MFX_FRAMEORDER_UNKNOWN;
    }
}

static HRESULT vpl_encode(msw_enc *e, ID3D11Texture2D *tex, UINT index, uint64_t time_us, const msw_enc_params *p,
                          msw_enc_output *out) {
    vpl_enc *v = (vpl_enc *)e;
    const int ltr = v->base.cfg.ltr && v->ltr_supported;
    HRESULT hr;

    if (p->bitrate_bps && p->bitrate_bps != v->bitrate) {
        hr = vpl_set_bitrate(v, p->bitrate_bps);
        if (FAILED(hr)) return hr;
        v->bitrate = p->bitrate_bps;
    }
    for (uint32_t i = 0; i < p->acked_ltr_count; i++)
        for (int s = 0; s < VPL_LTR_SLOTS; s++)
            if (v->ltr[s].token && v->ltr[s].token == p->acked_ltr_tokens[i]) v->ltr[s].acked = 1;

    mfxFrameSurface1 *surf = NULL;
    mfxStatus s = v->fn.GetSurfaceForEncode(v->session, &surf);
    if (s != MFX_ERR_NONE) return vpl_hr(s);
    hr = vpl_fill(v, surf, tex, index);
    if (FAILED(hr)) goto release;
    surf->Data.FrameOrder = v->frame;
    surf->Data.TimeStamp = time_us * 90 / 1000; /* 90 kHz */

    /* The same reference choice as the NVENC and AMF backends. */
    int force = (int)p->force;
    int use_slot = -1;
    if (force == MSW_FORCE_LTR_REFRESH) {
        uint64_t best = 0;
        for (int i = 0; i < VPL_LTR_SLOTS; i++)
            if (v->ltr[i].acked && v->ltr[i].token > best) {
                best = v->ltr[i].token;
                use_slot = i;
            }
        if (!ltr || use_slot < 0) force = MSW_FORCE_IDR;
    }
    const int idr = force == MSW_FORCE_IDR || v->frame == 0;
    if (idr) {
        memset(v->ltr, 0, sizeof v->ltr);
        use_slot = -1;
    }
    int mark_slot = -1;
    if (ltr && (idr || use_slot >= 0 || v->since_mark + 1 >= VPL_LTR_INTERVAL)) {
        int keep = -1;
        uint64_t best = 0;
        for (int i = 0; i < VPL_LTR_SLOTS; i++)
            if (v->ltr[i].acked && v->ltr[i].token > best) {
                best = v->ltr[i].token;
                keep = i;
            }
        mark_slot = 0;
        for (int i = 0; i < VPL_LTR_SLOTS; i++) {
            if (i == keep) continue;
            if (mark_slot == keep || v->ltr[i].token < v->ltr[mark_slot].token) mark_slot = i;
        }
        if (mark_slot == keep) mark_slot = -1;
    }

    mfxEncodeCtrl ctrl;
    memset(&ctrl, 0, sizeof ctrl);
    mfxExtAVCRefListCtrl rl;
    reflist_clear(&rl);
    mfxExtBuffer *ctrl_ext[1] = {&rl.Header};
    int use_rl = 0;
    if (idr) ctrl.FrameType = MFX_FRAMETYPE_I | MFX_FRAMETYPE_REF | MFX_FRAMETYPE_IDR;
    if (mark_slot >= 0) {
        rl.LongTermRefList[0].FrameOrder = v->frame;
        rl.LongTermRefList[0].PicStruct = MFX_PICSTRUCT_PROGRESSIVE;
        rl.LongTermRefList[0].LongTermIdx = (mfxU16)mark_slot;
        rl.ApplyLongTermIdx = 1;
        use_rl = 1;
    }
    if (use_slot >= 0) {
        /* Reference only the acked long-term frame: prefer it, reject everything newer. */
        const mfxU32 ref = (mfxU32)(v->ltr[use_slot].token - 1);
        rl.NumRefIdxL0Active = 1;
        rl.PreferredRefList[0].FrameOrder = ref;
        rl.PreferredRefList[0].PicStruct = MFX_PICSTRUCT_PROGRESSIVE;
        int n = 0;
        for (mfxU32 f = v->frame; f-- > ref + 1 && n < 16;) {
            rl.RejectedRefList[n].FrameOrder = f;
            rl.RejectedRefList[n].PicStruct = MFX_PICSTRUCT_PROGRESSIVE;
            n++;
        }
        use_rl = 1;
    }
    if (use_rl) {
        ctrl.ExtParam = ctrl_ext;
        ctrl.NumExtParam = 1;
    }

    mfxBitstream bs;
    memset(&bs, 0, sizeof bs);
    bs.Data = v->bs_buf;
    bs.MaxLength = v->bs_cap;
    mfxSyncPoint sync = NULL;
    const uint64_t deadline = msw_qpc_ns() + (uint64_t)VPL_WAIT_MS * 1000000ull;
    for (;;) {
        s = v->fn.EncodeFrameAsync(v->session, (idr || use_rl) ? &ctrl : NULL, surf, &bs, &sync);
        if (s != MFX_WRN_DEVICE_BUSY) break;
        if (msw_qpc_ns() > deadline) {
            hr = HRESULT_FROM_WIN32(ERROR_TIMEOUT);
            goto release;
        }
        Sleep(1);
    }
    if (s == MFX_ERR_MORE_DATA) {
        hr = S_OK; /* buffered: reported as a drop */
        goto release;
    }
    if (s < MFX_ERR_NONE) {
        hr = vpl_hr(s);
        goto release;
    }
    s = v->fn.SyncOperation(v->session, sync, VPL_WAIT_MS);
    if (s < MFX_ERR_NONE) {
        hr = vpl_hr(s);
        goto release;
    }
    hr = msw_enc_append(&v->base, bs.Data + bs.DataOffset, bs.DataLength);
    if (FAILED(hr)) goto release;
    out->keyframe = (bs.FrameType & MFX_FRAMETYPE_IDR) != 0;

    v->frame++;
    v->since_mark++;
    if (mark_slot >= 0) {
        v->ltr[mark_slot].token = v->frame; /* frame order + 1 */
        v->ltr[mark_slot].acked = 0;
        v->since_mark = 0;
        out->has_ltr_token = 1;
        out->ltr_token = v->frame;
    }
    out->ltr_refresh = use_slot >= 0 && !out->keyframe;
release:
    surf->FrameInterface->Release(surf);
    return hr;
}

static void vpl_destroy(msw_enc *e) {
    vpl_enc *v = (vpl_enc *)e;
    if (v->session) {
        if (v->initialized) v->fn.EncClose(v->session);
        v->fn.Close(v->session);
    }
    if (v->loader) v->fn.Unload(v->loader);
    if (v->dll) FreeLibrary(v->dll);
    free(v->bs_buf);
    free(v->cpu);
    free(v);
}

static const msw_enc_ops vpl_ops = {vpl_caps, vpl_configure, vpl_encode, vpl_destroy};

HRESULT msw_enc_vpl_create(msw_d3d *d, msw_enc **out) {
    msw_adapter_info info;
    msw_d3d_info(d, &info);
    if (info.vendor_id != 0x8086) return MSW_E_NOTFOUND; /* not an Intel adapter */
    vpl_enc *v = (vpl_enc *)calloc(1, sizeof *v);
    if (!v) return E_OUTOFMEMORY;
    v->base.ops = &vpl_ops;
    v->base.d = d;
    HRESULT hr;
    /* The dispatcher from the program's directory or PATH, then the runtime from the
     * system directory (where Intel's driver puts it). */
    int dispatcher = 1;
    v->dll = LoadLibraryExW(L"libvpl.dll", NULL, LOAD_LIBRARY_SEARCH_APPLICATION_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
    if (!v->dll) {
        dispatcher = 0;
#if defined(_M_X64) || defined(__x86_64__)
        v->dll = LoadLibraryExW(L"libmfx64-gen.dll", NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
#endif
    }
    if (!v->dll || !vpl_resolve(v)) {
        hr = MSW_E_NOTFOUND;
        goto fail;
    }
    if (dispatcher && !v->fn.Load) dispatcher = 0;
    MSW_TRY(vpl_session(v, dispatcher), fail);
    v->h264 = vpl_codec_works(v, MSW_CODEC_H264);
    v->hevc = vpl_codec_works(v, MSW_CODEC_HEVC);
    if (!v->h264 && !v->hevc) {
        hr = MSW_E_NOTFOUND;
        goto fail;
    }
    v->ltr_supported = (!v->h264 || vpl_ltr_query(v, MSW_CODEC_H264)) && (!v->hevc || vpl_ltr_query(v, MSW_CODEC_HEVC));
    *out = &v->base;
    return S_OK;
fail:
    vpl_destroy(&v->base);
    return hr;
}
