# platform/host/linux

The Linux host's capture and audio: [host.zig](host.zig) implements the platform
interface's `Capture` and `AudioSource`. Like the Linux client, the OS APIs are called from
small C files behind a narrow header ([mlh.h](mlh.h)) that translate-c reads; Zig never
sees the system headers. The video encoders (VAAPI with long-term references, a libx264
fallback) are described in [ENCODERS.md](ENCODERS.md). uinput injection is a separate
workstream; the host bundle is put together where those meet.

| Object | How |
| --- | --- |
| `Capture` | The xdg-desktop-portal ScreenCast interface ([mlh_portal.c](mlh_portal.c), libdbus): `CreateSession`, `SelectSources` (monitors, cursor mode, persist mode, restore token), `Start`, `OpenPipeWireRemote`. Then a PipeWire video stream on the portal's node ([mlh_capture.c](mlh_capture.c)). |
| `AudioSource` | A PipeWire capture stream with `stream.capture.sink = true`, so it records the default sink's monitor (what the machine plays), f32 at 48 kHz ([mlh_audio.c](mlh_audio.c)). The process callback appends to a 500 ms ring and notes the clock time of the newest frame (less the graph delay); `read` waits up to its timeout and returns the capture time of its first frame. A reader that falls a whole ring behind loses the oldest frames (counted). |

### Capture details

- **Buffers.** With `Options.modifiers` set, the first format offered carries those DRM
  modifiers (mandatory, don't-fixate) and asks for dma-buf; the second has none and asks
  for memfd or shared memory. The compositor picks. A dma-buf frame has `Image.gpu` =
  `*const mlh_dmabuf` (fourcc, modifier, planes' fds, offsets, strides), and also
  `Image.cpu` when the buffer is linear and PipeWire mapped it (synced with
  `DMA_BUF_IOCTL_SYNC`). A memory frame is `Image.cpu`, bgra8. RGB-ordered sources are
  swizzled to BGR into a copy, so frames are always B, G, R, X/A. The VideoCrop metadata
  is applied to memory frames. Options default to memory only until an encoder (7B) says
  which modifiers it imports.
- **Newest frame wins.** The process callback dequeues every buffer that came and keeps
  only the newest; older ones go straight back to the compositor (counted as dropped).
  The frame handed out is held until a newer one is taken, which is what `repeatLast`
  returns, so at most two buffers are held and the stream asks for 4 to 16.
- **Pacing.** Each buffer is time-stamped on arrival in the process callback.
  `captured_us` is the buffer's header pts when it is on our clock (CLOCK_MONOTONIC, not
  after arrival, within a second), else the arrival time. Screen streams are
  damage-driven: a static screen sends nothing, so `acquire` times out and the app
  keeps the stream alive with `repeatLast`, as on macOS.
- **Cursor.** Without `cfg.cursor`, the portal is asked for the metadata cursor mode
  (falling back to embedded when the portal lacks it). Each buffer's `SPA_META_Cursor`
  updates the pointer: position and hotspot in frame pixels, and the bitmap (converted to
  BGRA, `serial` changes with it) when it changed. `CapturedFrame.cursor` (a new optional
  field in api.zig) carries it. Buffers with an empty chunk are cursor-only updates: they
  wake `acquire`, which returns a repeat of the last picture with the new cursor.
- **Displays.** The portal returns one stream per monitor the user chose
  (`Options.multiple` lets them choose several); `CaptureConfig.display` indexes them
  and anything past the end is the first. `Capture.displays` arrives with #37 and maps
  onto the same list.
- **Errors.** No session bus, no portal or no PipeWire: `error.Unsupported`. The user
  cancelled: `error.Unsupported` (logged as cancelled). The session closed or the stream
  ended (monitor unplugged, sharing revoked): `error.DeviceLost`, and `start` again
  (silently, with a restore token).

### Unattended hosts: restore tokens

With `Options.token_path` set (use `tokenPath(state_dir)`: `screencast.token` next to
`identity.key` in `~/.config/moonsec`), `start` reads the token, passes it to
`SelectSources` with persist mode 2 ("until revoked"), and stores the token the portal
returns (mode 0600, written to a temporary file and renamed). The user approves once; a
restarted host captures without a dialog until they revoke it in their desktop's
settings. The spec makes tokens single use, so the latest is always stored.
xdg-desktop-portal 1.18 hands the same one back each time.

ScreenCast version 4 (xdg-desktop-portal 1.12) added restore tokens. Which backends
honour them (from the backends' docs and source; only the frontend's side is tested here):

| Desktop | Portal backend | Restore tokens | Cursor metadata | dma-buf |
| --- | --- | --- | --- | --- |
| GNOME 42+ | xdg-desktop-portal-gnome | yes | yes | yes, with modifiers |
| KDE Plasma 5.27+ / 6 | xdg-desktop-portal-kde | yes | yes | yes, with modifiers |
| wlroots (sway, river) | xdg-desktop-portal-wlr 0.7+ | yes | no (embedded or hidden) | required by 0.7 |
| Hyprland | xdg-desktop-portal-hyprland | yes | no | yes |

Without a restore token (older portals) every start shows the dialog; the host logs it.

### Virtual display (not built)

The design's Linux row is "compositor headless output". Not done here; the approach for
later:

- **GNOME**: Mutter's `org.gnome.Mutter.ScreenCast` session with `RecordVirtual`
  (virtual monitor of a given size, cursor mode as above) returns a PipeWire node just
  like a portal stream, so `mlh_capture` takes it as is. It needs a session D-Bus call
  outside the portal (allowed for unsandboxed apps); gnome-remote-desktop does this for
  headless logins.
- **KDE**: KWin's `zkde_screencast_unstable_v1.stream_virtual_output` (Wayland protocol,
  privileged) or the `org.kde.KWin.ScreenCast` portal extension's virtual output.
