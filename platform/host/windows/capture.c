/* Desktop Duplication capture (IDXGIOutputDuplication). */
#include "msw_internal.h"
#include "host_win.h"

#include <string.h>

struct msw_dup {
    msw_d3d *d;
    IDXGIOutput1 *output;
    IDXGIOutputDuplication *dup;
    DXGI_OUTDUPL_DESC desc;
    RECT rect;
    ID3D11Texture2D *copy; /* our copy of the last desktop image */
    uint32_t width, height;
    int holding; /* AcquireNextFrame succeeded and ReleaseFrame is pending */
    uint8_t *shape;
    uint32_t shape_len, shape_cap;
    DXGI_OUTDUPL_POINTER_SHAPE_INFO shape_info;
    DXGI_OUTDUPL_POINTER_POSITION pointer;
};

msw_hr msw_dup_create(msw_d3d *d, uint32_t output_index, msw_dup **out) {
    *out = NULL;
    msw_dup *p = (msw_dup *)calloc(1, sizeof *p);
    if (!p) return E_OUTOFMEMORY;
    p->d = d;
    HRESULT hr;
    IDXGIOutput *o = NULL;
    MSW_TRY(IDXGIAdapter1_EnumOutputs(d->adapter, output_index, &o), fail);
    MSW_TRY(IDXGIOutput_QueryInterface(o, &IID_IDXGIOutput1, (void **)&p->output), fail);
    DXGI_OUTPUT_DESC od;
    MSW_TRY(IDXGIOutput1_GetDesc(p->output, &od), fail);
    p->rect = od.DesktopCoordinates;
    MSW_TRY(IDXGIOutput1_DuplicateOutput(p->output, (IUnknown *)d->device, &p->dup), fail);
    IDXGIOutputDuplication_GetDesc(p->dup, &p->desc);
    p->width = p->desc.ModeDesc.Width;
    p->height = p->desc.ModeDesc.Height;

    D3D11_TEXTURE2D_DESC td = {0};
    td.Width = p->width;
    td.Height = p->height;
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DEFAULT;
    td.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    MSW_TRY(ID3D11Device_CreateTexture2D(d->device, &td, NULL, &p->copy), fail);
    MSW_RELEASE(o);
    *out = p;
    return S_OK;
fail:
    MSW_RELEASE(o);
    msw_dup_destroy(p);
    return hr;
}

void msw_dup_destroy(msw_dup *p) {
    if (!p) return;
    if (p->holding) IDXGIOutputDuplication_ReleaseFrame(p->dup);
    MSW_RELEASE(p->copy);
    MSW_RELEASE(p->dup);
    MSW_RELEASE(p->output);
    free(p->shape);
    free(p);
}

void msw_dup_size(const msw_dup *p, uint32_t *w, uint32_t *h) {
    *w = p->width;
    *h = p->height;
}

void msw_dup_desktop_rect(const msw_dup *p, int32_t *left, int32_t *top, int32_t *width, int32_t *height) {
    *left = p->rect.left;
    *top = p->rect.top;
    *width = p->rect.right - p->rect.left;
    *height = p->rect.bottom - p->rect.top;
}

void *msw_dup_last_texture(const msw_dup *p) { return p->copy; }

static uint64_t qpc_to_ns(LONGLONG t) {
    static LARGE_INTEGER freq;
    if (freq.QuadPart == 0) QueryPerformanceFrequency(&freq);
    uint64_t f = (uint64_t)freq.QuadPart, u = (uint64_t)t;
    return (u / f) * 1000000000ull + (u % f) * 1000000000ull / f;
}

msw_hr msw_dup_acquire(msw_dup *p, uint32_t timeout_ms, msw_dup_frame *out) {
    memset(out, 0, sizeof *out);
    if (p->holding) {
        IDXGIOutputDuplication_ReleaseFrame(p->dup);
        p->holding = 0;
    }
    DXGI_OUTDUPL_FRAME_INFO fi;
    IDXGIResource *res = NULL;
    ID3D11Texture2D *tex = NULL;
    HRESULT hr = IDXGIOutputDuplication_AcquireNextFrame(p->dup, timeout_ms, &fi, &res);
    if (FAILED(hr)) return hr;
    p->holding = 1;

    if (fi.LastMouseUpdateTime.QuadPart != 0) p->pointer = fi.PointerPosition;
    if (fi.PointerShapeBufferSize > 0) {
        if (fi.PointerShapeBufferSize > p->shape_cap) {
            uint8_t *n = (uint8_t *)realloc(p->shape, fi.PointerShapeBufferSize);
            if (n) {
                p->shape = n;
                p->shape_cap = fi.PointerShapeBufferSize;
            }
        }
        UINT got = 0;
        if (p->shape_cap >= fi.PointerShapeBufferSize &&
            SUCCEEDED(IDXGIOutputDuplication_GetFramePointerShape(p->dup, p->shape_cap, p->shape, &got, &p->shape_info))) {
            p->shape_len = got;
            out->pointer_shape_changed = 1;
        }
    }

    if (fi.LastPresentTime.QuadPart != 0) {
        hr = IDXGIResource_QueryInterface(res, &IID_ID3D11Texture2D, (void **)&tex);
        if (FAILED(hr)) goto done;
        ID3D11DeviceContext_CopyResource(p->d->context, (ID3D11Resource *)p->copy, (ID3D11Resource *)tex);
        out->present_ns = qpc_to_ns(fi.LastPresentTime.QuadPart);
    }
    /* The copy is ours: hand the desktop image back right away so DWM is never held up. */
    IDXGIOutputDuplication_ReleaseFrame(p->dup);
    p->holding = 0;

    out->texture = p->copy;
    out->width = p->width;
    out->height = p->height;
    out->accumulated_frames = fi.AccumulatedFrames;
    out->pointer_x = p->pointer.Position.x;
    out->pointer_y = p->pointer.Position.y;
    out->pointer_visible = p->pointer.Visible ? 1 : 0;
done:
    MSW_RELEASE(tex);
    MSW_RELEASE(res);
    return hr;
}

msw_hr msw_dup_pointer_shape(msw_dup *p, void *buf, uint32_t len, uint32_t *needed, uint32_t *type, uint32_t *width,
                             uint32_t *height, uint32_t *pitch, int32_t *hot_x, int32_t *hot_y) {
    *needed = p->shape_len;
    *type = p->shape_info.Type;
    *width = p->shape_info.Width;
    *height = p->shape_info.Height;
    *pitch = p->shape_info.Pitch;
    *hot_x = p->shape_info.HotSpot.x;
    *hot_y = p->shape_info.HotSpot.y;
    if (p->shape_len == 0) return MSW_E_NOTFOUND;
    if (len < p->shape_len) return HRESULT_FROM_WIN32(ERROR_INSUFFICIENT_BUFFER);
    memcpy(buf, p->shape, p->shape_len);
    return S_OK;
}
