/* NVENC through nvEncodeAPI64.dll, loaded at run time (no link-time NVIDIA dependency).
 * Takes the BGRA D3D11 texture directly (NV_ENC_BUFFER_FORMAT_ARGB), synchronous mode,
 * P1 preset with the ultra-low-latency tuning, CBR with a one-frame VBV, infinite GOP,
 * no B-frames, and long-term references in "per picture" mode.
 *
 * Untested on hardware so far (CI has no NVIDIA GPU): only create's not-found path runs
 * there. S8's NVENC rows check the LTR behaviour on a real GPU. */
#include "enc_internal.h"

#include <string.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-variable"
#pragma clang diagnostic ignored "-Wunused-const-variable"
#include "nvEncodeAPI.h"
#pragma clang diagnostic pop

typedef NVENCSTATUS(NVENCAPI *pfn_create_instance)(NV_ENCODE_API_FUNCTION_LIST *);
typedef NVENCSTATUS(NVENCAPI *pfn_max_version)(uint32_t *);

#define NV_LTR_SLOTS 2
/* Mark a long-term reference this often (frames); recovery refreshes against the
 * newest one the client acked. */
#define NV_LTR_INTERVAL 15
#define NV_MAX_REGS 8

typedef struct nv_ltr {
    uint64_t token; /* 0 = empty */
    int acked;
} nv_ltr;

typedef struct nv_reg {
    ID3D11Texture2D *tex;
    UINT index;
    NV_ENC_REGISTERED_PTR reg;
    uint64_t last_use;
} nv_reg;

typedef struct nv_enc {
    msw_enc base;
    HMODULE dll;
    NV_ENCODE_API_FUNCTION_LIST fn;
    void *enc;
    int h264, hevc, ltr_supported;
    int initialized;
    GUID codec_guid;
    NV_ENC_INITIALIZE_PARAMS init;
    NV_ENC_CONFIG config;
    NV_ENC_OUTPUT_PTR bitstream;
    nv_reg regs[NV_MAX_REGS];
    uint64_t frame;
    nv_ltr ltr[NV_LTR_SLOTS];
    uint64_t since_mark;
} nv_enc;

/* NVENCSTATUS as an HRESULT in FACILITY_ITF (0x8004_7Exx); "no device" maps to not-found. */
static HRESULT nv_hr(NVENCSTATUS s) {
    if (s == NV_ENC_SUCCESS) return S_OK;
    if (s == NV_ENC_ERR_NO_ENCODE_DEVICE || s == NV_ENC_ERR_UNSUPPORTED_DEVICE || s == NV_ENC_ERR_INVALID_ENCODERDEVICE)
        return MSW_E_NOTFOUND;
    if (s == NV_ENC_ERR_OUT_OF_MEMORY) return E_OUTOFMEMORY;
    if (s == NV_ENC_ERR_DEVICE_NOT_EXIST) return MSW_DXGI_ERROR_DEVICE_REMOVED;
    if (s == NV_ENC_ERR_UNIMPLEMENTED || s == NV_ENC_ERR_UNSUPPORTED_PARAM) return MSW_DXGI_ERROR_UNSUPPORTED;
    return MAKE_HRESULT(1, FACILITY_ITF, 0x7E00 + (int)s);
}

static int has_guid(nv_enc *n, const GUID *g) {
    uint32_t count = 0, got = 0;
    if (n->fn.nvEncGetEncodeGUIDCount(n->enc, &count) != NV_ENC_SUCCESS || count == 0) return 0;
    GUID guids[16];
    if (count > 16) count = 16;
    if (n->fn.nvEncGetEncodeGUIDs(n->enc, guids, count, &got) != NV_ENC_SUCCESS) return 0;
    for (uint32_t i = 0; i < got; i++)
        if (IsEqualGUID(&guids[i], g)) return 1;
    return 0;
}

static int cap(nv_enc *n, const GUID *codec, NV_ENC_CAPS which) {
    NV_ENC_CAPS_PARAM p = {0};
    p.version = NV_ENC_CAPS_PARAM_VER;
    p.capsToQuery = which;
    int v = 0;
    if (n->fn.nvEncGetEncodeCaps(n->enc, *codec, &p, &v) != NV_ENC_SUCCESS) return 0;
    return v;
}

static void nv_unregister_all(nv_enc *n) {
    for (int i = 0; i < NV_MAX_REGS; i++) {
        if (n->regs[i].reg) n->fn.nvEncUnregisterResource(n->enc, n->regs[i].reg);
        memset(&n->regs[i], 0, sizeof n->regs[i]);
    }
}

