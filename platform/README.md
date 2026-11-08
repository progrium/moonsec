# platform

The platform interface ([api.zig](api.zig)) is what every OS backend implements so the
host and client apps run on it. The apps (session spine) drive these objects and never
learn which OS, GPU API or codec library is underneath.

| Side | Object | Thread | Windows (Phase 2) |
| --- | --- | --- | --- |
| host | `Capture` | capture | Desktop Duplication |
| host | `Encoder` | encode | NVENC |
| host | `AudioSource` | audio | WASAPI loopback |
| host | `InputInjector` | network | SendInput |
| client | `Decoder` | decode | D3D11VA |
| client | `Presenter` | present | flip-model swapchain |
| client | `AudioSink` | audio | WASAPI |
| client | `InputSource` | input/network | Raw Input; XInput pads ([client/gamepad](client/gamepad/README.md)) |

A backend lives in `platform/<name>/` and exports `openHost(...) !HostBackend` and/or
`openClient(...) !ClientBackend`. Write plain methods on your own types and turn them
into interface values with `api.bind(api.Capture, MyCapture, &my_capture)`.

The rules (threads, clock, buffer ownership, errors) are at the top of `api.zig`. The
interface is stable from Phase 2 on: new fields get defaults and new vtable methods go at
the end.
