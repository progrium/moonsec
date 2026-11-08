# platform/host/windows

The Windows host backend: `openHost(allocator, options)` in [host.zig](host.zig)
returns a `platform.HostBackend` (see [../../api.zig](../../api.zig)).

| Object | Implementation | File |
| --- | --- | --- |
| `Capture` | Desktop Duplication (`IDXGIOutputDuplication`), copied into our own BGRA texture and released at once | capture.c |
| `Encoder` | NVENC (`nvEncodeAPI64.dll`), AMF (`amfrt64.dll`) and oneVPL (`libvpl.dll` / `libmfx64-gen.dll`), each loaded at run time; Media Foundation's software H.264 MFT as the fallback | enc_nvenc.c, enc_amf.c, enc_vpl.c, enc_mf.c, enc.c |
| `AudioSource` | WASAPI loopback of the default render endpoint, 48 kHz float, event driven | audio.c |
| `InputInjector` | `SendInput`: keys by scan code from HID usages, buttons, wheel, relative and absolute motion | input.c |
| `Clock` | `QueryPerformanceCounter` | ../../windows/msw.c |

C code follows [../../windows/README.md](../../windows/README.md): COM in C against Zig's
bundled mingw-w64 headers, and Zig sees only [host_win.h](host_win.h).

## Encoders

- **NVENC** (`.nvenc`): P1 preset with ultra-low-latency tuning, CBR with a one-frame VBV,
  infinite GOP, no B-frames, `repeatSPSPPS`, up to 4 slices. Bitrate changes go through
  `nvEncReconfigureEncoder` without an IDR. Long-term references use "per picture" mode
  with two slots: a frame is marked every 15 frames (and on every IDR and refresh), never
  over the newest acked slot, and `ltr_refresh` references the newest acked one. Its token
  is the frame number. The header is vendored in [third_party/nvenc](../../../third_party/nvenc)
  (SDK 12.0, driver 522.25 or newer). **Not yet run on an NVIDIA GPU**; S8's NVENC rows
  will check it.
- **Media Foundation software H.264** (`.mf_software`): the sync MFT that `MFTEnumEx`
  finds first, normally the Microsoft H.264 Video Encoder. Low-latency mode, CBR,
  baseline profile, no B-frames, one GOP per hour, `ForceKeyFrame` for IDRs, and
  `MeanBitRate` changed while streaming. No LTR, so `ltr_refresh` becomes an IDR. Frames
  are read back and converted to NV12 (BT.709, limited range) on the CPU. It's the CI path
  and the last fallback, not a fast path.
- **AMF** (`.amf`, AMD): `amfrt64.dll` from the driver (runtime 1.4 or newer). Takes the
  BGRA texture directly (the encoder converts on the GPU), ultra-low-latency usage with
  `LowLatencyInternal`, CBR with a one-frame VBV and HRD enforced, no B-frames, no
  periodic IDR (`IDRPeriod` 0 / `HevcGOPSPerIDR` 0), no pre-analysis, `QueryTimeout` for
  synchronous output, up to 4 slices. Bitrate changes set `TargetBitrate`/`PeakBitrate`/
  `VBVBufferSize` on the running encoder (dynamic properties, no IDR). Long-term
  references: `MaxOfLTRFrames` 2 with `LTRMode` keep-unused; per frame
  `MarkCurrentWithLTRIndex` and `ForceLTRReferenceBitfield` on the input surface, with the
  same two-slot policy as NVENC; the marked slot is read back from `MarkedLTRIndex`.
  `ltr` in the caps comes from initializing a probe encoder with LTR on. Headers in
  [third_party/amf](../../../third_party/amf). **Not yet run on an AMD GPU.**
- **oneVPL** (`.vpl`, Intel Xe / 11th-gen Core and newer): the dispatcher `libvpl.dll` if
  it is next to the program, else the driver's `libmfx64-gen.dll` (`MFXInitialize`). Needs
  a device made with video support (`openHost` asks for one). VDEnc (`LowPower`) with
  `LowDelayBRC`, CBR with a one-frame buffer, `AsyncDepth` 1, no B-frames, one IDR
  (`GopPicSize` 65535), RGB4 input converted by the hardware. The input surface comes from
  `MFXMemory_GetSurfaceForEncode`; when its native handle is a plain texture on our device
  the BGRA frame is copied on the GPU, else it is read back and written through `Map`.
  Bitrate changes go through `MFXVideoENCODE_Reset` with `StartNewSequence` off. Long-term
  references through `mfxExtAVCRefListCtrl` (H.264 and HEVC): `LongTermRefList` with
  `ApplyLongTermIdx` to mark, `PreferredRefList` plus `RejectedRefList` (every newer
  frame) to refresh. `ltr` in the caps comes from Query mode 1 on that buffer, as the API
  documents. Headers in [third_party/vpl](../../../third_party/vpl). **Not yet run on an
  Intel GPU.**
- `.auto` tries NVENC, AMF, oneVPL, then Media Foundation. AMF and oneVPL return
  not-found at once on another vendor's adapter (checked from the DXGI vendor ID), NVENC
  when its DLL is missing.

The recovery gate ([tools/recovery](../../../tools/recovery)) runs any of them through
loss and LTR recovery: `zig build recovery -- --backend win-nvenc|win-amf|win-vpl`.

## Running without a GPU (CI)

The windows-2022 runner has no GPU, no display output that DXGI can duplicate (adapter 0
is the Microsoft Basic Render Driver) and no audio endpoint. There, open with
`.driver = .warp, .encoder = .mf_software`: capture's `start` returns `Unsupported`, and
the encoder runs on textures the caller fills (`msw_texture_create` / `msw_texture_fill`).

`zig build test-win` runs [test.zig](test.zig). Tests for missing hardware print `skip`;
`MOONSEC_REQUIRE=mf,input` (set in CI) turns the named skips into failures. The names are
`dup`, `mf`, `nvenc`, `amf`, `vpl`, `audio` and `input`.

## Not done yet

- Rotated outputs (`DXGI_OUTDUPL_DESC.Rotation`) and HDR (`DuplicateOutput1`).
- Cursor: the pointer position and shape are kept (`msw_dup_pointer_shape`), but the
  platform interface has no cursor channel yet.
- Hardware Media Foundation encoders (async MFTs on D3D11 textures).
- AMF and oneVPL on real AMD and Intel GPUs (both are compile- and not-found-tested only).
- Virtual gamepads (they need a signed driver); `pad` actions are dropped.
- Real timing: capture, encode and SendInput latency need a Windows GPU host (S6).
