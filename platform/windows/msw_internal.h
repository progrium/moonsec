/* For C files under platform/: the COM side of msw.h. Not for Zig. */
#ifndef MSW_INTERNAL_H
#define MSW_INTERNAL_H

#ifndef COBJMACROS
#define COBJMACROS
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <d3d10.h> /* ID3D10Multithread */
#include <stdlib.h>

#include "msw.h"

struct msw_d3d {
    ID3D11Device *device;
    ID3D11DeviceContext *context;
    IDXGIAdapter1 *adapter;
    D3D_FEATURE_LEVEL feature_level;
    msw_driver driver;
};

/* Release a COM pointer and null it. */
#define MSW_RELEASE(p)                         \
    do {                                       \
        if (p) {                               \
            (p)->lpVtbl->Release(p);           \
            (p) = NULL;                        \
        }                                      \
    } while (0)

/* Evaluate an HRESULT expression into `hr` and jump to `label` on failure. */
#define MSW_TRY(expr, label)   \
    do {                       \
        hr = (expr);           \
        if (FAILED(hr)) goto label; \
    } while (0)

/* UTF-16 to UTF-8 into a fixed buffer, always NUL-terminated. */
void msw_utf8(const WCHAR *src, char *dst, size_t dst_len);

void msw_adapter_fill(IDXGIAdapter1 *a, msw_adapter_info *out);

#endif
