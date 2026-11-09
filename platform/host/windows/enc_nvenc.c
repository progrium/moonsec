/* NVENC through nvEncodeAPI64.dll, loaded at run time (no link-time NVIDIA dependency).
 * Takes the BGRA D3D11 texture directly (NV_ENC_BUFFER_FORMAT_ARGB). The session,
 * low-latency configuration and long-term references are platform/nvenc/nvenc_core.c,
 * shared with the Linux host; this file is the DLL, the D3D11 device and textures, and
 * NVENCSTATUS as HRESULTs.
 *
 * Untested on hardware so far (CI has no NVIDIA GPU): only create's not-found path runs
 * there. S8's NVENC rows check the LTR behaviour on a real GPU. */
#include "enc_internal.h"

#include <string.h>

#include "nvenc_core.h"

typedef struct nv_enc {
    msw_enc base;
    HMODULE dll;
    nvc core;
} nv_enc;

/* NVENCSTATUS as an HRESULT in FACILITY_ITF (0x8004_7Exx); "no device" maps to not-found. */
static HRESULT nv_hr(NVENCSTATUS s) {
    if (s == NV_ENC_SUCCESS) return S_OK;
    if (s == NV_ENC_ERR_NO_ENCODE_DEVICE || s == NV_ENC_ERR_UNSUPPORTED_DEVICE || s == NV_ENC_ERR_INVALID_ENCODERDEVICE)
        return MSW_E_NOTFOUND;
    if (s == NV_ENC_ERR_OUT_OF_MEMORY) return E_OUTOFMEMORY;
    if (s == NV_ENC_ERR_DEVICE_NOT_EXIST) return MSW_DXGI_ERROR_DEVICE_REMOVED;
    if (s == NV_ENC_ERR_UNIMPLEMENTED || s == NV_ENC_ERR_UNSUPPORTED_PARAM || s == NV_ENC_ERR_INVALID_VERSION)
        return MSW_DXGI_ERROR_UNSUPPORTED;
    return MAKE_HRESULT(1, FACILITY_ITF, 0x7E00 + (int)s);
}

static void nv_caps(const msw_enc *e, msw_enc_caps *out) {
    const nv_enc *n = (const nv_enc *)e;
    out->h264 = (uint32_t)n->core.h264;
    out->hevc = (uint32_t)n->core.hevc;
    out->ltr = (uint32_t)n->core.ltr_supported;
    out->max_slices = 4;
    out->gpu_input = 1;
}

static HRESULT nv_configure(msw_enc *e, const msw_enc_config *cfg) {
    nv_enc *n = (nv_enc *)e;
    if (cfg->codec != MSW_CODEC_H264 && cfg->codec != MSW_CODEC_HEVC) return MSW_DXGI_ERROR_UNSUPPORTED;
    const nvc_config c = {
        .codec = cfg->codec == MSW_CODEC_HEVC ? NVC_CODEC_HEVC : NVC_CODEC_H264,
        .width = cfg->width,
        .height = cfg->height,
        .fps = cfg->fps,
        .bitrate_bps = cfg->bitrate_bps,
        .slices = cfg->slices,
        .ltr = cfg->ltr,
    };
    return nv_hr(nvc_configure(&n->core, &c));
}

static int nv_append(void *ctx, const void *data, size_t len) { return FAILED(msw_enc_append((msw_enc *)ctx, data, len)); }

static HRESULT nv_encode(msw_enc *e, ID3D11Texture2D *tex, UINT index, uint64_t time_us, const msw_enc_params *p,
                         msw_enc_output *out) {
    nv_enc *n = (nv_enc *)e;
    NV_ENC_REGISTERED_PTR reg;
    HRESULT hr = nv_hr(nvc_register(&n->core, NV_ENC_INPUT_RESOURCE_TYPE_DIRECTX, tex, index, 0, NV_ENC_BUFFER_FORMAT_ARGB, &reg));
    if (FAILED(hr)) return hr;
    const nvc_params np = {
        .force = p->force == MSW_FORCE_IDR ? NVC_FORCE_IDR : p->force == MSW_FORCE_LTR_REFRESH ? NVC_FORCE_LTR_REFRESH : NVC_FORCE_NONE,
        .bitrate_bps = p->bitrate_bps,
        .acked_ltr_tokens = p->acked_ltr_tokens,
        .acked_ltr_count = p->acked_ltr_count,
    };
    nvc_output o;
    hr = nv_hr(nvc_encode(&n->core, reg, time_us, &np, nv_append, &n->base, &o));
    if (FAILED(hr)) return hr;
    out->keyframe = o.keyframe;
    out->has_ltr_token = o.has_ltr_token;
    out->ltr_token = o.ltr_token;
    out->ltr_refresh = o.ltr_refresh;
    return S_OK;
}

static void nv_destroy(msw_enc *e) {
    nv_enc *n = (nv_enc *)e;
    nvc_close(&n->core);
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
    nvc_pfn_max_version maxver = (nvc_pfn_max_version)(void *)GetProcAddress(n->dll, "NvEncodeAPIGetMaxSupportedVersion");
    nvc_pfn_create_instance create = (nvc_pfn_create_instance)(void *)GetProcAddress(n->dll, "NvEncodeAPICreateInstance");
    if (!maxver || !create) {
        hr = MSW_E_NOTFOUND;
        goto fail;
    }
    hr = nv_hr(nvc_open(&n->core, maxver, create, d->device, NV_ENC_DEVICE_TYPE_DIRECTX));
    if (FAILED(hr)) goto fail;
    *out = &n->base;
    return S_OK;
fail:
    nv_destroy(&n->base);
    return hr;
}
