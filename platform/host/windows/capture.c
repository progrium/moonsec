/* Desktop Duplication capture (IDXGIOutputDuplication).
 *
 * Damage: each presented frame's move and dirty rectangles (GetFrameMoveRects,
 * GetFrameDirtyRects, read before ReleaseFrame) are handed to host.zig as DXGI gives them;
 * DXGI already folds them over AccumulatedFrames. The first frame of a duplication has
 * none we trust (it is the whole desktop anyway). msw_dup_read_rect copies a rectangle of
 * our copy texture through a small staging texture, for lossless tiles. */
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
    int fresh; /* no frame presented yet on this duplication */
    uint8_t *meta; /* move rects, then dirty rects, of the last frame */
    uint32_t meta_cap;
    ID3D11Texture2D *staging; /* for msw_dup_read_rect, grown as asked */
    uint32_t staging_w, staging_h;
};

msw_hr msw_dup_create(msw_d3d *d, uint32_t output_index, msw_dup **out) {
    *out = NULL;
    msw_dup *p = (msw_dup *)calloc(1, sizeof *p);
    if (!p) return E_OUTOFMEMORY;
    p->d = d;
    p->fresh = 1;
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
    MSW_RELEASE(p->staging);
    MSW_RELEASE(p->copy);
    MSW_RELEASE(p->dup);
    MSW_RELEASE(p->output);
    free(p->shape);
    free(p->meta);
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

/* The frame's move and dirty rectangles into p->meta (before ReleaseFrame); 0 when DXGI
 * gave none or they could not be read (the damage is then unknown). */
static int read_damage(msw_dup *p, const DXGI_OUTDUPL_FRAME_INFO *fi, msw_dup_frame *out) {
    UINT need = fi->TotalMetadataBufferSize;
    if (need == 0) return 0;
    if (need > p->meta_cap) {
        uint8_t *n = (uint8_t *)realloc(p->meta, need);
        if (!n) return 0;
        p->meta = n;
        p->meta_cap = need;
    }
    UINT moves = 0, dirty = 0;
    if (FAILED(IDXGIOutputDuplication_GetFrameMoveRects(p->dup, p->meta_cap, (DXGI_OUTDUPL_MOVE_RECT *)p->meta, &moves))) return 0;
    if (FAILED(IDXGIOutputDuplication_GetFrameDirtyRects(p->dup, p->meta_cap - moves, (RECT *)(p->meta + moves), &dirty))) return 0;
    out->move_rects = (const int32_t *)p->meta;
    out->n_moves = moves / sizeof(DXGI_OUTDUPL_MOVE_RECT);
    out->dirty_rects = (const int32_t *)(p->meta + moves);
    out->n_dirty = dirty / sizeof(RECT);
    return 1;
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
        out->damage_known = (uint32_t)(read_damage(p, &fi, out) && !p->fresh);
        p->fresh = 0;
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

msw_hr msw_dup_read_rect(msw_dup *p, uint32_t x, uint32_t y, uint32_t w, uint32_t h, void *out, uint32_t out_stride) {
    if (!p->copy || w == 0 || h == 0 || x > p->width || y > p->height || w > p->width - x || h > p->height - y || out_stride < w * 4)
        return E_INVALIDARG;
    HRESULT hr = S_OK;
    if (!p->staging || w > p->staging_w || h > p->staging_h) {
        MSW_RELEASE(p->staging);
        uint32_t sw = w > p->staging_w ? w : p->staging_w, sh = h > p->staging_h ? h : p->staging_h;
        if (sw < 64) sw = 64;
        if (sh < 64) sh = 64;
        D3D11_TEXTURE2D_DESC td = {0};
        td.Width = sw;
        td.Height = sh;
        td.MipLevels = 1;
        td.ArraySize = 1;
        td.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        td.SampleDesc.Count = 1;
        td.Usage = D3D11_USAGE_STAGING;
        td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        p->staging_w = p->staging_h = 0;
        MSW_TRY(ID3D11Device_CreateTexture2D(p->d->device, &td, NULL, &p->staging), done);
        p->staging_w = sw;
        p->staging_h = sh;
    }
    D3D11_BOX box = {x, y, 0, x + w, y + h, 1};
    ID3D11DeviceContext_CopySubresourceRegion(p->d->context, (ID3D11Resource *)p->staging, 0, 0, 0, 0, (ID3D11Resource *)p->copy, 0, &box);
    D3D11_MAPPED_SUBRESOURCE m;
    MSW_TRY(ID3D11DeviceContext_Map(p->d->context, (ID3D11Resource *)p->staging, 0, D3D11_MAP_READ, 0, &m), done);
    for (uint32_t r = 0; r < h; r++) memcpy((uint8_t *)out + (size_t)r * out_stride, (const uint8_t *)m.pData + (size_t)r * m.RowPitch, (size_t)w * 4);
    ID3D11DeviceContext_Unmap(p->d->context, (ID3D11Resource *)p->staging, 0);
done:
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

/* ---- Display list ---------------------------------------------------------- */

/* The monitor's friendly name and the mode's exact refresh rate, from the display
 * configuration path whose source is GDI device `gdi`. */
static void display_config(const WCHAR *gdi, msw_display_info *out) {
    UINT32 np = 0, nm = 0;
    if (GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &np, &nm) != ERROR_SUCCESS || np == 0) return;
    DISPLAYCONFIG_PATH_INFO *paths = (DISPLAYCONFIG_PATH_INFO *)calloc(np, sizeof *paths);
    DISPLAYCONFIG_MODE_INFO *modes = (DISPLAYCONFIG_MODE_INFO *)calloc(nm ? nm : 1, sizeof *modes);
    if (!paths || !modes || QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &np, paths, &nm, modes, NULL) != ERROR_SUCCESS)
        goto done;
    for (UINT32 i = 0; i < np; i++) {
        DISPLAYCONFIG_SOURCE_DEVICE_NAME src;
        memset(&src, 0, sizeof src);
        src.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
        src.header.size = sizeof src;
        src.header.adapterId = paths[i].sourceInfo.adapterId;
        src.header.id = paths[i].sourceInfo.id;
        if (DisplayConfigGetDeviceInfo(&src.header) != ERROR_SUCCESS || wcscmp(src.viewGdiDeviceName, gdi) != 0) continue;
        const DISPLAYCONFIG_RATIONAL r = paths[i].targetInfo.refreshRate;
        if (r.Denominator != 0 && r.Numerator != 0)
            out->refresh_mhz = (uint32_t)(((uint64_t)r.Numerator * 1000 + r.Denominator / 2) / r.Denominator);
        DISPLAYCONFIG_TARGET_DEVICE_NAME tgt;
        memset(&tgt, 0, sizeof tgt);
        tgt.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME;
        tgt.header.size = sizeof tgt;
        tgt.header.adapterId = paths[i].targetInfo.adapterId;
        tgt.header.id = paths[i].targetInfo.id;
        if (DisplayConfigGetDeviceInfo(&tgt.header) == ERROR_SUCCESS) {
            msw_utf8(tgt.monitorFriendlyDeviceName, out->name, sizeof out->name);
            const DISPLAYCONFIG_VIDEO_OUTPUT_TECHNOLOGY t = tgt.outputTechnology;
            if (!out->name[0] && (t == DISPLAYCONFIG_OUTPUT_TECHNOLOGY_INTERNAL ||
                                  t == DISPLAYCONFIG_OUTPUT_TECHNOLOGY_DISPLAYPORT_EMBEDDED ||
                                  t == DISPLAYCONFIG_OUTPUT_TECHNOLOGY_UDI_EMBEDDED))
                strcpy(out->name, "Built-in Display");
        }
        break; /* a cloned source has several paths; the first names it */
    }
done:
    free(paths);
    free(modes);
}

static void display_fill(uint32_t index, const DXGI_OUTPUT_DESC *od, msw_display_info *out) {
    memset(out, 0, sizeof *out);
    out->index = index;
    out->x = od->DesktopCoordinates.left;
    out->y = od->DesktopCoordinates.top;
    out->width = (uint32_t)(od->DesktopCoordinates.right - od->DesktopCoordinates.left);
    out->height = (uint32_t)(od->DesktopCoordinates.bottom - od->DesktopCoordinates.top);
    /* The mode's own size in pixels (the desktop rectangle is scaled for a process that
     * is not DPI aware), and its rate in whole hertz until the display config gives the
     * exact one. */
    DEVMODEW dm;
    memset(&dm, 0, sizeof dm);
    dm.dmSize = sizeof dm;
    if (EnumDisplaySettingsW(od->DeviceName, ENUM_CURRENT_SETTINGS, &dm)) {
        if (dm.dmPelsWidth && dm.dmPelsHeight) {
            out->width = dm.dmPelsWidth;
            out->height = dm.dmPelsHeight;
        }
        if (dm.dmDisplayFrequency > 1) out->refresh_mhz = dm.dmDisplayFrequency * 1000;
    }
    MONITORINFO mi;
    memset(&mi, 0, sizeof mi);
    mi.cbSize = sizeof mi;
    if (od->Monitor && GetMonitorInfoW(od->Monitor, &mi)) out->primary = (mi.dwFlags & MONITORINFOF_PRIMARY) != 0;
    else out->primary = out->x == 0 && out->y == 0;
    display_config(od->DeviceName, out);
    if (!out->name[0]) {
        const WCHAR *n = od->DeviceName;
        if (wcsncmp(n, L"\\\\.\\", 4) == 0) n += 4;
        msw_utf8(n, out->name, sizeof out->name);
    }
}

msw_hr msw_displays(msw_d3d *d, uint32_t adapter_index, msw_display_info *out, uint32_t cap, uint32_t *count) {
    *count = 0;
    HRESULT hr = S_OK;
    IDXGIFactory1 *f = NULL;
    IDXGIAdapter1 *a = NULL;
    if (d && d->adapter) {
        a = d->adapter;
        IDXGIAdapter1_AddRef(a);
    } else {
        MSW_TRY(CreateDXGIFactory1(&IID_IDXGIFactory1, (void **)&f), done);
        MSW_TRY(IDXGIFactory1_EnumAdapters1(f, adapter_index, &a), done);
    }
    uint32_t n = 0;
    for (UINT i = 0;; i++) {
        IDXGIOutput *o = NULL;
        hr = IDXGIAdapter1_EnumOutputs(a, i, &o);
        if (hr == DXGI_ERROR_NOT_FOUND) {
            hr = S_OK;
            break;
        }
        if (FAILED(hr)) goto done;
        DXGI_OUTPUT_DESC od;
        hr = IDXGIOutput_GetDesc(o, &od);
        MSW_RELEASE(o);
        if (FAILED(hr)) goto done;
        if (!od.AttachedToDesktop) continue;
        if (n < cap) display_fill(i, &od, &out[n]);
        n++;
    }
    *count = n;
done:
    MSW_RELEASE(a);
    MSW_RELEASE(f);
    return hr;
}
