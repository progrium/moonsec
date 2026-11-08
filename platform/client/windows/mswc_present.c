/* Flip-model swapchain, NV12 to BGRA, overlay copy.
 *
 * Low-latency choices (docs/design.md, "Platform backends"):
 *   - DXGI_SWAP_EFFECT_FLIP_DISCARD with 2 buffers: the compositor can scan out our
 *     buffer directly (independent flip) when the window covers the output.
 *   - DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT with SetMaximumFrameLatency(1):
 *     the present thread waits on the object before drawing, so it never queues more
 *     than one frame inside DXGI.
 *   - DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING (when IDXGIFactory5 reports it) and
 *     Present(0, DXGI_PRESENT_ALLOW_TEARING) in lowest-latency mode: no vsync wait;
 *     VRR displays get variable refresh. Smooth mode is Present(1, 0).
 *   - Colour conversion and scaling: the D3D11 video processor when the device has
 *     one (hardware devices created with video support). Otherwise, as on WARP, which
 *     refuses D3D11_CREATE_DEVICE_VIDEO_SUPPORT, a two-SRV pixel shader (R8 luma,
 *     R8G8 chroma views of the NV12 texture) compiled at startup with
 *     d3dcompiler_47.dll, which ships with Windows 10 and later.
 *   - The overlay is a CopySubresourceRegion of a CPU-drawn BGRA image (opaque box).
 */
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#include "msw_internal.h"
#include "mswc.h"

#include <dxgi1_5.h>
#include <string.h>

#define VIEW_CACHE 8
#define OVERLAY_MAX_W 1024
#define OVERLAY_MAX_H 512

typedef struct view_entry {
    ID3D11Texture2D *tex; /* not owned: identity only */
    UINT index;
    ID3D11VideoProcessorInputView *view;
} view_entry;

typedef struct srv_entry {
    ID3D11Texture2D *tex; /* not owned: identity only */
    UINT index;
    ID3D11ShaderResourceView *y, *uv;
} srv_entry;

typedef struct shader_consts {
    float uv_scale[4]; /* xy: crop / coded size */
    float yoff[4];     /* x: luma offset, y: luma scale */
    float r[4], g[4], b[4]; /* rows applied to (y, u - 0.5, v - 0.5, 0) */
} shader_consts;

struct mswc_presenter {
    msw_d3d *d3d;
    mswc_window *win;
    IDXGISwapChain2 *sc;
    HANDLE waitable;
    UINT sc_flags;
    int tearing;
    UINT w, h;

    ID3D11Texture2D *back;
    ID3D11RenderTargetView *rtv;

    ID3D11VideoDevice *vd;
    ID3D11VideoContext *vc;
    ID3D11VideoProcessorEnumerator *vpe;
    ID3D11VideoProcessor *vp;
    ID3D11VideoProcessorOutputView *ov;
    UINT vp_in_w, vp_in_h, vp_out_w, vp_out_h;
    view_entry views[VIEW_CACHE];
    UINT next_view;

    /* Shader path (no video device). */
    int use_shader;
    ID3D11VertexShader *vs;
    ID3D11PixelShader *ps;
    ID3D11SamplerState *sampler;
    ID3D11Buffer *cb;
    srv_entry srvs[VIEW_CACHE];
    UINT next_srv;

    ID3D11Texture2D *overlay;
    UINT overlay_w, overlay_h;

    ID3D11Texture2D *readback;
};

static void drop_views(mswc_presenter *p) {
    for (int i = 0; i < VIEW_CACHE; i++) {
        MSW_RELEASE(p->views[i].view);
        p->views[i].tex = NULL;
    }
}

static void drop_srvs(mswc_presenter *p) {
    for (int i = 0; i < VIEW_CACHE; i++) {
        MSW_RELEASE(p->srvs[i].y);
        MSW_RELEASE(p->srvs[i].uv);
        p->srvs[i].tex = NULL;
    }
}

static void drop_vp(mswc_presenter *p) {
    drop_views(p);
    MSW_RELEASE(p->ov);
    MSW_RELEASE(p->vp);
    MSW_RELEASE(p->vpe);
    p->vp_in_w = p->vp_in_h = p->vp_out_w = p->vp_out_h = 0;
}

static void drop_targets(mswc_presenter *p) {
    MSW_RELEASE(p->ov);
    MSW_RELEASE(p->rtv);
    MSW_RELEASE(p->back);
    MSW_RELEASE(p->readback);
}

