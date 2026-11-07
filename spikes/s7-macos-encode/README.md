# Spike S7: macOS host encode baseline

**Question (design doc, S7):** what is the capture-to-encode baseline on a macOS host?
**Pass:** encode under 8 ms at 1080p60.

**Status: pass, with non-obvious encoder settings.**

> The probe (Zig driver plus an Objective-C ScreenCaptureKit → VideoToolbox core), its
> full results table and the raw CSVs live only on Jeff's MacBook, in
> `/tmp/moonsec-spikes/s7` and `/tmp/moonsec-spikes/s7-screencapture-encode.tar.gz`.
> The upload to the project was blocked, so they are not in this repo yet. This README
> records the reported results. Copy the tarball here before `/tmp` is cleared.

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

## Recommendation for the macOS backend

- Regular hardware encoder (not the low-latency rate control path), `RealTime=false`.
- A per-frame size cap via `DataRateLimits` (one frame's budget), tuned so the average
  bitrate isn't undershot.
- HEVC where the client can decode it (about 1.3 ms faster than H.264 at p50).
- Investigate the SCK late-capture tail; it is now the largest contributor to p99.

**Conflict with S8:** S8 found long-term references (the design's loss recovery) exist only
on the low-latency encoder path, which is the slow path here. See `docs/design.md` for how
the two results are reconciled.
