# platform/host/linux

The Linux host backend: `open(allocator, options)` in [host.zig](host.zig) returns a
`Host` whose `backend()` is a `platform.HostBackend` (see [../../api.zig](../../api.zig)).
`moonsec ... host --host linux` runs it (in `moonsec-linux` builds).

| Object | Implementation | File |
| --- | --- | --- |
| `Capture` | Synthetic test pattern for now; PipeWire capture comes with 7A | host.zig |
| `Encoder` | `.auto` tries VAAPI, then NVENC, then software (7B); synthetic passthrough until they land | host.zig |
| `AudioSource` | Synthetic tone for now; PipeWire capture comes with 7A | host.zig |
| `InputInjector` | uinput keyboard, mouse, absolute pointer and gamepads | [input.zig](input.zig) |
| `Clock` | `CLOCK_MONOTONIC` | host.zig |

The capture is wrapped so its `start` tells the injector the captured output's size:
absolute positions then land on the captured pixels.

## Input injection (uinput)

Each kind of input gets its own virtual device, so udev and libinput classify each one
correctly. The uinput plumbing, event codes and the HID usage table are shared with the
client in [../../linux/uinput.zig](../../linux/uinput.zig).

| Device | Reports | Notes |
| --- | --- | --- |
| `moonsec keyboard` | every `KEY_*` the HID usage table maps to | HID usages from the client, so the host's keyboard layout applies (as on Windows, where keys go by scan code) |
| `moonsec mouse` | buttons 1-5 (`BTN_LEFT/RIGHT/MIDDLE/SIDE/EXTRA`), `REL_X/Y`, `REL_WHEEL_HI_RES`/`REL_HWHEEL_HI_RES` | 120 per notch; `REL_WHEEL`/`REL_HWHEEL` notches are accumulated from the high-resolution value, as the kernel's HID driver does, for programs that read only those |
| `moonsec absolute pointer` | `ABS_X/Y` over the captured output's pixels, `INPUT_PROP_DIRECT`, three buttons | Created at the first absolute position and again when the output size changes. The buttons make udev tag it an absolute mouse, as with a VM's USB tablet; clicks still go through the mouse |
| `moonsec pad N (Xbox 360 layout)` | xpad's layout: `BTN_SOUTH/EAST`, `BTN_X/Y` (= `BTN_NORTH/WEST`), `BTN_TL/TR`, `BTN_SELECT/START/MODE`, `BTN_THUMBL/R`; sticks `ABS_X/Y/RX/RY` (-32768..32767, Y down positive), triggers `ABS_Z/RZ` (0..1023), d-pad `ABS_HAT0X/Y` | One per connected client pad, created on connect and removed on disconnect. USB ids 045e:028e, so SDL and Steam use their Xbox 360 mapping |

Every action is one report (its events, then `SYN_REPORT`) in one `write`. When a device
is destroyed the kernel releases whatever it still held, so ending a session never leaves
a key or button down. The keyboard and mouse are created when the host opens, so a missing
`/dev/uinput` shows at once; without it the host logs what to do and streams without input
(`require_input` makes `open` fail instead).

The host's devices use vendor `6d73` and products `0101`-`0103`. The Linux client skips
them (`uinput.isHostDevice`), so a client on the same machine doesn't read the injected
input back and send it again.

**Rumble:** the client pad protocol (#25) carries no force feedback yet, so the pads do
not advertise `EV_FF`, and games see a pad without rumble. When the protocol carries it,
the pad device needs `EV_FF`/`FF_RUMBLE` and a loop answering `UI_FF_UPLOAD`/`UI_FF_ERASE`
on the uinput fd.

**Multiple outputs:** compositors map an absolute device across the whole layout unless
told otherwise. With more than one output, map it to the captured one (sway:
`input 28019:259:moonsec_absolute_pointer map_to_output <name>`). Multi-display capture
(#37) will need the injector to follow the streamed display.

## Permissions

Creating devices needs write access to `/dev/uinput`, which is root-only by default.
[60-moonsec-uinput.rules](60-moonsec-uinput.rules) gives it to a `moonsec` group, and
[moonsec-uinput.conf](moonsec-uinput.conf) loads the module at boot. The Linux packages
(7G) install both and create the group. By hand:

```sh
sudo groupadd --system moonsec
sudo usermod -aG moonsec "$USER"            # then log in again
sudo install -m 644 platform/host/linux/60-moonsec-uinput.rules /etc/udev/rules.d/
sudo install -m 644 platform/host/linux/moonsec-uinput.conf /etc/modules-load.d/
sudo modprobe uinput
sudo udevadm control --reload-rules && sudo udevadm trigger --subsystem-match=misc
ls -l /dev/uinput                           # crw-rw---- root moonsec
```

The host logs which of the two is wrong: `/dev/uinput is missing` (load the module) or
`no write access to /dev/uinput` (the rule and group).

Being in the `moonsec` group lets a user type into any session on the machine, the same
power the `input` group gives for reading. Grant it only to the account the host runs as.

## Build and test

```sh
zig build test                     # the injector's translation, devices replaced by pipes
zig build test-linux-host          # real uinput devices read back from evdev; skips without /dev/uinput
zig build moonsec-linux            # moonsec-sim with --host linux and --client linux
zig build moonsec-linux -Dlinux-iroh=true   # also `peer iroh` / `run iroh` (builds the shim)
zig-out/bin/moonsec-linux run sim --host linux --verify-input       # needs /dev/uinput
platform/client/linux/headless.sh zig-out/bin/moonsec-linux run sim --host linux --client linux
```

`MOONSEC_REQUIRE=uinput` turns the `test-linux-host` skips into failures (CI sets it).
`--verify-input` reads the injected keys back from the keyboard's event node, as the
compositor reads them, and checks them against the synthetic client's key script.

**Careful on a desktop:** with the synthetic client, `--host linux` types its key script
(a, b, c, ...) and nudges the pointer in whatever window has focus. Run it in a VM, a
spare session, or with a real client.

The cloud containers have no `/dev/uinput`, so injection is tested on a GitHub
ubuntu-24.04 runner ([linux.yml](../../../.github/workflows/linux.yml), started by hand)
or on a Linux machine.

## Hardware check (for Jeff)

On a Linux machine with `/dev/uinput` (the VM is fine; a desktop session is not needed),
after the permissions above, from a checkout:

```sh
MOONSEC_REQUIRE=uinput zig build test-linux-host --summary all && zig build moonsec-linux && zig-out/bin/moonsec-linux run sim --host linux --verify-input --seconds 10
```

It passes when every injected device reads back as expected and the synthetic client's
key script arrives on the uinput keyboard in order. Don't run the last command in a
desktop session you are using: it types into the focused window.

The full check, a Linux GPU machine streaming its desktop to the Mac and Windows clients
while playing with a gamepad, needs 7A's capture, 7B's encoders, and `--client` options
for the Mac and Windows backends in `moonsec`; it follows them.
