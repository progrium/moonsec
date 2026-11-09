# platform

The platform interface ([api.zig](api.zig)) is what every OS backend implements so the
host and client apps run on it. The apps (session spine) drive these objects and never
learn which OS, GPU API or codec library is underneath.

| Side | Object | Thread | Windows (Phase 2) | macOS (Phase 4) | Linux (client Phase 4, host Phase 7) |
| --- | --- | --- | --- | --- | --- |
| host | `Capture` | capture | Desktop Duplication | ScreenCaptureKit | ScreenCast portal + PipeWire (dma-buf or memfd) |
| host | `Encoder` | encode | NVENC | VideoToolbox (low latency, LTR) | VAAPI, NVENC, software (7B) |
| host | `AudioSource` | audio | WASAPI loopback | ScreenCaptureKit audio | PipeWire, default sink's monitor |
| host | `InputInjector` | network | SendInput | CGEvent | uinput |
| client | `Decoder` | decode | D3D11VA | | libavcodec: VAAPI, software fallback |
| client | `Presenter` | present | flip-model swapchain | | Wayland + EGL/GLES 3 |
| client | `AudioSink` | audio | WASAPI | | PipeWire |
| client | `InputSource` | input/network | Raw Input | | evdev |

The macOS host backend is in [host/macos](host/macos/README.md). The Linux client is in
[client/linux](client/linux/README.md) and the Linux host in [host/linux](host/linux/README.md);
they share the uinput plumbing and key table in [linux/uinput.zig](linux/uinput.zig).

A backend lives in `platform/<name>/` and exports `openHost(...) !HostBackend` and/or
`openClient(...) !ClientBackend`. Write plain methods on your own types and turn them
into interface values with `api.bind(api.Capture, MyCapture, &my_capture)`.

The rules (threads, clock, buffer ownership, errors) are at the top of `api.zig`. The
interface is stable from Phase 2 on: new fields get defaults and new vtable methods go at
the end.

## Formats

Beyond 8-bit 4:2:0 SDR, a stream can be 4:4:4, 10-bit and HDR10 (BT.2020, PQ, ST 2086
and CTA-861.3 metadata). [format.zig](format.zig) has the types and `negotiate`; the wire
form is in [spec/wire-v0.md](../spec/wire-v0.md) ("Session"). Backends say what they take
in `EncoderCaps.coded` and `DecoderCaps.coded` (per codec; empty means 8-bit 4:2:0), the
client bundle's `display` says whether its screen is in HDR mode, and `Capture.start`
returns the captured display's colour mode and metadata when asked for HDR capture.
Encoders, decoders and presenters are configured with the chosen `VideoFormat`.

| Backend | What it does now | What it still needs |
| --- | --- | --- |
| Synthetic | Every format for the passthrough codec; the decoder and presenter check the format end to end (`zig build test-app` streams every combination). | |
| Linux client (libavcodec) | Software: HEVC Main10, Main 4:4:4, Main 4:4:4 10, AV1 Main/High 8/10-bit (dav1d), H.264 High 4:4:4; HDR10 metadata read from SEI and metadata OBUs; the GLES presenter draws 4:4:4 and 10-bit (reduced to 8 bits) and tone-maps PQ to SDR (`zig build test-linux`, fixtures from `client/linux/testdata/gen-formats.sh`). VAAPI surfaces other than NV12 are copied to memory. | HDR output: Wayland `wp_color_manager_v1` and a 10-bit EGL surface, then `display.hdr10`. Zero-copy P010 dma-buf import. |
| Windows client (MF/D3D11VA) | 8-bit 4:2:0. `mswc_decoder_hw_formats` probes the GPU's D3D11VA profiles (Main10, HEVC 4:4:4, AV1) for the hardware check. | P010 MFT output and a colour-space-aware video processor; an R10G10B10A2 swapchain with `SetColorSpace1(G2084 P2020)` and `SetHDRMetaData`, `display.hdr10` from `IDXGIOutput6::GetDesc1`; 4:4:4 and AV1 through our own D3D11VA driving or libavcodec's d3d11va (the system HEVC MFT has no RExt). See `client/windows/mswc_formats.c`. |
| Windows host (NVENC, PR #15) | Written and compile-checked on top of #15, not in this branch yet: H.264 High 4:4:4, HEVC Main10/FREXT, AV1 Main 8/10-bit, BT.709 or BT.2020/PQ VUI, mastering display and light level SEI (HEVC) or metadata OBUs (AV1) on IDRs; AV1 recovers with IDRs (no LTR in SDK 12.0). | HDR capture (`DuplicateOutput1` with FP16, a PQ conversion pass to R10G10B10A2) before HDR10 or HEVC 10-bit is offered. AMF and oneVPL (5E). |
| macOS host (VideoToolbox, PR #27) | 8-bit 4:2:0. | HEVC Main10: `kVTProfileLevel_HEVC_Main10_AutoLevel` with `kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange` input; HDR10: `ColorPrimaries`/`TransferFunction`/`YCbCrMatrix` set to ITU-R 2020/SMPTE ST 2084/ITU-R 2020 and `MasteringDisplayColorVolume`/`ContentLightLevelInfo` (the SEI bytes); ScreenCaptureKit HDR capture (`SCStreamConfiguration` `captureDynamicRange`, macOS 15). VideoToolbox has no HEVC 4:4:4 or AV1 encoder; whether LTR works on the Main10 low-latency path is unknown. |
| macOS client (VideoToolbox, PR #29) | 8-bit 4:2:0. | 10-bit output (`kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange`) and AV1 (`kCMVideoCodecType_AV1`, M3 and later); a CAMetalLayer with `wantsExtendedDynamicRangeContent`, an RGBA16Float or BGR10A2 drawable in `kCGColorSpaceITUR_2100_PQ`, `display.hdr10` from `NSScreen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1`. 4:4:4 HEVC decodes in software only. |

Hardware checks (none of this has run on a GPU yet):

- Linux client on a GPU: `platform/client/linux/headless.sh zig build test-linux` on a
  machine with VAAPI; the 10-bit and 4:4:4 fixtures should still decode (in hardware where
  the driver has the profile, else the software fallback logs why).
- Windows client: `zig build test-win` prints `D3D11VA formats:` for the GPU.
- NVENC (RTX 40 for AV1): apply `0001-nvenc-av1-444-10bit-hdr10.patch` on #15, then
  `zig build test-win`; `moonsec` with `--yuv444` against the Linux client should
  negotiate HEVC or H.264 4:4:4 and play.
- HDR10 needs an HDR display on both ends and the capture and presenter work above.
