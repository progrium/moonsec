# platform/windows

Shared Windows code for the host (`platform/host/windows`) and client
(`platform/client/windows`) backends.

## Binding approach: thin C shims

COM, D3D11, DXGI, Media Foundation and WASAPI are called from small C files
compiled by `zig cc` against the mingw-w64 headers that ship with Zig, using
`COBJMACROS` (`ID3D11Device_CreateTexture2D(dev, ...)`). Zig sees only a narrow
C ABI declared in headers that do not include `<windows.h>`, translated with
`b.addTranslateC`. This mirrors the macOS backends (`.m` files behind a C ABI).

Why not zigwin32 or translating the SDK headers directly:

- zigwin32 tracks Zig master; we pin Zig 0.16 per release and would have to pin
  and patch it too.
- `translate-c` of `windows.h` + d3d11/dxgi/mf/audioclient works, but takes about
  43 s and emits 136k lines, and the vtable calls read worse than the C macros.
- C shims need nothing outside the Zig toolchain and cross-compile from Linux, so
  `zig build check-win` catches compile and link errors on any host.

## Files

- `msw.h`: the Zig-facing C ABI (HRESULTs, COM init, QPC clock, D3D11 device
  creation on a hardware adapter or WARP, a GPU smoke test). No `<windows.h>`.
- `msw_internal.h`: for C files only; includes the COM headers, defines
  `struct msw_d3d` and the `MSW_RELEASE` / `MSW_TRY` helpers.
- `msw.c`: the implementation.
- `win.zig`: the Zig wrapper, exposed to other modules as `win`.
- `test.zig`: tests run by `zig build test-win`.

## Adding a backend

In `build.zig`, import `windowsModule(b, target, optimize)` as `win`, translate your
own Zig-facing header with `translatePlatformHeader`, and add your C files and
system libraries with `addWindowsC(b, module, files, libs)`. C files include
`msw_internal.h` to reach the shared device (`d->device`, `d->context`).

## Build steps

- `zig build test-win`: runs the tests (Windows host). On a GPU-less machine the
  tests use WARP and the Basic Render Driver.
- `zig build check-win`: cross-compiles and links the tests for x86_64 and aarch64
  Windows from any host.
