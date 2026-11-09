# platform/nvenc

The half of the NVENC encoders that doesn't depend on the OS ([nvenc_core.c](nvenc_core.c)),
shared by the Windows host ([host/windows/enc_nvenc.c](../host/windows/enc_nvenc.c):
`nvEncodeAPI64.dll`, D3D11 textures) and the Linux host
([host/linux/enc_nvenc.c](../host/linux/enc_nvenc.c): `libnvidia-encode.so.1`, CUDA device
memory). Each OS file loads the library, makes the device, registers its input resources
and maps `NVENCSTATUS` to its own errors; the core does the rest:

- session setup with a driver version check against the vendored header (SDK 12.0);
- the low-latency configuration: P1 preset, ultra-low-latency tuning, CBR with a one-frame
  VBV, infinite GOP, no B-frames, no lookahead, `slices` slices, parameter sets on every IDR;
- long-term references in "per picture" mode: two slots, a mark on every IDR, every 15
  frames and every refresh, into the slot that doesn't hold the newest acked one; a
  refresh references the newest acked one, or becomes an IDR when none is acked;
- bitrate changes through `nvEncReconfigureEncoder` without an IDR;
- input registration (least recently used of 8 goes) and the encode call.

`zig build test-nvenc-core` runs the core against a fake NVENC function list (marks,
refreshes, IDRs, reconfiguration), on any host. No NVIDIA hardware is planned for this
project, so the real NVENC paths are compile-only on Linux and checked on Windows only by
S8's NVENC rows when an NVIDIA machine is available.

## Linux NVENC

[nvenc_linux.h](../host/linux/nvenc_linux.h) is its C interface. Input is a linear dma-buf
(XRGB8888/ARGB8888 or NV12) imported with `cuImportExternalMemory` and cached by inode, or
pixels in memory copied into a pitched device buffer. Tiled dma-bufs (NVIDIA's own
modifiers) would need the EGL/GL interop path and are refused for now. It joins the Linux
host's encoder dispatch (`MLH_ENC_NVENC` in platform/host/linux, PR #44) once both land.

```sh
zig build test-nvenc-core      # the core, against a fake NVENC
zig build check-nvenc-linux    # Linux NVENC built for x86_64 and aarch64 Linux
zig build test-nvenc-linux     # Linux host: "not found" without an NVIDIA driver; a short encode with one
zig build check-win            # the Windows host on the same core
```
