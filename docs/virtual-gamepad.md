# Virtual gamepads on the Windows host

Phase 3 was meant to pick the driver route for virtual gamepads on Windows and didn't.
This note compares the routes, recommends one, and records what is built.

**Recommendation:** ship ViGEmBus 1.22.0 (the last signed release) as an optional
dependency now, behind the `pads.Backend` interface, and plan our own attestation-signed
fork of it only if ViGEmBus stops installing or Server hosts start to matter. Jeff
decides; see [Decision](#decision).

## What a virtual gamepad has to do

- **Reach XInput.** Most PC games read pads through XInput, which sees only devices on
  one of its three wire protocols: XUSB (the Xbox 360 USB driver, `xusb22.sys`),
  XInputHID (Xbox controllers over Bluetooth) and GIP (Xbox One and later) ([GDK: input
  hardware interfaces][gdk-hw]). A generic HID gamepad shows up in DirectInput, Raw
  Input, GameInput (through registry mappings), SDL and Steam Input, **but not in
  XInput**. So "make a HID gamepad" alone isn't enough.
- **Install without test mode.** On 64-bit Windows 10/11, kernel drivers need a
  Microsoft signature: attestation signing through Partner Center for client Windows,
  or HLK (WHCP) signing, which is also what Windows Server 2016 and later require
  ([signing offerings][ms-offerings]).
- **Carry what our wire format has.** `core.input.Gamepad` is buttons (XInput order is
  the recommended layout), two sticks and two triggers: exactly an `XINPUT_GAMEPAD`. Gyro,
  touchpad, rumble and lightbar have no field yet.

## Routes

### 1. ViGEmBus (Nefarius), retired but signed

A KMDF bus driver that plugs emulated USB devices: an Xbox 360 wired controller (the
inbox `xusb22.sys` loads on it, so XInput sees a real XUSB device) or a DualShock 4.

- **Status:** retired. The repository was archived on Nov 2, 2023 and the end-of-life
  statement says it "will no longer receive any updates" after a trademark conflict over
  the ViGEm name ([README][vigem-readme], [EOL statement][vigem-eol]). The last release
  is v1.22.0 (Sep 2023).
- **Signing:** the release binaries are "production-signed" by Microsoft for Windows
  10/11 ([README][vigem-readme]). They keep installing as long as Microsoft doesn't revoke
  them or block the driver; nothing in the EOL statement suggests either. Whether they
  load on Windows Server 2022 is what the new `vigem` CI job finds out (see
  [Status](#status)).
- **Install UX:** a separate installer, `ViGEmBus_1.22.0_x64_x86_arm64.exe` (Advanced
  Installer, admin, silent with `/exenoui /qn /norestart`). Sunshine and DS4Windows ask
  users to install it the same way. We can bundle it or link to it; the installer is
  6.3 MB, covers x64, x86 and arm64, and its SHA-256 is pinned in CI.
- **Old updater:** ViGEmBus v1.21.442 and older ship an updater that calls home to the
  `vigem.org` domain, which no longer belongs to the author; the EOL page says to fix the
  updater config or run its Legacinator tool. v1.22.0 is newer than the affected versions,
  but machines with an old install still have that updater.
- **XInput / DS4:** Xbox 360 wired (XInput, so nearly every game) and DualShock 4 (HID;
  games with native PlayStation support and Steam Input). XInput only gives four slots,
  shared with physical pads.
- **Licence:** the driver is BSD-3-Clause ([README][vigem-readme]). The client SDK
  (`ViGEmClient`) is MIT. We don't link either: `pad_vigem.c` speaks the bus's IOCTL
  protocol directly, following ViGEmClient's `BusShared.h`, and credits it.
- **Known rough edges:** one Sunshine report has a host's physical pad held
  "logically disconnected" after streaming through ViGEmBus ([Sunshine #4193][sunshine-4193]);
  not reproduced, and it may be HidHide or Steam rather than the bus.
- **Successor:** Nefarius's VirtualPad framework. DS4Windows maintainers who read its
  licence describe it as proprietary and say redistributing the installer needs
  permission ([DS4Windows discussion][ds4w]). Not an option without a licence deal.

### 2. Our own driver

Two shapes, very different in reach.

**2a. A HID gamepad through VHF or a UMDF HID minidriver.** The Virtual HID Framework
(VHF) lets a small KMDF source driver present a HID device; a UMDF 2 driver under
`mshidumdf.sys` can do the same in user mode.

- **Signing:** attestation signing in Partner Center: register for the Hardware Developer
  Program and buy an EV code-signing certificate (a few hundred dollars a year, on a
  hardware token or cloud HSM) ([attestation signing][ms-attest], [requirements][ms-reqs]).
  Attestation-signed drivers load on Windows 10/11 desktop only, can't ship to retail
  through Windows Update, and are not "Windows Certified" ([signing offerings][ms-offerings]).
  Windows Server needs HLK testing for a WHCP signature. Attestation covers user-mode
  drivers too, so UMDF doesn't avoid the EV certificate.
- **XInput:** none, as a plain HID gamepad. It might reach XInput by posing as an Xbox
  controller over the XInputHID protocol (same report descriptor and VID/PID, so
  `xinputhid.sys` binds), but that is unverified: the filter's INF matches Bluetooth
  hardware IDs, and it would need a spike to see whether a VHF child can match.
- **Install UX:** our own INF in our installer (pnputil / `UpdateDriverForPlugAndPlayDevices`);
  one admin prompt, no second vendor.
- **Licence:** ours.
- **Cost:** a driver to write, test on every Windows build, and keep signed (the EV cert
  renews yearly). Kernel bugs crash hosts.

**2b. Fork ViGEmBus (BSD-3) and sign it ourselves.** Rename it (the ViGEm name is a
trademark of someone else now), strip DS4 if we don't want it, attestation-sign it with
our EV certificate.

- Keeps XUSB, so XInput works on day one; the client side we built already speaks its
  protocol (only the interface GUID would change).
- Same signing cost and limits as 2a (EV cert, Partner Center, client Windows only; HLK
  for Server). We own a kernel driver we didn't write.
- This is the fallback if route 1 breaks.

### 3. Windows input injection API (no driver)

`Windows.UI.Input.Preview.Injection.InputInjector` has `InitializeGamepadInjection` and
`InjectGamepadInput` ([docs][ms-injectpad]). It needs the `inputInjectionBrokered`
restricted capability, which means a packaged app with a restricted capability that
Store certification rarely grants. The docs don't say which APIs see the injected pad,
and we found no report of XInput seeing it; assume Windows.Gaming.Input only until
someone tests it. Not useful for XInput games. Rejected.

### 4. Hooking the game's XInput (no driver)

Replace or detour `xinput1_*.dll` in the game process, as x360ce or InputFusion do
([InputFusion][inputfusion]). No driver, but it means injecting a DLL into every game:
anti-cheat bans it, and it needs per-game setup. Rejected for a streaming host.

### 5. Other drivers

- **Parsec, Steam Remote Play:** each ships its own signed virtual-USB or virtual HID
  driver; proprietary, not redistributable. (From what those products install, not from
  their docs.)
- **vJoy, ScpVBus:** vJoy is a DirectInput-only joystick; ScpVBus is ViGEm's unmaintained
  predecessor. Neither is a better bet than ViGEmBus. (From memory; not re-checked.)

## Comparison

| | ViGEmBus 1.22.0 | Own HID driver (VHF/UMDF) | Signed ViGEmBus fork | InputInjector API |
| --- | --- | --- | --- | --- |
| XInput | Yes (XUSB) | No; maybe via XInputHID (unverified) | Yes (XUSB) | No |
| DualShock 4 | Yes | If we write a DS4 descriptor | Yes, if kept | No |
| Signing | Done (Microsoft-signed release) | EV cert + attestation; HLK for Server | EV cert + attestation; HLK for Server | None |
| Install | Separate installer, admin | Our installer, admin | Our installer, admin | Packaged app + restricted capability |
| Maintenance | None possible (archived) | Ours | Ours | Microsoft's |
| Licence | BSD-3 driver; we use only the IOCTL protocol (from MIT headers) | Ours | BSD-3 (keep notice) | n/a |
| Time to ship | Now | Months (driver + signing setup) | Weeks (signing setup) | n/a |
| Main risk | Microsoft revokes or blocks it; a Windows change breaks it with no fix coming | Cost; still no XInput | We maintain a kernel driver | Not seen by games |

## Decision

**Recommended:** route 1 now, route 2b as the fallback.

1. Ship with ViGEmBus 1.22.0 as an optional dependency. The host works without it
   (keyboard and mouse only, one warning); the installer offers to install it, or we
   link to it. This gets XInput pads to Phase 4's gate without any signing work.
2. Keep the backend behind `pads.Backend`, so a fork or another driver drops in without
   touching the injector or the protocol.
3. Start the EV certificate and Partner Center registration anyway: Phase 5's IddCx
   virtual display driver needs the same signing pipeline, so the cost is shared. If
   ViGEmBus stops loading on a Windows update, or we need Windows Server hosts, fork it
   (2b) and sign it through that pipeline.
4. Don't build a HID-only driver (2a): it costs as much as 2b and loses XInput.

Things that would change this: Microsoft blocking ViGEmBus (watch the vulnerable driver
blocklist), the `vigem` CI job showing it won't load on Windows Server (only matters if
we target Server hosts), or Jeff wanting DS4 gyro and touchpad, which needs a wire format
change before any driver choice matters.

## Status

Built in `platform/host/windows`:

- `pads.zig`: the `Backend` interface (plug, update, unplug per slot) and `Pads`, which
  turns the receiver's pad actions into those calls: plug on connect, skip repeated
  snapshots, replug after a failed update, unplug on disconnect and at session end, and
  back off 5 s when there is no driver. Portable, with unit tests.
- `pad_vigem.c`: the ViGEmBus client in C (SetupAPI to find the bus, overlapped IOCTLs
  with a 2 s cap so a wedged driver can't hang the network thread). Plugs wired Xbox 360
  controllers.
- `host.zig`: `Options.gamepad` (`.vigem` by default, or `.none`); the injector routes
  `pad` actions to `Pads`. Button bits are XInput's (`XINPUT_GAMEPAD_*`); triggers go from
  16 to 8 bits.
- CI: `test (windows-2022)` checks pads are dropped cleanly with no driver. The new
  `vigem (windows-2022)` job installs ViGEmBus 1.22.0 (hash pinned), plugs a controller,
  and reads the snapshot back through `XInputGetState`.

Still needs Jeff's Windows GPU machine:

- A real game (XInput) and Steam's controller test seeing the pad, while streaming.
- Plug latency (`WaitDeviceReady`) on real hardware: the plug runs on the network thread
  once per connect.
- Clients don't capture gamepads yet (Phase 4: SDL3 or GameInput on the client), so
  end-to-end needs that or a test client sending pad snapshots.
- Rumble back to the client (`IOCTL_XUSB_REQUEST_NOTIFICATION`) needs a host-to-client
  message that the protocol doesn't have yet.

[gdk-hw]: https://learn.microsoft.com/en-us/gaming/gdk/docs/features/common/input/hardware/input-hardware-interfaces
[ms-offerings]: https://learn.microsoft.com/windows-hardware/drivers/dashboard/driver-signing-offerings
[ms-attest]: https://learn.microsoft.com/windows-hardware/drivers/dashboard/code-signing-attestation
[ms-reqs]: https://learn.microsoft.com/windows-hardware/drivers/dashboard/code-signing-reqs
[ms-injectpad]: https://learn.microsoft.com/en-us/uwp/api/windows.ui.input.preview.injection.inputinjector.injectgamepadinput
[vigem-readme]: https://github.com/nefarius/ViGEmBus/blob/master/README.md
[vigem-eol]: https://docs.nefarius.at/projects/ViGEm/End-of-Life/
[sunshine-4193]: https://github.com/LizardByte/Sunshine/issues/4193
[ds4w]: https://github.com/Ryochan7/DS4Windows/discussions/3124
[inputfusion]: https://github.com/xan105/inputfusion
