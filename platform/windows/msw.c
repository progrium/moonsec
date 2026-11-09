/* Shared Windows helpers: HRESULT messages, COM, QPC, D3D11 device creation. */
#include "msw_internal.h"

#include <stdio.h>
#include <string.h>

void msw_utf8(const WCHAR *src, char *dst, size_t dst_len) {
    if (dst_len == 0) return;
    int n = WideCharToMultiByte(CP_UTF8, 0, src, -1, dst, (int)dst_len, NULL, NULL);
    if (n <= 0) dst[0] = 0;
    dst[dst_len - 1] = 0;
}

size_t msw_hr_message(msw_hr hr, char *buf, size_t len) {
    if (len == 0) return 0;
    WCHAR w[512];
    DWORD n = FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, NULL, (DWORD)hr,
                             MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT), w, (DWORD)(sizeof w / sizeof w[0]), NULL);
    if (n == 0) {
        int k = snprintf(buf, len, "HRESULT 0x%08lx", (unsigned long)(uint32_t)hr);
        return k < 0 ? 0 : ((size_t)k < len ? (size_t)k : len - 1);
    }
    while (n > 0 && (w[n - 1] == L'\r' || w[n - 1] == L'\n' || w[n - 1] == L' ' || w[n - 1] == L'.')) n--;
    w[n] = 0;
    msw_utf8(w, buf, len);
    return strlen(buf);
}

msw_hr msw_com_init(void) {
    HRESULT hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    /* S_FALSE: already initialized on this thread, still needs a matching uninit. */
    return hr == S_FALSE ? S_OK : hr;
}

void msw_com_uninit(void) { CoUninitialize(); }

uint64_t msw_qpc_ns(void) {
    static LARGE_INTEGER freq; /* benign race: every thread writes the same value */
    if (freq.QuadPart == 0) QueryPerformanceFrequency(&freq);
    LARGE_INTEGER c;
    QueryPerformanceCounter(&c);
    uint64_t f = (uint64_t)freq.QuadPart, t = (uint64_t)c.QuadPart;
    return (t / f) * 1000000000ull + (t % f) * 1000000000ull / f;
}

void msw_adapter_fill(IDXGIAdapter1 *a, msw_adapter_info *out) {
    memset(out, 0, sizeof *out);
    DXGI_ADAPTER_DESC1 d;
    if (FAILED(IDXGIAdapter1_GetDesc1(a, &d))) return;
    msw_utf8(d.Description, out->description, sizeof out->description);
    out->vendor_id = d.VendorId;
    out->device_id = d.DeviceId;
    out->dedicated_video_memory = d.DedicatedVideoMemory;
    out->luid = ((int64_t)d.AdapterLuid.HighPart << 32) | (int64_t)d.AdapterLuid.LowPart;
    out->is_software = (d.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) != 0;
}

msw_hr msw_adapter_get(uint32_t index, msw_adapter_info *out) {
    IDXGIFactory1 *f = NULL;
    IDXGIAdapter1 *a = NULL;
    HRESULT hr;
    MSW_TRY(CreateDXGIFactory1(&IID_IDXGIFactory1, (void **)&f), done);
    MSW_TRY(IDXGIFactory1_EnumAdapters1(f, index, &a), done);
    msw_adapter_fill(a, out);
done:
    MSW_RELEASE(a);
    MSW_RELEASE(f);
    return hr;
}

static const D3D_FEATURE_LEVEL kLevels[] = {
    D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_10_0,
};