static void nv_caps(const msw_enc *e, msw_enc_caps *out) {
    const nv_enc *n = (const nv_enc *)e;
    out->h264 = (uint32_t)n->h264;
    out->hevc = (uint32_t)n->hevc;
    out->ltr = (uint32_t)n->ltr_supported;
    out->max_slices = 4;
    out->gpu_input = 1;
}

static HRESULT nv_configure(msw_enc *e, const msw_enc_config *cfg) {
    nv_enc *n = (nv_enc *)e;
    const GUID *codec = cfg->codec == MSW_CODEC_HEVC ? &NV_ENC_CODEC_HEVC_GUID : &NV_ENC_CODEC_H264_GUID;
    if ((cfg->codec == MSW_CODEC_HEVC && !n->hevc) || (cfg->codec == MSW_CODEC_H264 && !n->h264) ||
        (cfg->codec != MSW_CODEC_H264 && cfg->codec != MSW_CODEC_HEVC))
        return MSW_DXGI_ERROR_UNSUPPORTED;

    /* A new session for every configure: sizes and codecs may change. */
    if (n->initialized) {
        nv_unregister_all(n);
        if (n->bitstream) n->fn.nvEncDestroyBitstreamBuffer(n->enc, n->bitstream);
        n->bitstream = NULL;
        n->fn.nvEncDestroyEncoder(n->enc);
        n->enc = NULL;
        n->initialized = 0;
        NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS op = {0};
        op.version = NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS_VER;
        op.device = n->base.d->device;
        op.deviceType = NV_ENC_DEVICE_TYPE_DIRECTX;
        op.apiVersion = NVENCAPI_VERSION;
        HRESULT hr = nv_hr(n->fn.nvEncOpenEncodeSessionEx(&op, &n->enc));
        if (FAILED(hr)) return hr;
    }

    NV_ENC_PRESET_CONFIG pc = {0};
    pc.version = NV_ENC_PRESET_CONFIG_VER;
    pc.presetCfg.version = NV_ENC_CONFIG_VER;
    HRESULT hr = nv_hr(n->fn.nvEncGetEncodePresetConfigEx(n->enc, *codec, NV_ENC_PRESET_P1_GUID,
                                                           NV_ENC_TUNING_INFO_ULTRA_LOW_LATENCY, &pc));
    if (FAILED(hr)) return hr;
    n->config = pc.presetCfg;
    NV_ENC_CONFIG *c = &n->config;
    c->gopLength = NVENC_INFINITE_GOPLENGTH;
    c->frameIntervalP = 1; /* no B-frames */
    c->rcParams.rateControlMode = NV_ENC_PARAMS_RC_CBR;
    c->rcParams.averageBitRate = (uint32_t)cfg->bitrate_bps;
    c->rcParams.maxBitRate = (uint32_t)cfg->bitrate_bps;
    c->rcParams.vbvBufferSize = (uint32_t)(cfg->bitrate_bps / cfg->fps);
    c->rcParams.vbvInitialDelay = c->rcParams.vbvBufferSize;
    c->rcParams.enableLookahead = 0;
    const int ltr = cfg->ltr && n->ltr_supported;
    const uint32_t slices = cfg->slices ? cfg->slices : 1;
    if (cfg->codec == MSW_CODEC_HEVC) {
        NV_ENC_CONFIG_HEVC *h = &c->encodeCodecConfig.hevcConfig;
        h->idrPeriod = NVENC_INFINITE_GOPLENGTH;
        h->repeatSPSPPS = 1;
        h->sliceMode = 3;
        h->sliceModeData = slices;
        h->enableLTR = ltr;
        h->ltrNumFrames = ltr ? NV_LTR_SLOTS : 0;
        h->ltrTrustMode = 0;
        h->enableIntraRefresh = 0;
    } else {
        NV_ENC_CONFIG_H264 *h = &c->encodeCodecConfig.h264Config;
        h->idrPeriod = NVENC_INFINITE_GOPLENGTH;
        h->repeatSPSPPS = 1;
        h->sliceMode = 3;
        h->sliceModeData = slices;
        h->enableLTR = ltr;
        h->ltrNumFrames = ltr ? NV_LTR_SLOTS : 0;
        h->ltrTrustMode = 0;
        h->enableIntraRefresh = 0;
    }

    memset(&n->init, 0, sizeof n->init);
    n->init.version = NV_ENC_INITIALIZE_PARAMS_VER;
    n->init.encodeGUID = *codec;
    n->init.presetGUID = NV_ENC_PRESET_P1_GUID;
    n->init.tuningInfo = NV_ENC_TUNING_INFO_ULTRA_LOW_LATENCY;
    n->init.encodeWidth = n->init.darWidth = n->init.maxEncodeWidth = cfg->width;
    n->init.encodeHeight = n->init.darHeight = n->init.maxEncodeHeight = cfg->height;
    n->init.frameRateNum = cfg->fps;
    n->init.frameRateDen = 1;
    n->init.enablePTD = 1;
    n->init.enableEncodeAsync = 0;
    n->init.encodeConfig = &n->config;
    hr = nv_hr(n->fn.nvEncInitializeEncoder(n->enc, &n->init));
    if (FAILED(hr)) return hr;
    n->initialized = 1;
    n->codec_guid = *codec;

    NV_ENC_CREATE_BITSTREAM_BUFFER bb = {0};
    bb.version = NV_ENC_CREATE_BITSTREAM_BUFFER_VER;
    hr = nv_hr(n->fn.nvEncCreateBitstreamBuffer(n->enc, &bb));
    if (FAILED(hr)) return hr;
    n->bitstream = bb.bitstreamBuffer;
    n->frame = 0;
    n->since_mark = 0;
    memset(n->ltr, 0, sizeof n->ltr);
    return S_OK;
}

