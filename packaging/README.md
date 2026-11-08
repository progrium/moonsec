# packaging: installers, signing and notices

Phase 7, workstream 7G. One manual workflow, [release.yml](../.github/workflows/release.yml),
builds the installers for every host platform, signs them when the secrets are present,
and puts complete third-party notices in each package. Unsigned builds work without any
secrets, so the workflow doubles as the packaging test.

| Platform | Output | Built by | Signed with |
| --- | --- | --- | --- |
| Linux x86_64, aarch64 | `.deb`, `.rpm`, `.tar.gz` | [linux/build.sh](linux/build.sh) | not signed (repositories sign metadata); `SHA256SUMS` on the release |
| Windows x64, ARM64 | `.msi` with the `moonsec` service | [windows/build.ps1](windows/build.ps1) (WiX) | Authenticode: Azure Trusted Signing or a `.pfx` ([windows/sign.ps1](windows/sign.ps1)) |
| macOS universal | `.pkg` (apps + login agent), `.dmg` (apps) | [macos/build.sh](macos/build.sh) | Developer ID + hardened runtime, notarized and stapled |
| IddCx driver | attestation CAB, Microsoft-signed package | [windows/driver/attestation.ps1](windows/driver/attestation.ps1) | EV certificate (CAB), then Microsoft (driver) |

Version: the workflow's `version` input, else `git describe` on a `v*` tag, else
`0.0.0+<commit>` ([version.sh](version.sh)).

## What each package installs

**Linux.** `/usr/bin/moonsec`; the host launcher `/usr/lib/moonsec/moonsec-host`; the
systemd *user* unit `moonsec-host.service` (capture and input need the user's graphical
session, so it is not a system service); the udev rule `60-moonsec-uinput.rules`, which
gives the user at the seat `/dev/uinput` through logind's `uaccess` tag; and
`modules-load.d/moonsec-uinput.conf`, which loads `uinput` at boot. The postinst loads the
module and reloads udev so input works without a reboot. Enable the host per user:

```sh
systemctl --user enable --now moonsec-host
```

State: the device key and paired clients in `$XDG_CONFIG_HOME/moonsec` (the same place
`moonsec pair` uses); the host ticket and the **portal restore token** in
`$XDG_STATE_HOME/moonsec`. The launcher exports `MOONSEC_PORTAL_RESTORE_TOKEN` with that
token's path for 7A's PipeWire capture to read and write, so a restarted host reuses the
screen-share grant instead of asking again. Extra host options go in
`~/.config/moonsec/host.env` as `MOONSEC_HOST_ARGS=...`.

Dependencies come from the binary: `dpkg-shlibdeps` writes the `.deb`'s `Depends`, rpm
finds `Requires` from the ELF. Release builds target glibc 2.31.

**Windows.** `Program Files\moonsec\moonsec.exe`, `moonsec-svc.exe` and the notices.
The MSI registers `moonsec-svc.exe` as the auto-start `moonsec` service (LocalSystem). The
service captures nothing itself: Desktop Duplication, WASAPI loopback and SendInput only
work in the user's session, so it starts `moonsec.exe` there as the logged-on user, restarts
it when it exits, and moves it when the console session changes (logon, logoff, user
switch), the split Sunshine uses ([windows/svc/main.zig](windows/svc/main.zig)). The agent's
command line is `HKLM\SOFTWARE\moonsec\AgentCommandLine` if set, otherwise
`moonsec.exe peer iroh host --relay --state-dir %APPDATA%\moonsec ...`. Logs:
`%ProgramData%\moonsec\service.log` and `agent.log`. With `-IddDir`, the MSI also carries
the IddCx driver and adds it with `pnputil` (removed again on uninstall).

**macOS.** `moonsec Host.app` (no Dock icon) and `moonsec.app` (client) in
`/Applications`, both universal. The `.pkg` also installs
`/Library/LaunchAgents/com.github.progrium.moonsec.host.plist`, which starts the host in
each user's login session and keeps it running; the `.dmg` has just the two apps. Screen
Recording and Accessibility are TCC grants the user gives on first use; they stick across
updates only when every build is signed with the same Developer ID.

Today both apps, the Windows agent and the Linux launcher run the `moonsec` tool that is on
`main` (`peer iroh host`, one paired session per run, restarted by the unit, service or
launch agent). The real hosts and clients come with PRs #15/#27/#29/#30 and 7C; each then
only changes which binary or command a package runs.

## Notices