static HRESULT get_targets(mswc_presenter *p) {
    if (p->back) return S_OK;
    HRESULT hr;
    MSW_TRY(IDXGISwapChain2_GetBuffer(p->sc, 0, &IID_ID3D11Texture2D, (void **)&p->back), fail);
    MSW_TRY(ID3D11Device_CreateRenderTargetView(p->d3d->device, (ID3D11Resource *)p->back, NULL, &p->rtv), fail);
    return S_OK;
fail:
    drop_targets(p);
    return hr;
}

static int check_tearing(IDXGIFactory2 *f2) {
    IDXGIFactory5 *f5 = NULL;
    BOOL allow = FALSE;
    if (SUCCEEDED(IDXGIFactory2_QueryInterface(f2, &IID_IDXGIFactory5, (void **)&f5))) {
        if (FAILED(IDXGIFactory5_CheckFeatureSupport(f5, DXGI_FEATURE_PRESENT_ALLOW_TEARING, &allow, sizeof allow)))
            allow = FALSE;
        MSW_RELEASE(f5);
    }
    return allow ? 1 : 0;
}

static const char kShader[] =
    "Texture2DArray<float> Y : register(t0);\n"
    "Texture2DArray<float2> UV : register(t1);\n"
    "SamplerState S : register(s0);\n"
    "cbuffer C : register(b0) { float4 uv_scale; float4 yoff; float4 r; float4 g; float4 b; };\n"
    "struct V { float4 pos : SV_Position; float2 uv : TEXCOORD0; };\n"
    "V vs(uint id : SV_VertexID) {\n"
    "  float2 t = float2((id << 1) & 2, id & 2);\n"
    "  V o; o.pos = float4(t * float2(2, -2) + float2(-1, 1), 0, 1); o.uv = t * uv_scale.xy; return o;\n"
    "}\n"
    "float4 ps(V i) : SV_Target {\n"
    "  float y = (Y.Sample(S, float3(i.uv, 0)) - yoff.x) * yoff.y;\n"
    "  float2 c = UV.Sample(S, float3(i.uv, 0)) - 0.5;\n"
    "  float4 v = float4(y, c, 0);\n"
    "  return float4(saturate(float3(dot(r, v), dot(g, v), dot(b, v))), 1);\n"
    "}\n";

typedef HRESULT(WINAPI *d3dcompile_fn)(LPCVOID, SIZE_T, LPCSTR, const D3D_SHADER_MACRO *, ID3DInclude *, LPCSTR,
                                       LPCSTR, UINT, UINT, ID3DBlob **, ID3DBlob **);

static HRESULT compile(d3dcompile_fn fn, const char *entry, const char *target, ID3DBlob **out) {
    ID3DBlob *errs = NULL;
    HRESULT hr = fn(kShader, sizeof kShader - 1, "mswc_present", NULL, NULL, entry, target,
                    1u << 15 /* D3DCOMPILE_OPTIMIZATION_LEVEL3 */, 0, out, &errs);
    if (errs) {
        if (FAILED(hr)) OutputDebugStringA((const char *)ID3D10Blob_GetBufferPointer(errs));
        ID3D10Blob_Release(errs);
    }
    return hr;
}

