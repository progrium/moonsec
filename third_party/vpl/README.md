# Intel oneVPL API headers

The C API headers from Intel's [libvpl](https://github.com/intel/libvpl) at tag `v2.17.0`
(`api/vpl`, API 2.17), unmodified, without the C++ wrapper `mfxvideo++.h`. MIT-licensed
(`SPDX-License-Identifier: MIT` at the top of each file).

moonsec loads the oneVPL dispatcher `libvpl.dll` (when shipped next to the program) or
the GPU runtime `libmfx64-gen.dll` (installed by Intel's driver) at run time
(platform/host/windows/enc_vpl.c) and needs a 2.x runtime (Xe graphics, 11th-gen Core
and newer). Nothing links against Intel libraries and the build needs no SDK.