static HRESULT nv_lookup(nv_enc *n, ID3D11Texture2D *tex, UINT index, NV_ENC_REGISTERED_PTR *out) {
    int victim = 0;
    for (int i = 0; i < NV_MAX_REGS; i++) {
        if (n->regs[i].reg && n->regs[i].tex == tex && n->regs[i].index == index) {
            n->regs[i].last_use = n->frame;
            *out = n->regs[i].reg;
            return S_OK;
        }
        if (!n->regs[i].reg || n->regs[i].last_use < n->regs[victim].last_use) victim = i;
        if (!n->regs[victim].reg) break;
    }
    if (n->regs[victim].reg) n->fn.nvEncUnregisterResource(n->enc, n->regs[victim].reg);
    memset(&n->regs[victim], 0, sizeof n->regs[victim]);
    NV_ENC_REGISTER_RESOURCE r = {0};
    r.version = NV_ENC_REGISTER_RESOURCE_VER;
    r.resourceType = NV_ENC_INPUT_RESOURCE_TYPE_DIRECTX;
    r.width = n->base.cfg.width;
    r.height = n->base.cfg.height;
    r.subResourceIndex = index;
    r.resourceToRegister = tex;
    r.bufferFormat = NV_ENC_BUFFER_FORMAT_ARGB;
    r.bufferUsage = NV_ENC_INPUT_IMAGE;
    HRESULT hr = nv_hr(n->fn.nvEncRegisterResource(n->enc, &r));
    if (FAILED(hr)) return hr;
    n->regs[victim].tex = tex;
    n->regs[victim].index = index;
    n->regs[victim].reg = r.registeredResource;
    n->regs[victim].last_use = n->frame;
    *out = r.registeredResource;
    return S_OK;
}

