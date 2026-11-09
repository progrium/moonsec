/* What this GPU's D3D11VA decoder could do beyond 8-bit 4:2:0: Main10, HEVC 4:4:4
 * (RExt) and AV1 profiles, and whether it outputs P010 / Y410 for them.
 *
 * This is a probe, not the decode path. The client decodes through the Media Foundation
 * MFT (mswc_decode.c), which asks for NV12 output, and presents NV12 through the video
 * processor, so DecoderCaps.coded stays 8-bit 4:2:0 until those take more:
 *   - 10-bit / HDR10: set the MFT output type to MFVideoFormat_P010, keep P010 textures
 *     through the presenter's video processor (ID3D11VideoContext1::
 *     VideoProcessorSetStreamColorSpace1 with DXGI_COLOR_SPACE_YCBCR_STUDIO_G2084_LEFT_P2020),
 *     and on an HDR display present a DXGI_FORMAT_R10G10B10A2_UNORM swapchain with
 *     IDXGISwapChain3::SetColorSpace1(DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020) and
 *     IDXGISwapChain4::SetHDRMetaData (DXGI_HDR_METADATA_HDR10 from the config).
 *     DisplayCaps.hdr10 comes from IDXGIOutput6::GetDesc1 (ColorSpace == G2084 P2020).
 *   - 4:4:4: the system HEVC MFT has no RExt; it needs our own D3D11VA driving with the
 *     Main444 profiles below and AYUV/Y410 textures, or libavcodec's d3d11va hwaccel.
 *   - AV1: the AV1 Video Extension's MFT (MFVideoFormat_AV1) where installed, else the
 *     same libavcodec route; the AV1 profiles below say whether the GPU has it.
 * mswc_decoder_hw_formats reports what the hardware has so the hardware check on Jeff's
 * box can say which of these are worth building. Software (WARP) has no video device: 0.
 */
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#include "msw_internal.h"
#include "mswc.h"

#include <initguid.h>

/* Decoder profile GUIDs from dxva.h (DXVA_ModeAV1_VLD_*, DXVA_ModeHEVC_VLD_Main444 and
 * Main10_444); MinGW's d3d11.h has only HEVC Main and Main10. */
DEFINE_GUID(mswc_profile_av1_0, 0xb8be4ccb, 0xcf53, 0x46ba, 0x8d, 0x59, 0xd6, 0xb8, 0xa6, 0xda, 0x5d, 0x2a);
DEFINE_GUID(mswc_profile_av1_1, 0x6936ff0f, 0x45b1, 0x4163, 0x9c, 0xc1, 0x64, 0x6e, 0xf6, 0x94, 0x61, 0x08);
DEFINE_GUID(mswc_profile_hevc_444, 0x4008018f, 0xf537, 0x4b36, 0x98, 0xcf, 0x61, 0xaf, 0x8a, 0x2c, 0x1a, 0x33);
DEFINE_GUID(mswc_profile_hevc_444_10, 0x0dabeffa, 0x4458, 0x4602, 0xbc, 0x03, 0x07, 0x95, 0x65, 0x9d, 0x61, 0x7c);

static int has_profile(ID3D11VideoDevice *vd, const GUID *want, DXGI_FORMAT out) {
    UINT n = ID3D11VideoDevice_GetVideoDecoderProfileCount(vd);
    for (UINT i = 0; i < n; i++) {
        GUID g;
        if (FAILED(ID3D11VideoDevice_GetVideoDecoderProfile(vd, i, &g)) || !IsEqualGUID(&g, want)) continue;
        BOOL ok = FALSE;
        return SUCCEEDED(ID3D11VideoDevice_CheckVideoDecoderFormat(vd, want, out, &ok)) && ok;
    }
    return 0;
}

uint32_t mswc_decoder_hw_formats(msw_d3d *d3d, uint32_t codec) {
    ID3D11VideoDevice *vd = NULL;
    if (FAILED(ID3D11Device_QueryInterface(d3d->device, &IID_ID3D11VideoDevice, (void **)&vd))) return 0;
    uint32_t f = 0;
    switch (codec) {
    case MSWC_CODEC_H264:
        if (has_profile(vd, &D3D11_DECODER_PROFILE_H264_VLD_NOFGT, DXGI_FORMAT_NV12)) f |= MSWC_FMT_420_8;
        break;
    case MSWC_CODEC_HEVC:
        if (has_profile(vd, &D3D11_DECODER_PROFILE_HEVC_VLD_MAIN, DXGI_FORMAT_NV12)) f |= MSWC_FMT_420_8;
        if (has_profile(vd, &D3D11_DECODER_PROFILE_HEVC_VLD_MAIN10, DXGI_FORMAT_P010)) f |= MSWC_FMT_420_10 | MSWC_FMT_HDR10;
        if (has_profile(vd, &mswc_profile_hevc_444, DXGI_FORMAT_AYUV)) f |= MSWC_FMT_444_8;
        if (has_profile(vd, &mswc_profile_hevc_444_10, DXGI_FORMAT_Y410)) f |= MSWC_FMT_444_10;
        break;
    case MSWC_CODEC_AV1:
        if (has_profile(vd, &mswc_profile_av1_0, DXGI_FORMAT_NV12)) f |= MSWC_FMT_420_8;
        if (has_profile(vd, &mswc_profile_av1_0, DXGI_FORMAT_P010)) f |= MSWC_FMT_420_10 | MSWC_FMT_HDR10;
        if (has_profile(vd, &mswc_profile_av1_1, DXGI_FORMAT_AYUV)) f |= MSWC_FMT_444_8;
        if (has_profile(vd, &mswc_profile_av1_1, DXGI_FORMAT_Y410)) f |= MSWC_FMT_444_10;
        break;
    default: break;
    }
    ID3D11VideoDevice_Release(vd);
    return f;
}