[notices/gen.sh](notices/gen.sh) writes one `THIRD_PARTY_NOTICES.md` per package:
libopus (BSD-3-Clause, statically linked), Zig's standard library and compiler-rt (MIT),
every vendored header directory under `third_party/` (NVENC, AMF, oneVPL once #15/#35
merge: its `LICENSE*` or the header's own licence comment), anything passed with
`--extra NAME=FILE`, the system libraries a Linux binary loads (listed, not shipped), and
the shim's Rust crates from `cargo-about` (`shim/about.toml`). It fails when a piece is
missing rather than shipping partial notices.

**FFmpeg check.** On Linux, for each `libavcodec`/`libavutil`/`libavformat` a binary
needs, it reads the installed library's build configuration and stops if it was built
with `--enable-gpl`. Debian and Ubuntu build theirs that way (checked on Ubuntu 24.04:
`libavcodec.so.60` has `--enable-gpl`). So once the Linux client from #30 links the
system `libavcodec`, the Linux packages fail this check until one of these is chosen:
ship against an LGPL-only FFmpeg build (bundled as shared libraries, with its source
offer), decode through VA-API without libavcodec, or accept GPL for the Linux client
(depends on the project licence, still open). `MOONSEC_ALLOW_GPL_FFMPEG=1` skips the stop
for local experiments.

**Project licence.** Not decided yet (open question 6). Packages say
`LicenseRef-moonsec-undecided` until `MOONSEC_LICENSE` in [version.sh](version.sh) is
set to the chosen SPDX id.

## Signing secrets

Set these as repository Actions secrets. Each platform signs when its set is complete and
builds unsigned otherwise; the `require_signing` input makes a missing set an error.

| Secret | For |
| --- | --- |
| `AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET`, `TRUSTED_SIGNING_ENDPOINT`, `TRUSTED_SIGNING_ACCOUNT`, `TRUSTED_SIGNING_PROFILE` | Windows, Azure Trusted Signing (preferred) |
| `WINDOWS_CERT_PFX` (base64 `.pfx`), `WINDOWS_CERT_PASSWORD` | Windows, a traditional Authenticode certificate |
| `MACOS_CERT_P12` (base64 `.p12` with *Developer ID Application* and *Developer ID Installer*), `MACOS_CERT_PASSWORD` | macOS code and installer signing |
| `MACOS_NOTARY_KEY` (base64 `.p8`), `MACOS_NOTARY_KEY_ID`, `MACOS_NOTARY_ISSUER` | macOS notarization (App Store Connect API key) |
| `PARTNER_CENTER_TENANT_ID`, `PARTNER_CENTER_CLIENT_ID`, `PARTNER_CENTER_CLIENT_SECRET` | IddCx attestation submission (`attestation.ps1 -Submit`) |

## IddCx driver signing

Windows loads a kernel-visible driver package only when Microsoft signed it. Attestation
signing is the route without HLK testing:

1. Build the driver per architecture with `platform/windows/idd/build.ps1` (PR #39).
2. `pwsh packaging/windows/driver/attestation.ps1 -Cab -Package out\package-x64 -Package out\package-ARM64 -Out moonsec-idd.cab -Thumbprint <EV cert>`
   makes the CAB and signs it with the EV certificate. EV keys sit on a token or HSM, so
   this step runs where the token is.
3. `pwsh packaging/windows/driver/attestation.ps1 -Submit -CabFile moonsec-idd.cab -Out signed`
   creates the Partner Center product and submission, uploads, waits and downloads the
   Microsoft-signed package. Not yet run against a real account.
4. Zip the signed x64 package somewhere the workflow can fetch it and pass the URL as the
   `idd_package_url` input; the MSI then carries and installs the driver.

## ViGEmBus

The virtual gamepad path (#26) needs the ViGEmBus driver. Its code is BSD-3-Clause, so
redistributing the signed installer is allowed with its notice, but the project is retired
upstream. The packages don't bundle it for now; the host works without it (no virtual
gamepads). Bundling it later is a WiX Burn bundle chaining the ViGEmBus installer before
the MSI, plus `--extra "ViGEmBus=LICENSE"` for the notices.

## Shim release

App builds still compile the Rust shim, because `build.zig.zon` pins no shim release. To
drop Rust from app builds (the workflow then uses `-Dshim=prebuilt` automatically):

```sh
git tag shim-v0.1.0 && git push origin shim-v0.1.0   # needs Jeff's OK
# Actions -> shim -> Run workflow on the shim-v0.1.0 tag (publishes the release)
shim/pin-release.sh shim-v0.1.0                       # pins it in build.zig.zon; commit that
```

## Running it

```sh
# Linux, in a container or VM (needs rpm and dpkg-dev for all three formats)
zig build install-moonsec -Doptimize=ReleaseSafe
packaging/notices/gen.sh --package linux --bin zig-out/bin/moonsec --out dist/linux-notices.md
packaging/linux/build.sh --bin zig-out/bin/moonsec --notices dist/linux-notices.md --out dist
sudo packaging/linux/test-install.sh dist/moonsec_*.deb dist/moonsec-*.rpm

# Windows service only (cross-compiles from Linux; unit tests run on the host)
cd packaging/windows/svc && zig build test && zig build -Dtarget=x86_64-windows -Doptimize=ReleaseSafe
```

The cloud test (`test-install.sh`) installs the `.deb`, checks the files, the unit and the
notices, pairs a client with the installed binary, starts the host through the installed
launcher exactly as the unit runs it, and has the client stream from it for 5 s over iroh.
The release workflow runs the same test on both Linux architectures, installs and
uninstalls the MSI on Windows (checking that the service starts), and checks the macOS
`.pkg` contents and the `.dmg`'s app signature.

## Hardware check for Jeff

After a signed run of `release.yml` (all secrets set, `require_signing` on), on each machine:

```sh
# Windows (admin PowerShell): install, then stream from another device paired with `moonsec pair`
msiexec /i moonsec-<v>-windows-x64.msi; Get-Service moonsec; Get-Content $env:ProgramData\moonsec\service.log
# macOS: install, grant Screen Recording + Accessibility when asked, then stream
sudo installer -pkg moonsec-<v>-macos-universal.pkg -target / && spctl -a -vv "/Applications/moonsec Host.app"
# Linux: install, enable the user unit, then stream
sudo apt install ./moonsec_<v>_amd64.deb && systemctl --user enable --now moonsec-host
```
