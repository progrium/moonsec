# platform/host/linux: encoders

The Linux host's video encoders behind the platform interface's `Encoder`
([encoder.zig](encoder.zig)), with the same low-latency settings and long-term-reference
recovery as the Windows and macOS hosts. Capture (PipeWire), audio and input come from the
other Phase 7 workstreams and are wired up with these in the Linux host.

Like the Linux client, the OS libraries are called from small C files behind one narrow
header ([mlh_enc.h](mlh_enc.h)) that translate-c reads; Zig never sees libva or libavcodec.

| Backend | How | Recovery |
| --- | --- | --- |
| `vaapi` | libva loaded at run time ([enc_vaapi.c](enc_vaapi.c)): `dlopen("libva.so.2")`, so the host starts on machines without it. H.264 (High, Main or Constrained Baseline) and HEVC Main, `VAEntrypointEncSlice` or the low-power `EncSliceLP`. CBR (VBR when there is no CBR) with a one-frame HRD buffer, no B-frames, no lookahead, no periodic IDR, `slices` slices per frame; a new bitrate goes out as rate-control and HRD parameters with the next frame, without an IDR. | Long-term references when the driver takes packed sequence, picture and slice headers; IDR otherwise. |
| `software` | libavcodec's libx264 (OpenH264 if that is all libavcodec has) ([enc_sw.c](enc_sw.c)): tune `zerolatency`, `keyint=infinite`, `scenecut=0`, no B-frames, VBV of one frame, parameter sets on every IDR, `slices` slices. A new bitrate goes through `x264_encoder_reconfig`, no keyframe. H.264 only. | IDR (`ltr = false`). |
| `nvenc` | libcuda and libnvidia-encode loaded at run time ([enc_nv.c](enc_nv.c) over [enc_nvenc.c](enc_nvenc.c)), on the NVENC core shared with the Windows host (`platform/nvenc`). H.264 and HEVC, the same low-latency settings as Windows. A dma-buf goes to CUDA with `cuImportExternalMemory`; when CUDA refuses it (a buffer another driver exported) frames are mapped and uploaded from then on. `--device` / `Options.device` is a CUDA ordinal. Compile-only: no NVIDIA hardware is planned. | Long-term references when the GPU has them; IDR otherwise. |
| `auto` | The first of `vaapi`, `nvenc`, `software` that opens. | |

## Long-term references on VAAPI

libavcodec's VAAPI encoders don't expose long-term references or per-frame reference
control, so this goes to libva directly, where the application owns the reference
structure. [h26x.c](h26x.c) has:

- the planner (`refs_*`): two long-term slots, the previous frame and the current one. A
  long-term reference is marked on the IDR, every 15 frames and on every refresh, into the
  slot that does not hold the newest acked one. `Force.ltr_refresh` predicts from the newest
  acked long-term reference; with none acked it is an IDR.
- writers for the H.264 SPS/PPS/slice header (POC type 2, `gaps_in_frame_num_allowed`, the
  reference picked with `ref_pic_list_modification`, marking by MMCO 1, 4 and 6) and the
  HEVC VPS/SPS/PPS/slice header (an explicit short-term RPS per slice, long-term pictures by
  POC with their MSB cycle, one active reference). These go to the driver as packed headers,
  and the VA picture and slice parameters (`ReferenceFrames`, `RefPicList0`, the RPS flags)
  say the same thing.

