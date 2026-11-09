# Client gamepads

Gamepad capture for every client OS. Each backend turns its OS's pads into
`core.input.Gamepad` snapshots and hands them out as `api.InputEvent.pad`
events, so the session's `core.input.Sender` sends the same thing whatever
the client is.

| OS | API | File | Tested |
| --- | --- | --- | --- |
| Windows | XInput (xinput1_4, falling back to xinput9_1_0) | [xinput.zig](xinput.zig) | mapping and a fake XInput everywhere; DLL load on windows-2022 |
| macOS | GameController.framework | [gamecontroller.zig](gamecontroller.zig), [gc.m](gc.m) | mapping everywhere; framework calls on macos-15 |
| Linux | evdev with inotify hotplug | [evdev.zig](evdev.zig) | mapping everywhere; a uinput virtual pad on ubuntu-24.04 ([uinput_test.zig](uinput_test.zig)) |

**One layout.** `Gamepad.buttons` uses `core.input.Gamepad.Button`, which is
XInput's `wButtons` plus guide (0x0400). Sticks are -32768..32767 with up
positive; triggers 0..65535. Face buttons are named by position: `a` is the
bottom button whatever its label (cross on PlayStation, B on Nintendo).

**Slots.** [pads.zig](pads.zig) gives each device one of the four pad slots
for as long as it stays connected, drops unchanged states and queues events
between polls. A fifth pad waits for a free slot.

**Wiring.** Every `Source` has `poll(out) api.Error!usize` and only emits pad
events. A client backend calls it at the end of its own `InputSource.poll`
(the Windows client does), or binds it alone with
`api.bind(api.InputSource, ...)`. `root.Native` is the source type for the
target OS.

| Source | Open | Notes |
| --- | --- | --- |
| `xinput.Source` | `open(clock)`, never fails | Empty user slots are re-checked every 500 ms, since XInput is slow on them. GameInput (non-XInput pads) is a later addition. |
| `gamecontroller.Source` | `open(clock)` | `GCController.controllers` is updated on the main run loop, which the macOS client runs; values are read from the input thread. Background monitoring is on (macOS 11.3+). |
| `evdev.Source` | `open(clock, .{})` | Watches `/dev/input`; reads need the uaccess ACL desktops give pads. Times are the kernel's, on CLOCK_MONOTONIC. Microsoft pads (xpad) swap BTN_NORTH/WEST back to X/Y. |

Build: `zig build test` runs the unit tests on any OS; `zig build test-gamepad`
runs only these. On Linux the uinput tests skip without a writable
`/dev/uinput`; `-Drequire-uinput=true` makes that a failure (CI,
`.github/workflows/gamepad.yml`).
