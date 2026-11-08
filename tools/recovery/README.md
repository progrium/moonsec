# tools/recovery: the Phase 5 recovery gate

Phase 5's gate (docs/design.md) is "loss recovery without keyframe spikes on NVENC and
VideoToolbox". This tool checks it on a real encoder: it drives a host backend's
`platform.Encoder` through `core/recovery` (the same host and client state machines the
app uses) over a simulated link that loses frames, and records:

- every frame's size and type (IDR, LTR refresh, P),
- how long the client stayed frozen after each loss (from the moment it saw the gap to
  the recovery frame),
- whether any IDR was sent after the first,
- the size of an IDR at steady state (one forced after the run, not counted) to compare
  recovery frames with.

Time is virtual (one tick per frame; frames and acks each take half the RTT), so a run is
deterministic for a given seed and encoder. Only the encoder runs for real.

## Passing

`--expect ltr` (the default, the gate):

- the encoder reports long-term references,
- no IDR after the first,
- every forced refresh comes back marked as one (`ltr_refresh`),
- the largest recovery frame is at most `--max-refresh-ratio` (default 0.5) of the
  steady-state IDR (S8 on VideoToolbox: 52-90 KB refreshes against 311-326 KB IDRs),
- the client is decoding at the end, and the decoder (when there is one) never failed.

If the encoder's rate control holds IDRs to the one-frame VBV (the IDR comes out under
twice a mean P frame), sizes cannot show a spike, so the size limit is reported as not
checked and "no IDR after the first" carries the gate. The report also prints the largest
recovery frame against the mean P frame either way.

`--expect idr` is the fallback check for encoders without long-term references (Media
Foundation): every loss recovers through an IDR and the stream never stays frozen.

Exit status: 0 pass, 1 fail, 2 when the backend cannot be opened on this machine.

## Backends

| Name | Where | Encoder and input |
| --- | --- | --- |
| `synthetic` | any OS | the passthrough encoder and the synthetic decoder (which fails a frame whose reference the client never got). Sizes are its model (IDR 2x P, refresh 1.5x P), so its default limit is 0.8 and it checks the protocol, not sizes. |
| `win-nvenc` | Windows, NVIDIA GPU | NVENC, desktop-like content (content.zig) uploaded into a BGRA texture |
| `win-amf` | Windows, AMD GPU | AMF, same content |
| `win-vpl` | Windows, Intel GPU (Xe / 11th-gen Core or newer) | oneVPL, same content; put `libvpl.dll` next to the exe or rely on the driver's `libmfx64-gen.dll` |
| `win-auto` | Windows | whichever of the three the adapter has, else Media Foundation |
| `win-mf` | Windows, any | Media Foundation's software H.264 on WARP (no LTR: use `--expect idr`). CI runs it. |
| `mac-vt` | macOS, with the macOS host backend (platform/host/macos) in the checkout | VideoToolbox on the low-latency path (long-term references), same content in an IOSurface-backed BGRA CVPixelBuffer. Needs no Screen Recording permission. |

The content is a static page of "text" (costly intra, free to predict), a text window
sliding 4 px per frame and a small box of fresh noise every frame, so an IDR costs several
P frames as it does on a real desktop.

## Running it

```
zig build recovery -Doptimize=ReleaseSafe -- [options]
```

Options: `--backend NAME` (default synthetic), `--codec h264|hevc`, `--frames N` (600),
`--loss PCT` (2: chance a loss starts on a frame), `--burst N` (1: frames per loss),
`--rtt-ms N` (30), `--seed N`, `--size WxH` (1920x1080), `--fps N` (60), `--bitrate BPS`
(20000000), `--expect ltr|idr`, `--max-refresh-ratio R` (0.5), `--no-ltr`, `--json PATH`,
`--trace` (one line per frame).

### Hardware checks for Jeff

On the Windows GPU box (NVIDIA):

```
zig build recovery -Doptimize=ReleaseSafe -- --backend win-nvenc --json nvenc-h264.json
zig build recovery -Doptimize=ReleaseSafe -- --backend win-nvenc --codec hevc --json nvenc-hevc.json
```

On the MacBook (once the macOS host backend is in the checkout):

```
zig build recovery -Doptimize=ReleaseSafe -- --backend mac-vt --json vt-h264.json
zig build recovery -Doptimize=ReleaseSafe -- --backend mac-vt --codec hevc --json vt-hevc.json
```

Passing means `PASS` and exit status 0: no IDR after the first, and recovery frames well
under the IDR size. Harder runs: `--loss 5 --burst 3 --rtt-ms 80`.

On an AMD or Intel machine, the same with `--backend win-amf` or `--backend win-vpl`.

## CI

- `zig build test` runs `test-recovery` (test.zig) on Linux, macOS and Windows: the
  synthetic backend passes the LTR gate, without LTR it passes the IDR fallback and fails
  the LTR gate, bursts and long RTTs recover, runs are deterministic.
- core.yml runs the synthetic gate (1800 frames, 2% loss in bursts of 2).
- windows.yml runs `win-mf --expect idr` on windows-2022 (WARP, no GPU) and uploads the
  JSON.
- `zig build check-win` cross-compiles and links the Windows gate for x86_64 and aarch64.

## Not checked here

- Decoding of hardware streams: on hardware the client side counts a frame as decoded when
  recovery passes it on. S8 and S7b checked VideoToolbox decode bit-exact after LTR
  refreshes; a Windows decode check (the client backend's decoder on the same stream) is a
  follow-up.
- Real network timing: the link is a fixed delay per direction; netlab and the sim cover
  jitter, reordering and congestion.
