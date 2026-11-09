/* Media Foundation software H.264 encoder (a sync MFT, normally the Microsoft H.264
 * Video Encoder). BGRA textures are read back and converted to NV12 on the CPU, so this
 * is the CI path and the last fallback, not a fast path. No long-term references. */
#include <initguid.h> /* define the MF and CODECAPI GUIDs here (selectany) */
#include "enc_internal.h"

#include <codecapi.h>
#include <mfapi.h>
#include <mferror.h>
#include <mftransform.h>
#include <oleauto.h>
#include <strmif.h>
#include <string.h>

/* codecapi.h only gives C++ __uuidof names; build GUIDs from its STATIC_ values. */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wmissing-braces"
#define CAPI(n) static const GUID kCapi_##n = {STATIC_CODECAPI_##n};
CAPI(AVEncCommonBufferSize)
CAPI(AVEncCommonMeanBitRate)
CAPI(AVEncCommonQualityVsSpeed)
CAPI(AVEncCommonRateControlMode)
CAPI(AVEncMPVDefaultBPictureCount)
CAPI(AVEncMPVGOPSize)
CAPI(AVEncVideoForceKeyFrame)
CAPI(AVLowLatencyMode)
#undef CAPI
#pragma clang diagnostic pop

typedef struct mf_enc {
    msw_enc base;
    int mf_started;
    IMFTransform *mft;
    ICodecAPI *codec;
    DWORD in_id, out_id;
    int provides_samples;
    DWORD out_size;
    uint64_t bitrate;
    ID3D11Texture2D *staging;
    uint32_t staging_w, staging_h;
} mf_enc;

