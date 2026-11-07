# Spike S7: macOS host encode baseline

**Question (design doc, S7):** what is the capture-to-encode baseline on a macOS host?
**Pass:** encode under 8 ms at 1080p60.

**Status: pass, with non-obvious encoder settings.**

> The probe is here: a Zig 0.16 driver (`src/main.zig`) and an Objective-C
> ScreenCaptureKit → VideoToolbox core (`src/probe.m`). Raw output and per-frame CSVs for
> every run are in `results/`. Follow-up on the S8 conflict: [`../s7b-macos-ltr-encode`](../s7b-macos-ltr-encode/README.md).

Machine: MacBook Pro, Apple M3 Max, macOS 15.8.1. Real ScreenCaptureKit capture of the
desktop at 1920x1080, 60 Hz. Intel Macs were not tested.

## Results

Encode time per frame (submit to encoded callback), ms:

| Config | p50 | p95 | p99 | vs 8 ms |
| --- | --- | --- | --- | --- |
| H.264, `RealTime=false`, low-latency rate control off | 6.24 | 6.57 | 6.75 | pass |
| HEVC, `RealTime=false`, low-latency rate control off | 4.47 | 4.80 | 4.99 | pass |
| `RealTime=true` + `EnableLowLatencyRateControl` | 14.1 | 14.9 | 15.5 | fail |

The configuration that sounds right (RealTime on plus the low-latency rate control
encoder) costs about 14 ms even on an idle desktop. The encoder appears to pace itself to
fill the frame interval rather than doing more work.

Other stages, passing H.264 config:

| Stage | p50 | p95 | p99 |
| --- | --- | --- | --- |
| SCK capture vs vsync | −0.13 | — | 9.6 |
| Vsync to encoded frame | 6.12 | 12.95 | 15.71 |

- **Capture:** SCK usually delivers a frame 1–2 ms before its vsync, but some runs have a
  late tail (p99 9.6 ms). That tail, not the encoder, drives the vsync-to-encoded p95/p99.
- **Frame sizes:** without low-latency rate control, frames spike up to 3x the average.
  A `DataRateLimits` cap of one frame's budget brings the peak back to about 1x and keeps
  encode at 6.8 ms p99, but it undershoots the average bitrate. Needs tuning.
- About 3 of 25 runs exited with no output; the cause was not found.

## Full results (real capture, 1080p60)

Capture is signed (callback minus vsync); glass2enc is vsync to encoded frame. "LL-RC" is
`EnableLowLatencyRateControl`. All times ms, p50/p95/p99.

| Config | Scene | capture p50/p95/p99 | encode p50/p95/p99 | glass2enc p50/p95/p99 | Pass |
| --- | --- | --- | --- | --- | --- |
| **H.264, RealTime off, LL-RC off** | motion | -0.13 / 6.79 / 9.60 | **6.24 / 6.57 / 6.75** | 6.12 / 12.95 / 15.71 | ✅ |
| H.264, RealTime off, LL-RC off | noise | -1.48 / 0.74 / 1.14 | 5.87 / 6.25 / 6.35 | 4.36 / 6.90 / 7.20 | ✅ |
| H.264, RealTime off, LL-RC off | idle desktop | -1.03 / 1.37 / 6.00 | 6.26 / 6.55 / 6.67 | 5.25 / 7.79 / 12.30 | ✅ |
| H.264, RealTime off, LL-RC off, window capture | motion | 0.73 / 1.32 / 2.04 | 6.12 / 6.46 / 6.73 | 6.89 / 7.65 / 8.30 | ✅ |
| **HEVC, RealTime off, LL-RC off** | motion | -0.49 / 7.67 / 9.69 | **4.47 / 4.80 / 4.99** | 4.00 / 12.33 / 14.36 | ✅ |
| H.264, RealTime off, LL-RC off, 1-frame VBV (1.0x) | motion (20 s) | – | 6.25 / 6.63 / 6.81 | 6.04 / 12.99 / 15.44 | ✅ |
| H.264, RealTime on, LL-RC on (the "low-latency" setup) | motion (20 s) | -1.07 / 1.41 / 2.84 | 14.09 / 14.90 / 15.45 | 12.72 / 15.81 / 17.22 | ❌ |
| H.264, RealTime on, LL-RC off | motion (12 s) | -0.89 / 1.44 / 3.48 | 12.40 / 12.94 / 13.13 | 10.84 / 14.21 / 15.35 | ❌ |
| H.264, RealTime off, LL-RC on | motion (12 s) | – | 11.84 / 12.25 / 12.51 | 9.62 / 12.36 / 12.50 | ❌ |
| H.264, RealTime on, LL-RC on, ExpectedFrameRate=240 | motion (12 s) | – | 7.63 / 9.96 / 10.52 | 6.30 / 9.42 / 11.40 | ❌ |
| HEVC, RealTime on, LL-RC off | motion (12 s) | -1.06 / 1.39 / 2.40 | 10.51 / 11.08 / 11.36 | 8.90 / 12.00 / 12.80 | ❌ |
| H.264, RealTime on, LL-RC on | idle desktop (12 s) | -1.42 / 1.24 / 1.90 | 13.76 / 14.90 / 15.17 | 11.50 / 15.69 / 16.82 | ❌ |


## Reproduce

```sh
zig build --release=fast
S7_REALTIME=0 ./zig-out/bin/s7probe --source display --no-lowlat --seconds 30 --csv out.csv
./zig-out/bin/s7probe --help   # env knobs: S7_REALTIME, S7_VBV, S7_EXPECTED_FPS, S7_BASELINE
```

Needs Screen Recording permission for the terminal running it.

## Recommendation for the macOS backend

- Regular hardware encoder (not the low-latency rate control path), `RealTime=false`.
- A per-frame size cap via `DataRateLimits` (one frame's budget), tuned so the average
  bitrate isn't undershot.
- HEVC where the client can decode it (about 1.3 ms faster than H.264 at p50).
- Investigate the SCK late-capture tail; it is now the largest contributor to p99.

**Conflict with S8, resolved in S7b:** S8 found long-term references (the design's loss
recovery) exist only on the low-latency encoder path, the slow path here. The follow-up
[`s7b-macos-ltr-encode`](../s7b-macos-ltr-encode/README.md) measured that path with LTR on:
`RealTime=false` does not help there, but `ExpectedFrameRate=1000` brings it to 8.6 ms p99
(HEVC), and it is now the macOS default, replacing the recommendation above.
