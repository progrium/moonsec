# moonsec wire protocol v0

Status: draft, Nov 2026. Reference implementation: [`core/proto`](../core/proto) (round-trip
and malformed-input tests live next to each message). Design context: [docs/design.md](../docs/design.md),
"Media pipeline".

v0 covers the datagram envelope, stream IDs, the video shard header, frame acks and
transport-wide feedback. Audio, input, NACK, clock sync and the reliable control streams
get their own sections as they land; until then their datagrams use the envelope below
with message kinds owned by the module that defines them.

## Conventions

- All integers are **little-endian** and unsigned unless noted.
- Timestamps are **microseconds** on the sender's monotonic clock. Host and client clocks
  are not synchronized; the clock module estimates the offset.
- Sequence numbers and frame IDs are `u32` counters that **wrap**. Compare them with
  serial-number arithmetic: `a` is before `b` when `(i32)(a - b) < 0` (wrapping
  subtraction), valid while the two are less than 2^31 apart (`proto.seqBefore`).
- `varint` is unsigned LEB128, minimal form only (no trailing zero groups, at most 10
  bytes). `svarint` is a signed value zigzag-mapped (`(v << 1) ^ (v >> 63)`) then written
  as a varint.
- Reserved bits are written as 0. Receivers ignore reserved flag bits unless a section
  says otherwise.
- Every datagram is one message. Decoders reject truncated messages and, for messages
  with no length prefix, trailing bytes.
- Media datagrams stay at or under **1200 bytes**; video datagrams are 1150 bytes by default
  (8 envelope + 40 header + 1102 payload), which fits any QUIC datagram path.

## Envelope

Every datagram starts with 8 bytes:

| Offset | Size | Field | Meaning |
| ---: | ---: | --- | --- |
| 0 | 1 | `version` | Protocol version, `0`. Any other value: drop the datagram. |
| 1 | 1 | `stream` | Stream ID (below). `0` is invalid: drop. |
| 2 | 1 | `kind` | Message kind within the stream. |
| 3 | 1 | `flags` | Reserved, 0. |
| 4 | 4 | `seq` | Transport-wide sequence number. |

`seq` is one counter per direction, shared by all streams, incremented for **every**
datagram sent, retransmits included. Transport feedback reports arrivals by `seq`, so the
host's rate controller sees every packet regardless of stream.

New streams and new kinds do not bump `version`. A receiver that does not know a stream or
kind skips the datagram.

### Stream IDs

| ID | Stream | Direction | Notes |
| ---: | --- | --- | --- |
| 0 | invalid | | Never sent. |
| 1 | `video` | host → client | |
| 2 | `audio` | host → client | Frames and RS parity: [audio-v0.md](audio-v0.md). |
| 3 | `input` | client → host | Kinds defined with the input module. |
| 4 | `control_fast` | both | Small latency-critical control: frame acks, feedback. |
| 5 | `mic` | client → host | Reserved; not in v1. |
| 6–255 | | | Unassigned. |

Reliable control (session setup, clipboard, display config, file transfer) runs on a QUIC
stream, not datagrams: [control-v0.md](control-v0.md).

## Video

### `video` kind 1: shard

A frame is split into **slices** (the encoder's slices, so packetizing starts before the
frame finishes encoding). Each slice is split into one or more **FEC groups**. Each group
has `data_shards` data shards followed by `parity_shards` Reed-Solomon parity shards. One
shard per datagram. Header, 40 bytes, after the envelope:

| Offset | Size | Field | Meaning |
| ---: | ---: | --- | --- |
| 0 | 4 | `media_seq` | Video packet number, one per distinct shard. NACKs refer to it; a retransmit reuses it (with a new envelope `seq`). |
| 4 | 4 | `frame_id` | Increments by one per encoded frame. |
| 8 | 1 | `slice` | Slice index in the frame. |
| 9 | 1 | `slice_count` | Slices in the frame, ≥ 1. |
| 10 | 1 | `group` | FEC group index in the slice. |
| 11 | 1 | `group_count` | FEC groups in the slice, ≥ 1. |
| 12 | 1 | `shard` | Index in the group: `[0, data_shards)` data, then parity. |
| 13 | 1 | `data_shards` | K, ≥ 1. |
| 14 | 1 | `parity_shards` | M, ≥ 0. 0 when FEC is off (NACK mode, relayed paths). |
| 15 | 1 | `flags` | See below. |
| 16 | 4 | `group_len` | Bytes of encoded data in the group, before padding. |
| 20 | 8 | `capture_us` | Host clock when the frame was captured. |
| 28 | 4 | `encode_us` | Microseconds from capture to the encoder returning the frame (the encode-done timestamp, as a delta). |
| 32 | 8 | `ltr_token` | Long-term reference token; 0 unless `flags.ltr`. |
| 40 | | payload | Shard bytes, to the end of the datagram. |

Flags (bit 0 = LSB):

