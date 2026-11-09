# moonsec public C ABI v1

Status: **1.0 draft**, Nov 2026. Not frozen. Header: [include/moonsec.h](../include/moonsec.h).
Implementation: [app/abi.zig](../app/abi.zig). Tests and the ABI dump: [abi/](../abi/README.md).
Design context: [docs/design.md](../docs/design.md), "Architecture" (layer 1, the public C ABI).

The ABI lets an app in any language embed a moonsec host or client: create one with a key
store and relay settings, pair, connect by ticket, run sessions, exchange input and
clipboard text, and read telemetry. It is a thin layer over the same host and client apps
the `moonsec` tool runs ([app/apps.zig](../app/apps.zig)), so the tool and the ABI share one
code path.

## Names

Every symbol starts with `moonsec_` (functions, types) or `MOONSEC_` (constants). The
design doc's `host_*`, `client_*`, `session_*` and `telemetry_*` groups are
`moonsec_host_*`, `moonsec_client_*`, `moonsec_session_*` and `moonsec_session_telemetry`;
the prefix keeps them from colliding with other C libraries in the same process.

Constants are `#define`s and fields that hold them are fixed-width integers (`uint32_t`,
`int32_t`), never C `enum` types, whose size the C standard leaves to the compiler.

## Versioning

- `MOONSEC_ABI_VERSION` is what the caller compiled against; `moonsec_version()` is the
  library that loaded, both as `(major << 16) | (minor << 8) | patch`. A caller works with
  any library of the same major version.
- **Within 1.x the ABI only grows.** Allowed: new functions, new constants (new event
  types, input kinds, flags, status codes), and new fields at the end of a struct that
  starts with `struct_size`. Not allowed: removing or renaming anything, changing a
  function's signature, changing a field's offset, size or meaning, or reusing a value.
- **`struct_size`.** Every struct that crosses the boundary in either direction and may
  grow starts with `uint32_t struct_size`, which the caller sets to `sizeof` the struct it
  compiled with. The library reads only that many bytes of an input struct (fields past it
  are treated as zero, the default) and writes only that many bytes of an output struct.
  So an app built against 1.0 runs on a 1.3 library, and an app built against 1.3 runs on
  a 1.0 library as long as it leaves the 1.3 fields at zero. 1.0 refuses a struct smaller
  than 1.0's layout with `MOONSEC_ERR_INVALID`.
- **Frozen structs** (no `struct_size`): `moonsec_video_format`, `moonsec_input`,
  `moonsec_stage_stats`, `moonsec_display_info`. They are embedded in other structs or
  passed in arrays, so they never change; new needs get new structs.
- **Zero is the default.** Every config field means "default" at zero, so
  `memset(&cfg, 0, sizeof cfg); cfg.struct_size = sizeof cfg;` is a working config.
- `moonsec_features()` says what this build can do (`MOONSEC_FEATURE_*`): a function the
  build lacks still exists and returns `MOONSEC_ERR_UNSUPPORTED`, so the symbol table is
  the same for every build of 1.x.

The ABI dump test ([abi/](../abi/README.md)) enforces this: struct sizes and field
offsets, constant values and the function list are compared with the committed
`abi/abi-v1.txt`, and `abi/include_check.cpp` pins every function's signature.

## Handles and lifetimes

Four opaque handles: `moonsec_host`, `moonsec_client`, `moonsec_session` (one host-client
stream) and `moonsec_loopback` (an in-process simulated network).

- `*_create` returns a handle; `*_destroy` frees it and everything under it. Destroying a
  host or client closes its sessions (the peer gets a bye) and joins its threads.
- A session belongs to its host or client. It stays valid after it ends, so the app can
  read its final telemetry, until `moonsec_session_release` or the parent's destroy.
  Releasing an open session closes it first.
- Every function checks its handle and returns `MOONSEC_ERR_INVALID` for NULL or a handle
  of the wrong kind; `*_destroy(NULL)` does nothing. Using a handle after it is freed is
  undefined, as in any C API.

## Errors

Functions return `moonsec_status`: `MOONSEC_OK` (0) or a negative `MOONSEC_ERR_*`.
`moonsec_last_error` copies a one-line description of the calling thread's last failure
(thread-local, never cleared by success, not changed by `moonsec_last_error` itself).
`moonsec_status_string` names a code. The poll functions return 1 (an event), 0 (none) or
a negative status; `moonsec_session_state` returns a state or a negative status.

