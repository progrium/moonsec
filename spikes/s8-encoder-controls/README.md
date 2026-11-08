# S8 — Encoder capability matrix (VideoToolbox half)

**Status: VideoToolbox done (2 of 3 pass); NVENC, AMF and oneVPL implemented in the Windows host backend (platform/host/windows) from their SDK docs, pending a run on each vendor's GPU.**
Run on Jeff's M3 Max MacBook in `/tmp/moonsec-spikes/s8`; the harness, probe and raw logs here were copied
from that run (`s8-results.tgz`).

Question (design doc, S8): do the hardware encoders support what the design needs —
per-frame bitrate change without IDR, intra-refresh, long-term references (for RFI)?

Machine: MacBook Pro Mac15,10, Apple M3 Max, macOS 15.8.1 (24H32), SDK 15.0.
Harness: `s8.m` (Obj-C, C ABI only, no deps). 1920x1080 NV12 synthetic content
(moving pattern + noise, so the rate controller is always binding), 60 fps timestamps,
RealTime=1, AllowFrameReordering=0, MaxKeyFrameInterval=100000, 20 Mbps start.
Raw logs in `results/`.

```
clang -O2 -fobjc-arc -framework Foundation -framework VideoToolbox -framework CoreMedia -framework CoreVideo s8.m -o s8
./s8 h264|hevc bitrate|bitrate-ll|irefresh-none|irefresh-frames N|irefresh-ll-dur S|ltr ACKDELAY|ltr-norefresh ACKDELAY
S8SKIPCORRUPT=1 ./s8 hevc ltr 3   # client drops frames between loss and refresh (see LTR notes)
```

Two encoder paths exist on Apple silicon:
- default (`ave.avc` / `ave.hevc`): the plain AVE hardware encoder.
- low-latency (`kVTVideoEncoderSpecification_EnableLowLatencyRateControl`, `h264.rtvc` / `hevc.rtvc`):
  the FaceTime-style real-time path. Creates fine with RequireHardwareAccelerated=YES; process CPU time
  is the same as the default path (~2.1 vs 2.3 s user for 360 frames, nearly all of it our pixel fill), so
  it is AVE underneath. **LTR exists only on this path.**

## Matrix

| Backend | Per-frame bitrate, no IDR | Intra-refresh | Long-term refs / RFI | Status |
|---|---|---|---|---|
| VideoToolbox H.264 (M3 Max) | **PASS** (both paths) | **FAIL** — no working knob | **PASS** (low-latency path) | tested |
| VideoToolbox HEVC (M3 Max) | **PASS** (both paths) | **FAIL** — private key accepted but ignored | **PASS** (low-latency path; client must drop frames until refresh) | tested |
| NVENC | vendor docs: yes (`nvEncReconfigureEncoder`, no IDR needed) | vendor docs: yes (`enableIntraRefresh`) | vendor docs: yes (LTR + `nvEncInvalidateRefFrames`) | **implemented (enc_nvenc.c), untested** |
| AMF | SDK docs: yes (`TargetBitrate`/`PeakBitrate` are dynamic properties; no IDR) | SDK docs: yes (`IntraRefreshMBsNumberPerSlot`; not used) | SDK docs: yes (`MaxOfLTRFrames`, per-frame `MarkCurrentWithLTRIndex` / `ForceLTRReferenceBitfield`, output `MarkedLTRIndex`) | **implemented (enc_amf.c), untested** |
| oneVPL | SDK docs: yes (`MFXVideoENCODE_Reset` with `StartNewSequence` off) | SDK docs: yes (`mfxExtCodingOption2.IntRefType`; not used) | SDK docs: yes (`mfxExtAVCRefListCtrl`: `LongTermRefList` + `ApplyLongTermIdx` to mark, `PreferredRefList`/`RejectedRefList` to refresh; H.264 and HEVC; support found by Query mode 1) | **implemented (enc_vpl.c), untested** |

The Windows rows are what each SDK documents, as the backends use it; none has run on its
GPU yet. To fill them in on hardware, run the Phase 5 recovery gate
([tools/recovery](../../tools/recovery/README.md)), which checks per-frame bitrate
changes (in the backend tests, `zig build test-win`) and LTR recovery without IDRs:
`zig build recovery -Doptimize=ReleaseSafe -- --backend win-nvenc` (or `win-amf`,
`win-vpl`; add `--codec hevc`).

Gate ("at least NVENC and VideoToolbox pass"): VideoToolbox passes on bitrate + LTR, fails on intra-refresh.
Since the design uses LTR/RFI for loss and intra-refresh only to avoid periodic keyframes, VideoToolbox is
usable: run with no periodic keyframes at all and recover with LTR, IDR only as last resort.

## Details

### 1. Per-frame bitrate change (AverageBitRate set between frames: 20 → 4 → 30 → 8 Mbps at frames 120/240/300)