static HRESULT nv_encode(msw_enc *e, ID3D11Texture2D *tex, UINT index, uint64_t time_us, const msw_enc_params *p,
                         msw_enc_output *out) {
    nv_enc *n = (nv_enc *)e;
    HRESULT hr;
    const int hevc = n->base.cfg.codec == MSW_CODEC_HEVC;
    const int ltr = n->base.cfg.ltr && n->ltr_supported;

    if (p->bitrate_bps && p->bitrate_bps != n->config.rcParams.averageBitRate) {
        n->config.rcParams.averageBitRate = (uint32_t)p->bitrate_bps;
        n->config.rcParams.maxBitRate = (uint32_t)p->bitrate_bps;
        n->config.rcParams.vbvBufferSize = (uint32_t)(p->bitrate_bps / n->base.cfg.fps);
        n->config.rcParams.vbvInitialDelay = n->config.rcParams.vbvBufferSize;
        NV_ENC_RECONFIGURE_PARAMS rp = {0};
        rp.version = NV_ENC_RECONFIGURE_PARAMS_VER;
        rp.reInitEncodeParams = n->init;
        rp.reInitEncodeParams.encodeConfig = &n->config;
        rp.resetEncoder = 0;
        rp.forceIDR = 0;
        hr = nv_hr(n->fn.nvEncReconfigureEncoder(n->enc, &rp));
        if (FAILED(hr)) return hr;
    }
    for (uint32_t i = 0; i < p->acked_ltr_count; i++)
        for (int s = 0; s < NV_LTR_SLOTS; s++)
            if (n->ltr[s].token && n->ltr[s].token == p->acked_ltr_tokens[i]) n->ltr[s].acked = 1;

    NV_ENC_REGISTERED_PTR reg;
    MSW_TRY(nv_lookup(n, tex, index, &reg), done);
    NV_ENC_MAP_INPUT_RESOURCE map = {0};
    map.version = NV_ENC_MAP_INPUT_RESOURCE_VER;
    map.registeredResource = reg;
    MSW_TRY(nv_hr(n->fn.nvEncMapInputResource(n->enc, &map)), done);

    NV_ENC_PIC_PARAMS pp = {0};
    pp.version = NV_ENC_PIC_PARAMS_VER;
    pp.inputWidth = n->base.cfg.width;
    pp.inputHeight = n->base.cfg.height;
    pp.inputBuffer = map.mappedResource;
    pp.bufferFmt = map.mappedBufferFmt;
    pp.outputBitstream = n->bitstream;
    pp.pictureStruct = NV_ENC_PIC_STRUCT_FRAME;
    pp.inputTimeStamp = time_us;
    pp.frameIdx = (uint32_t)n->frame;

    int force = (int)p->force;
    int use_slot = -1;
    if (force == MSW_FORCE_LTR_REFRESH) {
        uint64_t best = 0;
        for (int s = 0; s < NV_LTR_SLOTS; s++)
            if (n->ltr[s].acked && n->ltr[s].token > best) {
                best = n->ltr[s].token;
                use_slot = s;
            }
        if (!ltr || use_slot < 0) force = MSW_FORCE_IDR;
    }
    const int idr = force == MSW_FORCE_IDR || n->frame == 0;
    if (idr) {
        pp.encodePicFlags = NV_ENC_PIC_FLAG_FORCEIDR | NV_ENC_PIC_FLAG_OUTPUT_SPSPPS;
        memset(n->ltr, 0, sizeof n->ltr); /* an IDR empties the DPB */
        use_slot = -1;
    }
    /* Mark this frame a long-term reference on IDRs, refreshes and every NV_LTR_INTERVAL
     * frames, into the slot that is not the newest acked one. */
    int mark_slot = -1;
    if (ltr && (idr || use_slot >= 0 || n->since_mark + 1 >= NV_LTR_INTERVAL)) {
        int keep = -1;
        uint64_t best = 0;
        for (int s = 0; s < NV_LTR_SLOTS; s++)
            if (n->ltr[s].acked && n->ltr[s].token > best) {
                best = n->ltr[s].token;
                keep = s;
            }
        mark_slot = 0;
        for (int s = 0; s < NV_LTR_SLOTS; s++) {
            if (s == keep) continue;
            if (mark_slot == keep || n->ltr[s].token < n->ltr[mark_slot].token) mark_slot = s;
        }
        if (mark_slot == keep) mark_slot = -1;
    }
    if (hevc) {
        NV_ENC_PIC_PARAMS_HEVC *h = &pp.codecPicParams.hevcPicParams;
        if (mark_slot >= 0) {
            h->ltrMarkFrame = 1;
            h->ltrMarkFrameIdx = (uint32_t)mark_slot;
        }
        if (use_slot >= 0) {
            h->ltrUseFrames = 1;
            h->ltrUseFrameBitmap = 1u << use_slot;
        }
    } else {
        NV_ENC_PIC_PARAMS_H264 *h = &pp.codecPicParams.h264PicParams;
        if (mark_slot >= 0) {
            h->ltrMarkFrame = 1;
            h->ltrMarkFrameIdx = (uint32_t)mark_slot;
        }
        if (use_slot >= 0) {
            h->ltrUseFrames = 1;
            h->ltrUseFrameBitmap = 1u << use_slot;
        }
    }

    NVENCSTATUS st = n->fn.nvEncEncodePicture(n->enc, &pp);
    if (st == NV_ENC_SUCCESS) {
        NV_ENC_LOCK_BITSTREAM lb = {0};
        lb.version = NV_ENC_LOCK_BITSTREAM_VER;
        lb.outputBitstream = n->bitstream;
        hr = nv_hr(n->fn.nvEncLockBitstream(n->enc, &lb));
        if (SUCCEEDED(hr)) {
            hr = msw_enc_append(&n->base, lb.bitstreamBufferPtr, lb.bitstreamSizeInBytes);
            out->keyframe = lb.pictureType == NV_ENC_PIC_TYPE_IDR;
            n->fn.nvEncUnlockBitstream(n->enc, n->bitstream);
        }
    } else if (st == NV_ENC_ERR_NEED_MORE_INPUT) {
        hr = S_OK; /* buffered: reported as a drop */
    } else {
        hr = nv_hr(st);
    }
    n->fn.nvEncUnmapInputResource(n->enc, map.mappedResource);
    if (FAILED(hr)) goto done;

    n->frame++;
    n->since_mark++;
    if (mark_slot >= 0) {
        n->ltr[mark_slot].token = n->frame; /* frame number, from 1 */
        n->ltr[mark_slot].acked = 0;
        n->since_mark = 0;
        out->has_ltr_token = 1;
        out->ltr_token = n->frame;
    }
    out->ltr_refresh = use_slot >= 0;
done:
    return hr;
}

