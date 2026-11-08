# nvEncodeAPI.h

NVIDIA Video Codec SDK 12.0.16 encoder header, MIT-licensed (see the notice at the
top of the file), taken unmodified from FFmpeg's nv-codec-headers at tag
`n12.0.16.1`. Needs an NVIDIA driver of 522.25 or newer on Windows.

moonsec loads `nvEncodeAPI64.dll` at run time (platform/host/windows/enc_nvenc.c), so
nothing links against NVIDIA libraries and the build needs no SDK.