| Bit | Name | Meaning |
| ---: | --- | --- |
| 0 | `keyframe` | IDR; decodable with no prior state. |
| 1 | `ltr_refresh` | References only a long-term reference the client has acked: decodable after a gap. This is the recovery frame a stuck client waits for. |
| 2 | `ltr` | This frame is a long-term reference; the client acks `ltr_token` after decoding it. |
| 3 | `retransmit` | Re-sent shard (NACK response). |
| 4–7 | | Reserved; ignored on receive. |

**Shard sizes.** Let `S = ceil(group_len / data_shards)`. Every data shard carries `S`
bytes except the last data shard, which carries `group_len − S·(data_shards − 1)` (at
least 1; a header where this is ≤ 0 is invalid). Parity shards carry `S` bytes, computed
over the data shards zero-padded to `S`. The payload length must equal this exactly;
receivers drop the datagram otherwise.

**FEC.** Parity is a systematic Reed-Solomon code over GF(2^8) (`core/media/fec.zig`:
Cauchy rows, scaled so the first parity shard is the XOR of the data shards). The host
sends a group's data shards, then its parity shards, each with its own `media_seq`, so a
group's shards hold `media_seq` from `first` to `first + data_shards + parity_shards − 1`
and `first = media_seq − shard`. Every shard of a group carries the same `data_shards`,
`parity_shards` and `group_len`; receivers drop shards that disagree with the first one
they saw. Any `data_shards` of the group's shards rebuild it. `parity_shards` can change
from group to group (the host sizes it from measured loss, `core/media/policy.zig`).

**Validity.** Receivers drop a shard unless `slice < slice_count`, `group < group_count`,
`shard < data_shards + parity_shards`, `data_shards ≥ 1`, `group_len ≥ 1` and, when `ltr`
is clear, `ltr_token = 0`.

**Why the LTR token is in our header.** VideoToolbox returns it as a sample attachment, not
in the bitstream, so the client can only learn it from us (design doc, S8).

**Client behaviour on loss.** When a frame cannot be completed, the client stops decoding
and drops every later frame until one with `keyframe` or `ltr_refresh` arrives, and says
so in its frame acks. Apple's HEVC decoder breaks permanently if fed frames after a gap.

## Control-fast

### `control_fast` kind 1: frame ack (client → host)

Tells the host which long-term references the client has decoded, and whether it is stuck
waiting for recovery. Sent when an `ltr` frame decodes and when a gap is detected; may be
repeated.

| Offset | Size | Field | Meaning |
| ---: | ---: | --- | --- |
| 0 | 1 | `flags` | Bit 0 `recovery_needed`; bit 1 `want_idr` (answer with an IDR, not an LTR refresh: the client has no keyframe yet, or an `ltr_refresh` frame failed to decode; only with `recovery_needed`); others reserved. |
| 1 | 4 | `gap_frame` | First frame the client could not decode; must be 0 unless `recovery_needed`. |
| 5 | 1 | `count` | Number of entries, 0–255. |
| 6 | 12·count | entries | `frame_id u32`, `ltr_token u64` per decoded long-term reference. |

No trailing bytes. On `recovery_needed` the host encodes its next frame against the newest
acked long-term reference (`ltr_refresh`), or sends an IDR if it has none or `want_idr` is
set. The client repeats the request if no recovery frame arrives within about RTT + 2 frames;
the host treats repeats for a gap it answered less than about one RTT ago as copies in flight,
and falls back to an IDR after repeated refreshes for the same gap (`core/recovery`).

### `control_fast` kind 2: transport-wide feedback (client → host)

Per-packet arrival times for a run of envelope `seq` numbers (TWCC-style), sent every
5–10 ms. The host's delay-gradient estimator and frame-train capacity estimate run on it.

| Offset | Size | Field | Meaning |
| ---: | ---: | --- | --- |
| 0 | 2 | `feedback_seq` | Increments per feedback message, wraps; lets the host see lost feedback. |
| 2 | 4 | `base_seq` | Envelope `seq` of the first packet covered. |
| 6 | 2 | `count` | Packets covered, `base_seq … base_seq+count−1` (wrapping), ≥ 1. |
| 8 | 8 | `ref_time_us` | Client clock; base for the first delta. |
| 16 | ceil(count/8) | bitmap | Bit `i` (LSB first in each byte) set if packet `base_seq+i` arrived. Padding bits are 0. |
| … | | deltas | One `svarint` per set bit, in sequence order: arrival time in µs minus the previous received packet's arrival (the first minus `ref_time_us`). |

Deltas are signed so reordered arrivals encode naturally. A message whose deltas take any
arrival below 0 or past 2^64−1, whose delta count differs from the bitmap's set bits, or
that has trailing bytes is invalid. At ~90 µs spacing a delta is 2 bytes, so 100 packets
cost about 230 bytes.

A packet not reported as received in one message may be reported in a later one (late
arrival); the host takes the latest report.

### `control_fast` kind 3: NACK (client → host)

Asks the host to resend video shards by `media_seq`. Defined in `core/media/nack.zig`.

| Offset | Size | Field | Meaning |
| ---: | ---: | --- | --- |
| 0 | 6·n | entries | `base u32`, `mask u16` per entry, n ≥ 1. Names `media_seq` `base`, and `base+1+i` for each set bit `i` (LSB first). |

