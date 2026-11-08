# platform

The platform interface ([api.zig](api.zig)) is what every OS backend implements so the
host and client apps run on it. The apps (session spine) drive these objects and never
learn which OS, GPU API or codec library is underneath.

| Side | Object | Thread | Windows (Phase 2) | Linux (client Phase 4, host Phase 7) |
| --- | --- | --- | --- | --- |
| host | `Capture` | capture | Desktop Duplication | PipeWire (7A; synthetic until then) |
| host | `Encoder` | encode | NVENC | VAAPI, NVENC, software (7B; synthetic until then) |
| host | `AudioSource` | audio | WASAPI loopback | PipeWire (7A; synthetic until then) |
| host | `InputInjector` | network | SendInput | uinput |
| client | `Decoder` | decode | D3D11VA | libavcodec: VAAPI, software fallback |
| client | `Presenter` | present | flip-model swapchain | Wayland + EGL/GLES 3 |
| client | `AudioSink` | audio | WASAPI | PipeWire |
| client | `InputSource` | input/network | Raw Input | evdev |

The Linux client is in [client/linux](client/linux/README.md) and the Linux host in
[host/linux](host/linux/README.md); they share the uinput plumbing and key table in
[linux/uinput.zig](linux/uinput.zig).

A backend lives in `platform/<name>/` and exports `openHost(...) !HostBackend` and/or
`openClient(...) !ClientBackend`. Write plain methods on your own types and turn them
into interface values with `api.bind(api.Capture, MyCapture, &my_capture)`.

The rules (threads, clock, buffer ownership, errors) are at the top of `api.zig`. The
interface is stable from Phase 2 on: new fields get defaults and new vtable methods go at
the end.