static HRESULT setup_shader(mswc_presenter *p) {
    HMODULE lib = LoadLibraryW(L"d3dcompiler_47.dll");
    if (!lib) return HRESULT_FROM_WIN32(GetLastError());
    d3dcompile_fn fn;
    FARPROC proc = GetProcAddress(lib, "D3DCompile");
    memcpy(&fn, &proc, sizeof fn);
    HRESULT hr = fn ? S_OK : HRESULT_FROM_WIN32(GetLastError());
    ID3DBlob *vsb = NULL, *psb = NULL;
    if (FAILED(hr)) goto done;
    MSW_TRY(compile(fn, "vs", "vs_4_0", &vsb), done);
    MSW_TRY(compile(fn, "ps", "ps_4_0", &psb), done);
    MSW_TRY(ID3D11Device_CreateVertexShader(p->d3d->device, ID3D10Blob_GetBufferPointer(vsb),
                                            ID3D10Blob_GetBufferSize(vsb), NULL, &p->vs),
            done);
    MSW_TRY(ID3D11Device_CreatePixelShader(p->d3d->device, ID3D10Blob_GetBufferPointer(psb),
                                           ID3D10Blob_GetBufferSize(psb), NULL, &p->ps),
            done);
    D3D11_SAMPLER_DESC sd;
    memset(&sd, 0, sizeof sd);
    sd.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
    sd.AddressU = sd.AddressV = sd.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
    sd.MaxLOD = D3D11_FLOAT32_MAX;
    MSW_TRY(ID3D11Device_CreateSamplerState(p->d3d->device, &sd, &p->sampler), done);
    D3D11_BUFFER_DESC bd;
    memset(&bd, 0, sizeof bd);
    bd.ByteWidth = sizeof(shader_consts);
    bd.Usage = D3D11_USAGE_DEFAULT;
    bd.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
    MSW_TRY(ID3D11Device_CreateBuffer(p->d3d->device, &bd, NULL, &p->cb), done);
done:
    MSW_RELEASE(vsb);
    MSW_RELEASE(psb);
    /* d3dcompiler stays loaded: unloading it while its blobs' code may be cached is
     * not worth the few hundred KB. */
    return hr;
}

msw_hr mswc_presenter_create(msw_d3d *d3d, mswc_window *win, uint32_t flags, mswc_presenter **out) {
    *out = NULL;
    mswc_presenter *p = (mswc_presenter *)calloc(1, sizeof *p);
    if (!p) return E_OUTOFMEMORY;
    p->d3d = d3d;
    p->win = win;
    HRESULT hr;
    IDXGIFactory2 *f2 = NULL;
    IDXGISwapChain1 *sc1 = NULL;
    D3D11_TEXTURE2D_DESC td;

    MSW_TRY(IDXGIAdapter1_GetParent(d3d->adapter, &IID_IDXGIFactory2, (void **)&f2), fail);
    p->tearing = check_tearing(f2);

    uint32_t w, h;
    mswc_window_size(win, &w, &h);
    p->w = w ? w : 1;
    p->h = h ? h : 1;
    DXGI_SWAP_CHAIN_DESC1 sd;
    memset(&sd, 0, sizeof sd);
    sd.Width = p->w;
    sd.Height = p->h;
    sd.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    sd.SampleDesc.Count = 1;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.BufferCount = 2;
    sd.Scaling = DXGI_SCALING_STRETCH;
    sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    sd.AlphaMode = DXGI_ALPHA_MODE_IGNORE;
    p->sc_flags = DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT | (p->tearing ? DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING : 0);
    sd.Flags = p->sc_flags;
    MSW_TRY(IDXGIFactory2_CreateSwapChainForHwnd(f2, (IUnknown *)d3d->device, (HWND)mswc_window_hwnd(win), &sd, NULL,
                                                 NULL, &sc1),
            fail);
    MSW_TRY(IDXGISwapChain1_QueryInterface(sc1, &IID_IDXGISwapChain2, (void **)&p->sc), fail);
    /* Alt+Enter would switch to exclusive fullscreen behind our back. */
    IDXGIFactory2_MakeWindowAssociation(f2, (HWND)mswc_window_hwnd(win), DXGI_MWA_NO_ALT_ENTER);
    MSW_TRY(IDXGISwapChain2_SetMaximumFrameLatency(p->sc, 1), fail);
    p->waitable = IDXGISwapChain2_GetFrameLatencyWaitableObject(p->sc);
    if (!p->waitable) {
        hr = E_FAIL;
        goto fail;
    }

    if ((flags & MSWC_PRESENTER_SHADER) ||
        FAILED(ID3D11Device_QueryInterface(d3d->device, &IID_ID3D11VideoDevice, (void **)&p->vd)) ||
        FAILED(ID3D11DeviceContext_QueryInterface(d3d->context, &IID_ID3D11VideoContext, (void **)&p->vc))) {
        MSW_RELEASE(p->vd);
        MSW_RELEASE(p->vc);
        p->use_shader = 1;
        MSW_TRY(setup_shader(p), fail);
    }

    memset(&td, 0, sizeof td);
    td.Width = OVERLAY_MAX_W;
    td.Height = OVERLAY_MAX_H;
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DEFAULT;
    MSW_TRY(ID3D11Device_CreateTexture2D(d3d->device, &td, NULL, &p->overlay), fail);

    MSW_RELEASE(sc1);
    MSW_RELEASE(f2);
    *out = p;
    return S_OK;
fail:
    MSW_RELEASE(sc1);
    MSW_RELEASE(f2);
    mswc_presenter_destroy(p);
    return hr;
}