A message whose length is not a positive multiple of 6 is invalid. The host resends each
named shard it still holds and that is younger than its retransmit age limit, with the
same shard header plus `flags.retransmit` and a new envelope `seq`; it ignores the rest.
The client sends the first NACK for a gap after a reorder wait (adaptive, 1–5 ms by
default) and repeats it every RTT plus slack while the shard's frame is still pending.

### `control_fast` kinds 18 and 32–34: session (both directions)

Session setup on datagrams, until the reliable QUIC control streams land. Defined in
`app/wire.zig`. Every field is little-endian; reserved bytes are 0.

| kind | name | direction | payload |
| ---: | --- | --- | --- |
| 18 | `clock_report` | client → host | `i64 offset_us` (host clock − client clock, from clock sync), `i64 error_bound_us`. 16 bytes. The host uses it to time input injection against capture. |
| 32 | `hello` | client → host | `u32 nonce`, `u8 codecs` (bit 0 H.264, 1 HEVC, 2 AV1, 3 passthrough), 3 reserved, `u32 max_width`, `u32 max_height` (0 = any), `u8 formats[4]` (per codec: H.264, HEVC, AV1, passthrough; bits below), `u8 display` (bit 0: the display is in an HDR10 mode), 1 reserved, `u16 peak_nits` (display peak luminance, cd/m², 0 = unknown). 24 bytes. |
| 33 | `config` | host → client | `u32 nonce` (echo), `u8 codec` (1 H.264, 2 HEVC, 3 AV1, 250 passthrough), `u8 slices`, `u16 fps`, `u32 width`, `u32 height`, `u64 bitrate_bps`, `u8 chroma` (0 4:2:0, 1 4:4:4), `u8 bit_depth` (8 or 10), `u8 color` (0 SDR BT.709, 1 HDR10), `u8 flags` (bit 0: HDR metadata follows), `hdr_metadata` (28 bytes, zero when flag 0 is clear). 56 bytes; `fps`, `slices`, `width`, `height` non-zero. |
| 34 | `bye` | both | `u8 reason` (0 done, 1 quit, 2 error). |

Format bits, one byte per codec in `hello`'s `formats` (platform/format.zig `Formats`):
bit 0 8-bit 4:2:0, 1 10-bit 4:2:0, 2 8-bit 4:4:4, 3 10-bit 4:4:4, 4 HDR10 (the decoder
reads BT.2020/PQ and the presenter shows or tone-maps it, at whichever 10-bit formats it
has); bits 5–7 reserved, ignored. A codec set in `codecs` with no format bits decodes
8-bit 4:2:0 only. A client advertises what its decoder decodes **and** its presenter can
show; `display` says whether showing HDR10 as HDR is possible now.

`hdr_metadata` is SMPTE ST 2086 plus CTA-861.3 in HEVC SEI units: `u16 x, u16 y` for the
R, G, B primaries then the white point (units of 0.00002), `u32 max_luminance`, `u32
min_luminance` (0.0001 cd/m²), `u16 max_cll`, `u16 max_fall` (cd/m², 0 unknown).

A `config` is valid only with a known chroma and colour, 8 or 10 bits, HDR10 at 10 bits
only, and metadata only with HDR10; a client drops any other as malformed. Both messages
are still accepted at their original lengths (16 and 24 bytes), meaning no format bits
and 8-bit 4:2:0 SDR.

The host picks the codec and format (`format.negotiate`): among the codecs both sides
have, in the host's order of preference, the format with HDR10 (only when the captured
display is in HDR mode, the client's display is too and the user allows it), then 4:4:4
(when the host prefers it), then 10-bit (when the host prefers it or HDR10 needs it);
the first feature outranks the later ones and ties go to the codec order. A `hello` with
a new nonce, or with different capabilities, can change the choice; the host then
reconfigures its encoder and starts again from an IDR.

A host streaming one encode to several clients (spec/multi-user-v0.md) picks the best
format every client takes, and can send a client a new `config` with a different codec,
format or size mid-session, when another client joins or leaves. The client then
reconfigures its decoder and drops frames until the next IDR, which the host sends right
after; if none arrives within its recovery retry timeout, it asks for one.

The client sends `hello` every 100 ms until a `config` with its nonce arrives. The host
answers every `hello` with `config`; a `hello` with a nonce it has not seen starts a new
session from a keyframe. Either side leaves by sending `bye` three times, 20 ms apart; a
side that hears nothing from the other for 5 s ends the session.

## Changes

- v0 (Nov 2026): first draft.
- v0 (Nov 2026): session messages (`hello`, `config`, `bye`, `clock_report`) for the Phase 2 apps.
- v0 (Nov 2026): `hello` carries per-codec format bits and the display's HDR mode (24
  bytes); `config` names chroma, bit depth, colour space and HDR metadata (56 bytes). The
  16- and 24-byte forms are still accepted.
- v0 (Nov 2026): a `config` can change the stream mid-session (multi-user hosts).
