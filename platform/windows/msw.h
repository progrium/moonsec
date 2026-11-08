/* moonsec Windows platform: the C ABI that Zig sees.
 *
 * COM, D3D11, DXGI, Media Foundation and WASAPI code lives in small .c files
 * compiled by `zig cc` against Zig's bundled mingw-w64 headers. This header
 * (and every other Zig-facing header under platform/) must not include
 * <windows.h>: it is translated with b.addTranslateC and should stay tiny.
 * C files that need the COM types include msw_internal.h instead.
 *
 * Conventions: functions return an HRESULT as int32_t (negative = failure),
 * objects are opaque pointers, out-parameters come last.
 */
#ifndef MSW_H
#define MSW_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef int32_t msw_hr;

#define MSW_OK 0
/* HRESULTs Zig code checks for by value. */
#define MSW_E_FAIL ((msw_hr)0x80004005u)
#define MSW_E_INVALIDARG ((msw_hr)0x80070057u)
#define MSW_E_OUTOFMEMORY ((msw_hr)0x8007000Eu)
#define MSW_E_NOTFOUND ((msw_hr)0x80070490u)               /* HRESULT_FROM_WIN32(ERROR_NOT_FOUND) */
#define MSW_DXGI_ERROR_NOT_FOUND ((msw_hr)0x887A0002u)
#define MSW_DXGI_ERROR_UNSUPPORTED ((msw_hr)0x887A0004u)
#define MSW_DXGI_ERROR_ACCESS_LOST ((msw_hr)0x887A0026u)
#define MSW_DXGI_ERROR_WAIT_TIMEOUT ((msw_hr)0x887A0027u)
#define MSW_DXGI_ERROR_DEVICE_REMOVED ((msw_hr)0x887A0005u)

/* Writes the system message for `hr` (UTF-8, no trailing newline) and returns its
 * length. Unknown codes give "HRESULT 0x........". */
size_t msw_hr_message(msw_hr hr, char *buf, size_t len);

/* COM on the calling thread (multithreaded apartment). Pair with msw_com_uninit. */
msw_hr msw_com_init(void);
void msw_com_uninit(void);

/* QueryPerformanceCounter in nanoseconds: the clock every capture and encode
 * timestamp on Windows uses. */
uint64_t msw_qpc_ns(void);

/* ---- D3D11 device ---------------------------------------------------------- */

typedef enum msw_driver {
    /* A hardware adapter from DXGI (adapter_index in enumeration order, 0 = primary). */
    MSW_DRIVER_HARDWARE = 0,
    /* WARP, the software rasterizer. Always present, has no outputs; CI uses it. */
    MSW_DRIVER_WARP = 1,
} msw_driver;

enum {
    /* D3D11_CREATE_DEVICE_DEBUG; needs the Graphics Tools optional feature. */
    MSW_D3D_DEBUG = 1u << 0,
    /* Video support (D3D11_CREATE_DEVICE_VIDEO_SUPPORT) for decode and video processing. */
    MSW_D3D_VIDEO = 1u << 1,
};

typedef struct msw_d3d msw_d3d;

typedef struct msw_adapter_info {
    char description[128]; /* UTF-8 */
    uint32_t vendor_id;    /* 0x10DE NVIDIA, 0x1002 AMD, 0x8086 Intel, 0x1414 Microsoft (WARP/Basic) */
    uint32_t device_id;
    uint64_t dedicated_video_memory;
    int64_t luid; /* LUID packed as (HighPart << 32) | LowPart */
    uint32_t feature_level; /* D3D_FEATURE_LEVEL, e.g. 0xb000 for 11_0 */
    uint32_t is_software;   /* DXGI_ADAPTER_FLAG_SOFTWARE */
} msw_adapter_info;

/* Enumerates DXGI adapters (index 0 is the primary). Returns MSW_DXGI_ERROR_NOT_FOUND
 * past the end. feature_level is 0: the adapter is not opened. */
msw_hr msw_adapter_get(uint32_t index, msw_adapter_info *out);

/* Creates a device and its immediate context. The device is multithread-protected
 * (ID3D10Multithread), since capture, encode and present share it across threads. */
msw_hr msw_d3d_create(msw_driver driver, uint32_t adapter_index, uint32_t flags, msw_d3d **out);
void msw_d3d_destroy(msw_d3d *d);
void msw_d3d_info(const msw_d3d *d, msw_adapter_info *out);
/* Borrowed COM pointers (ID3D11Device*, ID3D11DeviceContext*, IDXGIAdapter1*) for C
 * code in other modules that does not include msw_internal.h. No AddRef. */
void *msw_d3d_device(const msw_d3d *d);
void *msw_d3d_context(const msw_d3d *d);
void *msw_d3d_adapter(const msw_d3d *d);

/* GPU smoke test: clears a BGRA render target of w x h to `bgra` (0xAARRGGBB),
 * copies it to a staging texture, maps it and returns the pixel at (x, y). */
msw_hr msw_d3d_selftest(msw_d3d *d, uint32_t w, uint32_t h, uint32_t bgra, uint32_t x, uint32_t y,
                        uint32_t *out_pixel);

/* ---- Textures (tests, synthetic sources, readback) --------------------------- */

/* A w x h BGRA texture (ID3D11Texture2D*, DEFAULT usage, render target and shader
 * resource) filled with `bgra`. Release with msw_texture_release. */
msw_hr msw_texture_create(msw_d3d *d, uint32_t w, uint32_t h, uint32_t bgra, void **out_texture);
void msw_texture_release(void *texture);
/* Fills the rectangle [x, x+w) x [y, y+h) of a BGRA texture with `bgra`. */
msw_hr msw_texture_fill(msw_d3d *d, void *texture, uint32_t x, uint32_t y, uint32_t w, uint32_t h, uint32_t bgra);
/* Copies subresource `index` of a BGRA texture to `dst` (rows of `stride` bytes). */
msw_hr msw_texture_read(msw_d3d *d, void *texture, uint32_t index, uint8_t *dst, uint32_t stride);

#ifdef __cplusplus
}
#endif

#endif