void mswc_presenter_destroy(mswc_presenter *p) {
    if (!p) return;
    drop_vp(p);
    drop_srvs(p);
    drop_targets(p);
    MSW_RELEASE(p->cb);
    MSW_RELEASE(p->sampler);
    MSW_RELEASE(p->ps);
    MSW_RELEASE(p->vs);
    MSW_RELEASE(p->overlay);
    MSW_RELEASE(p->vc);
    MSW_RELEASE(p->vd);
    if (p->waitable) CloseHandle(p->waitable);
    MSW_RELEASE(p->sc);
    free(p);
}

int mswc_presenter_tearing(const mswc_presenter *p) { return p->tearing; }

int mswc_presenter_uses_shader(const mswc_presenter *p) { return p->use_shader; }

void mswc_presenter_size(const mswc_presenter *p, uint32_t *w, uint32_t *h) {
    *w = p->w;
    *h = p->h;
}

msw_hr mswc_presenter_wait(mswc_presenter *p, uint32_t timeout_ms) {
    DWORD r = WaitForSingleObjectEx(p->waitable, timeout_ms, TRUE);
    if (r == WAIT_OBJECT_0) return S_OK;
    if (r == WAIT_TIMEOUT) return DXGI_ERROR_WAIT_TIMEOUT;
    return HRESULT_FROM_WIN32(GetLastError());
}

msw_hr mswc_presenter_sync_size(mswc_presenter *p) {
    uint32_t w, h;
    mswc_window_size(p->win, &w, &h);
    if (w == 0 || h == 0 || (w == p->w && h == p->h)) return S_OK; /* minimized or unchanged */
    drop_vp(p);
    drop_targets(p);
    HRESULT hr = IDXGISwapChain2_ResizeBuffers(p->sc, 0, w, h, DXGI_FORMAT_UNKNOWN, p->sc_flags);
    if (FAILED(hr)) return hr;
    p->w = w;
    p->h = h;
    return S_OK;
}

static HRESULT ensure_vp(mswc_presenter *p, UINT in_w, UINT in_h) {
    if (p->vp && p->vp_in_w == in_w && p->vp_in_h == in_h && p->vp_out_w == p->w && p->vp_out_h == p->h)
        return S_OK;
    drop_vp(p);
    HRESULT hr;
    D3D11_VIDEO_PROCESSOR_CONTENT_DESC cd;
    memset(&cd, 0, sizeof cd);
    cd.InputFrameFormat = D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE;
    cd.InputWidth = in_w;
    cd.InputHeight = in_h;
    cd.OutputWidth = p->w;
    cd.OutputHeight = p->h;
    cd.Usage = D3D11_VIDEO_USAGE_OPTIMAL_SPEED;
    MSW_TRY(ID3D11VideoDevice_CreateVideoProcessorEnumerator(p->vd, &cd, &p->vpe), fail);
    MSW_TRY(ID3D11VideoDevice_CreateVideoProcessor(p->vd, p->vpe, 0, &p->vp), fail);
    p->vp_in_w = in_w;
    p->vp_in_h = in_h;
    p->vp_out_w = p->w;
    p->vp_out_h = p->h;
    /* Don't let the driver add its own processing or cadence logic. */
    ID3D11VideoContext_VideoProcessorSetStreamAutoProcessingMode(p->vc, p->vp, 0, FALSE);
    ID3D11VideoContext_VideoProcessorSetStreamFrameFormat(p->vc, p->vp, 0, D3D11_VIDEO_FRAME_FORMAT_PROGRESSIVE);
    D3D11_VIDEO_PROCESSOR_COLOR_SPACE out_cs;
    memset(&out_cs, 0, sizeof out_cs);
    out_cs.RGB_Range = 0; /* full-range RGB */
    ID3D11VideoContext_VideoProcessorSetOutputColorSpace(p->vc, p->vp, &out_cs);
    return S_OK;
fail:
    drop_vp(p);
    return hr;
}

