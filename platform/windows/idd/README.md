# platform/windows/idd

The moonsec virtual display driver: an IddCx (UMDF 2) indirect display driver that
gives a Windows host with no monitor attached a display to stream (docs/design.md,
Phase 5: "headless host works").

| File | What |
| --- | --- |
| [moonsec_idd.h](moonsec_idd.h) | The control interface: device interface GUID, IOCTLs, structs. Shared by the driver and the host. |
| [driver/Driver.cpp](driver/Driver.cpp) | The driver (C++, WDK). |
| [driver/MoonsecIdd.inf](driver/MoonsecIdd.inf), [driver/MoonsecIdd.vcxproj](driver/MoonsecIdd.vcxproj) | INF and MSBuild project (IddCx 1.4, UMDF 2.25, Windows 10 1803+). |
| [build.ps1](build.ps1) | Builds, stamps, verifies, catalogs and test-signs the package. |
| [install.ps1](install.ps1) | Trusts the test certificate and installs the package (copied into it). |

The host side is [platform/host/windows/vdisp.c](../../host/windows/vdisp.c), used by the
Windows backend's `Capture` when `CaptureConfig.virtual_display` asks for one.

## How it works

- The driver plugs in up to four monitors with no EDID. The OS asks it for their modes:
  the requested mode is the preferred one, followed by a few common sizes at the same rate.
- Control is over a device interface (`MOONSEC_IDD_INTERFACE_GUID_INIT`) with
  `DeviceIoControl`: `ADD` (mode and preferred render adapter), `REMOVE`, `SET_MODE`
  (replug with a new preferred mode), `REMOVE_ALL`, `INFO` and `PING`.
- Each monitor's swap chain is drained on its own thread (frames are released right
  away). The host does not get frames from the driver: it captures the new display with
  Desktop Duplication, like any other, on its own GPU (the `ADD` request passes the host's
  adapter LUID, and the driver asks IddCx to render there).
- **Lifecycle.** `Capture.stop` removes the display; closing the bundle removes all of
  them. If the host dies instead: (1) the driver unplugs every monitor when no request has
  arrived for 3 s (the host pings every 500 ms), and (2) when the host made the device
  itself (`SwDeviceCreate`, the default), Windows removes the device when the process
  exits.
- **Fallback.** If the driver is missing or the display can't be created or captured,
  the backend captures physical display `CaptureConfig.display` instead (and fails only
  when there is none).

The host asks for one of these in `CaptureConfig.virtual_display`:

| Policy | Behavior |
| --- | --- |
| `.off` (default) | Physical display only. |
| `.when_headless` | A virtual display only when no physical display is active. |
| `.always` | Always stream a virtual display at the client's size. |

## Building

On Windows with Visual Studio 2022 and the WDK (the windows-2022 runner has both):

```powershell
pwsh platform/windows/idd/build.ps1            # x64; -Platform ARM64 for Arm
```

The package lands in `platform/windows/idd/out/package-x64/`. CI builds the same thing in
the `windows` workflow's "virtual display driver" job and uploads it as the
**moonsec-idd-x64** artifact.

Signing is a self-signed test certificate (`CN=moonsec IDD test`), which only machines
that trust it will load. Release signing (attestation signing through the Partner
Center, which needs an EV certificate) is Phase 7.

## Hardware check (Jeff's Windows GPU box)

One time, from an elevated PowerShell:

```powershell
bcdedit /set testsigning on     # then reboot
# Download the moonsec-idd-x64 artifact from the PR's windows workflow run, unzip, then in that folder:
.\install.ps1
```

Then, with the monitor still plugged in:

```powershell
$env:MOONSEC_REQUIRE = "idd"
zig build test-win --summary all
```

The three "virtual display" tests should pass: add/activate/re-mode/remove, the ping
watchdog, and the backend capturing a 1280x720 display and re-moding it to 1600x900.

Then unplug the monitor (or disable it in Display Settings so no physical display is
active), and stream with `virtual_display = .when_headless`: the host should create a
display at the client's size and the client should see a desktop. Kill the host process
(Task Manager) mid-stream: the display should disappear within about 3 seconds.

To remove the driver: `.\install.ps1 -Uninstall`, then `bcdedit /set testsigning off`.

## Not done yet

- HDR (IddCx 1.10 `IDDCX_ADAPTER_FLAGS_CAN_PROCESS_FP16`) and hardware cursor
  (`IddCxMonitorSetupHardwareCursor`): the cursor is drawn into the desktop image.
- Release signing (Phase 7) and an installer.
- A capture path straight from the swap chain (skipping Desktop Duplication), if DDA on
  an indirect display turns out to add latency on real hardware.
