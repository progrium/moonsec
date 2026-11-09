# Browser host

A browser tab as a moonsec host: an HTML5 canvas game (or a video) streams its picture and
sound to remote clients, and their keyboard, mouse and gamepad input comes back into the
page. The same core runs as on native hosts: the multi-user host (`app/multi_host.zig`, one
encode fanned out to every member), the Opus stage and the pairing exchange (`core/pair`),
all in wasm. The transport is iroh in the browser (shim-web), and the clients are web
clients (or any moonsec client) dialing over iroh.

Status: works end to end through a local relay with Chromium, Firefox and WebKit as host
and as clients (Playwright builds on Linux; real Safari not tried). Only paired devices get
a session, several can watch and play at once, and `<audio>`/`<video>` sound streams along
with the game's Web Audio.

```
host tab                                                  client tabs
┌──────────────────────────────────────────┐              ┌──────────────────────────┐
│ host-patch.js (first in <head>)           │              │ client.html (web client) │
│   AudioContext tap bus, media elements,   │              │ pairing (pair.js + core/ │
│   virtual pads, rAF hook (+ timer)        │              │   pair in wasm), then    │
│ game (any canvas game, untouched)         │              │   admission              │
│ host.js: VideoFrame(canvas) per game      │   iroh over  │ InputCapture -> worker   │
│   frame -> worker; actions -> DOM events  │◄── relay ───►│ worker: core (client),   │
│   per member; identity + allowlist        │              │   WebCodecs decode, iroh │
│ host-worker.js: core in wasm (multi host  │              │ AudioWorklet sink        │
│   + Opus + pairing), VideoEncoder,        │              └──────────────────────────┘
│   AudioEncoder or libopus, iroh accept    │
│ host-tap.js (AudioWorklet): mix -> worker │
└──────────────────────────────────────────┘
```

| Path | What it is |
| --- | --- |
| [`app/web_host.zig`](../../app/web_host.zig) | The multi-user host, the host Opus stage and the host side of pairing and admission behind a C ABI (`mh_*`), `zig-out/web/moonsec-host.wasm` |
| [`app/web_pipe.zig`](../../app/web_pipe.zig) | The JS-backed `PacketPipe`, shared with the client's `app/web.zig` (one per member on the host) |
| [`src/host/patch.ts`](../src/host/patch.ts) | Page patches loaded before the game: AudioContext tap, media element hook, `navigator.getGamepads`, rAF hook |
| [`src/host/host.ts`](../src/host/host.ts) | `BrowserHost.start({canvas, relayUrls})`: capture, identity and allowlist, invites, media elements, injection |
| [`src/host/worker.ts`](../src/host/worker.ts) | Core, iroh endpoint (pairing and admission on each connection, members), WebCodecs video and audio encode, LTR on reference buffers |
| [`src/host/inject.ts`](../src/host/inject.ts) | Actions to synthetic key, pointer, mouse and wheel events, and virtual gamepads, per member |
| [`src/host/tap-worklet.ts`](../src/host/tap-worklet.ts) | AudioWorklet that copies the page's mix to the worker |
| [`host.html`](../host.html), [`demo/orb-drift.js`](../demo/orb-drift.js) | The demo: a small original canvas game with Web Audio, keys, mouse, wheel and gamepad; the invite (link, QR code, PIN) and paired devices |
| [`src/media/worker.ts`](../src/media/worker.ts) (`dialIroh`) | The web client's side: pair with a `MOONSEC1:` ticket if needed, then ask for a session |
| [`e2e/browser-host.mjs`](../e2e/browser-host.mjs) | End-to-end run per browser: relay, host tab, client tab, checks and latency |
| [`e2e/browser-host-multi.mjs`](../e2e/browser-host-multi.mjs) | Pairing and several viewers: invite link, two players at once, leave and rejoin, a stranger refused, PIN pairing, forgetting a device |
| [`e2e/host-lab.mjs`](../e2e/host-lab.mjs) | What both share: the relay, the static server, browser launch options |
| [`e2e/webcodecs-caps.mjs`](../e2e/webcodecs-caps.mjs) | What this Chromium's WebCodecs can do (encoders, scalability, reference buffers) |
| [`results/`](results) | Raw JSON of the runs below |

