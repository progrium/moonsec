# Browser host (spike)

A browser tab as a moonsec host: an HTML5 canvas game streams its canvas and audio to
remote clients, and their keyboard, mouse and gamepad input comes back into the page. The
same core runs as on native hosts (`app/host_session.zig` and the Opus stage, in wasm). The
transport is iroh in the browser (shim-web, PR #33), and the client is the web client
(PRs #32 and #34) dialing over iroh.

Status: spike. It works end to end in headless Chromium through a local relay, including
the game's audio and gamepads. It has no admission or pairing yet, so anyone with the ticket
can connect. Only Chromium has been tried.

```
host tab                                                  client tab
┌──────────────────────────────────────────┐              ┌──────────────────────────┐
│ host-patch.js (first in <head>)           │              │ client.html (web client) │
│   AudioContext tap bus, virtual pads,     │              │ InputCapture -> worker   │
│   rAF hook (+ timer when rAF stops)       │              │ worker: core (client),   │
│ game (any canvas game, untouched)         │              │   WebCodecs decode,      │
│ host.js: VideoFrame(canvas) per game      │   iroh over  │   iroh (shim-web)        │
│   frame -> worker; actions -> DOM events  │◄── relay ───►│ AudioWorklet sink        │
│ host-worker.js: core (host session +      │              └──────────────────────────┘
│   Opus) in wasm, VideoEncoder,            │
│   AudioEncoder or libopus, iroh accept    │
│ host-tap.js (AudioWorklet): mix -> worker │
└──────────────────────────────────────────┘
```

| Path | What it is |
| --- | --- |
| [`app/web_host.zig`](../../app/web_host.zig) | The host session and the host Opus stage behind a C ABI (`mh_*`), `zig-out/web/moonsec-host.wasm` |
| [`app/web_pipe.zig`](../../app/web_pipe.zig) | The JS-backed `PacketPipe`, shared with the client's `app/web.zig` |
| [`src/host/patch.ts`](../src/host/patch.ts) | Page patches loaded before the game: AudioContext tap, `navigator.getGamepads`, rAF hook |
| [`src/host/host.ts`](../src/host/host.ts) | `BrowserHost.start({canvas, relayUrls})`: capture, worker, injection |
| [`src/host/worker.ts`](../src/host/worker.ts) | Core, iroh endpoint (accepts one client at a time), WebCodecs video and audio encode, LTR on reference buffers |
| [`src/host/inject.ts`](../src/host/inject.ts) | Actions to synthetic key, pointer, mouse and wheel events, and virtual gamepads |
| [`src/host/tap-worklet.ts`](../src/host/tap-worklet.ts) | AudioWorklet that copies the game's mix to the worker |
| [`host.html`](../host.html), [`demo/orb-drift.js`](../demo/orb-drift.js) | The demo: a small original canvas game with Web Audio, keys, mouse, wheel and gamepad |
| [`e2e/browser-host.mjs`](../e2e/browser-host.mjs) | End-to-end run: relay, host tab, client tab, checks and latency |
| [`e2e/webcodecs-caps.mjs`](../e2e/webcodecs-caps.mjs) | What this Chromium's WebCodecs can do (encoders, scalability, reference buffers) |
| [`results/`](results) | Raw JSON of the runs below |

## Run it

```sh
zig build web-wasm                    # zig-out/web/moonsec-host.wasm, moonsec-client.wasm
shim-web/build.sh                     # shim-web/pkg (iroh in the browser)
cd web && npm ci && npm run build && cd ..
node web/e2e/browser-host.mjs --variants default,webcodecs-audio,stream,av1,loss,loss-av1,loss-ltr-av1
xvfb-run -a node web/e2e/browser-host.mjs --variants background --headed
```

`browser-host.mjs` starts `iroh-relay` with `relay/lab.toml`, serves `web/` (plus the wasm and
`shim-web/pkg`), and opens the host and the client in separate browser contexts.

By hand, with a relay the browsers trust, serve `web/` the same way and open
`host.html?relay=https://your-relay`, then click **Start hosting**. The panel prints a
`client.html?ticket=…` link to open anywhere. Host query options are `audioenc=wasm|webcodecs`,
`capture=raf|stream`, `codec=h264,av1`, `bitrate`, `fps` and `ltr=0`, plus the test-only
`loss` and `outage`. On the client, `mouse=absolute` and `probe` are useful.

To host another game, put `<script src="dist/host-patch.js"></script>` first in its
`<head>`, then call `BrowserHost.start({ canvas, relayUrls })` from a click. The game itself
needs no changes.

## Results

Chromium 153 (Playwright 1.63), headless, on one 4-core container. Both tabs connect through a
local `iroh-relay` on loopback, so the network is about 1–2 ms RTT through the relay. The demo
game runs at 960×540, 60 fps, 6 Mbit/s, with software encode and decode (the container has no
GPU). 30 presses per input kind per variant ([results/headless.json](results/headless.json)).

**Input to photon** runs from the client page's DOM event (`keydown`, `mousedown`, or the
moment the scripted pad's button changes) until the client draws the first frame where the
game's probe square has changed. That covers the client capture, network, injection into
the host page, the wait for the game's next frame, capture, encode, network, decode and
draw. Compositor time comes on top of that, usually one to two frames.

| variant | codec | key p50 / p90 | mouse p50 / p90 | pad p50 / p90 |
| --- | --- | --- | --- | --- |
| default (rAF capture, libopus) | H.264 | 18.1 / 21.1 ms | 15.8 / 22.7 ms | 15.8 / 26.1 ms |
| WebCodecs Opus | H.264 | 18.7 / 23.7 ms | 18.8 / 26.0 ms | 19.1 / 23.9 ms |
| `captureStream` capture | H.264 | 20.0 / 24.8 ms | 18.7 / 24.3 ms | 19.0 / 23.7 ms |
| AV1 | AV1 | 19.7 / 23.6 ms | 18.6 / 27.2 ms | 20.2 / 26.8 ms |

About 8 ms of each figure is the game itself: on average, input lands halfway through a
16.7 ms frame. The core's own stage times (p50 / p99) for the default variant:

| stage | p50 | p99 |
| --- | --- | --- |
| capture (`new VideoFrame(canvas)` after the game's frame) | 0.6 ms | 1.7 ms |
| encode (WebCodecs H.264, OpenH264 software, 960×540) | 2.6 ms | 4.4 ms |
| network (encoded to received, through the relay) | 1.4 ms | 2.7 ms |
| decode (client, software) | 0.6 ms | 2.3 ms |
| present (decoded to drawn) | 2.1 ms | 3.9 ms |
| total (capture to drawn) | 6.8 ms | 10.1 ms |
| input (client capture to injected into the host page) | 2.0 ms | 8.4 ms |

The host is ready with a ticket about 0.4 s after the page loads. The client goes from page
load to its first frame in about 0.65 s. With AV1 the stream is half the bytes of H.264
(3.1 MB vs 6.6 MB per run) at about 1 ms more encode time.

All seven variants pass every check. The client draws about 60 fps with no decode errors and
non-blank frames. The game's audio is heard on the client (the 440 Hz drone, and 0 to 3
concealed frames per clean run). Keys move the player, the left stick moves it too, the mouse
lands within 8 px of the expected spot in absolute mode, the wheel changes the player's size,
and the game sees a remote pad in `getGamepads()`. When the client leaves, the host goes back
to waiting.

## Findings and limits

**Transport.** Browser to browser over iroh works as is: both sides are browser endpoints on
the same relay, and the host binds with the `moonsec/0` ALPN and accepts. One gotcha cost
time. If the JS `Endpoint` wrapper is garbage collected, wasm-bindgen's finalizer drops the
Rust endpoint and the connection closes under the session. The symptom was "14 frames, then
nothing": the host's datagrams piled up unsent with no error. The client worker now keeps a
reference. shim-web's own tests keep the endpoint in scope, so they never hit this. It could
be guarded in shim-web itself, by having a `Connection` hold its endpoint.

**Capture.** Wrapping `requestAnimationFrame` and grabbing `new VideoFrame(canvas)` in a
microtask after the game's callback gives a frame right after the game draws, with a
measured capture time. `canvas.captureStream()` with `MediaStreamTrackProcessor` gives the
same latency here, but no capture timestamps, and frame timing is up to the browser. WebGL
canvases should work with either (the drawing buffer is read in the same task); only the 2D
demo was tried. A canvas resize mid-stream is scaled by the encoder, not renegotiated.

**Encode.** WebCodecs H.264 here is OpenH264 in software, about 2.5 ms at 960×540; this
container has no hardware encoder to compare. The core's encode stage pairs every
`encodeParams` with one `onEncoded`, so one frame at a time is inside the encoder. A frame
that arrives while the encoder is busy is dropped (2 or 3 per run). An encoder that never
outputs a frame times out after 250 ms and forces a keyframe. Rate control is off: changing
the bitrate means `configure()` again, which is wired up but untested. HEVC encode is not
offered by this Chromium.

**Long-term references (LTR).** Plain WebCodecs has no reference control. Chromium has
manual reference buffers (`scalabilityMode: "manual"`, `VideoEncoder.getAllFrameBuffers()`,
`referenceBuffers`/`updateBuffer` per encode) behind
`--enable-blink-features=WebCodecsVideoEncoderBuffers`. With the flag on, AV1 and H.264 get 3
buffers each, and VP8 and VP9 get none ([results/webcodecs-caps-buffers.json](results/webcodecs-caps-buffers.json)).
The host maps the core's LTR protocol onto them: two long-term slots that alternate (the
newest acked one is never overwritten), one short-term buffer, a mark every 30 frames, and a
refresh that references only the newest acked slot.
- **AV1: works.** With 2% loss plus a 400 ms outage every 3 s, all 21 recoveries were LTR
  refreshes, with 1 keyframe in the whole run. With LTR off, the same run needed 21 keyframes.
  Both recovered on time, but refreshes cost about 10% fewer bytes (3.13 vs 3.47 MB per run).
- **H.264: broken.** OpenH264 accepts the options, but its refresh frames don't decode
  right on the client. The probe square stopped updating, and the client kept asking for
  recovery: 75 requests and 59 freezes for 61 refreshes
  ([results/h264-ltr-refreshes-broken.json](results/h264-ltr-refreshes-broken.json)). The
  host now uses LTR only for AV1.
- The flag is the catch: a normal Chrome profile doesn't have it, so in practice a browser
  host recovers with keyframes. The H.264 failure is probably the encoder's reference
  signalling, not the protocol: AV1 on the same code path works.

**Audio.** The patch routes everything a realtime `AudioContext` connects to its
`destination` through a bus, so the game still plays locally. Once hosting starts, an
AudioWorklet tap on the bus copies the mix to the worker in 128-frame quanta. The worker
cuts 10 ms frames and encodes them either with the core's libopus in wasm (default) or with
WebCodecs `AudioEncoder` (Opus, 10 ms frames, in-band FEC). Either way, the frames go out
on the audio stream through the core's sender with Reed-Solomon parity, the same wire format
as native hosts. Both encoders work, with 0 to 3 concealed frames per clean run. The
client's audio delay was 40–60 ms. That number is the client jitter buffer plus the
worklet hops. Its 20 ms target is the client's setting, not something the host controls.
Limits:
- Only the first AudioContext is tapped.
- `<audio>`/`<video>` elements are not captured. Routing them through
  `createMediaElementSource` would work for same-origin media.
- Contexts are created at 48 kHz unless the game asks for another rate. If it does, the
  host drops that audio.
- Remote clicks are synthetic, so they can't unlock audio. The host user's own
  **Start hosting** click resumes every context that exists then. A context the game
  creates later needs a real click on the host tab.

**Input.** Actions from the core's input receiver become DOM events on the host page:
`keydown`/`keyup`/`keypress` with `code`, `key`, modifiers and legacy `keyCode`/`which`
(GameMaker's HTML5 runner and older games read those), pointer and mouse
events with `buttons`, `movementX/Y` in relative mode and absolute positions mapped onto the
canvas, `click` and `contextmenu`, wheel events, and virtual standard-mapping gamepads in
`navigator.getGamepads()` with `gamepadconnected`/`disconnected`. Synthetic events have
`isTrusted: false`. Games rarely check it, but it means a remote client cannot start Pointer
Lock, fullscreen or audio on the host. Keys reach whatever has focus on the host page,
falling back to `document.body`. When the client leaves, everything it held is released.

**Tab throttling.** In a background tab Chromium stops `requestAnimationFrame`, so the game
froze: 1 fps while another tab was in front, even though our capture timer kept streaming.
To fix it, the rAF patch runs the game's queued callbacks from a 60 Hz timer whenever the
native rAF hasn't fired for 100 ms. With that, the game ran at 58 fps behind another tab,
and the client got 56 fps and full audio ([results/background-headed.json](results/background-headed.json),
headed Chromium under Xvfb). This depends on the tab playing audio: audible tabs are exempt
from timer throttling. A silent game in a hidden tab would get 1 Hz timers, and after 5
minutes intensive throttling. That comes from Chromium's documented policy; it wasn't
measured here. Hosting from a visible window, or a Document Picture-in-Picture window, avoids
the problem. Workers are not throttled in either case.

**Not done.** Admission and pairing (the host side of `core/pair` isn't in the browser
module; for now the ticket is the access), more than one client (multi-user sessions are
PR #38), Firefox and Safari, hardware encode, CPU cost, a real network and a public relay,
cursor shape, clipboard, HiDPI canvases, and resizes.