msw_hr msw_d3d_create(msw_driver driver, uint32_t adapter_index, uint32_t flags, msw_d3d **out) {
    *out = NULL;
    msw_d3d *d = (msw_d3d *)calloc(1, sizeof *d);
    if (!d) return E_OUTOFMEMORY;
    d->driver = driver;
    HRESULT hr = S_OK;
    IDXGIFactory1 *f = NULL;
    IDXGIDevice *dxgi_dev = NULL;
    IDXGIAdapter *adapter0 = NULL;
    ID3D10Multithread *mt = NULL;

    UINT cflags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
    if (flags & MSW_D3D_DEBUG) cflags |= D3D11_CREATE_DEVICE_DEBUG;
    if (flags & MSW_D3D_VIDEO) cflags |= D3D11_CREATE_DEVICE_VIDEO_SUPPORT;

    if (driver == MSW_DRIVER_HARDWARE) {
        MSW_TRY(CreateDXGIFactory1(&IID_IDXGIFactory1, (void **)&f), fail);
        MSW_TRY(IDXGIFactory1_EnumAdapters1(f, adapter_index, &d->adapter), fail);
        /* An explicit adapter needs D3D_DRIVER_TYPE_UNKNOWN. */
        hr = D3D11CreateDevice((IDXGIAdapter *)d->adapter, D3D_DRIVER_TYPE_UNKNOWN, NULL, cflags, kLevels,
                               (UINT)(sizeof kLevels / sizeof kLevels[0]), D3D11_SDK_VERSION, &d->device,
                               &d->feature_level, &d->context);
        if (hr == E_INVALIDARG) /* pre-11.1 runtime: retry without 11_1 */
            hr = D3D11CreateDevice((IDXGIAdapter *)d->adapter, D3D_DRIVER_TYPE_UNKNOWN, NULL, cflags, kLevels + 1,
                                   (UINT)(sizeof kLevels / sizeof kLevels[0]) - 1, D3D11_SDK_VERSION, &d->device,
                                   &d->feature_level, &d->context);
        if (FAILED(hr)) goto fail;
    } else {
        hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_WARP, NULL, cflags, kLevels,
                               (UINT)(sizeof kLevels / sizeof kLevels[0]), D3D11_SDK_VERSION, &d->device,
                               &d->feature_level, &d->context);
        if (hr == E_INVALIDARG)
            hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_WARP, NULL, cflags, kLevels + 1,
                                   (UINT)(sizeof kLevels / sizeof kLevels[0]) - 1, D3D11_SDK_VERSION, &d->device,
                                   &d->feature_level, &d->context);
        if (FAILED(hr)) goto fail;
        MSW_TRY(ID3D11Device_QueryInterface(d->device, &IID_IDXGIDevice, (void **)&dxgi_dev), fail);
        MSW_TRY(IDXGIDevice_GetAdapter(dxgi_dev, &adapter0), fail);
        MSW_TRY(IDXGIAdapter_QueryInterface(adapter0, &IID_IDXGIAdapter1, (void **)&d->adapter), fail);
    }

    if (SUCCEEDED(ID3D11DeviceContext_QueryInterface(d->context, &IID_ID3D10Multithread, (void **)&mt))) {
        ID3D10Multithread_SetMultithreadProtected(mt, TRUE);
        MSW_RELEASE(mt);
    }
    MSW_RELEASE(adapter0);
    MSW_RELEASE(dxgi_dev);
    MSW_RELEASE(f);
    *out = d;
    return S_OK;

fail:
    MSW_RELEASE(adapter0);
    MSW_RELEASE(dxgi_dev);
    MSW_RELEASE(f);
    msw_d3d_destroy(d);
    return hr;
}

void msw_d3d_destroy(msw_d3d *d) {
    if (!d) return;
    if (d->context) ID3D11DeviceContext_ClearState(d->context);
    MSW_RELEASE(d->context);
    MSW_RELEASE(d->device);
    MSW_RELEASE(d->adapter);
    free(d);
}

void msw_d3d_info(const msw_d3d *d, msw_adapter_info *out) {
    msw_adapter_fill(d->adapter, out);
    out->feature_level = (uint32_t)d->feature_level;
}

void *msw_d3d_device(const msw_d3d *d) { return d->device; }
void *msw_d3d_context(const msw_d3d *d) { return d->context; }
void *msw_d3d_adapter(const msw_d3d *d) { return d->adapter; }

msw_hr msw_d3d_selftest(msw_d3d *d, uint32_t w, uint32_t h, uint32_t bgra, uint32_t x, uint32_t y,
                        uint32_t *out_pixel) {
    if (x >= w || y >= h) return E_INVALIDARG;
    HRESULT hr;
    ID3D11Texture2D *rt = NULL, *staging = NULL;
    ID3D11RenderTargetView *rtv = NULL;
    D3D11_TEXTURE2D_DESC td = {0};
    td.Width = w;
    td.Height = h;
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DEFAULT;
    td.BindFlags = D3D11_BIND_RENDER_TARGET;
    MSW_TRY(ID3D11Device_CreateTexture2D(d->device, &td, NULL, &rt), done);
    MSW_TRY(ID3D11Device_CreateRenderTargetView(d->device, (ID3D11Resource *)rt, NULL, &rtv), done);
    const float color[4] = {
        (float)((bgra >> 16) & 0xff) / 255.0f, (float)((bgra >> 8) & 0xff) / 255.0f,
        (float)(bgra & 0xff) / 255.0f, (float)((bgra >> 24) & 0xff) / 255.0f,
    };
    ID3D11DeviceContext_ClearRenderTargetView(d->context, rtv, color);

    td.Usage = D3D11_USAGE_STAGING;
    td.BindFlags = 0;
    td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    MSW_TRY(ID3D11Device_CreateTexture2D(d->device, &td, NULL, &staging), done);
    ID3D11DeviceContext_CopyResource(d->context, (ID3D11Resource *)staging, (ID3D11Resource *)rt);
    D3D11_MAPPED_SUBRESOURCE m;
    MSW_TRY(ID3D11DeviceContext_Map(d->context, (ID3D11Resource *)staging, 0, D3D11_MAP_READ, 0, &m), done);
    *out_pixel = *(const uint32_t *)((const uint8_t *)m.pData + (size_t)y * m.RowPitch + (size_t)x * 4);
    ID3D11DeviceContext_Unmap(d->context, (ID3D11Resource *)staging, 0);
done:
    MSW_RELEASE(rtv);
    MSW_RELEASE(staging);
    MSW_RELEASE(rt);
    return hr;
}