static HRESULT input_view(mswc_presenter *p, ID3D11Texture2D *tex, UINT index, ID3D11VideoProcessorInputView **out) {
    for (int i = 0; i < VIEW_CACHE; i++) {
        if (p->views[i].view && p->views[i].tex == tex && p->views[i].index == index) {
            *out = p->views[i].view;
            return S_OK;
        }
    }
    D3D11_VIDEO_PROCESSOR_INPUT_VIEW_DESC vd;
    memset(&vd, 0, sizeof vd);
    vd.ViewDimension = D3D11_VPIV_DIMENSION_TEXTURE2D;
    vd.Texture2D.ArraySlice = index;
    ID3D11VideoProcessorInputView *v = NULL;
    HRESULT hr = ID3D11VideoDevice_CreateVideoProcessorInputView(p->vd, (ID3D11Resource *)tex, p->vpe, &vd, &v);
    if (FAILED(hr)) return hr;
    view_entry *e = &p->views[p->next_view];
    p->next_view = (p->next_view + 1) % VIEW_CACHE;
    MSW_RELEASE(e->view);
    e->tex = tex;
    e->index = index;
    e->view = v;
    *out = v;
    return S_OK;
}

/* Largest rectangle of the frame's aspect ratio centred in the back buffer. */
static RECT letterbox(UINT fw, UINT fh, UINT w, UINT h) {
    RECT r;
    UINT64 a = (UINT64)fw * h, b = (UINT64)fh * w;
    UINT dw = w, dh = h;
    if (a > b)
        dh = (UINT)((UINT64)w * fh / fw);
    else if (a < b)
        dw = (UINT)((UINT64)h * fw / fh);
    r.left = (LONG)((w - dw) / 2);
    r.top = (LONG)((h - dh) / 2);
    r.right = r.left + (LONG)dw;
    r.bottom = r.top + (LONG)dh;
    return r;
}

static HRESULT draw_vp(mswc_presenter *p, const mswc_frame *frame) {
    HRESULT hr;
    D3D11_TEXTURE2D_DESC td;
    ID3D11Texture2D_GetDesc((ID3D11Texture2D *)frame->texture, &td);
    MSW_TRY(ensure_vp(p, td.Width, td.Height), done);
    if (!p->ov) {
        D3D11_VIDEO_PROCESSOR_OUTPUT_VIEW_DESC od;
        memset(&od, 0, sizeof od);
        od.ViewDimension = D3D11_VPOV_DIMENSION_TEXTURE2D;
        MSW_TRY(ID3D11VideoDevice_CreateVideoProcessorOutputView(p->vd, (ID3D11Resource *)p->back, p->vpe, &od,
                                                                 &p->ov),
                done);
    }
    ID3D11VideoProcessorInputView *iv = NULL;
    MSW_TRY(input_view(p, (ID3D11Texture2D *)frame->texture, frame->index, &iv), done);

    RECT src = {0, 0, (LONG)frame->width, (LONG)frame->height};
    RECT dst = letterbox(frame->width, frame->height, p->w, p->h);
    RECT all = {0, 0, (LONG)p->w, (LONG)p->h};
    ID3D11VideoContext_VideoProcessorSetStreamSourceRect(p->vc, p->vp, 0, TRUE, &src);
    ID3D11VideoContext_VideoProcessorSetStreamDestRect(p->vc, p->vp, 0, TRUE, &dst);
    ID3D11VideoContext_VideoProcessorSetOutputTargetRect(p->vc, p->vp, TRUE, &all);
    D3D11_VIDEO_PROCESSOR_COLOR_SPACE in_cs;
    memset(&in_cs, 0, sizeof in_cs);
    in_cs.YCbCr_Matrix = frame->height >= 720 ? 1 : 0; /* BT.709 for HD, BT.601 below */
    in_cs.Nominal_Range = D3D11_VIDEO_PROCESSOR_NOMINAL_RANGE_16_235;
    ID3D11VideoContext_VideoProcessorSetStreamColorSpace(p->vc, p->vp, 0, &in_cs);

    D3D11_VIDEO_PROCESSOR_STREAM st;
    memset(&st, 0, sizeof st);
    st.Enable = TRUE;
    st.pInputSurface = iv;
    MSW_TRY(ID3D11VideoContext_VideoProcessorBlt(p->vc, p->vp, p->ov, 0, 1, &st), done);
done:
    return hr;
}

