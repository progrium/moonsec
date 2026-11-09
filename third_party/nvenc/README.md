# nvEncodeAPI.h

NVIDIA Video Codec SDK 12.0.16 encoder header, MIT-licensed (see the notice at the
top of the file), taken unmodified from FFmpeg's nv-codec-headers at tag
`n12.0.16.1`. Needs an NVIDIA driver of 522.25 or newer on Windows.

moonsec loads `nvEncodeAPI64.dll` (platform/host/windows/enc_nvenc.c) and on Linux
`libnvidia-encode.so.1` and `libcuda.so.1` (platform/host/linux/enc_nvenc.c, driver
520.56.06 or newer) at run time, so nothing links against NVIDIA libraries and the build
needs no SDK. The few CUDA driver declarations Linux needs are in enc_nvenc.c.
