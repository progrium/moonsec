# web: browser client

TypeScript glue around the Zig core compiled to wasm32 (docs/design.md, "Web client").
This directory holds the input path and the browser test harness so far; the media
pipeline (WebCodecs, AudioWorklet playback) and the iroh transport (`shim-web/`) land
next to it.

```
src/transport.ts        Transport interface (datagrams), WebSocket test transport
src/input/core.ts       the core's input sender (core/input/wasm.zig) from JS
src/input/capture.ts    DOM, Pointer Lock, Keyboard Lock, Gamepad API -> core input calls
src/input/hid.ts        KeyboardEvent.code -> USB HID usage
src/input/gamepad.ts    Gamepad API -> core.input.Gamepad (XInput button order)
e2e/                    Playwright harness, stub host, Safari (safaridriver) runner
```

## Build and test

```sh
zig build web-wasm          # zig-out/web/moonsec-core.wasm and the stub host's wasm
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