## Run it

```sh
zig build web-wasm                    # zig-out/web/moonsec-host.wasm, moonsec-client.wasm
shim-web/build.sh                     # shim-web/pkg (iroh in the browser, moonsec-pair.wasm)
cd web && npm ci && npm run build && npx playwright install chromium firefox webkit && cd ..
node web/e2e/browser-host.mjs --variants default,webcodecs-audio,stream,av1,loss,loss-av1,loss-ltr-av1,media
node web/e2e/browser-host.mjs --browser firefox --variants default,media     # or webkit
node web/e2e/browser-host-multi.mjs --host chromium --client firefox          # any pair
xvfb-run -a node web/e2e/browser-host.mjs --variants background --headed
```

Firefox plays audio only through PulseAudio; on a machine without a sound server, start one
with a null sink first (`pulseaudio --start; pactl load-module module-null-sink
sink_name=harness; pactl set-default-sink harness`), as `.github/workflows/web.yml` does.

The scripts start `iroh-relay` with `relay/lab.toml`, serve `web/` (plus the wasm and
`shim-web/pkg`), and open the host and each client in its own browser context.

By hand, with a relay the browsers trust, serve `web/` the same way and open
`host.html?relay=https://your-relay`, then click **Start hosting**. The panel shows an
invite: a `client.html?ticket=MOONSEC1:…` link and its QR code (open it on the device to
pair), and a PIN for the address link. **Invite a device** opens another window. Host query
options are `invite=N` (devices the first window pairs, 0 for none), `input=everyone|owner|view`,
`max`, `media=1` (also play a looping tone in an `<audio>` element), `audioenc=wasm|webcodecs`,
`capture=raf|stream`, `codec=h264,av1`, `bitrate`, `fps` and `ltr=0`, plus the test-only
`loss` and `outage`. On the client, `pin`, `name`, `mouse=absolute` and `probe` are useful.

To host another game, put `<script src="dist/host-patch.js"></script>` first in its
`<head>`, then call `BrowserHost.start({ canvas, relayUrls })` from a click, and
`host.invite()` to let a device pair. The game itself needs no changes.

## Pairing and admission

The browser host follows spec/pairing-v0.md like a native host, with the same code: the
exchange, tickets, PINs (CPace) and admission run in `core/pair` inside moonsec-host.wasm,
and the web client runs the client side in moonsec-pair.wasm (shim-web/js/pair.js).

- **Identity.** The host's endpoint key is its identity. `BrowserHost` keeps it in
  `localStorage` (`moonsec.host.key`), so the host's ID, and with it every pairing,
  survives reloads. `secretKey` and `storage` override that.
- **Invites.** `host.invite({ seconds, pairings, attempts, secret, pin })` opens a pairing
  window (120 s, 1 device, 5 wrong guesses by default). The report's `invite` has a QR
  ticket with the window's one-time secret (shown as a link and a QR code, made by
  `core/pair/qr.zig`) and a six-digit PIN for the address ticket. Every connection's first
  stream is either a pairing exchange or `admit`; outside a window, a pairing attempt hears
  "not pairing right now".
- **Allowlist.** Paired devices go to `localStorage` (`moonsec.host.clients`), with a name
  and whether their input applies. Each `admit` checks it. `host.forget(id)` removes a device
  and ends its session at once; `host.setInput(id, false)` makes it view only from its next
  session; `host.kick(id)` ends a session but leaves the device paired.
- **Client.** `client.html?ticket=MOONSEC1:…` pairs with the ticket's secret (or asks for the
  PIN, or takes `?pin=`) unless this browser already paired with that host, then connects,
  checks the host's ID against the ticket and asks for a session. Its key and paired hosts
  are in `localStorage` (`moonsec.client.key`, `moonsec.client.hosts`). Two tabs of one
  browser profile share that key, so the host sees them as one device.