static void nv_destroy(msw_enc *e) {
    nv_enc *n = (nv_enc *)e;
    if (n->enc) {
        nv_unregister_all(n);
        if (n->bitstream) n->fn.nvEncDestroyBitstreamBuffer(n->enc, n->bitstream);
        n->fn.nvEncDestroyEncoder(n->enc);
    }
    if (n->dll) FreeLibrary(n->dll);
    free(n);
}

static const msw_enc_ops nv_ops = {nv_caps, nv_configure, nv_encode, nv_destroy};

HRESULT msw_enc_nvenc_create(msw_d3d *d, msw_enc **out) {
#if defined(_M_X64) || defined(__x86_64__)
    const WCHAR *dll = L"nvEncodeAPI64.dll";
#else
    const WCHAR *dll = NULL; /* NVIDIA ships no NVENC for Windows on Arm */
#endif
    if (!dll) return MSW_E_NOTFOUND;
    nv_enc *n = (nv_enc *)calloc(1, sizeof *n);
    if (!n) return E_OUTOFMEMORY;
    n->base.ops = &nv_ops;
    n->base.d = d;
    HRESULT hr;
    n->dll = LoadLibraryExW(dll, NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!n->dll) {
        hr = MSW_E_NOTFOUND;
        goto fail;
    }
    pfn_max_version maxver = (pfn_max_version)(void *)GetProcAddress(n->dll, "NvEncodeAPIGetMaxSupportedVersion");
    pfn_create_instance create = (pfn_create_instance)(void *)GetProcAddress(n->dll, "NvEncodeAPICreateInstance");
    if (!maxver || !create) {
        hr = MSW_E_NOTFOUND;
        goto fail;
    }
    uint32_t v = 0;
    if (maxver(&v) != NV_ENC_SUCCESS || v < ((NVENCAPI_MAJOR_VERSION << 4) | NVENCAPI_MINOR_VERSION)) {
        hr = MSW_DXGI_ERROR_UNSUPPORTED; /* driver older than the header (522.25) */
        goto fail;
    }
    n->fn.version = NV_ENCODE_API_FUNCTION_LIST_VER;
    MSW_TRY(nv_hr(create(&n->fn)), fail);
    NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS op = {0};
    op.version = NV_ENC_OPEN_ENCODE_SESSION_EX_PARAMS_VER;
    op.device = d->device;
    op.deviceType = NV_ENC_DEVICE_TYPE_DIRECTX;
    op.apiVersion = NVENCAPI_VERSION;
    MSW_TRY(nv_hr(n->fn.nvEncOpenEncodeSessionEx(&op, &n->enc)), fail);
    n->h264 = has_guid(n, &NV_ENC_CODEC_H264_GUID);
    n->hevc = has_guid(n, &NV_ENC_CODEC_HEVC_GUID);
    n->ltr_supported = cap(n, n->h264 ? &NV_ENC_CODEC_H264_GUID : &NV_ENC_CODEC_HEVC_GUID, NV_ENC_CAPS_NUM_MAX_LTR_FRAMES) >= NV_LTR_SLOTS;
    if (!n->h264 && !n->hevc) {
        hr = MSW_E_NOTFOUND;
        goto fail;
    }
    *out = &n->base;
    return S_OK;
fail:
    nv_destroy(&n->base);
    return hr;
}
