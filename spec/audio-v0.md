# Audio stream, wire v0

Status: draft, Nov 2026. Reference implementation: [`core/audio`](../core/audio); codec
binding: [`codec/opus`](../codec/opus). Conventions (little-endian, µs timestamps, wrapping
`u32` sequence numbers, one message per datagram, no trailing bytes) are those of
[wire-v0.md](wire-v0.md). Every message below follows the 8-byte envelope, `stream` = 2.

| kind | name | direction |
| --- | --- | --- |
| 1 | `frame` | host → client |
| 2 | `parity` | host → client |

## Codec

Opus (libopus 1.5.2), 48 kHz, stereo, 10 ms frames, VBR, about 128 kbit/s. In-band FEC is
on in libopus' mode 2 (`OPUS_SET_INBAND_FEC(2)`): speech-like content goes to SILK or
hybrid mode and carries a low-bitrate copy of the previous frame (LBRR); music stays in
CELT, which has no FEC, because mode 1 would move music to hybrid mode at a large quality
cost (sim: 19.4 dB waveform SNR in CELT against 6.9 dB in hybrid). The light Reed-Solomon
parity below covers what in-band FEC does not.

A frame carries exactly one Opus packet. Receivers must accept any Opus frame size; the
reference jitter buffer assumes a fixed size per stream (480 samples by default).

## `frame`

| Size | Field | Notes |
| ---: | --- | --- |
| 4 | `seq` | Audio frame counter, +1 per frame. Wraps. |
| 8 | `capture_us` | Host clock at the frame's first sample. |
| 2 | `samples` | Samples per channel at 48 kHz (480 = 10 ms). Not zero. |
| 1 | `flags` | Bit 0: the packet carries in-band FEC for frame `seq − 1` (for Opus, `opus_packet_has_lbrr`). Other bits 0. |
| rest | `packet` | The codec packet, 1–1000 bytes. |

## `parity`

Reed-Solomon parity (the code of [`core/media/fec.zig`](../core/media/fec.zig): systematic,
Cauchy, GF(2^8)) over the bodies of `k` consecutive frames, a body being everything after
the envelope (frame header and packet), each zero-padded to the longest. Any `k` of the
`k + m` shards rebuild every body. The host sends the group's parity right after its last
frame.

| Size | Field | Notes |
| ---: | --- | --- |
| 4 | `first_seq` | `seq` of the group's first frame. |
| 1 | `k` | Frames in the group, 1–8. |
| 1 | `m` | Parity shards in the group, 1–2. |
| 1 | `index` | This shard, 0 to `m − 1`. |
| 2 × k | `lens` | Body length of each frame in the group, 16–1015, to trim recovered bodies. |
| rest | `shard` | Parity bytes; length equals the largest of `lens`. |

Default `k` = 2, `m` = 1: about 50% more audio bitrate (≈ 80 kbit/s), and the first frame of
a group is rebuilt one frame after it was due to arrive, inside a 20 ms jitter buffer with
10 ms frames. Larger `k` recovers too late for that buffer. A sender may set `m` = 0 and
send no parity.

## Receiver behavior (reference)

The jitter buffer plays one frame per device frame on the client's clock (audio is not
the clock master). It holds the fastest-arriving frames for `target` = 20 ms and plays, in
order of preference: the frame; the next frame's in-band FEC if the frame is missing and
the next frame's `flags` bit 0 is set; or codec concealment. Frames that arrive after
their slot are discarded. Once per second it compares the fastest frames' buffering with
the target and, after two seconds more than half a frame off, decodes and discards one
frame or adds one concealed frame, which absorbs clock drift. A frame more than 32 frames
ahead of playout restarts the buffer.
