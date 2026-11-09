# moonsec displays and mid-stream configs v0

Status: draft, Nov 2026. Reference implementation: [`core/display`](../core/display)
(message codecs, size fitting and the client's config schedule, with round-trip,
malformed-input and wrap tests) and the sessions in [`app/`](../app) (end to end over the
sim in `app/test.zig`). Design context: [docs/design.md](../docs/design.md), "Platform
backends" and "Rate control" (the ladder's resolution step needs a mid-stream config).

This document covers three things:

1. The host's **display list**, so a client can show the host's monitors.
2. **Display selection**: the client picks a display, or caps the stream's size and frame
   rate, and can change its mind mid-stream.
3. **Mid-stream configs**: the stream's size, frame rate or display changes without
   tearing the session down, whether the client asked (a select), the host's rate ladder
   stepped, or the host's display changed mode under the capture.

## Transport

The bodies below are meant for the control channel ([control-v0.md](control-v0.md)),
registry block `0x0200`–`0x02ff`, feature bit 8 (`displays`). Until the apps run their
session on the control channel, the same bodies ride `control_fast` datagrams
([wire-v0.md](wire-v0.md), "Session"), with the retries described here:

| Message | Control type | Datagram kind | Direction |
| --- | ---: | ---: | --- |
| `display_list` | `0x0200` | 35 | host → client |
| `select_display` | `0x0201` | 36 | client → host |
| `stream_config` | `0x0202` | 33 (`config`) | host → client |
| `config_ack` | `0x0203` | 37 | client → host |

On the control channel the acks and repeats are unnecessary (the stream is reliable and
ordered), but `stream_config` keeps its `epoch` and `first_frame`, because video frames
travel on datagrams and can overtake it.

All integers are little-endian; reserved bytes are 0.

## `display_list` (host → client)

| Offset | Size | Field | Meaning |
| ---: | ---: | --- | --- |
| 0 | 4 | `gen` | Changes whenever the list does (hotplug, mode change, rename). |
| 4 | 4 | `current` | `id` of the display being streamed. |
| 8 | 1 | `count` | Entries, 0–16. |
| 9 | 3 | reserved | |
| 12 | 52·count | entries | Below. |

Entry, 52 bytes:

| Offset | Size | Field | Meaning |
| ---: | ---: | --- | --- |
| 0 | 4 | `id` | The backend's id for the display (what `select_display` names). |
| 4 | 4 | `width` | Current mode, pixels, non-zero. |
| 8 | 4 | `height` | Non-zero. |
| 12 | 4 | `refresh_mhz` | Refresh rate in millihertz; 0 unknown. |
| 16 | 4 | `x` | `i32`: top-left corner on the host's desktop. |
| 20 | 4 | `y` | `i32`. |
| 24 | 1 | `flags` | Bit 0 `primary`; others reserved. |
| 25 | 1 | `name_len` | 0–24. |
| 26 | 2 | reserved | |
| 28 | 24 | `name` | UTF-8, `name_len` bytes used, the rest 0. Hosts cut long names at a character boundary. |

A list whose length is not `12 + 52·count`, with `count > 16`, a zero width or height, a
`name_len` over 24 or a name that is not UTF-8 is invalid. Ids are stable while a display
stays connected; a display that comes back may get another id.

The host sends the list with every `stream_config` and whenever it changes. Hosts poll
their backend's list about once a second (`Capture.displays`); a backend without a list
sends none, and the client treats the stream as the host's only display.

## `select_display` (client → host)

| Offset | Size | Field | Meaning |
| ---: | ---: | --- | --- |
| 0 | 4 | `request` | Increments per new choice (from 1, wraps, skipping 0). |
| 4 | 4 | `display` | Display `id`, or `0xffffffff` to keep the current one. |
| 8 | 4 | `max_width` | Cap, pixels; 0 none. |
| 12 | 4 | `max_height` | Cap; 0 none. |
| 16 | 2 | `max_fps` | Cap; 0 none. |
| 18 | 2 | reserved | |