- **wlroots**: `swaymsg create_output` adds a headless output (`HEADLESS-n`) on a running
  sway, sized with `output HEADLESS-n mode WxH`; then the portal (or a restore token
  that names it) captures it. Removal: `swaymsg output HEADLESS-n unplug`.

The policy and size would come from `CaptureConfig.virtual_display` once #39 merges.

## Build and test

Ubuntu 24.04 packages: `libdbus-1-dev libpipewire-0.3-dev`; the tests also build the
Linux client's audio sink (`libavcodec-dev libavutil-dev libva-dev libwayland-dev
libegl-dev libgles-dev`), and run under `weston pipewire pipewire-bin wireplumber
dbus-daemon xdg-desktop-portal`.

```sh
zig build test-linux-host                                   # skips what this machine lacks
platform/host/linux/headless.sh zig build test-linux-host   # in a headless desktop
MOONSEC_REQUIRE=portal,pipewire platform/host/linux/headless.sh zig build test-linux-host
```

[headless.sh](headless.sh) runs Weston with its PipeWire backend (the output is a
PipeWire video node; pixman renderer, no GPU) and the kiosk shell, PipeWire and
WirePlumber with a null sink as the default, and a D-Bus session in which
xdg-desktop-portal starts on first use. The portal's ScreenCast backend is the test's
own ([testwin/testportal.c](testwin/testportal.c)): the real frontend routes to it, and it
hands out Weston's output node without a dialog. So the host's portal client, the
frontend's restore-token handling and the PipeWire stream are all the real ones.
xdg-desktop-portal-wlr on a headless sway was the plan, but xdpw 0.7 refuses to cast
without dma-buf and the container has no GPU.

What the tests check ([test.zig](test.zig)):

- **Capture through the portal.** A fullscreen wl_shm window draws the measurement test
  pattern stamped with the time at 60 fps; two seconds of captured frames must all
  decode, with frame numbers in order and capture after draw. Weston's PipeWire output
  runs at 30 fps: about 60 frames, every stamp read, draw to capture about 12 to 21 ms.
  Then the window stops drawing: `acquire` times out and `repeatLast` gives the last
  picture again.
- **Restore token.** The token is stored, a second start passes it, and the frontend
  hands the backend's restore data back (what lets a real backend skip its dialog),
  with persist mode 2 and the metadata cursor mode asked for.
- **Cursor and formats** (a PipeWire source the test drives, no portal): an RGBx picture
  comes out as BGRX, the cursor metadata's position, hotspot and RGBA bitmap come out as
  BGRA, and a cursor-only buffer gives a repeat with the new position.
- **Audio.** A 440 Hz tone at 0.25 played into the null sink comes back from its monitor
  at RMS 0.177, about 48 000 frames a second, time stamps on the clock and in order.

Not covered without a GPU: dma-buf frames (the dma-buf format is offered and falls back
to memory on Weston, which is tested; dma-buf buffers themselves are compile-only), and a
real desktop's portal dialog.

## Hardware check for Jeff

On a GNOME or KDE desktop with a GPU (Wayland session), run this twice:

```sh
MOONSEC_HW=1 MOONSEC_HW_DMABUF=1 zig build test-linux-host
```

The first run shows the portal's dialog (pick a monitor; the pattern window goes
fullscreen on it); the second must not, and prints `had a restore token before` with a
start time in milliseconds. Both print `hardware: ... N dma-buf (modifier 0x...)` and fail
unless every frame was dma-buf. Move a window during the 3 s run to get frames.

## Files

- `mlh.h`: the Zig-facing C ABI. `mlh_internal.h`: helpers shared by the C files.
- `mlh_portal.c`, `mlh_capture.c`, `mlh_audio.c`, `mlh_common.c`: see above.
- `host.zig`: `Capture`, `AudioSource`, `tokenPath`, the clock.
- `testwin/`: test-only helpers: a wl_shm window, the test portal backend and a
  controllable PipeWire source.
- `headless.sh`: the headless desktop. `build.zig`: `test-linux-host` and
  `linuxHostModule`.