| Config | IDRs after frame 0 | Mbps 60–120 / 125–240 / 245–300 / 305–360 | Frames to settle at 4 Mbps |
|---|---|---|---|
| H.264 default | 0 | 18.8 / 4.1 / 28.8 / 8.5 | 0 |
| H.264 low-latency | 0 | 20.0 / 3.8 / 27.9 / 7.9 | 7 |
| HEVC default | 0 | 19.7 / 4.1 / 30.6 / 7.6 | 1 |
| HEVC low-latency | 0 | 20.0 / 3.7 / 27.5 / 8.0 | 11 |

- Setting the property mid-session returns noErr and takes effect on the next frame; no sync frame is emitted.
- Also setting `DataRateLimits` alongside made no measurable difference in this content (identical numbers).
- Submit→callback latency with one frame in flight: ~8–11 ms mean at 1080p (relevant to S7's 8 ms target; first frame ~25–57 ms).

### 2. Intra-refresh

- No public VideoToolbox key for intra-refresh (checked SDK 15.0 headers).
- `IntraRefreshFrames` (undocumented) is listed only on the default HEVC encoder. It accepts 30/120 and reads back,
  but the output is **byte-for-byte identical in size** to the run without it (same mean, same peaks, no recovery-point SEI,
  no change in frame-size spread). Ignored. On H.264 it returns -12900 (property not supported).
- Low-latency path has `MaxRefreshFrameIntervalDuration` (undocumented). Setting 1 s produces **full IDRs every 60 frames**
  (NAL 5 / NAL 20, ~93–140 KB), i.e. periodic keyframes, not gradual refresh.
- Peak/mean frame size with no refresh: 2.0 (H.264 LL) to 4.2 (HEVC LL). No spreading mechanism available.
- Not tried: passing `IntraRefreshFrames` in the encoder specification instead of as a property.

### 3. Long-term references (public API, macOS 12+): `EnableLTR`, `RequireLTRAcknowledgementToken`, `AcknowledgedLTRTokens`, `ForceLTRRefresh`

Test: encode 240 frames; simulated client acks every received LTR token after an ack delay (3 or 10 frames);
frames 100–104 are lost (never acked, nor anything after them until the refresh); at loss detection (105 + ack delay)
the next frame is encoded with `ForceLTRRefresh`. Verification by decoding with VTDecompressionSession twice —
full stream vs. stream with frames lost — and comparing a luma hash per frame.

| Config | Refresh frame type / size | Mean P size | IDR size | Lossy decode bit-exact from | Control (no refresh) |
|---|---|---|---|---|---|
| H.264 LL, ack delay 3 | P, 59 KB | 40 KB | 311 KB | frame 108 (the refresh), all frames after | never recovers |
| H.264 LL, ack delay 10 | P, 52 KB | 40 KB | 311 KB | frame 115 (the refresh) | — |
| HEVC LL, ack delay 3 | P, 90 KB | 41 KB | 326 KB | frame 108* | never recovers (decoder errors on every frame) |
| HEVC LL, ack delay 10 | P, 51 KB | 41 KB | 326 KB | frame 115* | — |

- `EnableLTR` is only available on the low-latency path; on the default encoders it is not in the supported-properties list.
- No sync frame ever emitted after frame 0 in any LTR run. Refresh frame costs ~1.3–2.2x a normal P frame vs ~8x for an IDR.
- H.264: feeding the decoder the broken frames between loss and refresh is harmless; it recovers bit-exact at the refresh.
- *HEVC: if the decoder is fed frames that reference lost pictures (105–107 here), VT's HEVC decoder returns
  `kVTVideoDecoderBadDataErr` (-12909) for that frame **and every frame after it, including the refresh**. If the client
  drops frames from the first gap until the refresh frame arrives, it recovers bit-exact. Client rule: on a detected gap,
  stop feeding the decoder until a refresh/IDR. (Not checked whether D3D11VA/VAAPI behave the same.)
- The encoder decides which frames carry LTR tokens (H.264: ~40% of frames; HEVC: every frame at ack delay 3, ~10% at ack delay 10).
  The host can't choose LTR slots, only ack and force refresh.

## Takeaways for the design
1. Rate controller: free to change bitrate per frame on VideoToolbox; use the low-latency path anyway (needed for LTR); it settles in 7–11 frames.
2. Recovery on VideoToolbox = LTR ack + `ForceLTRRefresh`, IDR as last resort. Works on H.264 and HEVC.
3. No intra-refresh on VideoToolbox; plan for no periodic keyframes (MaxKeyFrameInterval huge) rather than gradual refresh.
4. Client needs "freeze until refresh" on loss (required for VT HEVC decode, harmless elsewhere).
5. Hosts need to ack LTR tokens back from the client — the protocol needs an ack-token message (client → host) carrying the token from
   the frame's attachment; the token must travel with the frame (it's a VT sample attachment, not in the bitstream).
