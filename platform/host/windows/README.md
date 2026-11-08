# platform/host/windows

The Windows host backend: `openHost(allocator, options)` in [host.zig](host.zig)
returns a `platform.HostBackend` (see [../../api.zig](../../api.zig)).

| Object | Implementation | File |
| --- | --- | --- |
| `Capture` | Desktop Duplication (`IDXGIOutputDuplication`), copied into our own BGRA texture and released at once | capture.c |
| `Encoder` | NVENC through `nvEncodeAPI64.dll` loaded at run time; Media Foundation's software H.264 MFT as the fallback | enc_nvenc.c, enc_mf.c, enc.c |
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
- `.auto` tries NVENC first, then Media Foundation. AMF and oneVPL come later.

## Running without a GPU (CI)

The windows-2022 runner has no GPU, no display output that DXGI can duplicate (adapter 0
is the Microsoft Basic Render Driver) and no audio endpoint. There, open with
`.driver = .warp, .encoder = .mf_software`: capture's `start` returns `Unsupported`, and
the encoder runs on textures the caller fills (`msw_texture_create` / `msw_texture_fill`).

`zig build test-win` runs [test.zig](test.zig). Tests for missing hardware print `skip`;
`MOONSEC_REQUIRE=mf,input` (set in CI) turns the named skips into failures. The names are
`dup`, `mf`, `nvenc`, `audio` and `input`.

## Not done yet

- Rotated outputs (`DXGI_OUTDUPL_DESC.Rotation`) and HDR (`DuplicateOutput1`).
- Cursor: the pointer position and shape are kept (`msw_dup_pointer_shape`), but the
  platform interface has no cursor channel yet.
- Hardware Media Foundation encoders (async MFTs on D3D11 textures), AMF and oneVPL.
- Virtual gamepads (they need a signed driver); `pad` actions are dropped.
- Real timing: capture, encode and SendInput latency need a Windows GPU host (S6).