static void mf_close(mf_enc *m) {
    if (m->mft) {
        IMFTransform_ProcessMessage(m->mft, MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
        IMFTransform_ProcessMessage(m->mft, MFT_MESSAGE_NOTIFY_END_STREAMING, 0);
    }
    MSW_RELEASE(m->codec);
    MSW_RELEASE(m->mft);
}

static HRESULT mf_activate(mf_enc *m) {
    MFT_REGISTER_TYPE_INFO in = {MFMediaType_Video, MFVideoFormat_NV12};
    MFT_REGISTER_TYPE_INFO outt = {MFMediaType_Video, MFVideoFormat_H264};
    IMFActivate **acts = NULL;
    UINT32 n = 0;
    HRESULT hr = MFTEnumEx(MFT_CATEGORY_VIDEO_ENCODER, MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_LOCALMFT | MFT_ENUM_FLAG_SORTANDFILTER,
                           &in, &outt, &acts, &n);
    if (FAILED(hr)) return hr;
    if (n == 0) hr = MSW_E_NOTFOUND;
    else hr = IMFActivate_ActivateObject(acts[0], &IID_IMFTransform, (void **)&m->mft);
    for (UINT32 i = 0; i < n; i++) IMFActivate_Release(acts[i]);
    CoTaskMemFree(acts);
    if (FAILED(hr)) return hr;
    if (FAILED(IMFTransform_QueryInterface(m->mft, &IID_ICodecAPI, (void **)&m->codec))) m->codec = NULL;
    return S_OK;
}

static HRESULT set_u4(ICodecAPI *c, const GUID *api, ULONG v) {
    if (!c) return E_NOINTERFACE;
    VARIANT var;
    VariantInit(&var);
    var.vt = VT_UI4;
    var.ulVal = v;
    return ICodecAPI_SetValue(c, api, &var);
}

static HRESULT set_bool(ICodecAPI *c, const GUID *api, int v) {
    if (!c) return E_NOINTERFACE;
    VARIANT var;
    VariantInit(&var);
    var.vt = VT_BOOL;
    var.boolVal = v ? VARIANT_TRUE : VARIANT_FALSE;
    return ICodecAPI_SetValue(c, api, &var);
}

static void mf_caps(const msw_enc *e, msw_enc_caps *out) {
    (void)e;
    out->h264 = 1;
    out->max_slices = 1;
    out->cpu_input = 0;
    out->gpu_input = 1; /* takes the texture; the readback is internal */
}

static HRESULT video_type(const GUID *subtype, const msw_enc_config *cfg, IMFMediaType **out) {
    IMFMediaType *t = NULL;
    HRESULT hr;
    MSW_TRY(MFCreateMediaType(&t), fail);
    MSW_TRY(IMFMediaType_SetGUID(t, &MF_MT_MAJOR_TYPE, &MFMediaType_Video), fail);
    MSW_TRY(IMFMediaType_SetGUID(t, &MF_MT_SUBTYPE, subtype), fail);
    MSW_TRY(IMFMediaType_SetUINT64(t, &MF_MT_FRAME_SIZE, ((UINT64)cfg->width << 32) | cfg->height), fail);
    MSW_TRY(IMFMediaType_SetUINT64(t, &MF_MT_FRAME_RATE, ((UINT64)cfg->fps << 32) | 1), fail);
    MSW_TRY(IMFMediaType_SetUINT64(t, &MF_MT_PIXEL_ASPECT_RATIO, ((UINT64)1 << 32) | 1), fail);
    MSW_TRY(IMFMediaType_SetUINT32(t, &MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive), fail);
    MSW_TRY(IMFMediaType_SetUINT32(t, &MF_MT_YUV_MATRIX, MFVideoTransferMatrix_BT709), fail);
    MSW_TRY(IMFMediaType_SetUINT32(t, &MF_MT_VIDEO_NOMINAL_RANGE, MFNominalRange_16_235), fail);
    *out = t;
    return S_OK;
fail:
    MSW_RELEASE(t);
    return hr;
}

static HRESULT mf_configure(msw_enc *e, const msw_enc_config *cfg) {
    mf_enc *m = (mf_enc *)e;
    if (cfg->codec != MSW_CODEC_H264) return MSW_DXGI_ERROR_UNSUPPORTED;
    if ((cfg->width | cfg->height) & 1) return E_INVALIDARG;
    mf_close(m);
    HRESULT hr;
    IMFMediaType *outt = NULL, *in = NULL;
    MSW_TRY(mf_activate(m), done);

    /* Rate control and latency before the media types, as the encoder reads them then. */
    set_u4(m->codec, &kCapi_AVEncCommonRateControlMode, eAVEncCommonRateControlMode_CBR);
    set_u4(m->codec, &kCapi_AVEncCommonMeanBitRate, (ULONG)cfg->bitrate_bps);
    set_bool(m->codec, &kCapi_AVLowLatencyMode, 1);
    set_u4(m->codec, &kCapi_AVEncMPVDefaultBPictureCount, 0);
    /* No periodic keyframes: one GOP per hour. */
    set_u4(m->codec, &kCapi_AVEncMPVGOPSize, cfg->fps * 3600);
    /* One-frame VBV. */
    set_u4(m->codec, &kCapi_AVEncCommonBufferSize, (ULONG)(cfg->bitrate_bps / cfg->fps));
    set_u4(m->codec, &kCapi_AVEncCommonQualityVsSpeed, 0);

    MSW_TRY(video_type(&MFVideoFormat_H264, cfg, &outt), done);
    MSW_TRY(IMFMediaType_SetUINT32(outt, &MF_MT_AVG_BITRATE, (UINT32)cfg->bitrate_bps), done);
    MSW_TRY(IMFMediaType_SetUINT32(outt, &MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_Base), done);
    MSW_TRY(video_type(&MFVideoFormat_NV12, cfg, &in), done);

    hr = IMFTransform_GetStreamIDs(m->mft, 1, &m->in_id, 1, &m->out_id);
    if (hr == E_NOTIMPL) m->in_id = m->out_id = 0;
    else if (FAILED(hr)) goto done;
    MSW_TRY(IMFTransform_SetOutputType(m->mft, m->out_id, outt, 0), done);
    MSW_TRY(IMFTransform_SetInputType(m->mft, m->in_id, in, 0), done);

    MFT_OUTPUT_STREAM_INFO si;
    MSW_TRY(IMFTransform_GetOutputStreamInfo(m->mft, m->out_id, &si), done);
    m->provides_samples = (si.dwFlags & (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES | MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES)) != 0;
    m->out_size = si.cbSize ? si.cbSize : cfg->width * cfg->height * 3 / 2;
    m->bitrate = cfg->bitrate_bps;
    MSW_TRY(IMFTransform_ProcessMessage(m->mft, MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0), done);
    MSW_TRY(IMFTransform_ProcessMessage(m->mft, MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0), done);
done:
    MSW_RELEASE(outt);
    MSW_RELEASE(in);
    if (FAILED(hr)) mf_close(m);
    return hr;
}

static inline uint8_t clamp8(int v) { return (uint8_t)(v < 0 ? 0 : v > 255 ? 255 : v); }

/* BGRA to NV12, BT.709 limited range, chroma from each 2x2 block's average. */
static void bgra_to_nv12(const uint8_t *src, uint32_t pitch, uint32_t w, uint32_t h, uint8_t *dst) {
    uint8_t *yp = dst, *uv = dst + (size_t)w * h;
    for (uint32_t y = 0; y < h; y += 2) {
        const uint8_t *r0 = src + (size_t)y * pitch, *r1 = r0 + pitch;
        uint8_t *y0 = yp + (size_t)y * w, *y1 = y0 + w, *c = uv + (size_t)(y / 2) * w;
        for (uint32_t x = 0; x < w; x += 2) {
            int sb = 0, sg = 0, sr = 0;
            for (int k = 0; k < 4; k++) {
                const uint8_t *p = (k < 2 ? r0 : r1) + (size_t)(x + (k & 1)) * 4;
                int b = p[0], g = p[1], r = p[2];
                (k < 2 ? y0 : y1)[x + (k & 1)] = clamp8(((47 * r + 157 * g + 16 * b + 128) >> 8) + 16);
                sb += b;
                sg += g;
                sr += r;
            }
            sb = (sb + 2) >> 2;
            sg = (sg + 2) >> 2;
            sr = (sr + 2) >> 2;
            c[x] = clamp8(((-26 * sr - 87 * sg + 112 * sb + 128) >> 8) + 128);
            c[x + 1] = clamp8(((112 * sr - 102 * sg - 10 * sb + 128) >> 8) + 128);
        }
    }
}

static HRESULT mf_input_sample(mf_enc *m, ID3D11Texture2D *tex, UINT index, uint64_t time_us, IMFSample **out) {
    const uint32_t w = m->base.cfg.width, h = m->base.cfg.height;
    HRESULT hr;
    IMFMediaBuffer *buf = NULL;
    IMFSample *s = NULL;
    D3D11_TEXTURE2D_DESC td;
    ID3D11Texture2D_GetDesc(tex, &td);
    if (td.Width < w || td.Height < h || td.Format != DXGI_FORMAT_B8G8R8A8_UNORM) return E_INVALIDARG;
    if (!m->staging || m->staging_w != w || m->staging_h != h) {
        MSW_RELEASE(m->staging);
        D3D11_TEXTURE2D_DESC sd = {0};
        sd.Width = w;
        sd.Height = h;
        sd.MipLevels = 1;
        sd.ArraySize = 1;
        sd.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        sd.SampleDesc.Count = 1;
        sd.Usage = D3D11_USAGE_STAGING;
        sd.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        MSW_TRY(ID3D11Device_CreateTexture2D(m->base.d->device, &sd, NULL, &m->staging), fail);
        m->staging_w = w;
        m->staging_h = h;
    }
    D3D11_BOX box = {0, 0, 0, w, h, 1};
    ID3D11DeviceContext_CopySubresourceRegion(m->base.d->context, (ID3D11Resource *)m->staging, 0, 0, 0, 0,
                                              (ID3D11Resource *)tex, index, &box);
    D3D11_MAPPED_SUBRESOURCE map;
    MSW_TRY(ID3D11DeviceContext_Map(m->base.d->context, (ID3D11Resource *)m->staging, 0, D3D11_MAP_READ, 0, &map), fail);
    const DWORD len = w * h * 3 / 2;
    hr = MFCreateMemoryBuffer(len, &buf);
    if (SUCCEEDED(hr)) {
        BYTE *p = NULL;
        hr = IMFMediaBuffer_Lock(buf, &p, NULL, NULL);
        if (SUCCEEDED(hr)) {
            bgra_to_nv12((const uint8_t *)map.pData, map.RowPitch, w, h, p);
            IMFMediaBuffer_Unlock(buf);
            IMFMediaBuffer_SetCurrentLength(buf, len);
        }
    }
    ID3D11DeviceContext_Unmap(m->base.d->context, (ID3D11Resource *)m->staging, 0);
    if (FAILED(hr)) goto fail;
    MSW_TRY(MFCreateSample(&s), fail);
    MSW_TRY(IMFSample_AddBuffer(s, buf), fail);
    MSW_TRY(IMFSample_SetSampleTime(s, (LONGLONG)time_us * 10), fail);
    MSW_TRY(IMFSample_SetSampleDuration(s, 10000000ll / m->base.cfg.fps), fail);
    MSW_RELEASE(buf);
    *out = s;
    return S_OK;
fail:
    MSW_RELEASE(buf);
    MSW_RELEASE(s);
    return hr;
}

/* Pulls every pending output sample into e->out. */
static HRESULT mf_drain(mf_enc *m, msw_enc_output *out) {
    for (;;) {
        IMFSample *os = NULL;
        IMFMediaBuffer *ob = NULL;
        HRESULT hr;
        if (!m->provides_samples) {
            MSW_TRY(MFCreateSample(&os), fail);
            MSW_TRY(MFCreateMemoryBuffer(m->out_size, &ob), fail);
            MSW_TRY(IMFSample_AddBuffer(os, ob), fail);
            MSW_RELEASE(ob);
        }
        MFT_OUTPUT_DATA_BUFFER db = {m->out_id, os, 0, NULL};
        DWORD status = 0;
        hr = IMFTransform_ProcessOutput(m->mft, 0, 1, &db, &status);
        if (db.pEvents) IMFCollection_Release(db.pEvents);
        if (m->provides_samples) os = db.pSample;
        if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT) {
            MSW_RELEASE(os);
            return S_OK;
        }
        if (hr == MF_E_TRANSFORM_STREAM_CHANGE) {
            MSW_RELEASE(os);
            IMFMediaType *t = NULL;
            MSW_TRY(IMFTransform_GetOutputAvailableType(m->mft, m->out_id, 0, &t), fail);
            hr = IMFTransform_SetOutputType(m->mft, m->out_id, t, 0);
            MSW_RELEASE(t);
            if (FAILED(hr)) return hr;
            continue;
        }
        if (FAILED(hr)) goto fail;
        UINT32 clean = 0;
        if (SUCCEEDED(IMFSample_GetUINT32(os, &MFSampleExtension_CleanPoint, &clean)) && clean) out->keyframe = 1;
        MSW_TRY(IMFSample_ConvertToContiguousBuffer(os, &ob), fail);
        BYTE *p = NULL;
        DWORD len = 0;
        MSW_TRY(IMFMediaBuffer_Lock(ob, &p, NULL, &len), fail);
        hr = msw_enc_append(&m->base, p, len);
        IMFMediaBuffer_Unlock(ob);
        if (FAILED(hr)) goto fail;
        MSW_RELEASE(ob);
        MSW_RELEASE(os);
        continue;
    fail:
        MSW_RELEASE(ob);
        MSW_RELEASE(os);
        return hr;
    }
}