msw_hr msw_texture_create(msw_d3d *d, uint32_t w, uint32_t h, uint32_t bgra, void **out_texture) {
    *out_texture = NULL;
    D3D11_TEXTURE2D_DESC td = {0};
    td.Width = w;
    td.Height = h;
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DEFAULT;
    td.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    ID3D11Texture2D *t = NULL;
    HRESULT hr = ID3D11Device_CreateTexture2D(d->device, &td, NULL, &t);
    if (FAILED(hr)) return hr;
    hr = msw_texture_fill(d, t, 0, 0, w, h, bgra);
    if (FAILED(hr)) {
        MSW_RELEASE(t);
        return hr;
    }
    *out_texture = t;
    return S_OK;
}

void msw_texture_release(void *texture) {
    ID3D11Texture2D *t = (ID3D11Texture2D *)texture;
    MSW_RELEASE(t);
}

msw_hr msw_texture_fill(msw_d3d *d, void *texture, uint32_t x, uint32_t y, uint32_t w, uint32_t h, uint32_t bgra) {
    ID3D11Texture2D *t = (ID3D11Texture2D *)texture;
    D3D11_TEXTURE2D_DESC td;
    ID3D11Texture2D_GetDesc(t, &td);
    if (x >= td.Width || y >= td.Height) return E_INVALIDARG;
    if (w > td.Width - x) w = td.Width - x;
    if (h > td.Height - y) h = td.Height - y;
    uint32_t *row = (uint32_t *)malloc((size_t)w * 4);
    if (!row) return E_OUTOFMEMORY;
    for (uint32_t i = 0; i < w; i++) row[i] = bgra;
    for (uint32_t r = 0; r < h; r++) {
        D3D11_BOX box = {x, y + r, 0, x + w, y + r + 1, 1};
        ID3D11DeviceContext_UpdateSubresource(d->context, (ID3D11Resource *)t, 0, &box, row, w * 4, 0);
    }
    free(row);
    return S_OK;
}

msw_hr msw_texture_read(msw_d3d *d, void *texture, uint32_t index, uint8_t *dst, uint32_t stride) {
    ID3D11Texture2D *t = (ID3D11Texture2D *)texture, *staging = NULL;
    D3D11_TEXTURE2D_DESC td;
    ID3D11Texture2D_GetDesc(t, &td);
    uint32_t w = td.Width, h = td.Height;
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_STAGING;
    td.BindFlags = 0;
    td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    td.MiscFlags = 0;
    HRESULT hr;
    MSW_TRY(ID3D11Device_CreateTexture2D(d->device, &td, NULL, &staging), done);
    ID3D11DeviceContext_CopySubresourceRegion(d->context, (ID3D11Resource *)staging, 0, 0, 0, 0,
                                              (ID3D11Resource *)t, index, NULL);
    D3D11_MAPPED_SUBRESOURCE m;
    MSW_TRY(ID3D11DeviceContext_Map(d->context, (ID3D11Resource *)staging, 0, D3D11_MAP_READ, 0, &m), done);
    for (uint32_t r = 0; r < h; r++) memcpy(dst + (size_t)r * stride, (const uint8_t *)m.pData + (size_t)r * m.RowPitch, (size_t)w * 4);
    ID3D11DeviceContext_Unmap(d->context, (ID3D11Resource *)staging, 0);
done:
    MSW_RELEASE(staging);
    return hr;
}

msw_hr msw_texture_noise(msw_d3d *d, void *texture, uint32_t seed) {
    ID3D11Texture2D *t = (ID3D11Texture2D *)texture;
    D3D11_TEXTURE2D_DESC td;
    ID3D11Texture2D_GetDesc(t, &td);
    uint32_t *px = (uint32_t *)malloc((size_t)td.Width * td.Height * 4);
    if (!px) return E_OUTOFMEMORY;
    uint32_t x = seed * 2654435761u + 1u;
    for (size_t i = 0; i < (size_t)td.Width * td.Height; i++) {
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        px[i] = x | 0xFF000000u;
    }
    ID3D11DeviceContext_UpdateSubresource(d->context, (ID3D11Resource *)t, 0, NULL, px, td.Width * 4, 0);
    free(px);
    return S_OK;
}
