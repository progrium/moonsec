# web: browser client

TypeScript glue around the Zig core compiled to wasm32 (docs/design.md, "Web client").
This directory holds the input path and the browser test harness so far; the media
pipeline (WebCodecs, AudioWorklet playback) and the iroh transport (`shim-web/`) land
next to it.

```
src/transport.ts        Transport interface (datagrams), WebSocket test transport
src/core.ts             the client session in wasm (app/web.zig, moonsec-client.wasm)
src/media/              media pipeline: worker (core, transport, WebCodecs, OffscreenCanvas),
                        AudioWorklet sink, codec strings, overlay, client.html's page
src/input/core.ts       the core's input sender (core/input/wasm.zig) from JS
src/input/capture.ts    DOM, Pointer Lock, Keyboard Lock, Gamepad API -> core input calls
src/input/hid.ts        KeyboardEvent.code -> USB HID usage
src/input/gamepad.ts    Gamepad API -> core.input.Gamepad (XInput button order)
e2e/                    Playwright harness, stub host, Safari (safaridriver) runner,
                        media-host.mjs (a real host behind a WebSocket bridge), media.spec.ts
testdata/               the H.264 fixture the media host replays (gen.sh)
```

## Build and test

```sh
zig build web-wasm          # zig-out/web: moonsec-core.wasm, moonsec-client.wasm, the stub host's wasm
zig build web-host          # zig-out/bin/moonsec-sim, the host media.spec.ts streams from
cd web && npm ci
npx tsc --noEmit
npx playwright install chromium firefox webkit
npm run e2e                 # all three; add -- --project=firefox for one
npm run safari              # macOS: real Safari via safaridriver (sudo safaridriver --enable once)
```

Results, including per-browser decode and draw timings, go to `test-results/web/<browser>.json`.
CI (`.github/workflows/web.yml`) runs Chromium, Firefox and WebKit on Linux and real Safari on
macos-15, and uploads those files.

## Input

Input goes through the same `core.input.Sender` the native clients use (sequenced keys and
buttons repeated until acked, motion as running totals, full gamepad snapshots), built for
wasm32 and called from `src/input/core.ts`. The browser side only maps events:

| Feature | Chromium | Firefox | Safari | Fallback |
| --- | --- | --- | --- | --- |
| Pointer Lock | yes | yes | yes | absolute positions on the video (0..65535) |
| `unadjustedMovement` (raw deltas) | Windows, macOS, ChromeOS | no | no | plain lock: deltas carry OS acceleration |
| Keyboard Lock (in fullscreen) | yes | no | no | the browser keeps Esc, Alt+Tab, Cmd/Win and its shortcuts |
| Gamepad API | yes | after a button press | after a button press | polled every 250 ms for discovery, 4 ms while a pad is connected |

Keys use `KeyboardEvent.code` (the physical key, so the host's layout applies). Mouse modes:
`auto` (absolute until a click locks the pointer, and that click lands), `relative` (a click
only locks), `absolute` (never locks; desktop use). Focus loss or unlock releases every held
key and button. Gamepads map the W3C standard layout to XInput's button bits with Y axes
flipped to up-positive, the layout every native client and host uses.

## Harness

`e2e/stub-host.mjs` stands in for a host behind a relay until shim-web and the media
pipeline land. Input datagrams are decoded by the core's own `input.Receiver`
(`e2e/host_stub.zig`, built to wasm) and acked, with optional seeded loss (`?loss=0.3`).
Video is a replay of the fixtures in `e2e/testdata` (H.264, VP8 fallback) over a test
framing, decoded in a Worker with OffscreenCanvas; audio is a 440 Hz tone through an
AudioWorklet with a 20 ms jitter buffer.

Checks per browser: keyboard, mouse buttons, wheel and motion arrive in order with nothing
held at the end; 30% input loss loses no key presses; gamepad snapshots (a scripted pad)
arrive; 60 frames decode and draw with non-black pixels; the tone plays at the right level
and pitch. Headless browsers emulate Pointer Lock, so locked motion is fed as DOM events
with `movementX/Y` on top of the driven mouse.

When shim-web and the media pipeline land, the stub swaps for a real host through a local
`iroh-relay`: `Transport` gets an iroh implementation, and the video and audio probes are
replaced by the client's own pipeline with the same checks.

## Media pipeline

The client session the native clients run (`app/client_session.zig`: reassembly, NACKs,
transport feedback, frame acks and recovery, clock sync, input) and the Opus audio stage
(`codec/opus/stage.zig`, with the 20 ms jitter buffer of spec/audio-v0.md) are compiled to
wasm32-wasi as `moonsec-client.wasm` (`app/web.zig`, ~540 KB, ReleaseSafe). Its ABI keeps
buffers on the Zig side: arriving datagrams are written straight into the session's receive
ring, frames and PCM are read in place, outgoing datagrams come out through one imported
`ms_send`. Times are `performance.now()` microseconds as f64. `src/core.ts` wraps it.

Everything runs in one Worker (`src/media/worker.ts`) except audio output:

- **Video:** WebCodecs `VideoDecoder` with `optimizeForLatency` and `prefer-hardware` when
  `isConfigSupported()` allows it. The hello offers H.264, plus HEVC and AV1 when the
  browser supports them; the exact codec string comes from the first keyframe's SPS (H.264
  and HEVC) or sequence header (AV1). Chunks are Annex B (no `description`). Each frame is
  decoded as soon as the core hands it out, drawn onto the OffscreenCanvas in the output
  callback and closed; at most two frames are inside the decoder. The core holds frames back
  after a gap until the recovery frame, as on native clients, so the decoder never sees an
  undecodable frame. A decoder error fails the frames in flight to the core (which asks for
  recovery), rebuilds the decoder and waits for a keyframe.