static HRESULT shader_views(mswc_presenter *p, ID3D11Texture2D *tex, UINT index, srv_entry **out) {
    for (int i = 0; i < VIEW_CACHE; i++) {
        if (p->srvs[i].y && p->srvs[i].tex == tex && p->srvs[i].index == index) {
            *out = &p->srvs[i];
            return S_OK;
        }
    }
    srv_entry *e = &p->srvs[p->next_srv];
    p->next_srv = (p->next_srv + 1) % VIEW_CACHE;
    MSW_RELEASE(e->y);
    MSW_RELEASE(e->uv);
    e->tex = NULL;
    D3D11_SHADER_RESOURCE_VIEW_DESC vd;
    memset(&vd, 0, sizeof vd);
    vd.ViewDimension = D3D11_SRV_DIMENSION_TEXTURE2DARRAY;
    vd.Texture2DArray.MipLevels = 1;
    vd.Texture2DArray.FirstArraySlice = index;
    vd.Texture2DArray.ArraySize = 1;
    vd.Format = DXGI_FORMAT_R8_UNORM;
    HRESULT hr = ID3D11Device_CreateShaderResourceView(p->d3d->device, (ID3D11Resource *)tex, &vd, &e->y);
    if (FAILED(hr)) return hr;
    vd.Format = DXGI_FORMAT_R8G8_UNORM;
    hr = ID3D11Device_CreateShaderResourceView(p->d3d->device, (ID3D11Resource *)tex, &vd, &e->uv);
    if (FAILED(hr)) {
        MSW_RELEASE(e->y);
        return hr;
    }
    e->tex = tex;
    e->index = index;
    *out = e;
    return S_OK;
}

static HRESULT draw_shader(mswc_presenter *p, const mswc_frame *frame) {
    D3D11_TEXTURE2D_DESC td;
    ID3D11Texture2D_GetDesc((ID3D11Texture2D *)frame->texture, &td);
    srv_entry *e = NULL;
    HRESULT hr = shader_views(p, (ID3D11Texture2D *)frame->texture, frame->index, &e);
    if (FAILED(hr)) return hr;

    shader_consts k;
    memset(&k, 0, sizeof k);
    k.uv_scale[0] = (float)frame->width / (float)td.Width;
    k.uv_scale[1] = (float)frame->height / (float)td.Height;
    /* Limited-range luma; chroma rows for BT.709 (HD) or BT.601. */
    k.yoff[0] = 16.0f / 255.0f;
    k.yoff[1] = 255.0f / 219.0f;
    const float cs = 255.0f / 224.0f;
    if (frame->height >= 720) {
        const float r[4] = {1, 0, 1.5748f * cs, 0}, g[4] = {1, -0.1873f * cs, -0.4681f * cs, 0},
                    b[4] = {1, 1.8556f * cs, 0, 0};
        memcpy(k.r, r, sizeof r);
        memcpy(k.g, g, sizeof g);
        memcpy(k.b, b, sizeof b);
    } else {
        const float r[4] = {1, 0, 1.402f * cs, 0}, g[4] = {1, -0.344136f * cs, -0.714136f * cs, 0},
                    b[4] = {1, 1.772f * cs, 0, 0};
        memcpy(k.r, r, sizeof r);
        memcpy(k.g, g, sizeof g);
        memcpy(k.b, b, sizeof b);
    }
    ID3D11DeviceContext *ctx = p->d3d->context;
    ID3D11DeviceContext_UpdateSubresource(ctx, (ID3D11Resource *)p->cb, 0, NULL, &k, 0, 0);

    RECT dst = letterbox(frame->width, frame->height, p->w, p->h);
    D3D11_VIEWPORT vp = {(float)dst.left, (float)dst.top, (float)(dst.right - dst.left), (float)(dst.bottom - dst.top),
                         0, 1};
    ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, &p->rtv, NULL);
    ID3D11DeviceContext_RSSetViewports(ctx, 1, &vp);
    ID3D11DeviceContext_IASetInputLayout(ctx, NULL);
    ID3D11DeviceContext_IASetPrimitiveTopology(ctx, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    ID3D11DeviceContext_VSSetShader(ctx, p->vs, NULL, 0);
    ID3D11DeviceContext_VSSetConstantBuffers(ctx, 0, 1, &p->cb);
    ID3D11DeviceContext_PSSetShader(ctx, p->ps, NULL, 0);
    ID3D11DeviceContext_PSSetConstantBuffers(ctx, 0, 1, &p->cb);
    ID3D11DeviceContext_PSSetSamplers(ctx, 0, 1, &p->sampler);
    ID3D11ShaderResourceView *srv[2] = {e->y, e->uv};
    ID3D11DeviceContext_PSSetShaderResources(ctx, 0, 2, srv);
    ID3D11DeviceContext_Draw(ctx, 3, 0);
    /* Unbind so the decoder can write the texture again. */
    ID3D11ShaderResourceView *none[2] = {NULL, NULL};
    ID3D11DeviceContext_PSSetShaderResources(ctx, 0, 2, none);
    ID3D11DeviceContext_OMSetRenderTargets(ctx, 0, NULL, NULL);
    return S_OK;
}