20 bytes. The host streams that display at the largest size with the display's aspect
ratio that fits the caps and does not exceed the display (even dimensions), and at
`min(host fps, max_fps)`. At the display's own size the capture follows the display's mode;
below it the capture (or encoder) scales. The caps also become the top of the rate ladder.

The client repeats the newest select every 100 ms until a `stream_config` with `request`
at least that value arrives. The host ignores repeats of a request it applied or holds. If
the host cannot apply it (unknown display, capture failed) it keeps streaming as before and
still answers with a `stream_config` carrying the `request`, so the client stops repeating;
the client sees that `display` did not change.

In a multi-user session (spec/multi-user-v0.md) every member gets the same encode, of
the display the host picked, so the host refuses every `select_display` this way. Who
may pick the shared display is not decided yet.

## `stream_config` (host → client)

The datagram `config` message ([wire-v0.md](wire-v0.md)), now 72 bytes:

| Offset | Size | Field | Meaning |
| ---: | ---: | --- | --- |
| 0 | 4 | `nonce` | The client's hello nonce (datagrams only). |
| 4 | 1 | `codec` | 1 H.264, 2 HEVC, 3 AV1, 250 passthrough. |
| 5 | 1 | `slices` | ≥ 1. |
| 6 | 2 | `fps` | ≥ 1. |
| 8 | 4 | `width` | ≥ 1. |
| 12 | 4 | `height` | ≥ 1. |
| 16 | 8 | `bitrate_bps` | The encoder's bitrate when this config was sent (informational). |
| 24 | 32 | format | Chroma, bit depth, colour space, flags and HDR metadata (wire-v0). |
| 56 | 4 | `epoch` | 0 for the session's first config, then +1 per change (wraps). |
| 60 | 4 | `first_frame` | Video `frame_id` of the first frame encoded with this config. |
| 64 | 4 | `display` | `id` of the display streamed. |
| 68 | 4 | `request` | Newest `select_display.request` the host applied or refused; 0 none. |

The 24- and 56-byte forms (no `epoch` onward) are still accepted, read as epoch 0.

**Host.** A change takes effect at the next frame: the host reconfigures capture and
encoder, bumps `epoch`, sets `first_frame` to the next `frame_id`, and encodes that frame
as an IDR with the video flag `new_config` (wire-v0, bit 4). Nothing before it is a valid
reference, so the host forgets its acked long-term references. It sends the config at once
(with the display list) and repeats both about every 100 ms plus an RTT until a
`config_ack` covers them. A new config starts only after at least one frame of the previous
one went out: frames carry no epoch, so two configs starting at the same frame would be
ambiguous to a client that heard only the first.

**Client.** Configs can arrive before or after their first frame, and frames before
`first_frame` still use the old one. The client keeps the current config and up to four
pending ones (`display.Schedule`); each frame out of reassembly uses the newest config
whose `first_frame` is at or before its id. When the next frame to decode has a different
codec, size or frame rate than the decoder was configured for, the client configures the
decoder and presenter again first (the window stays; it shows the new size). A frame with
`new_config` whose config has not arrived makes the client drop it and the frames after it
(recovery asks for a keyframe as for any loss) until a frame whose known config starts at
or after it, so a frame is never decoded with the wrong size.

## `config_ack` (client → host)

| Offset | Size | Field | Meaning |
| ---: | ---: | --- | --- |
| 0 | 4 | `nonce` | The client's hello nonce. |
| 4 | 4 | `epoch` | Newest config epoch the client has (applied or pending). |
| 8 | 4 | `display_gen` | `gen` of the newest display list it has; 0 before any. |

12 bytes. Sent for every `stream_config` and `display_list` that arrives.

## Platform

`Capture` gains an optional `displays(out) -> count` method ([platform/api.zig](../platform/api.zig));
`CaptureConfig.display` takes a `DisplayInfo.id`. A captured frame whose size differs from
what `start` returned means the display changed mode: the app configures the encoder for
it and the session sends a new config. The synthetic backend has N fake displays,
`setMode` and `addDisplay`, so all of this runs in `zig build test-app` and `moonsec sim
--displays 320x180,256x192 --switch 1000:1`.

## Changes

- v0 (Nov 2026): first draft.