- **Audio:** the AudioWorklet (`src/media/audio-worklet.ts`) keeps about 18 ms of PCM and
  asks the worker for a frame whenever it runs low; the worker renders one from the core's
  jitter buffer. The context runs at 48 kHz (resampled linearly if the browser refuses).
- **Overlay:** stream, RTT, loss, freezes, the relay badge, and last/p50/p99 per stage
  (encode, network, decode, present, total), the same numbers the native overlay draws.

`client.html` runs it against `e2e/media-host.mjs`, which bridges a WebSocket to a real
moonsec host process (`moonsec-sim peer sim host --fixture web/testdata/...`): the full
host session (packetizer, NACK retransmits, recovery, rate controller, Opus) with an encoder
that replays the committed H.264 fixture and answers recovery requests with its next IDR
(`platform/synthetic/fixture.zig`). `/ws?loss=0.03&outage=2500:400` drops host datagrams in
the bridge. The WebSocket transport reports the path as relayed, as iroh in a browser always
is. It is the test transport until shim-web's iroh transport (6A) replaces it; the worker
only needs `Transport` from `src/transport.ts`.

`e2e/media.spec.ts` checks, per browser: a clean 5 s session presents over 80% of frames
with no decode errors, non-black pixels, clock sync, the relay badge, and the 440 Hz tone
played; with 3% loss and a 400 ms outage, NACKs and a recovery happen, the picture comes
back, and the decoder still sees no error. It skips browsers whose WebCodecs has no H.264
(Playwright's Chromium decodes it in software). Timings go to
`test-results/web/media-<browser>-{clean,lossy}.json`.

Headless Chromium on the Linux container (software decode, loopback, 640x360 fixture):

| stage | p50 | p99 |
| --- | --- | --- |
| network (encoded to received) | 0.8 ms | 20 ms |
| decode (received to output) | 0.7 ms | 3.8 ms |
| present (output to drawn) | 1.2 ms | 3.2 ms |
| total (capture to drawn) | 2.7 ms | 22.6 ms |

Not done here: input from `src/input` still goes through 6C's separate input sender in
`moonsec-core.wasm`; the session in `moonsec-client.wasm` has its own (`ms_input_*` in
`src/core.ts`), and capture should switch to it so input shares the session's envelope
sequence and acks. HEVC and AV1 codec strings are parsed but untested (no browser here
decodes HEVC; AV1 has no fixture). Draw time is when `drawImage` returns, not when the
compositor shows the frame (about one to two frames more, per the design).

## Hardware checks for Jeff

On a real machine with a mouse, keyboard and controller, against the harness:

```sh
zig build web-wasm && cd web && npm ci && npm run stub
# open http://127.0.0.1:8787/harness.html in Chrome, Firefox and Safari
```

Click the black box (the pointer should lock; Chrome on macOS or Windows should report
`unadjustedMovement: true` in the log), move the mouse, type, scroll, and press buttons on a
controller, then compare `curl -s 127.0.0.1:8787/state` with what you did. Double-click
for fullscreen: in Chrome, Keyboard Lock should then pass Esc (held: exits), Alt+Tab and the
Windows/Cmd key through to the host instead of the browser.

Media pipeline, on each browser (hardware decode and real audio output, which CI can't show):

```sh
zig build web-wasm web-host && cd web && npm ci && npm run media
# open http://127.0.0.1:8788/client.html, click Connect; add ?loss=0.03&outage=2500:400 for recovery
```

The overlay should show the decoder with `prefer-hardware`, a moving test pattern and a
steady tone; Safari needs 16.4 or later (WebCodecs video, OffscreenCanvas 2D).
