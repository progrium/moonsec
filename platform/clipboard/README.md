# System clipboard backends

Clipboard sync over the control channel ([spec/control-v0.md](../../spec/control-v0.md),
"Clipboard") reads and writes the system clipboard through `Clipboard` (`root.zig`). The app
polls `changeCount` from its network stage (every 250 ms by default), reads the text when it
moved, and writes what the peer copied (`app/clipsync.zig`). Text only for now; UTF-8 with
LF line breaks.

| Backend | File | Change detection | Tested |
| --- | --- | --- | --- |
| Win32 | `win32.zig` | `GetClipboardSequenceNumber` | `windows-2022` runner |
| NSPasteboard | `macos.zig`, `pasteboard.m` | `changeCount` | `macos-15` runner |
| Wayland data-control | `linux_wayland.c` | `selection` events | headless sway 1.9 (`wlr-data-control-unstable-v1`), container and CI |
| X11 | `linux_x11.c` | XFixes selection notify | Xvfb, container and CI; interop with `xclip` checked by hand |
| In memory | `root.zig` (`Memory`) | a counter | tests, the sim |

`System.open()` picks the backend for the build target. On Linux it tries Wayland first
(`ext-data-control-v1`, else `wlr-data-control-unstable-v1`) and falls back to X11; the
Linux backend links libwayland-client, libX11 and libXfixes, so it is built only with
`-Dlinux-clipboard` (Ubuntu: `apt install libwayland-dev libx11-dev libxfixes-dev`). The
two Linux backends run a thread with their own display connection so they answer other
apps' paste requests at once and fetch each new selection as soon as it is announced.

Not covered yet: `ext-data-control-v1` has only been compiled (no compositor here has it;
wlroots 0.19+, KWin and others do), GNOME/Mutter (no data-control protocol, so X11 through
Xwayland), X11 INCR *sending* (text larger than one request, roughly 16 MB with
BIG-REQUESTS, is refused; receiving INCR works), images and HTML.

`protocols/` holds the two protocol XMLs and the code `wayland-scanner` 1.22 generated from
them (`client-header`, `private-code`), so builds need no scanner.

## Tests

    zig build test-clipboard                        # Windows, macOS
    zig build test-clipboard -Dlinux-clipboard      # Linux, under X11 or a Wayland compositor with data-control

It writes through one handle and reads through a second (on Linux a second display
connection, so the text crosses between clients), both ways, including a 200 KB text. It
skips when no clipboard is reachable.

## Hardware check (Jeff)

Copy and paste both ways between the Mac and the Windows box, over iroh with the synthetic
video stream. On the Mac (host):

    zig build install-moonsec
    zig-out/bin/moonsec peer iroh host --ticket-file ticket.txt --relay --clipboard --seconds 300

Copy `ticket.txt` to the Windows box, then there (client):

    zig build install-moonsec
    zig-out\bin\moonsec.exe peer iroh client --ticket-file ticket.txt --relay --clipboard --seconds 120

Within the two minutes: copy text on the Mac and paste on Windows, then the other way, and
try a multi-line text and some emoji. Both ends print a `control:` line at the end with the
copies sent and applied. Swap the roles to check the other direction of the session too.