static HRESULT mf_encode(msw_enc *e, ID3D11Texture2D *tex, UINT index, uint64_t time_us, const msw_enc_params *p,
                         msw_enc_output *out) {
    mf_enc *m = (mf_enc *)e;
    HRESULT hr;
    IMFSample *s = NULL;
    if (p->bitrate_bps && p->bitrate_bps != m->bitrate) {
        if (SUCCEEDED(set_u4(m->codec, &kCapi_AVEncCommonMeanBitRate, (ULONG)p->bitrate_bps))) m->bitrate = p->bitrate_bps;
    }
    /* No long-term references here: an LTR refresh is an IDR. */
    if (p->force != MSW_FORCE_NONE) set_u4(m->codec, &kCapi_AVEncVideoForceKeyFrame, 1);
    MSW_TRY(mf_input_sample(m, tex, index, time_us, &s), done);
    hr = IMFTransform_ProcessInput(m->mft, m->in_id, s, 0);
    if (hr == MF_E_NOTACCEPTING) {
        MSW_TRY(mf_drain(m, out), done);
        hr = IMFTransform_ProcessInput(m->mft, m->in_id, s, 0);
    }
    if (FAILED(hr)) goto done;
    hr = mf_drain(m, out);
done:
    MSW_RELEASE(s);
    return hr;
}

static void mf_destroy(msw_enc *e) {
    mf_enc *m = (mf_enc *)e;
    mf_close(m);
    MSW_RELEASE(m->staging);
    if (m->mf_started) MFShutdown();
    free(m);
}

static const msw_enc_ops mf_ops = {mf_caps, mf_configure, mf_encode, mf_destroy};

HRESULT msw_enc_mf_create(msw_d3d *d, msw_enc **out) {
    mf_enc *m = (mf_enc *)calloc(1, sizeof *m);
    if (!m) return E_OUTOFMEMORY;
    m->base.ops = &mf_ops;
    m->base.d = d;
    HRESULT hr = MFStartup(MF_VERSION, MFSTARTUP_LITE);
    if (FAILED(hr)) {
        free(m);
        return hr == E_NOTIMPL ? MSW_E_NOTFOUND : hr;
    }
    m->mf_started = 1;
    /* Probe now so a machine without the encoder fails at create, not configure. */
    hr = mf_activate(m);
    mf_close(m);
    if (FAILED(hr)) {
        mf_destroy(&m->base);
        return hr;
    }
    *out = &m->base;
    return S_OK;
}