msw_hr mswc_presenter_draw(mswc_presenter *p, const mswc_frame *frame) {
    HRESULT hr;
    MSW_TRY(get_targets(p), done);
    static const float black[4] = {0, 0, 0, 1};
    ID3D11DeviceContext_ClearRenderTargetView(p->d3d->context, p->rtv, black);

    if (frame && frame->texture) {
        if (p->use_shader)
            MSW_TRY(draw_shader(p, frame), done);
        else
            MSW_TRY(draw_vp(p, frame), done);
    }

    if (p->overlay_w && p->overlay_h) {
        D3D11_BOX box = {0, 0, 0, p->overlay_w < p->w ? p->overlay_w : p->w, p->overlay_h < p->h ? p->overlay_h : p->h,
                         1};
        ID3D11DeviceContext_CopySubresourceRegion(p->d3d->context, (ID3D11Resource *)p->back, 0, 0, 0, 0,
                                                  (ID3D11Resource *)p->overlay, 0, &box);
    }
    hr = S_OK;
done:
    return hr;
}

msw_hr mswc_presenter_present(mswc_presenter *p, uint32_t mode) {
    HRESULT hr;
    if (mode == MSWC_PRESENT_SMOOTH)
        hr = IDXGISwapChain2_Present(p->sc, 1, 0);
    else
        hr = IDXGISwapChain2_Present(p->sc, 0, p->tearing ? DXGI_PRESENT_ALLOW_TEARING : 0);
    /* DXGI_STATUS_OCCLUDED and friends are successes; the next wait still works. */
    return FAILED(hr) ? hr : S_OK;
}

msw_hr mswc_presenter_set_overlay(mswc_presenter *p, const uint32_t *pixels, uint32_t w, uint32_t h,
                                  uint32_t stride) {
    if (w > OVERLAY_MAX_W) w = OVERLAY_MAX_W;
    if (h > OVERLAY_MAX_H) h = OVERLAY_MAX_H;
    if (!pixels || w == 0 || h == 0) {
        p->overlay_w = p->overlay_h = 0;
        return S_OK;
    }
    D3D11_BOX box = {0, 0, 0, w, h, 1};
    ID3D11DeviceContext_UpdateSubresource(p->d3d->context, (ID3D11Resource *)p->overlay, 0, &box, pixels,
                                          stride * 4, 0);
    p->overlay_w = w;
    p->overlay_h = h;
    return S_OK;
}

msw_hr mswc_presenter_read_pixel(mswc_presenter *p, uint32_t x, uint32_t y, uint32_t *out) {
    if (x >= p->w || y >= p->h) return E_INVALIDARG;
    HRESULT hr;
    MSW_TRY(get_targets(p), done);
    if (!p->readback) {
        D3D11_TEXTURE2D_DESC td;
        ID3D11Texture2D_GetDesc(p->back, &td);
        td.Usage = D3D11_USAGE_STAGING;
        td.BindFlags = 0;
        td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
        td.MiscFlags = 0;
        MSW_TRY(ID3D11Device_CreateTexture2D(p->d3d->device, &td, NULL, &p->readback), done);
    }
    ID3D11DeviceContext_CopyResource(p->d3d->context, (ID3D11Resource *)p->readback, (ID3D11Resource *)p->back);
    D3D11_MAPPED_SUBRESOURCE m;
    MSW_TRY(ID3D11DeviceContext_Map(p->d3d->context, (ID3D11Resource *)p->readback, 0, D3D11_MAP_READ, 0, &m), done);
    *out = *(const uint32_t *)((const uint8_t *)m.pData + (size_t)y * m.RowPitch + (size_t)x * 4);
    ID3D11DeviceContext_Unmap(p->d3d->context, (ID3D11Resource *)p->readback, 0);
done:
    return hr;
}