## Buffers and strings

- The caller owns every buffer. The library copies input strings during the call and never
  keeps a caller pointer (config strings included).
- String outputs take `(char *buf, size_t cap, size_t *len)`: `*len` is always set to the
  full length without the NUL; when `cap <= *len` the call returns
  `MOONSEC_ERR_BUFFER_TOO_SMALL` and writes nothing, so `(NULL, 0, &len)` asks for the size.
- Strings are UTF-8 and NUL-terminated; clipboard text is passed with an explicit length.
- Fixed-size `char` arrays in output structs (`peer_id`, tickets, PIN) are always
  NUL-terminated.

## Threads

- **Every function is thread-safe.** Each host and client has one mutex; every call on it,
  on its sessions, and its sessions' network stages take it.
- **iroh sessions run on the library's threads**: a network thread and a media thread per
  session (capture+encode on a host, decode+present on a client), as `HostApp/ClientApp
  .runThreaded` does for the `moonsec` tool, plus one accept thread per listening host.
- **Loopback sessions run in virtual time on the caller's thread**, inside
  `moonsec_loopback_advance`, so tests are deterministic and need no sleeps.
- **Callbacks** (`notify`, `on_frame`) run on a library thread, or inside
  `moonsec_loopback_advance`, possibly with the host's or client's mutex held. They must
  return quickly and must not call moonsec functions. They only signal the app (wake an
  event loop, copy a picture).
- `*_destroy` must not run at the same time as another call on the same handle.

## Events: polling, with a wake-up callback

Everything that happens asynchronously comes as an event on the host's or client's queue,
taken with `moonsec_host_poll_event` / `moonsec_client_poll_event` (optionally waiting up
to `timeout_ms`). An app that has its own event loop sets `notify` in the config: it is
called when the queue goes from empty to non-empty, and the app drains the queue from its
own thread.

