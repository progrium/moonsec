# moonsec control channel v0

Status: draft, Nov 2026. Reference implementation: [`core/control`](../core/control)
(framing, hello and clipboard state, with round-trip, malformed-input and chunking tests).
Design context: [docs/design.md](../docs/design.md), "Media pipeline" ("Control: reliable
QUIC streams for session setup, clipboard, display config and file transfer").

The datagram protocol ([wire-v0.md](wire-v0.md)) carries media, input and latency-critical
feedback. Everything that must arrive, in order, and is not latency-critical runs on the
**control channel**: one bidirectional QUIC stream per connection. This document defines
its framing, the message type registry that other features add to, the channel handshake
and the clipboard messages.

## Conventions

As in [wire-v0.md](wire-v0.md): integers are **little-endian** and unsigned unless noted,
reserved bits and bytes are written as 0, text is UTF-8.

## The stream

- The **client opens** the stream (`open_bi`) as soon as its connection is up, and writes
  `hello` at once (QUIC opens streams lazily: the host's `accept_bi` returns when the first
  bytes arrive). The host accepts the first bidirectional stream the client opens after
  pairing/admission and answers with its own `hello`. Pairing and admission
  ([pairing-v0.md](pairing-v0.md)) use their own short-lived streams before it.
- Each side sends `hello` as its first message and nothing else until it has sent it. A
  side may send further messages right after its own `hello`, without waiting for the
  peer's, but must not send a message of a feature the peer has not advertised (below), so
  in practice feature messages wait for the peer's `hello`.
- The stream lives as long as the connection. When a reconnecting client replaces its
  connection (wire-v0's `conn_epoch`), it opens a new control stream on the new connection
  and both sides start over with `hello`; state that must survive (the clipboard's clock)
  is kept by the endpoints, not the stream.
- A side that ends the session finishes its send side after its last message. A side that
  sees a protocol error sends `close` (if it can), then resets the stream with application
  error code 1. The datagram session keeps running without the control channel; features
  that need it turn off.

## Framing

Every message is a frame:

| Offset | Size | Field | Meaning |
| ---: | ---: | --- | --- |
| 0 | 4 | `length` | Bytes after this field: 4 + body length. At least 4. |
| 4 | 2 | `type` | Message type (registry below). 0 is invalid. |
| 6 | 1 | `version` | Version of this message type's body, starting at 0. |
| 7 | 1 | `flags` | Bit 0 `required` (below); bits 1–7 reserved, ignored on receive. |
| 8 | | body | `length − 4` bytes. |

**Size.** Each side advertises the largest frame it accepts (`max_message`, counted from
the `type` field, so the `length` value) in `hello`; it is at least **65 536**. A sender
never sends a larger frame. A frame whose `length` is below 4 or above the receiver's
`max_message` is a protocol error: the receiver cannot resynchronize a byte stream, so it
closes the channel. Before the peer's `hello` arrives a sender assumes 65 536.

**Unknown types and versions.** A receiver that does not know a `type`, or knows it only at
a lower `version`, skips the frame if `required` is clear and closes the channel
(`close` reason `unsupported`) if it is set. Senders set `required` only on messages whose
loss would leave the two sides disagreeing about session state.

**Extending a message.** A compatible change appends fields to the body and keeps the
`version`; receivers ignore trailing bytes they do not know (unlike datagrams). A change
that older receivers would misread bumps `version`, and is only sent to a peer that
advertised it (through a feature bit or a version list in `hello`).

**No interleaving.** Frames are written whole and in order. A large message (a clipboard
image, a file) delays everything behind it, which is why bulk transfers are split into
chunks well under `max_message` (file transfer, when it lands, will also get its own
stream).

## Type registry

`type` is a `u16`, allocated in blocks of 256 per feature so features can be built in
parallel without collisions. A feature defines its messages in its own section of this
document (or its own spec, linked here) and claims its block below.

| Range | Feature | Spec |
| ---: | --- | --- |
| `0x0000` | invalid | |
| `0x0001`–`0x00ff` | channel: `hello`, `close` | this document |
| `0x0100`–`0x01ff` | clipboard | this document |
| `0x0200`–`0x02ff` | displays: list, select, mode changes (Phase 5B) | reserved |
| `0x0300`–`0x03ff` | multi-user sessions: join, leave, input handoff (Phase 5D) | reserved |
| `0x0400`–`0x04ff` | codec, chroma and colour negotiation (Phase 5F) | reserved |
| `0x0500`–`0x05ff` | file transfer | reserved |
| `0x0600`–`0xefff` | unassigned | |
| `0xf000`–`0xffff` | experiments; never shipped enabled | |

Feature bits in `hello` follow the same split (below).

## Channel messages

### `0x0001` hello (both directions, first message)

| Offset | Size | Field | Meaning |
| ---: | ---: | --- | --- |
| 0 | 1 | `role` | 0 host, 1 client. A side that receives its own role closes the channel. |
| 1 | 3 | reserved | 0. |
| 4 | 4 | `max_message` | Largest frame this side accepts (see Framing), ≥ 65 536. |
| 8 | 8 | `features` | Feature bits (below). |

Sent with `version` 0 and `required` set. A body shorter than 16 bytes is a protocol error.
The channel is **up** once both `hello`s have been exchanged; each side then knows the
peer's `max_message` and features. A feature bit says "I understand and accept this
feature's messages": a side only sends a feature's messages to a peer that advertised its
bit (the channel's own messages are always allowed).

Feature bits (bit 0 = LSB):

| Bit | Feature |
| ---: | --- |
| 0 | `clipboard_text`: the clipboard messages below, `text/plain` format. |
| 1 | `clipboard_image`: reserved (PNG). |
| 2 | `clipboard_html`: reserved. |
| 3–7 | clipboard, reserved. |
| 8–15 | displays (5B), reserved. |
| 16–23 | multi-user (5D), reserved. |
| 24–31 | codec negotiation (5F), reserved. |
| 32–39 | file transfer, reserved. |
| 40–63 | unassigned. |

A side clears a feature's bit to refuse that feature's messages (see Clipboard, "Policy").

### `0x0002` close (both directions)

| Offset | Size | Field | Meaning |
| ---: | ---: | --- | --- |
| 0 | 1 | `reason` | 0 done, 1 protocol error, 2 unsupported (an unknown `required` message), 3 too large. |
| 1 | | `text` | Optional UTF-8 detail for logs, to the end of the frame, at most 256 bytes. |

The last message a side sends on the channel. Sent with `required` clear.

## Clipboard

Clipboard sync keeps the host's and the client's system clipboards equal: when either
side copies, the other side's clipboard gets the same content. v0 syncs **text only**
(UTF-8); the format byte and the `clipboard_image` and `clipboard_html` bits are reserved
for images and HTML.

### `0x0100` clip_set (both directions)

| Offset | Size | Field | Meaning |
| ---: | ---: | --- | --- |
| 0 | 8 | `clock` | Lamport clock of this copy (below), ≥ 1. |
| 8 | 1 | `format` | 1 `text/plain;charset=utf-8`. 2 `image/png` and 3 `text/html` are reserved. |
| 9 | 3 | reserved | 0. |
| 12 | | `data` | The content, to the end of the frame. Empty = the clipboard holds nothing syncable. |

Text uses **LF** line breaks on the wire; platforms that use CRLF (Windows) convert on read
and write.

Sent with `version` 0 and `required` clear. A receiver drops (and counts) a `clip_set`
whose `format` it does not know, whose text is not valid UTF-8, whose `data` is longer
than its own text cap, or whose `clock` is 0.

**Size cap.** Each side has a text cap, 1 MiB by default and never more than the peer's
`max_message` − 16. A side whose clipboard holds more text than the cap sends nothing for
that copy (the peer keeps its old content) and counts it.

### Ordering: latest wins

Each side keeps a Lamport clock `L` (starting at 0) and the stamp `(clock, origin)` of the
content its clipboard holds now, where `origin` is the role that copied it. Stamps compare
by `clock`, then by `origin` with **client > host** (the user is at the client, so a tie
goes to what they copied there).

- **Local copy.** The side's system clipboard changed and the change is not an echo
  (below): `L = L + 1`; the content's stamp is `(L, own role)`; send `clip_set` with
  `clock = L`.
- **Receive.** `L = max(L, clock)`. If `(clock, peer role)` is newer than the current
  content's stamp, write `data` to the system clipboard and take its stamp; otherwise drop
  the message as stale.

When both sides copy at about the same time, each receives the other's `clip_set`; both
apply the same comparison to the same two stamps, so both end up holding the same content.

On a reconnect both sides keep `L` and the current stamp. When a new channel comes up,
each side re-sends its current content with its existing stamp if it copied it itself
(origin = own role) since the app started, so a copy made while the connection was down
is not lost; the peer applies it only if it is newer than what it holds.

The content a side's clipboard holds when the app starts is not a copy: it is remembered
(stamp clock 0), never sent, so connecting does not overwrite the peer's clipboard.

### Echo suppression

Writing received content to the system clipboard makes the OS report a clipboard change,
which must not be sent back (the two sides would ping-pong). A side remembers the content it
last wrote from a `clip_set` (a 64-bit hash and length suffice) and treats a local change
whose content matches it as an echo: it sends nothing and does not bump `L`. A platform
backend that can tell its own writes apart (a change counter it reads right after writing)
may suppress them earlier, but the content check is what the protocol relies on.

### Policy

Clipboard sharing is set per direction (host → client, client → host). A side that does
not want the peer's clipboard clears `clipboard_text` in `hello`, and the peer then never
sends `clip_set`; a side that does not want to share its own clipboard keeps the bit (if it
receives) and never sends `clip_set`. Clipboard contents never go through logs or
telemetry, only their sizes.

## Changes

- v0 (Nov 2026): first draft: framing, type registry, `hello`, `close`, clipboard text.