Without packed headers the driver writes its own and the caps say `ltr = false`. Block sizes
and the HEVC tools a driver requires (`VAConfigAttribEncHEVCBlockSizes`/`Features`) are
honoured. `EncoderCaps.ltr` is for the configured codec (H.264's before `configure`).

The writers and the planner can't run on a VAAPI encoder in CI, so
[testenc.c](testenc.c) uses them to write pictures of PCM blocks and skipped blocks (H.264
with CAVLC; HEVC with a small CABAC encoder). A skipped block copies the reference the
planner chose, so libavcodec's decoder shows exactly which picture each frame predicted
from: the tests decode a run with long-term marks, a lost burst that included a marked
frame, a refresh against the newest acked reference and the frames after it, and compare
every picture with the host's bit for bit, for both codecs.

Not yet: AV1 (`VAProfileAV1Profile0` encode needs our own sequence and frame header OBUs;
caps report `av1 = false`), and the #36 format fields (10-bit, 4:4:4, HDR) until #36 merges.

## Input

`Image.gpu`, when set, is a `*const mlh_dmabuf` (fds, fourcc, modifier, planes): the frame
Linux capture hands over. XRGB8888/ARGB8888 dma-bufs are imported as VA surfaces
(`VA_SURFACE_ATTRIB_MEM_TYPE_DRM_PRIME_2`, cached by inode) and converted to NV12 by VA video
processing (BT.709, limited range) with no copy; NV12 dma-bufs are encoded directly.
Otherwise `Image.cpu` holds BGRA or NV12, uploaded through `vaDeriveImage`. The software
encoder converts BGRA itself ([enc.c](enc.c) `mlh_bgra_to_i420`, BT.709 limited) and reads
linear dma-bufs through a mapping (`DMA_BUF_IOCTL_SYNC`); tiled ones are refused.

## Build and test

Ubuntu 24.04 packages: `libavcodec-dev libavutil-dev libva-dev` (Ubuntu's libavcodec has
libx264). The tests also use the Linux client's decoder, so its packages too (see
[platform/client/linux](../../client/linux/README.md)).

```sh
zig build test-linux-enc                    # the tests below
zig build linux-enc-check -- --help         # the hardware check (moonsec-enc-check)
```

`test-linux-enc` runs anywhere with libavcodec:

- H.264 and HEVC long-term marking, loss and refresh through the test encoders, bit exact;
- the software encoder: a lossless round trip compared with `mlh_bgra_to_i420` bit for bit
  (with two slices and keyframes on request), the loss scenario below at 640x360 (every
  recovery an IDR, stamps read on every picture), a bitrate change without a keyframe, a
  linear dma-buf (memfd), and the platform interface;
- VAAPI: on a machine without a VAAPI encoder (Mesa has no software one, and CI has no GPU)
  `create` says not found and `auto` lands on software; on a machine with one, the test runs
  the hardware check on it instead;
- NVENC: without an NVIDIA driver `create` says not found and `auto` moves on; with one,
  the test runs the hardware check on it.

`moonsec-enc-check` drives an encoder through losses the way the session does: desktop-like
content (a page of noisy text, a sliding window, the test pattern), a burst lost every 47
frames, the client frozen until the refresh one RTT later, acks one RTT after decode. The
client decodes with libavcodec and reads every picture's stamp. It passes when no IDR
follows the first, every refresh is marked as one, the largest refresh is at most half a
steady-state IDR, no picture carries another frame's stamp and no recovery picture is
unreadable (`--expect idr` for encoders without long-term references). Exit 0 pass, 1 fail,
2 when the encoder can't be opened.

## Hardware check for Jeff

On a Linux machine with an Intel or AMD GPU (`vainfo` lists `VAEntrypointEncSlice` or
`EncSliceLP` for H.264), in a checkout of this branch:

```sh
zig build linux-enc-check -Doptimize=ReleaseSafe -- --kind vaapi && \
zig build linux-enc-check -Doptimize=ReleaseSafe -- --kind vaapi --codec hevc --slices 4
```

Both should print `long-term refs: yes`, `IDRs after the first 0`, refreshes well under the
steady-state IDR, and `result: PASS`. `long-term refs: no` means the driver took no packed
headers; send the output and `vainfo` so we can look at the driver.

## Files

- `mlh_enc.h`: the Zig-facing C ABI. `enc_internal.h`: shared by the C files.
- `enc.c`: dispatch, output buffer, splitting an access unit into slices, BGRA to I420.
- `enc_vaapi.c`, `enc_sw.c`: the backends. `dmabuf.c`: CPU reads of linear dma-bufs.
- `h26x.h`, `h26x.c`: bit writer, H.264/HEVC headers, the long-term-reference planner.
- `testenc.c`: the PCM-and-skip test encoders.
- `encoder.zig`: `Encoder` for the platform interface. `enc_check.zig`: the hardware check.
- `enc_test.zig`: `zig build test-linux-enc`. `build_enc.zig`: its build steps.
