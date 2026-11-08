# latency: glass-to-glass by host and client

The Phase 4 gate in [docs/design.md](../../docs/design.md) is "every host/client pair in the
target table streams with the Phase 2 latency bar", and the Phase 2 bar is glass-to-glass
within 5 ms of Moonlight at 1080p60 on wired LAN. This tool turns photodiode logs, camera
footage or screenshots of the measurement pattern ([platform/pattern.zig](../../platform/pattern.zig))
into latency numbers, and a manifest of them into a host×client matrix that passes or fails.

| File | What |
| --- | --- |
| [analyze.zig](analyze.zig) | Photodiode edges, PNM pictures, barcode and digit reads, statistics |
| [matrix.zig](matrix.zig) | The manifest, the bar, the matrix report |
| [synth.zig](synth.zig) | The synthetic pair under a simulated photodiode and camera |
| [main.zig](main.zig) | The `latency` command |
| [test.zig](test.zig) | The gate end to end on the synthetic pair (part of `zig build test`) |

## Commands

```sh
zig build latency-e2e                     # synthetic pair: record, measure, gate; zig-out/latency/report.md
zig build install                         # zig-out/bin/latency, then:
latency photodiode bench/win-linux.csv
latency camera bench/win-linux.ppm --host-crop 0,0,960,540 --client-crop 960,0,960,540
latency screenshot shots/                 # a directory of .ppm/.pgm, left half host, right half client
latency matrix bench/manifest.txt --out report.md   # exits 1 unless every target pair passes
latency synthetic --out-dir out           # just record the synthetic pair and write out/manifest.txt
```

## On the bench

The host's screen shows the pattern full screen, drawn from the host's clock every frame;
the client streams it. Measure moonsec and then the reference (Moonlight) on the same two
machines, same mode (1080p60), same method, and list both in the manifest.

- **Photodiode.** Tape one diode over the flash square (bottom right) of each screen. It is
  white for the first 100 ms of every second, so each second gives a rising and a falling
  edge. Log both diodes on one clock as CSV, `t_us,host,client`, at 1 kHz or faster (an
  Arduino or a scope export). Levels can be in any unit; edges are found at the midpoint of
  each channel's range with hysteresis, and interpolated between samples. Thirty seconds
  gives about 60 edges; the gate wants at least 10 (`min_edges`) and compares medians.
- **Camera.** Film both screens in one shot at 120 fps or more, and convert to a PPM
  stream: `ffmpeg -i clip.mp4 -f image2pipe -c:v ppm clip.ppm` (or `-pix_fmt gray -c:v pgm`
  for a third of the size). Give each screen's crop in pixels, tight to the pattern and as
  square-on as you can film it. Each frame is read by the barcode (µs) and, when glare or a
  half-refreshed frame spoils the barcode, by the digits (ms). Each frame is quantized to
  the screens' refresh, so the gate compares means over at least 100 frames (`min_frames`).
- **Screenshots.** The same reader on pictures that show both screens: for a capture card
  on the client's output next to the host's, or a host and client on one desktop.

## Manifest

```
# Lab bench, Nov 2026. Paths are relative to this file.
bar margin_ms=5 min_edges=10 min_frames=100
target windows windows
target windows linux
run host=windows client=linux stack=moonsec method=photodiode file=win-linux.csv mode=1080p60
run host=windows client=linux stack=reference name="Moonlight 6.1" method=photodiode file=win-linux-ml.csv mode=1080p60
run host=windows client=linux stack=moonsec method=camera file=win-linux.ppm host_crop=0,0,960,540 client_crop=960,0,960,540
```

Without `target` lines the targets are the design's table: Windows and macOS hosts, each
with Windows, macOS and Linux clients. A pair passes when every moonsec run on it is within
`margin_ms` of the reference run with the same method; `max_ms=N` sets an absolute bar for
runs that have no reference. Pairs that were measured but are not targets show in the
matrix in italics and do not count.

## In CI

`zig build latency-e2e` runs the synthetic host and client over the simulated LAN as
moonsec, and over the clean link as the stand-in reference, with a simulated photodiode on
each flash square and a simulated 125 fps camera on both screens (glare over the client's
barcode on every seventh frame, so the digit reader runs too). It writes the CSVs and PGM
streams, runs `latency matrix` on them and adds the report to the job summary. The tests in
[test.zig](test.zig) check that the photodiode and camera agree with the session's own
glass-to-glass telemetry, and that a run 9 ms slower than its reference fails the gate.

## Not yet

- A program that shows the pattern full screen on a real host. The synthetic capture draws
  it; on Windows and macOS something has to put it on the screen for both the moonsec and
  the Moonlight runs.
- Perspective correction for camera crops; crops are read as if square-on.
