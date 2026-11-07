# Spike S7b: macOS encode latency with long-term references

**Question:** S7 got fast encodes only on the regular VideoToolbox encoder with
`RealTime=false`. S8 found long-term references (LTR, the design's loss recovery) only on the
low-latency encoder (`EnableLowLatencyRateControl`). Can the low-latency encoder, with LTR on
and real capture, encode 1080p60 under 8 ms p99, and does LTR recovery still work there?

**Answer: close, not quite.** The best low-latency + LTR setup is `RealTime=true` with
`ExpectedFrameRate=1000`: HEVC 8.0 ms p50 / 8.6 ms p99 (two 30 s runs, very stable), H.264
7.6 ms p50 / 8.1–10.9 ms p99 (varies run to run). That is about 2–4 ms slower than the regular
encoder without LTR in the same session (H.264 6.55 ms, HEVC 4.56 ms p99). LTR recovery
worked on every run: 101 of 101 simulated loss events (noise run aside, see findings) recovered bit-exact with a non-IDR
refresh frame. `RealTime=false` does **not** help on the low-latency encoder; it adds long
tails.

Machine: MacBook Pro M3 Max, macOS 15.8.1, AC power. Background load during runs included
Chrome and `mediaanalysisd` (~75% CPU), so tails are pessimistic.

## Method

The S7 probe (`src/`, Zig 0.16 driver + Objective-C core) with these additions:

- `S7_LTR=1`: `EnableLTR` on the session. A simulated client acks each frame's
  `RequireLTRAcknowledgementToken` 3 frames after submit (`S7_LTR_ACK`). Every 300 frames
  (`S7_LTR_EVERY`), 5 frames are lost (`S7_LTR_LEN`); the client acks nothing from the loss
  until the refresh. The host learns of the loss 3 frames after the last lost frame and
  encodes that frame with `ForceLTRRefresh`.
- After the run, the stream is decoded twice with `VTDecompressionSession`: in full, and as
  the client would see it (dropping everything from the first lost frame until the refresh,
  S8's rule for HEVC). A loss event passes when the refresh frame is not a sync frame and every
  frame from the refresh to the next loss decodes without error and with the same luma hash as
  the full decode. A control with `S7_LTR_NOREFRESH=1` fails as expected (mismatches from the
  loss onward).
- New knobs: `S7_MAXDELAY` (`MaxFrameDelayCount`), `S7_PTS_RATE` (timestamp rate),
  `S7_NODUR` (no frame duration). Existing: `S7_REALTIME`, `S7_EXPECTED_FPS`, `S7_VBV`.
- Real ScreenCaptureKit capture of the display at 1920x1080 NV12, 60 Hz, with the probe's
  animated window ("motion"). 20 Mbit/s, no reordering, no periodic keyframes. First second
  dropped. Encode = `EncodeFrame` call to output callback; pass = p99 < 8 ms.

## Results

Encode ms (p50 / p95 / p99). All low-latency rows have LTR on and the encoder ID
`h264.rtvc` / `hevc.rtvc`. "Recovered" counts loss events that recovered bit-exact.

| Config | Codec | Encode p50 / p95 / p99 | Recovered |
| --- | --- | --- | --- |
| Regular encoder, RealTime off, no LTR (same-session baseline) | H.264 | 5.91 / 6.35 / 6.55 | – |
| Regular encoder, RealTime off, no LTR (same-session baseline) | HEVC | 4.12 / 4.47 / 4.56 | – |
| LL + LTR, RealTime on | H.264 | 14.26 / 15.01 / 15.39 | 3/3 |
| LL + LTR, RealTime on | HEVC | 15.21 / 15.96 / 16.31 | 3/3 |
| LL + LTR, **RealTime off** | H.264 | 14.54 / 17.79 / 23.28 | 3/3 |
| LL + LTR, **RealTime off** | HEVC | 15.33 / 16.49 / 19.57 | 3/3 |
| LL + LTR, RealTime off, MaxFrameDelayCount 0 | H.264 | 14.39 / 16.52 / 21.12 | 3/3 |
| LL + LTR, RealTime off, no frame duration | H.264 | 14.13 / 15.75 / 19.88 | 2/2 |
| LL + LTR, RealTime off, ExpectedFrameRate 240 | H.264 | 10.61 / 15.11 / 17.58 | 3/3 |
| LL + LTR, RealTime off, ExpectedFrameRate 240 | HEVC | 10.92 / 16.21 / 20.92 | 3/3 |
| LL + LTR, RealTime off, ExpectedFrameRate 480 (12 s) | H.264 | 7.84 / 8.15 / 8.37 | 2/2 |
| LL + LTR, RealTime off, ExpectedFrameRate 480 (30 s, run a) | H.264 | 11.63 / 32.20 / 86.39 | 5/5 |
| LL + LTR, RealTime off, ExpectedFrameRate 480 (30 s, run b) | H.264 | 9.99 / 12.40 / 14.19 | 5/5 |
| LL + LTR, RealTime off, ExpectedFrameRate 480 (30 s) | HEVC | 11.13 / 18.97 / 32.37 | 5/5 |
| LL + LTR, RealTime off, ExpectedFrameRate 720 | H.264 | 10.10 / 15.30 / 52.51 | 3/3 |
| LL + LTR, RealTime off, ExpectedFrameRate 1000 (12 s) | H.264 | 7.86 / 8.64 / 10.44 | 2/2 |
| LL + LTR, RealTime on, ExpectedFrameRate 240 | H.264 | 10.21 / 14.76 / 15.11 | 3/3 |
| LL + LTR, RealTime on, ExpectedFrameRate 240 | HEVC | 10.77 / 15.45 / 15.90 | 3/3 |
| LL + LTR, RealTime on, ExpectedFrameRate 480 | H.264 | 9.76 / 10.44 / 10.79 | 3/3 |
| LL + LTR, RealTime on, ExpectedFrameRate 480 (30 s) | H.264 | 7.62 / 12.17 / 12.36 | 5/5 |
| LL + LTR, RealTime on, ExpectedFrameRate 480 | HEVC | 10.31 / 11.07 / 11.49 | 3/3 |
| **LL + LTR, RealTime on, ExpectedFrameRate 1000** | H.264 | 7.57 / 7.91 / 8.05 | 3/3 |
| **LL + LTR, RealTime on, ExpectedFrameRate 1000 (30 s)** | H.264 | 7.66 / 9.91 / 10.38 | 5/5 |
| **LL + LTR, RealTime on, ExpectedFrameRate 1000 (30 s, run a)** | HEVC | 8.03 / 8.47 / 8.64 | 5/5 |
| **LL + LTR, RealTime on, ExpectedFrameRate 1000 (30 s, run b)** | HEVC | 8.00 / 8.37 / 8.59 | 5/5 |
| LL + LTR, RealTime on, ExpectedFrameRate 1000, 1-frame cap | H.264 | 7.52 / 7.86 / 8.08 | 3/3 |
| LL + LTR, RealTime on, ExpectedFrameRate 1000, 1-frame cap (30 s) | H.264 | 8.04 / 10.47 / 10.88 | 5/5 |
| LL + LTR, RealTime on, ExpectedFrameRate 2000 | H.264 | 7.59 / 10.10 / 10.44 | 3/3 |
| LL + LTR, RealTime off, ExpectedFrameRate 240, timestamps at 240 Hz | H.264 | 8.38 / 10.14 / 14.41 | 2/2 |
| LL + LTR, RealTime off, ExpectedFrameRate 480, noise content | H.264 | 12.28 / 12.85 / 13.07 | 0/3 (see below) |

Runs are 20 s unless noted. Raw output (`*.txt`, including every refresh frame's size and
encode time) and per-frame CSVs (`*.csv`, with `ltr_token`, `refresh` and `lost` columns) are
in `results/`.

## Findings

1. **`RealTime=false` is not the fix on the low-latency encoder.** Unlike the regular
   encoder, the low-latency one is no faster with it off (14.5 ms p50) and grows long tails
   (p99 up to 86 ms with other knobs). Its p50 drop to ~7.8 ms at high `ExpectedFrameRate`
   comes with tails that vary wildly between runs.
2. **`ExpectedFrameRate` is the knob that matters.** The low-latency encoder seems to pace
   each frame to fit the expected frame interval. Telling it 1000 fps, with `RealTime=true`,
   brings encode to ~7.6 ms (H.264) / ~8.0 ms (HEVC) p50 with a tight distribution. 2000
   is no better. Setting faster timestamps instead (`S7_PTS_RATE`) changes the bitrate math
   (frames shrink to 10 KB) and is not a usable route.
3. **HEVC is steadier than H.264 here,** unlike on the regular encoder where it is also
   faster. HEVC at 1000 fps-expected held 8.6 ms p99 in both 30 s runs; H.264 alternates
   between ~8.1 ms and ~10.4 ms p99 runs (bimodal; not root-caused).
4. **LTR recovery works on every fast config.** 101 of 101 loss events across all runs except the noise run
   recovered bit-exact from the refresh frame, with no sync frames after frame 0. Refresh
   frames on the best configs are 63–81 KB against a 40 KB mean P frame (about 1.6–2x), and
   encode in 7.0–10.5 ms, the same as other frames.
5. **The one-frame size cap** (`DataRateLimits`) does not change latency on this path; the
   low-latency rate control already keeps frames tight (S7).
6. **The low-latency encoder drops frames on noise content.** With full-screen noise at
   20 Mbit/s it emitted only half the frames (543 of 1146 not encoded). The verifier counts
   missing frames as failures, hence 0/3. This is rate control dropping frames it can't fit,
   not an LTR failure, but a backend must handle frames that never come out.
7. The regular encoder rejects `EnableLTR` (-12900), confirming S8.
8. About 4 of 37 runs crashed during SCK startup or shutdown (`Trace/BPT trap`) with no
   output, as in S7. Those runs are not in `results/`.

## Recommendation

Take the low-latency encoder with LTR as the macOS default: `EnableLowLatencyRateControl`,
`EnableLTR`, `RealTime=true`, `ExpectedFrameRate=1000`, HEVC where the client can decode it.
It costs about 2–4 ms of encode versus the regular encoder and lands at ~8.6 ms p99 (HEVC),
just over the 8 ms bar, but recovery from loss is a ~1.8x P frame instead of an IDR at about
8x. The regular encoder (6.6 / 4.6 ms p99) with IDR-only recovery stays as an option for
links with near-zero loss. Whether that 0.6 ms miss on the S7 bar is acceptable is a design
call, not a measurement.

## Reproduce

```sh
zig build --release=fast
S7_LTR=1 S7_REALTIME=1 S7_EXPECTED_FPS=1000 ./run.sh hevc-best 30 --codec hevc
S7_LTR=1 S7_LTR_NOREFRESH=1 ./zig-out/bin/s7probe --source synthetic --seconds 6   # negative control
```

`run.sh NAME SECONDS [args]` captures the display, writes `results/NAME.{txt,csv}` and prints
the summary. Needs Screen Recording permission for the terminal running it.
