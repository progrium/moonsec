# Regional refine (encoder QP maps)

Stage 2 of "Lossless tiles and idle refinement for sharp remote text". Idle refinement
(core/still) sharpens the screen when all of it is still; regional refine does the same per
block inside the normal stream, so a ticking clock, a blinking caret or a video in one
corner no longer keeps the text next to it soft. It is Selkies' paint-over ledger fitted to
our single encode with LTRs: one encoder and one QP map per frame, no encoder per stripe.

## How it works

- **Damage.** Capture reports what changed (`api.CapturedFrame.damage`, folded into a
  `core.damage.Grid`). Unknown damage (null) counts as everything changed, so a backend
  without damage simply never refines regionally.
- **Ledger** ([core/qpmap](../core/qpmap/root.zig)). One entry per encoder block (16×16 for
  H.264, the CTB for HEVC: the encoder says which in `caps.qp_map.block`). Damage makes a
  block coarse. A block still for `refine_after` frames (9, about 150 ms at 60 fps), or one
  that changed in at most a quarter of its last 4 × `refine_after` frames (low motion: a
  caret), gets a QP offset of −6, then −12 on the next coded frame, then counts as clean and
  gets none, so it codes as a skip against its sharp reference. At most 1/64 of the blocks
  get an offset per frame, from a cursor that rotates over the screen.
- **Rate control stays in charge.** The offsets are added to the QP the encoder's rate
  control picks, so CBR still holds the frame budget; the map moves bits from coarse blocks
  to still ones. In the x264 test below the stream grew about 15%.
- **When not to.** No map on forced frames (IDR, LTR refresh), on idle-refine frames
  (`refine_qp` set: core/still has the whole screen), or while `refineOk` is false (the rate
  controller is cutting or recovering from a cut, the path is stalled). A frame coded while
  the controller turned unhappy, or one the encoder dropped, doesn't advance the ledger: its
  blocks are redone later. A keyframe or a refresh against an older LTR makes every block
  coarse again.
- **Host loop** ([app/qprefine.zig](../app/qprefine.zig)): `HostApp` and `MultiHostApp`
  (one encode for every member) observe every captured frame's damage, plan a map into
  `EncodeParams.qp_map` and commit what came out. `HostOptions.qp_refine` turns it off.

## Encoders

| Encoder | QP maps | How |
| --- | --- | --- |
| x264 via libavcodec (Linux software) | Yes, 16 px | `AV_FRAME_DATA_REGIONS_OF_INTEREST`, one region per run of equal offsets; libavcodec turns it into x264 `quant_offsets` (qoffset = offset/25, needs AQ, which superfast/zerolatency keep). Tested end to end. |
| OpenH264 via libavcodec | No | libavcodec exposes no per-block QP for it. |
| NVENC (Windows, Linux) | Yes, 16 px H.264, 32 px HEVC | `qpMapMode = NV_ENC_QP_MAP_DELTA` and `NV_ENC_PIC_PARAMS.qpDeltaMap` per frame. Checked against the fake NVENC in `test-nvenc-core`; no NVIDIA hardware here. |
| VAAPI (Linux) | When the driver has ROI with delta QP | `VAEncMiscParameterBufferROI` with `roi_value_is_qp_delta`, one rectangle per run, at most the driver's `num_roi_regions` (`caps.qp_map.max_regions`, which the ledger plans within). Drivers without `roi_rc_qp_delta_support` report no maps. Compile-only: no VAAPI encoder in CI. |
| Media Foundation (Windows software) | No | The Microsoft H.264 MFT takes no per-block QP. Hardware MFTs with `CODECAPI_AVEncVideoROIEnabled` could, but we don't use them. |
| VideoToolbox (macOS) | No | No per-block QP that we know of; macOS hosts get idle refinement and lossless tiles only. |
| Browser host (WebCodecs) | No | `VideoEncoder` has a per-frame quantizer at most, no map. |
| AV1 (any) | No | Not wired up: the NVENC core does H.264 and HEVC only. NVENC's map would be per 64 px superblock. |
| Synthetic | Yes, 16 px | Counts maps and refuses badly sized ones, for the sim. |

An encoder without maps reports `caps.qp_map.block = 0`; the host then keeps no ledger and
sends nothing.

## Tests

- `zig build test`: the ledger (refines next to a moving region and never inside it, the
  pace, low motion, dropped and constrained frames, keyframes, the region limit).
- `zig build test-linux-enc`: x264 at 320×192 and 1.5 Mbit/s with fine text and a noisy
  "video" corner; the still text's luma PSNR goes from about 32 dB to about 40 dB with the
  ledger's maps.
- `zig build test-nvenc-core`: the delta map reaches `NV_ENC_PIC_PARAMS`, a wrong size doesn't.
- `zig build test-app`: the sim on clean and lossy WAN paths; no map on a forced frame, ever,
  and maps on still blocks once synthetic capture reports damage.
