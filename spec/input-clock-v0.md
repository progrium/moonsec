# Input and clock sync, wire v0

Status: draft, Nov 2026. Reference implementations: [`core/input`](../core/input) and
[`core/clock`](../core/clock). Conventions (little-endian, µs timestamps, wrapping `u32`
sequence numbers, one message per datagram, no trailing bytes) are those of
[wire-v0.md](wire-v0.md). Every message below follows the 8-byte envelope.

## Input stream (`stream` = 3)

| kind | name | direction |
| --- | --- | --- |
| 1 | `events` | client → host |
| 2 | `ack` | host → client |

### `events`

Every packet is self-sufficient: it repeats the unacknowledged events, carries motion as
running totals, and carries full gamepad and held-key state, so any one packet that
arrives brings the host up to date.

| Size | Field | Notes |
| ---: | --- | --- |
| 4 | `packet_seq` | Per-packet counter. The host drops a packet not after the newest it processed. |
| 8 | `send_time` | Client clock. |
| 4 | `first_seq` | Event sequence number of the first event below. |
| 1 | `n_events` | Events below (the newest unacked, at most 32 by default). |
| 4 + 4 | `motion_x`, `motion_y` | `i32` running totals of relative motion; wrap. The host applies the difference from the last totals it saw. |
| 1 | `flags` | Bit 0: `abs` follows. Bit 1: held-key list incomplete (more than 16 held). |
| 2 + 2 | `abs_x`, `abs_y` | Only with flag bit 0. Latest absolute pointer position, 0–65535 across the display. |
| 1 | `buttons_held` | Bit `b−1` set while mouse button `b` is down. |
| 1 + 2n | `n_keys`, keys | HID usages currently held, `n_keys` ≤ 16. |
| 1 | `pad_mask` | Bit `i` set: pad `i` (0–3) is connected and its snapshot follows; higher bits must be 0. |
| 16 each | pad snapshot | `u32 buttons`, `i16 lx ly rx ry`, `u16 lt rt`. |
| 24 each | event | See below. |

Event (24 bytes): `u8 kind`, `u8 flags` (bit 0: down), `u16 code`, `i32 a`, `i32 b`,
`u32 age` (µs before `send_time`), `i32 motion_x`, `i32 motion_y` (the totals when the
event happened, so motion before a click is applied before it).

| kind | event | fields |
| --- | --- | --- |
| 1 | key | `code` = HID usage, `down` |
| 2 | mouse button | `code` = button (1-based), `down` |
| 3 | scroll | `a`, `b` = horizontal, vertical, 120 per notch |
| 4 | absolute move | `a`, `b` = position; sent before a click so it lands where the user clicked |

Unknown event kinds are skipped. After applying the new events, the host reconciles its
held keys and buttons with the lists in the packet, releasing anything whose release was
lost beyond the redundancy window.

### `ack`

| Size | Field | Notes |
| ---: | --- | --- |
| 4 | `next_seq` | The host has applied every event before this one; the client stops repeating them. |

## Clock sync (control-fast stream, `stream` = 4)

| kind | name | direction | payload |
| --- | --- | --- | --- |
| 16 | `clock_ping` | client → host | `u32 seq`, `i64 t1` (client send time) |
| 17 | `clock_pong` | host → client | `u32 seq`, `i64 t1` (echoed), `i64 t2` (host receive time), `i64 t3` (host send time) |

The client stamps the pong's arrival `t4` and computes, per round trip,
`offset = ((t2 − t1) + (t3 − t4)) / 2` (host minus client) and
`rtt = (t4 − t1) − (t3 − t2)`. Kinds start at 16 to stay clear of proto's own
control-fast kinds. The estimator itself is described in `core/clock/root.zig`.
