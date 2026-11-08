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
| client | `InputSource` | input/network | Raw Input |

A backend lives in `platform/<name>/` and exports `openHost(...) !HostBackend` and/or
`openClient(...) !ClientBackend`. Write plain methods on your own types and turn them
into interface values with `api.bind(api.Capture, MyCapture, &my_capture)`.

Multiple displays (Phase 5): `Capture.displays` is optional (`bind` leaves it null when
the type has no `displays` method). A backend that has it lists its displays with stable
ids, and `start(.{ .display = id })` captures that one, at its own size when `width` and
`height` are 0 or scaled to them otherwise. When the display changes mode while
capturing at its own size, keep capturing and deliver frames at the new size; the app
reconfigures the encoder and the client ([spec/display-v0.md](../spec/display-v0.md)).
Switching displays is `stop` then `start`. The synthetic backend has N fake displays,
`setMode` and `addDisplay`.

The rules (threads, clock, buffer ownership, errors) are at the top of `api.zig`. The
interface is stable from Phase 2 on: new fields get defaults and new vtable methods go at
the end.