- The host's storage is the hosted page's storage: the game can read the host's key and
  allowlist. Host only games you trust with that.

## Several viewers

Admitted clients are members of one multi-user session (spec/multi-user-v0.md), the same
`MultiHost` the C ABI uses for `max_clients > 1`: one capture and one encode; each member
has its own pipe, pacing, NACK retransmits, rate estimate, clock and input stream. A
recovery request from any member makes the next frame a keyframe for all (with long-term
references, only references every member acked are used). A member that joins mid-stream
gets a keyframe. The session starts with the first member and ends with the last, and its
wasm instance goes with it (members are never freed inside a `MultiHost`, so a long session
holds the state of every member that left until it ends).

Input follows the roster's policy. The browser host's default is `everyone`, since a
hosted game is usually something to play together: every member's keys, buttons and pads
apply. A key is down on the page while any member holds it, each member's gamepads get
virtual pad slots of their own (up to the page's 4), and a member that leaves has everything
it held released. `owner` (one member at a time, as on native hosts) and `view` are options.
The web client has no control channel yet, so under `owner` it cannot ask for or hand on
input: the first member that may control holds it until it leaves.

## Media elements

The patch remembers every `<audio>` and `<video>` element that plays, in the document or not
(`new Audio()`), and once hosting starts their sound is routed into the tapped AudioContext
with `createMediaElementSource`, so it streams and still plays on the host. A page with no
AudioContext gets one for this. Cross-origin media without CORS (no `crossorigin`
attribute) is left alone: Web Audio would only get silence from it, and it would go quiet
on the host too. Elements fed by a `MediaStream` are left alone as well. `mediaElements:
false` turns this off. A `<video>` element can also be the picture: pass it as `canvas`.

## Results

Playwright 1.63's Chromium 153, Firefox 155 and WebKit 26.6, headless, on one 4-core Linux
container, all on the same machine as the relay. Both tabs connect through a local
`iroh-relay` on loopback, so the network is about 1–2 ms RTT through the relay. The demo
game runs at 960×540, 60 fps, 6 Mbit/s, with software encode and decode (no GPU). 30 presses
per input kind per variant. Every client pairs through the host's invite link first.
Raw runs: [results/headless.json](results/headless.json) (Chromium),
[results/headless-firefox.json](results/headless-firefox.json),
[results/headless-webkit.json](results/headless-webkit.json), and the
`results/multi-*.json` files for the pairing and several-viewer runs.

**Input to photon** runs from the client page's DOM event (`keydown`, `mousedown`, or the
moment the scripted pad's button changes) until the client draws the first frame where the
game's probe square has changed. That covers the client capture, network, injection into
the host page, the wait for the game's next frame, capture, encode, network, decode and
draw. Compositor time comes on top of that, usually one to two frames.

| host and client | variant | codec | key p50 / p90 | mouse p50 / p90 | pad p50 / p90 |
| --- | --- | --- | --- | --- | --- |
| Chromium | default (rAF capture, libopus) | H.264 | 15.5 / 24.5 ms | 15.9 / 25.1 ms | 16.8 / 25.7 ms |
| Chromium | WebCodecs Opus | H.264 | 17.9 / 23.7 ms | 17.6 / 24.2 ms | 19.1 / 25.8 ms |
| Chromium | `captureStream` capture | H.264 | 21.2 / 34.7 ms | 16.4 / 27.0 ms | 19.4 / 27.0 ms |
| Chromium | AV1 | AV1 | 17.5 / 24.4 ms | 18.9 / 23.9 ms | 21.1 / 28.7 ms |
| Chromium | media element tone | H.264 | 15.9 / 24.5 ms | 18.0 / 23.3 ms | 17.5 / 24.0 ms |
| Firefox | default | AV1 | 44 / 62 ms | 41 / 54 ms | 44 / 61 ms |
| WebKit | default | H.264 | 93 / 171 ms | 119 / 201 ms | 118 / 172 ms |

About 8 ms of each figure is the game itself: on average, input lands halfway through a
16.7 ms frame. The core's own stage times (p50 / p99) for Chromium's default variant:

| stage | p50 | p99 |
| --- | --- | --- |
| capture (`new VideoFrame(canvas)` after the game's frame) | 0.6 ms | 2.5 ms |
| encode (WebCodecs H.264, OpenH264 software, 960×540) | 2.6 ms | 5.5 ms |
| network (encoded to received, through the relay) | 1.3 ms | 3.8 ms |
| decode (client, software) | 0.6 ms | 2.1 ms |
| present (decoded to drawn) | 2.2 ms | 5.4 ms |
| total (capture to drawn) | 6.7 ms | 13.7 ms |
| input (client capture to injected into the host page) | 1.7 ms | 15.2 ms |

In Chromium, all eight variants pass every check, as they did before pairing and the
multi-user host. The client draws about 60 fps with no decode errors and non-blank frames.
The game's audio is heard on the client (0 to 3 concealed frames per clean run; the loss
variants conceal more, as before). Keys move the player, the left stick moves it too, the
mouse lands within 8 px of the expected spot in absolute mode, the wheel changes the
player's size, and the game sees a remote pad in `getGamepads()`. When the client leaves,
the host goes back to waiting. The media variant turns the game's drone off and plays a
660 Hz tone in an `<audio>` element: the client hears it.

**Firefox and WebKit as hosts** pass the same checks (default and media), more slowly:

- **Firefox** offers WebCodecs H.264 when its OpenH264 plugin is missing (it is not in
  Playwright's build), then holds every frame until a flush, so nothing ever came out. The
  host now probes each candidate codec with one frame before choosing it, and Firefox ends up
  on AV1: about 23 ms per frame in software, so the encoder runs at 30 fps or so and drops
  the rest (latency about 45 ms). A Firefox with OpenH264 should do better; not tried.
- **WebKit** encodes H.264 in 5–7 ms, but capture (`new VideoFrame(canvas)`, about 10 ms),
  its wasm iroh path (about 25 ms network p50) and decode on a WebKit client are slow here,
  and frames that never come out of its encoder force keyframes (about 40 per run). Two of
  four long WebKit-host runs ended with the WebKit client tab crashing ("Target crashed")
  partway through the 90 input presses; a WebKit client of a Chromium host streamed 90 s
  without one. That looks like the engine, not this code, but it is not explained.
- WebKit can start an AudioContext "interrupted", and nothing then reaches the tap (host) or
  the speakers (client). Both now resume it while it is, and on the next gesture. WebKit also
  plays media only from a gesture, so the media variant clicks **Start hosting** for real.

**Pairing and several viewers** ([`browser-host-multi.mjs`](../e2e/browser-host-multi.mjs))
pass with a Chromium host and Chromium, Firefox or WebKit clients, and with Firefox and
WebKit hosts and Chromium clients: two devices pair through one invite (the window closes
after its two pairings), both stream and hear audio, both play at once (each one's keys move
the player, and the game sees two pads), one leaves without stalling the other and comes
back with the address link (admitted, no pairing), a stranger with the address and a guessed
PIN is told the host is not pairing and never streams, a PIN-only window pairs it with the
right PIN, and a forgotten device loses its session at once and is refused afterwards.

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
- Only the first AudioContext is tapped (media elements are routed into it).
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

**Not done.** Real Safari (only Playwright's WebKit on Linux), the control channel in the
web client (so under the `owner` policy a web client cannot ask for input or hand it on),
per-device permissions beyond input on/off, freeing a departed member's state before the
session ends, hardware encode, CPU cost, a real network and a public relay, cursor shape,
clipboard, HiDPI canvases, and resizes.
