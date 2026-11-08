/* Media Foundation video decode: the system H.264/HEVC decoder MFT in low-latency
 * mode, on D3D11VA through a DXGI device manager when it can, in software otherwise.
 *
 * Why the MFT and not raw D3D11VA: driving ID3D11VideoDecoder directly needs our own
 * H.264 and HEVC slice-header parsing to fill the DXVA picture parameters. The system
 * MFT does that and then decodes on the same D3D11VA hardware, handing back NV12
 * textures from its own pool. CODECAPI_AVLowLatencyMode makes it emit each frame as
 * soon as it is decoded (no reorder delay), which is right for our streams (no
 * B-frames). The software path is the same MFT without a device manager; CI (WARP, no
 * GPU) runs that one.
 */
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#include "msw_internal.h"
#include "mswc.h"

#include <initguid.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mftransform.h>
#include <codecapi.h>
#include <icodecapi.h>
#include <string.h>

struct mswc_decoder {
    msw_d3d *d3d;
    IMFTransform *mft;
    IMFDXGIDeviceManager *dm;
    int hw;
    int out_provides_samples;
    DWORD out_size;
    /* Output type: coded size, crop, stride (software). */
    UINT32 coded_w, coded_h, crop_w, crop_h;
    LONG stride;
    int have_output_type;
    /* Software path: the texture frames are uploaded to. */
    ID3D11Texture2D *upload;
    UINT32 upload_w, upload_h;
    int mf_started;
};

static HRESULT set_output_type(mswc_decoder *d) {
    HRESULT hr = MF_E_INVALIDMEDIATYPE;
    for (DWORD i = 0;; i++) {
        IMFMediaType *t = NULL;
        HRESULT e = IMFTransform_GetOutputAvailableType(d->mft, 0, i, &t);
        if (FAILED(e)) {
            if (e != MF_E_NO_MORE_TYPES) hr = e;
            break;
        }
        GUID sub;
        if (SUCCEEDED(IMFMediaType_GetGUID(t, &MF_MT_SUBTYPE, &sub)) && IsEqualGUID(&sub, &MFVideoFormat_NV12)) {
            hr = IMFTransform_SetOutputType(d->mft, 0, t, 0);
            if (SUCCEEDED(hr)) {
                UINT64 fs = 0;
                IMFMediaType_GetUINT64(t, &MF_MT_FRAME_SIZE, &fs);
                d->coded_w = (UINT32)(fs >> 32);
                d->coded_h = (UINT32)fs;
                d->crop_w = d->coded_w;
                d->crop_h = d->coded_h;
                MFVideoArea area;
                UINT32 sz = 0;
                if (SUCCEEDED(IMFMediaType_GetBlob(t, &MF_MT_MINIMUM_DISPLAY_APERTURE, (UINT8 *)&area, sizeof area,
                                                   &sz)) &&
                    sz == sizeof area && area.Area.cx > 0 && area.Area.cy > 0) {
                    d->crop_w = (UINT32)area.Area.cx;
                    d->crop_h = (UINT32)area.Area.cy;
                }
                UINT32 stride = 0;
                if (SUCCEEDED(IMFMediaType_GetUINT32(t, &MF_MT_DEFAULT_STRIDE, &stride)))
                    d->stride = (LONG)stride;
                else
                    d->stride = (LONG)d->coded_w;
                MFT_OUTPUT_STREAM_INFO si;
                memset(&si, 0, sizeof si);
                if (SUCCEEDED(IMFTransform_GetOutputStreamInfo(d->mft, 0, &si))) {
                    d->out_provides_samples =
                        (si.dwFlags & (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES | MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES)) != 0;
                    d->out_size = si.cbSize;
                }
                d->have_output_type = d->coded_w > 0 && d->coded_h > 0;
            }
            MSW_RELEASE(t);
            break;
        }
        MSW_RELEASE(t);
    }
    return hr;
}

static HRESULT find_mft(const GUID *subtype, IMFTransform **out) {
    MFT_REGISTER_TYPE_INFO in = {MFMediaType_Video, *subtype};
    IMFActivate **acts = NULL;
    UINT32 n = 0;
    HRESULT hr = MFTEnumEx(MFT_CATEGORY_VIDEO_DECODER, MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_LOCALMFT |
                                                           MFT_ENUM_FLAG_SORTANDFILTER,
                           &in, NULL, &acts, &n);
    if (FAILED(hr)) return hr;
    hr = MF_E_TOPO_CODEC_NOT_FOUND;
    for (UINT32 i = 0; i < n; i++) {
        if (FAILED(hr)) hr = IMFActivate_ActivateObject(acts[i], &IID_IMFTransform, (void **)out);
        IMFActivate_Release(acts[i]);
    }
    CoTaskMemFree(acts);
    return hr;
}