Why polling rather than one callback per event: the app chooses the thread its code runs
on, no callback can re-enter the library and deadlock, and bindings for languages with
their own runtimes (Go, C#, Swift, JS via N-API) don't need to make foreign threads call
into managed code. The one data callback, `on_frame`, exists because a picture is only
valid during the call.

| Event | Who | Fields |
| --- | --- | --- |
| `SESSION_STARTED` | both | `session`, `format`, `width`, `height` |
| `SESSION_ENDED` | both | `session`, `code` = `MOONSEC_END_*` |
| `FORMAT_CHANGED` | both | `session`, `format`, `width`, `height` |
| `INPUT` | host with `MOONSEC_HOST_APP_INPUT` | `session`, `input` |
| `CLIPBOARD` | both, `MOONSEC_CLIPBOARD_APP` | `session` (text via `moonsec_session_clipboard_get`) |
| `PATH_CHANGED` | both | `session`, `code` 1 relayed / 0 direct |
| `PAIRED` | host | `peer_id`, `peer_name` |
| `PAIR_FAILED` | host | `peer_id`, `code` = `MOONSEC_PAIR_FAIL_*` |
| `PAIR_CLOSED` | host | `code` = devices paired in the window |
| `REFUSED` | host | `peer_id`; `code` 1 when refused for being busy |
| `INPUT_OWNER` | both, multi-user | `session` holding input (host: the member's; client: its own, NULL when another member or the host's user holds it); `code` = the holder's member id, 0 for the host's user |

`time_us` is the local monotonic clock (the loopback's virtual clock for loopback
sessions). Releasing a session drops its queued events.

## Hosts and clients

`moonsec_host_config` and `moonsec_client_config` carry:

- **Backend**: `MOONSEC_BACKEND_SYNTHETIC` (test pattern, passthrough codec; what tests
  and examples use) or `MOONSEC_BACKEND_SYSTEM` (the OS's capture, encoder, decoder and
  presenter; `MOONSEC_FEATURE_SYSTEM_BACKEND`). System sessions run in real time, so
  they need iroh: the loopback refuses them with `MOONSEC_ERR_UNSUPPORTED`. What each OS
  opens is in [app/system.zig](../app/system.zig):

  | OS | Host | Client |
  | --- | --- | --- |
  | Linux | ScreenCast portal + PipeWire capture, VAAPI then libx264 (NVENC when the Linux NVENC backend joins the picker), PipeWire audio, uinput | libavcodec (VAAPI, software), a Wayland + EGL window, PipeWire, evdev |
  | Windows | Desktop Duplication, NVENC then Media Foundation, WASAPI loopback, SendInput | Media Foundation / D3D11VA, a flip-model swapchain, WASAPI, Raw Input and XInput |
  | macOS | ScreenCaptureKit, VideoToolbox, CGEvent | VideoToolbox, a Metal window (made on the main thread, which must run its run loop), CoreAudio, GameController |

  A Linux host with a state directory keeps the portal's restore token there
  (`screencast.token`), so the user approves screen sharing once. Audio is left out when
  the OS has no audio service rather than failing the session.
- **Identity and key store**: `state_dir` holds the device key (`identity.key`, 0600)
  and the paired-device lists, as `moonsec --state-dir` does
  ([pairing-v0.md](pairing-v0.md), "Key storage"). NULL is the per-user default
  directory (`$MOONSEC_STATE_DIR`, else the OS config directory); `""` is a fresh key in
  memory and nothing saved. `moonsec_host_id` / `moonsec_client_id` give the endpoint ID.
- **Relay**: `relay_mode` is `DISABLED` (direct paths only, binds on loopback unless
  `bind_addr` says otherwise), `DEFAULT` (n0's public relays and discovery) or `CUSTOM`
  (`relay_url` only, with `relay_ca_pem` for a self-hosted relay's private CA).
- **Host stream settings**: preferred `codec` (0: the backend's best of HEVC, H.264, AV1),
  `fps`, start `bitrate_bps`, `display`, a capture size hint, and flags:
  `YUV444`, `TEN_BIT`, `NO_HDR` (format preferences for the per-client negotiation of
  [platform/format.zig](../platform/format.zig)), `RATE_CONTROL`, `LOSS_POLICY`,
  `NO_AUDIO`, `APP_INPUT`, `INSECURE_NO_PAIRING`.
- **Client settings**: the `codecs` to offer (mask; 0: all the decoder has), a maximum
  size, `NO_AUDIO`, `NO_OS_INPUT`, `FULLSCREEN`, `INSECURE_NO_PAIRING`, and the `on_frame`
  callback.

## Transports

**iroh** (`MOONSEC_FEATURE_IROH`). `moonsec_host_listen` binds and starts accepting;
`moonsec_host_ticket` gives a moonsec address ticket (`MOONSEC1:...`, the host's ID plus
its iroh address). `moonsec_client_connect(ticket)` dials, checks the host's ID against
the ticket, asks for admission ([pairing-v0.md](pairing-v0.md), "Admission"), and starts
the session. A bare iroh ticket also works (no ID check). Every connection goes through
admission; a host admits only clients on its allowlist, others get `MOONSEC_ERR_REFUSED`
and the host a `REFUSED` event, and a client connects only to hosts it paired with. The
`INSECURE_NO_PAIRING` flags turn this off on either side, for tests and labs only.
(`REQUIRE_PAIRED`, which used to opt in, is still accepted and now means the default.)
`moonsec_host_set_permissions(host, peer_id, MOONSEC_PERM_*)` sets what a paired client may
do besides watching: `INPUT` (its input is applied) and `CLIPBOARD`; new pairings get `ALL`.
It is saved with the allowlist and applies to the client's live session at once (the
clipboard: messages are dropped at once, the feature goes from the next channel).

**Loopback** (`MOONSEC_FEATURE_LOOPBACK`). `moonsec_loopback_create` makes an in-process
simulated network ([transport/sim.zig](../transport/sim.zig)) with a profile (`CLEAN`,
`LAN`, `WAN`); `moonsec_host_listen_loopback` and `moonsec_client_connect_loopback`
attach one host and one client; `moonsec_loopback_advance` runs both for a stretch of
virtual time. For tests and for trying the API without a network.

## Pairing

`moonsec_host_pair_begin` opens a window (length, number of devices, QR and/or PIN) and
returns the QR ticket (with a one-time secret), the address ticket and the PIN to show.
The host's accept thread serves pairing requests next to admission, so the host keeps
streaming while the window is open. `moonsec_client_pair(ticket, pin)` runs the client
side and blocks until it is done. Both ends save the other to their allowlists in
`state_dir`. Protocol: [pairing-v0.md](pairing-v0.md).

## Sessions

- **State**: `CONNECTING` (host: waiting for hello; client: waiting for config),
  `STREAMING`, `ENDED`. End reasons: `CLOSED` (this side), `PEER_CLOSED` (bye from the
  peer), `TIMEOUT`, `TRANSPORT`, `FAILED` (no common codec, backend failure).
- **Input** goes client to host: `moonsec_session_send_input` with a `moonsec_input`
  (key by USB HID usage, mouse button, scroll, relative or absolute motion, gamepad state
  in XInput layout). It rides the input stream with redundancy
  ([input-clock-v0.md](input-clock-v0.md)). The host injects it through its backend, or
  with `APP_INPUT` hands it to the app as `INPUT` events (for an app that drives its own
  content, such as a game).
- **Clipboard** ([control-v0.md](control-v0.md)): `MOONSEC_CLIPBOARD_SYSTEM` syncs the OS
  clipboard; `MOONSEC_CLIPBOARD_APP` gives the app `moonsec_session_clipboard_set` (its
  copy, sent to the peer) and `moonsec_session_clipboard_get` (the peer's latest), with a
  `CLIPBOARD` event when the peer's text arrives.
- **Format**: `moonsec_session_format` gives the negotiated codec, chroma, bit depth,
  colour space and size; `FORMAT_CHANGED` reports a change.
- **Reconnect** (iroh): a session outlives a dropped connection. When the connection
  closes, or nothing arrives from the host for 2 s, the client dials the host again from
  the ticket, checks it is the same host and asks for admission again, as on its first
  connection. The host's accept loop admits the new connection and hands it to the live
  session of the same client endpoint (it does not count against `max_clients`), a
  multi-user member included. The session stays `STREAMING` throughout, with no events;
  `reconnects` in the telemetry counts the new connections. A session ends only after
  60 s with no connection (`TIMEOUT`), or when the host refuses the client on a redial
  (the client's session then times out). A close still sends a bye, so the peer ends
  at once. The timeouts are fixed in this draft.

## Telemetry

`moonsec_session_telemetry` fills a snapshot: state, end reason, format and size, encoder
bitrate, pacing rate, RTT, relayed/stalled/clock-synced flags, frame counters (sent or
presented, lost, keyframes, refreshes, retransmits, FEC parity, freezes and the longest
gap), input events, path changes and reconnects, and per-stage latency over the recent
window (count, min, mean, p50, p95, p99, max) for `CAPTURE`, `ENCODE`, `NETWORK`,
`DECODE`, `PRESENT`, `TOTAL` (glass to glass) and `INPUT`. Host-side stages are filled on
the host's session, client-side ones on the client's; cross-clock stages need the clock
offset (`MOONSEC_TELEMETRY_CLOCK_SYNCED`). `stages` has 8 slots so 1.x can add one stage
without growing the struct; `stage_count` says how many are filled.

## Multi-user

A host with `max_clients` above 1 (up to 32) streams to that many clients at once over
iroh ([multi-user-v0.md](multi-user-v0.md), [app/multi_host.zig](../app/multi_host.zig)):
one capture and one encode, sent to every member, in the best codec and format all of
them decode. Each member is its own `moonsec_session` on the host, with its own events,
telemetry and clipboard; a client past the cap is refused as busy (`REFUSED`, `code` 1).
The stream starts with the first member and stops when the last one leaves; the next
client starts it again. Loopback sessions are always one client.

- Input follows the owner policy: one member holds input at a time (the first member
  that joins gets it), other members' input is dropped. `moonsec_host_give_input(host,
  session)` hands it to a member, or back to the host's user with NULL;
  `moonsec_session_request_input` (client) asks for it, which the roster shows to the
  owner and the host. `INPUT_OWNER` reports every change on both sides. With
  `APP_INPUT`, each `INPUT` event names the member it came from (NULL for the key
  releases the host sends when input changes hands).
- Every member may take input (a per-device permission in the allowlist is a
  follow-up), and the policy is always `owner`; `everyone` and `view_only` are not
  exposed yet.
- Clients always advertise the multi-user feature, so they get rosters from any
  multi-user host.

## Displays

`moonsec_host_displays` lists the host's displays ([display-v0.md](display-v0.md)).
`index` is the backend's display id, the value `moonsec_host_config.display` takes;
`hdr` is 0 until backends report it, and `name` is at most 24 bytes from the backend.

- While a session streams, the list is the one its capture last reported (polled about
  once a second, so a plugged-in display shows up).
- With none streaming, the synthetic backend lists its display at the configured size.
  The OS capture backends do not list displays yet (`UNSUPPORTED`): opening one only to
  ask would open its encoder and input device.
- `MOONSEC_FEATURE_DISPLAYS` is set in every build.

Not exposed yet (open questions on naming and events): the client's view of the host's
list and its display select, and an event when the list changes. Multi-user hosts refuse
selects.

## Linking

- `zig build abi` installs `include/moonsec.h`, `lib/libmoonsec.a` and the shared
  `libmoonsec.so` / `.dylib` / `.dll`, with iroh. The shared library carries everything;
  a static link also needs `libiroh_shim.a` (installed next to it) and the shim's system
  libraries (see `linkShim` in [build.zig](../build.zig)).
- `zig build abi-sim` builds `libmoonsec-sim` without iroh (loopback only), which needs no
  Rust; the ABI tests link it.
- `-Dabi-system=true|false` puts the OS backends into both libraries. On by default for
  Windows targets and on macOS hosts; on Linux it needs the libraries listed in
  [platform/client/build.zig](../platform/client/build.zig) and
  [platform/host/linux/build.zig](../platform/host/linux/build.zig), so it is off by
  default there. A library built with them links the OS's media libraries (Linux:
  libavcodec, libva, Wayland, EGL, GLES, PipeWire, D-Bus).
- On Windows, define `MOONSEC_SHARED` before including the header when linking the DLL.

## Implemented in this draft

| Area | Status |
| --- | --- |
| Version, features, errors, strings, struct_size | done |
| Host and client on the synthetic backend | done |
| System backends (`MOONSEC_BACKEND_SYSTEM`) | done: built in with `-Dabi-system` (default on for Windows and macOS). Linux runs end to end in `zig build test-abi-system` under a headless Weston (portal capture, libx264, software decode, EGL window); Windows cross-compiles; macOS is untested here (no SDK) |
| Loopback transport | done |
| iroh: listen, ticket, connect, admission (pairing required unless `INSECURE_NO_PAIRING`) | done |
| Pairing (QR and PIN), key store in `state_dir` | done |
| Reconnect after a dropped connection | done over iroh (client redials with admission, the host hands the connection to the live session; one-client and multi-user hosts); `abi/test_reconnect.c` |
| Events, notify, frame callback | done |
| Input both ways incl. gamepads | done |
| Clipboard (app and system) | done |
| Codec and format preferences | done (per-client negotiation, #36) |
| Telemetry and per-stage latency | done |
| Multi-user (#38) | done over iroh (owner policy, every member may control); `abi/test_multi.c`, and on the OS backends in `test-abi-system -- multi` |
| Displays (#37) | listing: `moonsec_host_displays` (synthetic backend, and any backend that lists while streaming); selecting from the client is not exposed |

## Freeze

The header is marked 1.0 (this document's status, the `-draft` suffix dropped from
`moonsec_version_string`, and `abi/abi-v1.txt` frozen) when:

1. Jeff has reviewed the header.
2. The Phase 5 PRs it wraps have merged (#31, #36 and #38 have; #37 has not) and their
   features are wired or confirmed as declared above.
3. At least one system backend runs through the ABI on real hardware.

Open questions for that review:

1. **Prefix.** `moonsec_host_create` rather than the design doc's bare `host_create`.
2. **Events.** Polling with a `notify` wake-up, rather than one callback per event type.
3. **Key store.** Only `state_dir` now. Keychain or DPAPI stores, or an app-supplied key
   store (load/store callbacks), would be a 1.x config field.
4. **Pictures.** The system backend presents in its own window; `on_frame` hands the app
   the picture too. Is a "render into my surface" mode (the app passes a window or
   texture) needed for 1.0, or is it a 1.x addition?
5. **Multi-user policy.** Only the owner policy, and every member may control. Should
   the config pick the policy (`everyone`, `view_only`) and a per-device "may control"
   in 1.0, or later?
