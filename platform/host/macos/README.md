# platform/host/macos

The macOS host backend (design doc, Phase 4): `openHost` in [host.zig](host.zig) returns a
`platform.HostBackend`.

| Object | macOS API | Notes |
| --- | --- | --- |
| `Capture` | ScreenCaptureKit (`SCStream` on a display) | NV12 by default; `Image.gpu` is a `CVPixelBufferRef` |
| `Encoder` | VideoToolbox | low-latency encoder with LTR by default (S7b, S8) |
| `AudioSource` | ScreenCaptureKit system audio | 48 kHz f32, this process excluded |
| `InputInjector` | CGEvent | HID usages to virtual key codes in [keymap.zig](keymap.zig) |
| `Clock` | `mach_absolute_time` | microseconds |

## Binding approach

The framework code is Objective-C (ARC) in small `.m` files compiled by `zig build`.
Zig sees only [mh.h](mh.h), a plain C ABI with no framework headers, translated with
`addTranslateC`. Core Foundation objects cross as `void *`. This mirrors the Windows
backends (C files behind `msw.h`).

- `common.m`: clock, per-thread error messages, TCC checks, displays, pixel buffers.
- `capture.m`: ScreenCaptureKit video.
- `audio.m`: ScreenCaptureKit audio.
- `encode.m`: VideoToolbox encoder, plus a small decoder the tests use to check output.
- `input.m`: CGEvent injection.

## Capture

`SCStream` hands frames to a serial queue; the handler keeps only the newest complete
frame in a one-slot mailbox, and `acquire` takes it, waiting up to the caller's timeout.
A consumer that falls behind never sees a backlog: the older frame is released at once
(counted as `replaced`), so SCK's surface pool never runs dry.

Timestamps: `captured_us` is `SCStreamFrameInfoDisplayTime` (the vsync the frame belongs
to), on the bundle clock, but never later than when the frame arrived. S7 saw display
times a few ms *after* delivery; clamping keeps capture-to-encode latency non-negative.
Late frames are tolerated: a frame that arrives more than two frame intervals after its
display time is still delivered (it is the newest picture) and counted as `late`; a frame
whose display time is not after the previous one's is dropped as `stale`. Idle frames (no
change on screen) are not delivered, so `acquire` returns null and the app repeats with
`repeatLast`. If the stream stops (display reconfigured, sleep), `acquire` restarts it once
and returns null. `Capture.stats()` has the counters.

## Encoder

Created by probing VideoToolbox in this order, taking the first that works:

1. Low-latency (`EnableLowLatencyRateControl`) on hardware, with `EnableLTR`,
   `RealTime=true` and `ExpectedFrameRate=1000`. This is the S7b default: ~8.6 ms p99 HEVC
   at 1080p60 on an M3 Max, with LTR refresh recovering every loss without an IDR.
2. Low-latency, any encoder (software allowed).
3. The regular encoder, `RealTime=false` (S7: faster, but no LTR, so recovery is IDR).
4. The regular encoder in software.

`EncoderOptions.mode` pins one path and `require_hardware` refuses software. All paths
use no frame reordering, no periodic keyframes, and `PrioritizeEncodingSpeedOverQuality`.
VideoToolbox emits length-prefixed NAL units; the backend converts to Annex B and puts the
parameter sets in front of every keyframe. One slice per frame (VideoToolbox has no slice
count). A frame the low-latency rate control drops (S7b finding 6) comes back as null.

LTR: each output frame's `RequireLTRAcknowledgementToken` is `EncodedFrame.ltr_token`;
`EncodeParams.acked_ltr_tokens` go in as `AcknowledgedLTRTokens`; `Force.ltr_refresh` is
`ForceLTRRefresh` (an IDR when LTR is off).

### Rate ladder hooks

`EncodeParams.bitrate_bps` sets `AverageBitRate` before the frame: no keyframe (S8).
`Encoder.configure` keeps the session when only bitrate or frame rate change and makes a
new one for a new codec, size or LTR setting (the next frame is a keyframe). Frames of
another size than configured are scaled to it with a `VTPixelTransferSession`, so a ladder
step needs nothing but `configure`. `Host.applyRung(rung)` (from
`HostSession.takeReconfigure`) also resizes the capture stream so SCK does the scaling.

## Input

Keys are posted by virtual key code (layout-independent, like HID usages); modifier keys
go out as `kCGEventFlagsChanged` and every event carries the held modifiers. Held buttons
turn motion into drags; repeated clicks in place within the double-click interval count up.
Relative motion sets the delta fields games read and moves the cursor, clamped to the
displays. Absolute positions map 0..65535 onto the display given in `Options.display`.
Gamepads are dropped for now.

## Virtual display (headless host)

[vdisplay.m](vdisplay.m) wraps CGVirtualDisplay, private CoreGraphics API (macOS 11+), so
a Mac with no display attached (or a closed lid) still has one to stream. `Capture.start`
creates it when `CaptureConfig.virtual_display` asks (`.when_headless`: only with no active
display; `.always`: every time), at the client's size in pixels (no HiDPI) and the
requested rate, then captures it with ScreenCaptureKit like any display. Absolute pointer
moves follow it.

- **Feature flag.** The classes are looked up at run time (`NSClassFromString`), never
  linked, so a macOS without them makes `mh_vdisplay_available()` 0 and capture falls back
  to the physical display. `-Dmac-virtual-display=false` builds without it.
- **Lifecycle.** `Capture.stop` releases it and the window server removes it; it is also
  removed when the host process exits, crash included.
- **Mode changes.** A smaller mode is applied in place (`applySettings`); a larger one
  than the display was made for makes a new display.
- **Fallback.** Creation or capture failing falls back to `CaptureConfig.display`; with
  no physical display either, `start` fails.
- **Permissions.** Creating needs none; capturing needs Screen Recording.

Tested on:

| macOS | Where | Create / re-mode / remove | Capture |
| --- | --- | --- | --- |
| 15 (macos-15 runner) | CI | see the `macos` workflow summary | no TCC grant on the runner |

The design calls for re-running `zig build test-mac` on every macOS beta; add a row here
each time.

Hardware check (Jeff's MacBook): grant Screen Recording to the terminal, then
`MOONSEC_REQUIRE=vdisplay,capture zig build test-mac`. Then close the lid with no external
display (on power, with "prevent automatic sleeping" on), stream with
`virtual_display = .when_headless`, and check the client sees a desktop; kill the host and
check the display is gone (`system_profiler SPDisplaysDataType`).

## Permissions

Capture and audio need Screen Recording; injection needs Accessibility. `openHost` does
not prompt. `screenCaptureAllowed()` and `postEventAllowed()` check without prompting;
without the permission capture fails to start (logged with what to grant) and the system
drops injected events.

## Build steps

- `zig build test-mac` (macOS): compiles the `.m` files and runs [test.zig](test.zig).
  The VideoToolbox tests run anywhere; capture, audio and input skip without permission.
  `MOONSEC_REQUIRE=capture,audio,input,hardware,ltr` turns those skips into failures.
- `zig build check-mac` (any host): type-checks the Zig side for aarch64 and x86_64 macOS.
- `zig build build-test-mac`: installs the test binary to `zig-out/mac-test/` (CI runs it
  directly to keep every test's report in the log).

CI (`.github/workflows/macos.yml`) runs the tests on macos-15 and writes which
VideoToolbox encoders the runner has to the job summary.
