# Refine stream v0: lossless tiles

Status: draft, Nov 2026. Implemented in `core/refine/` (`qoi.zig`, `wire.zig`, `host.zig`,
`client.zig`); the session glue is in `app/host_session.zig` and `app/client_session.zig`.

Video codecs blur small text even at good bitrates. Lossless tiles fix that for the part of
the screen that holds still: the host sends exact pixels of still 64×64 cells, coded with
QOI, in bandwidth the video does not use; the client draws them on a layer over the video
and drops each one in the same present that shows the video changing under it. The video
alone is always a correct picture; tiles only ever make it sharper.

Tiles are the third of three steps for sharp text (the design "Lossless tiles and idle
refinement for sharp remote text"): idle refinement re-codes a still frame at a lower QP
(video flag `refine`, [wire-v0.md](wire-v0.md)), regional QP maps sharpen still blocks
inside a moving frame, and tiles make what still holds still exact.

## Negotiation

The client asks for tiles in its `hello` ([wire-v0.md](wire-v0.md), `control_fast` kind
32): the 28-byte form adds `u32 tiles`, a bit set of the tile codecs it decodes. v0 has one,
bit 0, QOI. A client sets it only when its presenter can composite a tile layer
(`api.Presenter.tiles`). The 16- and 24-byte hellos mean `tiles` = 0.

A host that has tiles turned on sends them to a client whose `tiles` has bit 0 set, and
never otherwise. There is no answer: a client learns that the host sends tiles from the
first `damage` message it receives, and until then keeps its layer hidden and sends no tile
acks. (The design also named control-channel feature bit 40 in type range `0x0600`; that
bit is reserved for tiles in [control-v0.md](control-v0.md) but not used in v0, since the
datagram `hello` already carries the capability on every transport, including the browser.)

Tiles are off for an HDR10 stream in v0.

## Cells, epochs and frames

The stream's picture is cut into a grid of 64×64 cells in row-major order, from the top
left; cells on the right and bottom edges are cut to the picture. Cell `c` is at
`(c mod cols, c div cols)` with `cols = ceil(width / 64)`. A grid has at most 65 535 cells
(`u16`), which covers 8K.

Every message names the stream config it belongs to by its `epoch`
([display-v0.md](display-v0.md), the `config` message): a new config (size, codec,
display) starts a new grid, and a receiver drops any message of another epoch. Frame ids
are the video's 32-bit frame ids, compared with wraparound.

A tile carries `since`: the video frame id from which its cell has looked like this. Its
pixels are the cell's captured pixels at that frame, never the decoded video's.

## Datagrams

Host to client on stream 6, `refine` (envelope as in [wire-v0.md](wire-v0.md)); the reply
on `control_fast` kind 4. All integers little-endian; uvarints are LEB128.

### `refine` kind 1: tile piece

One piece of an encoded tile. A tile of `total_len` bytes is cut into `ceil(total_len /
1100)` pieces of 1100 bytes, the last holding the rest.

| Offset | Size | Field | Meaning |
| ---: | ---: | --- | --- |
| 0 | 4 | `epoch` | Stream config. |
| 4 | 2 | `cell` | Cell index. |
| 6 | 4 | `since` | Frame id from which the cell looks like this. |
| 10 | 1 | `codec` | 1: QOI. |
| 11 | 1 | `piece` | Index of this piece, below `pieces`. |
| 12 | 1 | `pieces` | Pieces of the tile, 1–16. |
| 13 | 2 | `total_len` | The encoded tile's length; the same in every piece. |
| 15 | n | `data` | The piece: 1100 bytes, or the rest for the last piece. |

A piece that breaks any of these rules is malformed and dropped: `pieces` from 1 to 16,
`piece < pieces`, `pieces = ceil(total_len / 1100)`, `data` exactly as long as the rule
says. A client assembles pieces by (`cell`, `since`); pieces of a newer `since` for the same
cell replace an older assembly.

The tile is a whole QOI image (qoiformat.org, version 1.0): the 14-byte header with the
cell's width and height and 3 channels, the ops, the 8-byte end marker. A tile whose header
does not match its cell's size, that runs short or long, or that decodes to more pixels than
the cell is dropped. Decoded pixels are opaque (alpha 255).

### `refine` kind 2: damage

Which cells the video frames changed. The host sends one for every frame it encodes,
twice (before the frame's first shard and after its last), whether or not it sends tiles at
that moment.

| Offset | Size | Field | Meaning |
| ---: | ---: | --- | --- |
| 0 | 4 | `epoch` | Stream config. |
| 4 | 4 | `frame_id` | The newest frame the message covers. |
| 8 | 2 | `cells` | Cells in the host's grid; a client whose grid differs drops it. |
| 10 | 1 | `flags` | Bit 0 `all`: every cell. Bit 1 `union`: a `span` follows. |
| 11 | var | `span` | uvarint, with `union` only: 1 to 2³¹−1. |
| | 1 | `count` | Bitmaps, without `all` only: 1–3, exactly 1 with `union`. |
| | var | bitmaps | `count` run-length coded bitmaps of `cells` bits. |

Two forms:

- **Per frame** (no `union`): bitmap 0 is the cells frame `frame_id` changed, bitmap 1
  those of `frame_id − 1`, bitmap 2 those of `frame_id − 2`, as many as the host still has.
  A lost damage message is covered by the next two.
- **Union** (`union`): one bitmap, the cells changed by any frame in (`frame_id − span`,
  `frame_id`]. `all` instead of a bitmap: every cell (the host's history does not reach
  back that far, or the bitmap did not fit). This is the answer to a resync request.

A bitmap is coded as runs over the cells in order: uvarint lengths, alternating clean
(first) and changed, summing to `cells`. Only the first run may be 0. A message with bytes
left over is malformed.

A host that does not know what changed in a frame (the capture API reports nothing, and it
could not compare the pixels) sends that frame's bitmap with every cell set.

### `control_fast` kind 4: tile ack (client to host)

| Offset | Size | Field | Meaning |
| ---: | ---: | --- | --- |
| 0 | 4 | `epoch` | Stream config. |
| 4 | 1 | `flags` | Bit 0 `reset`: the client cleared its layer, send everything again. Bit 1 `resync`: answer with a union damage message. |
| 5 | 4 | `covered_to` | With `resync`: the newest frame up to which the client has every frame's damage. |
| 9 | 1 | `count` | Entries, 0–120. |
| 10 | 7·n | entries | `u16 cell`, `u32 since`, `u8 held` (bit 0). |

`held` 1: the client completed this tile and will show it while it is valid. `held` 0: it
dropped the tile without its cell having changed (a union damage message could not tell
whether the change came before or after `since`), so the host sends it again if the cell
still looks the same. A host answers `resync` with a union damage message from the frame
after `covered_to` to its newest frame (`all` if `covered_to` is from before its first
frame or beyond its history). It ignores acks of another epoch and entries for cells
outside its grid.

## Validity

A tile of cell `c` with `since` `s` shows at a present of frame `p` only while

1. `p` is at or after `s`, and
2. no frame in (`s`, `p`] damaged `c`.

The client keeps each frame's damage until it has presented that frame. At each present it
applies the damage of every frame up to the one it presents, in order, and then:

- a shown tile whose cell was damaged is cleared in **this** present;
- a complete tile becomes visible in the first present at or after its `since` whose
  frames since `s` did not damage its cell; a tile whose cell was damaged after `s` is stale
  and dropped.

If the damage of a frame being presented is missing (lost twice and not covered by later
messages), the client hides the layer for that present (the video alone is right), asks
for a resync, and asks again every 8 presents. If no answer arrives within 30 presents it
clears the layer and sends a `reset`. A union answer applies at once to its whole span; a
tile it cannot place before or after the change is dropped and acked with `held` 0.

This is what keeps a tile from ever showing over content that changed: the video frame
that carries the change and the damage message that clears the tile arrive for the same
present. The synthetic presenter checks it (every tile pixel drawn is compared with the
video under it) in every sim scenario, under loss, outages, path changes and multi-user
fan-out.

## Host behaviour

These are the reference implementation's choices; a client does not depend on them.

- **Which cells.** A cell becomes a candidate once still for 18 frames (300 ms at 60 fps),
  or 64 for a cell that changed 3 or more times in the last 64 frames (a caret, a clock).
  Flat cells (one colour) are skipped: video gets them right. Cells QOI cannot get below
  half their raw RGB size are skipped as photo-like. The rest go nearest the pointer
  first, then by edge count. At most 8 cells are read and encoded per frame; encoded
  tiles are cached (16 MB) until their cell changes.
- **Damage.** From the capture API where it reports it (PipeWire `SPA_META_VideoDamage`,
  DXGI dirty and move rects, ScreenCaptureKit dirty rects), otherwise from a hash of every
  cell of the captured frame.
- **When to send.** Only into spare bandwidth: a token bucket refilled at 90% of
  (target rate − measured video rate), with bursts of at most 7200 bytes per round; only
  when the pacer has nothing queued and no frame is still leaving; not while the rate
  controller is backing off, the stream is paused or stalled, or on a relayed path below
  2 Mbit/s. Tile datagrams are counted by the rate controller for the link's load but not
  as video (no acked-rate or train samples).
- **Resends.** A tile not acked within rtt + one frame + 20 ms is sent again if its cell
  still looks the same.
- **Several clients.** One engine per encode, shared by every member of a multi-user
  session (one capture read, one QOI encode); each member has its own budget, acks and
  resends. A member who joins later gets the cached tiles of still cells.

## Client behaviour

- A presenter draws, per present: the video, then the tile layer alpha-blended over it
  (when the update says visible), then any overlay. Tiles are never baked into the
  decoder's frames (a C ABI `on_frame` picture never includes them).
- The layer is the stream's size and is drawn with the same transform as the video, with
  no filtering at 1:1, so it stays aligned with the picture under it.
- The browser client decodes into RGBA and composites on a second OffscreenCanvas with
  image smoothing off.

## Changes

- v0 (Nov 2026): first draft.