msw_hr mswc_decoder_create(msw_d3d *d3d, uint32_t codec, int hardware, mswc_decoder **out) {
    *out = NULL;
    const GUID *sub;
    if (codec == MSWC_CODEC_H264)
        sub = &MFVideoFormat_H264;
    else if (codec == MSWC_CODEC_HEVC)
        sub = &MFVideoFormat_HEVC;
    else
        return E_INVALIDARG;

    mswc_decoder *d = (mswc_decoder *)calloc(1, sizeof *d);
    if (!d) return E_OUTOFMEMORY;
    d->d3d = d3d;
    HRESULT hr;
    IMFAttributes *attrs = NULL;
    IMFMediaType *in = NULL;
    ICodecAPI *api = NULL;

    MSW_TRY(MFStartup(MF_VERSION, MFSTARTUP_LITE), fail);
    d->mf_started = 1;
    MSW_TRY(find_mft(sub, &d->mft), fail);

    if (SUCCEEDED(IMFTransform_GetAttributes(d->mft, &attrs))) {
        IMFAttributes_SetUINT32(attrs, &MF_LOW_LATENCY, TRUE);
        UINT32 aware = 0;
        if (hardware && SUCCEEDED(IMFAttributes_GetUINT32(attrs, &MF_SA_D3D11_AWARE, &aware)) && aware) {
            UINT token = 0;
            if (SUCCEEDED(MFCreateDXGIDeviceManager(&token, &d->dm)) &&
                SUCCEEDED(IMFDXGIDeviceManager_ResetDevice(d->dm, (IUnknown *)d3d->device, token)) &&
                SUCCEEDED(IMFTransform_ProcessMessage(d->mft, MFT_MESSAGE_SET_D3D_MANAGER, (ULONG_PTR)d->dm))) {
                d->hw = 1;
            } else {
                IMFTransform_ProcessMessage(d->mft, MFT_MESSAGE_SET_D3D_MANAGER, 0);
                MSW_RELEASE(d->dm);
            }
        }
    }
    if (SUCCEEDED(IMFTransform_QueryInterface(d->mft, &IID_ICodecAPI, (void **)&api))) {
        VARIANT v;
        VariantInit(&v);
        v.vt = VT_UI4;
        v.ulVal = 1;
        /* CODECAPI_AVLowLatencyMode; same GUID as MF_LOW_LATENCY, which C can name. */
        ICodecAPI_SetValue(api, &MF_LOW_LATENCY, &v);
        MSW_RELEASE(api);
    }

    MSW_TRY(MFCreateMediaType(&in), fail);
    IMFMediaType_SetGUID(in, &MF_MT_MAJOR_TYPE, &MFMediaType_Video);
    IMFMediaType_SetGUID(in, &MF_MT_SUBTYPE, sub);
    IMFMediaType_SetUINT32(in, &MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
    MSW_TRY(IMFTransform_SetInputType(d->mft, 0, in, 0), fail);
    /* The output type may not be settable before the first frame; then the first
     * ProcessOutput reports a stream change and we set it there. */
    set_output_type(d);

    IMFTransform_ProcessMessage(d->mft, MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
    IMFTransform_ProcessMessage(d->mft, MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
    MSW_RELEASE(in);
    MSW_RELEASE(attrs);
    *out = d;
    return S_OK;

fail:
    MSW_RELEASE(in);
    MSW_RELEASE(attrs);
    mswc_decoder_destroy(d);
    return hr;
}

void mswc_decoder_destroy(mswc_decoder *d) {
    if (!d) return;
    if (d->mft) {
        IMFTransform_ProcessMessage(d->mft, MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
        IMFTransform_ProcessMessage(d->mft, MFT_MESSAGE_NOTIFY_END_STREAMING, 0);
        if (d->dm) IMFTransform_ProcessMessage(d->mft, MFT_MESSAGE_SET_D3D_MANAGER, 0);
    }
    MSW_RELEASE(d->mft);
    MSW_RELEASE(d->dm);
    MSW_RELEASE(d->upload);
    if (d->mf_started) MFShutdown();
    free(d);
}

int mswc_decoder_is_hardware(const mswc_decoder *d) { return d->hw; }

static HRESULT make_sample(DWORD size, IMFSample **out) {
    IMFSample *s = NULL;
    IMFMediaBuffer *b = NULL;
    HRESULT hr;
    MSW_TRY(MFCreateSample(&s), fail);
    MSW_TRY(MFCreateMemoryBuffer(size, &b), fail);
    MSW_TRY(IMFSample_AddBuffer(s, b), fail);
    MSW_RELEASE(b);
    *out = s;
    return S_OK;
fail:
    MSW_RELEASE(b);
    MSW_RELEASE(s);
    return hr;
}

/* Software path: copy the NV12 picture into the upload texture. */
static HRESULT upload(mswc_decoder *d, IMFSample *s, mswc_frame *f) {
    HRESULT hr;
    IMFMediaBuffer *b = NULL;
    IMF2DBuffer *b2 = NULL;
    BYTE *p = NULL;
    LONG pitch = 0;
    DWORD max = 0, cur = 0;
    int locked2d = 0, locked = 0;
    MSW_TRY(IMFSample_GetBufferByIndex(s, 0, &b), done);
    if (SUCCEEDED(IMFMediaBuffer_QueryInterface(b, &IID_IMF2DBuffer, (void **)&b2)) &&
        SUCCEEDED(IMF2DBuffer_Lock2D(b2, &p, &pitch))) {
        locked2d = 1;
    } else {
        MSW_TRY(IMFMediaBuffer_Lock(b, &p, &max, &cur), done);
        locked = 1;
        pitch = d->stride;
    }
    if (pitch <= 0) {
        hr = E_UNEXPECTED; /* bottom-up NV12 does not exist */
        goto done;
    }
    if (!d->upload || d->upload_w != d->coded_w || d->upload_h != d->coded_h) {
        MSW_RELEASE(d->upload);
        D3D11_TEXTURE2D_DESC td;
        memset(&td, 0, sizeof td);
        td.Width = d->coded_w;
        td.Height = d->coded_h;
        td.MipLevels = 1;
        td.ArraySize = 1;
        td.Format = DXGI_FORMAT_NV12;
        td.SampleDesc.Count = 1;
        td.Usage = D3D11_USAGE_DEFAULT;
        td.BindFlags = D3D11_BIND_SHADER_RESOURCE;
        MSW_TRY(ID3D11Device_CreateTexture2D(d->d3d->device, &td, NULL, &d->upload), done);
        d->upload_w = d->coded_w;
        d->upload_h = d->coded_h;
    }
    /* NV12 UpdateSubresource takes both planes from one pointer: the UV rows follow
     * the Y rows at the same pitch, which is how MF lays out its buffer. */
    ID3D11DeviceContext_UpdateSubresource(d->d3d->context, (ID3D11Resource *)d->upload, 0, NULL, p, (UINT)pitch,
                                          (UINT)pitch * d->coded_h * 3 / 2);
    f->texture = d->upload;
    f->index = 0;
    hr = S_OK;
done:
    if (locked2d) IMF2DBuffer_Unlock2D(b2);
    if (locked) IMFMediaBuffer_Unlock(b);
    MSW_RELEASE(b2);
    MSW_RELEASE(b);
    return hr;
}

static HRESULT to_frame(mswc_decoder *d, IMFSample *s, mswc_frame *f) {
    memset(f, 0, sizeof *f);
    LONGLONG t = 0;
    IMFSample_GetSampleTime(s, &t);
    f->pts = t;
    f->width = d->crop_w;
    f->height = d->crop_h;
    if (!d->hw) return upload(d, s, f);

    HRESULT hr;
    IMFMediaBuffer *b = NULL;
    IMFDXGIBuffer *db = NULL;
    ID3D11Texture2D *tex = NULL;
    UINT idx = 0;
    MSW_TRY(IMFSample_GetBufferByIndex(s, 0, &b), done);
    MSW_TRY(IMFMediaBuffer_QueryInterface(b, &IID_IMFDXGIBuffer, (void **)&db), done);
    MSW_TRY(IMFDXGIBuffer_GetResource(db, &IID_ID3D11Texture2D, (void **)&tex), done);
    MSW_TRY(IMFDXGIBuffer_GetSubresourceIndex(db, &idx), done);
    /* The sample keeps the texture alive; hold the sample, not an extra texture ref. */
    f->texture = tex;
    f->index = idx;
    IMFSample_AddRef(s);
    f->_sample = s;
done:
    MSW_RELEASE(tex);
    MSW_RELEASE(db);
    MSW_RELEASE(b);
    return hr;
}

/* Pulls every output the MFT has. The newest picture ends in *frame. */
static HRESULT drain(mswc_decoder *d, mswc_frame *frame, int *got) {
    for (int guard = 0; guard < 16; guard++) {
        MFT_OUTPUT_DATA_BUFFER ob;
        memset(&ob, 0, sizeof ob);
        HRESULT hr;
        if (!d->out_provides_samples) {
            if (!d->have_output_type) {
                hr = set_output_type(d);
                if (FAILED(hr)) return hr;
            }
            DWORD size = d->out_size ? d->out_size : d->coded_w * d->coded_h * 3 / 2;
            MSW_TRY(make_sample(size, &ob.pSample), out);
        }
        DWORD status = 0;
        hr = IMFTransform_ProcessOutput(d->mft, 0, 1, &ob, &status);
        if (ob.pEvents) IMFCollection_Release(ob.pEvents);
        if (hr == MF_E_TRANSFORM_STREAM_CHANGE) {
            if (ob.pSample) IMFSample_Release(ob.pSample);
            d->have_output_type = 0;
            hr = set_output_type(d);
            if (FAILED(hr)) return hr;
            continue;
        }
        if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT) {
            if (ob.pSample) IMFSample_Release(ob.pSample);
            return S_OK;
        }
        if (FAILED(hr)) {
            if (ob.pSample) IMFSample_Release(ob.pSample);
            return hr;
        }
        if (*got) mswc_decoder_release_frame(d, frame);
        hr = to_frame(d, ob.pSample, frame);
        IMFSample_Release(ob.pSample);
        if (FAILED(hr)) return hr;
        *got = 1;
    out:
        if (FAILED(hr)) return hr;
    }
    return S_OK;
}

msw_hr mswc_decoder_decode(mswc_decoder *d, const uint8_t *data, size_t len, int64_t pts, mswc_frame *frame,
                           int *got) {
    *got = 0;
    memset(frame, 0, sizeof *frame);
    if (len == 0 || len > 0x7fffffff) return E_INVALIDARG;
    HRESULT hr;
    IMFSample *s = NULL;
    IMFMediaBuffer *b = NULL;
    BYTE *p = NULL;
    MSW_TRY(make_sample((DWORD)len, &s), done);
    MSW_TRY(IMFSample_GetBufferByIndex(s, 0, &b), done);
    MSW_TRY(IMFMediaBuffer_Lock(b, &p, NULL, NULL), done);
    memcpy(p, data, len);
    IMFMediaBuffer_Unlock(b);
    IMFMediaBuffer_SetCurrentLength(b, (DWORD)len);
    IMFSample_SetSampleTime(s, pts);

    hr = IMFTransform_ProcessInput(d->mft, 0, s, 0);
    if (hr == MF_E_NOTACCEPTING) {
        MSW_TRY(drain(d, frame, got), done);
        hr = IMFTransform_ProcessInput(d->mft, 0, s, 0);
    }
    if (FAILED(hr)) goto done;
    hr = drain(d, frame, got);
done:
    if (FAILED(hr) && *got) {
        mswc_decoder_release_frame(d, frame);
        *got = 0;
    }
    MSW_RELEASE(b);
    MSW_RELEASE(s);
    return hr;
}

void mswc_decoder_release_frame(mswc_decoder *d, mswc_frame *f) {
    (void)d;
    if (f->_sample) IMFSample_Release((IMFSample *)f->_sample);
    memset(f, 0, sizeof *f);
}

msw_hr mswc_decoder_flush(mswc_decoder *d) { return IMFTransform_ProcessMessage(d->mft, MFT_MESSAGE_COMMAND_FLUSH, 0); }

msw_hr mswc_frame_read_nv12(msw_d3d *d3d, const mswc_frame *f, uint32_t x, uint32_t y, uint8_t yuv[3]) {
    if (!f->texture || x >= f->width || y >= f->height) return E_INVALIDARG;
    x &= ~1u;
    y &= ~1u;
    HRESULT hr;
    ID3D11Texture2D *st = NULL;
    D3D11_TEXTURE2D_DESC td;
    ID3D11Texture2D_GetDesc((ID3D11Texture2D *)f->texture, &td);
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Usage = D3D11_USAGE_STAGING;
    td.BindFlags = 0;
    td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    td.MiscFlags = 0;
    MSW_TRY(ID3D11Device_CreateTexture2D(d3d->device, &td, NULL, &st), done);
    ID3D11DeviceContext_CopySubresourceRegion(d3d->context, (ID3D11Resource *)st, 0, 0, 0, 0,
                                              (ID3D11Resource *)f->texture, f->index, NULL);
    D3D11_MAPPED_SUBRESOURCE m;
    MSW_TRY(ID3D11DeviceContext_Map(d3d->context, (ID3D11Resource *)st, 0, D3D11_MAP_READ, 0, &m), done);
    const uint8_t *base = (const uint8_t *)m.pData;
    yuv[0] = base[(size_t)y * m.RowPitch + x];
    const uint8_t *uv = base + (size_t)m.RowPitch * td.Height + (size_t)(y / 2) * m.RowPitch + x;
    yuv[1] = uv[0];
    yuv[2] = uv[1];
    ID3D11DeviceContext_Unmap(d3d->context, (ID3D11Resource *)st, 0);
done:
    MSW_RELEASE(st);
    return hr;
}
