#!/usr/bin/env bash
# Regenerates the AV1, 4:4:4 and 10-bit/HDR10 test streams for test.zig (Ubuntu 24.04:
# ffmpeg 6.1 with libaom, libsvtav1 and libx265; python3). Each is 6 frames of 128x96 with
# no B-frames, built from raw YUV so the decoded values are known:
#
#   solid_128x96.av1           AV1 Main 8-bit 4:2:0 (libaom), Y/U/V 96/177/100, the H.264
#                              and HEVC streams' colour (0x3060C0, BT.601 limited).
#   stripes_128x96_444.h265    HEVC Main 4:4:4 (RExt) 8-bit: Y 128, V 128, U alternating
#                              80/176 every column, which 4:2:0 cannot carry.
#   stripes_128x96_444.av1     AV1 High 4:4:4 8-bit (libaom), the same picture.
#   hdr10_128x96_main10.h265   HEVC Main10 4:2:0, BT.2020/PQ, mastering display and content
#                              light level SEI: 10-bit Y 509, U/V 512, a 100 cd/m² grey.
#   hdr10_128x96_10bit.av1     AV1 Main 10-bit 4:2:0 (libsvtav1), BT.2020/PQ, metadata
#                              OBUs: the same grey.
#   hdr10_128x96_444_10.h265   HEVC Main 4:4:4 10, BT.2020/PQ: grey Y 509 with the 10-bit
#                              U stripes 320/704.
#
# Near-lossless quantizers keep the values within a few codes; test.zig allows for that.
set -euo pipefail
cd "$(dirname "$0")"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

python3 - "$tmp" <<'PY'
import struct, sys
d = sys.argv[1]
W, H, N = 128, 96, 6
def plane(f, w, h, val, bits):
    fmt = '<H' if bits > 8 else 'B'
    for y in range(h):
        f.write(b''.join(struct.pack(fmt, val(x, y)) for x in range(w)))
def write(name, bits, sub, y, u, v):
    cw, ch = (W // 2, H // 2) if sub else (W, H)
    with open(f'{d}/{name}', 'wb') as f:
        for _ in range(N):
            plane(f, W, H, y, bits); plane(f, cw, ch, u, bits); plane(f, cw, ch, v, bits)
write('solid420.yuv', 8, True, lambda x, y: 96, lambda x, y: 177, lambda x, y: 100)
write('stripes444.yuv', 8, False, lambda x, y: 128, lambda x, y: 80 if x % 2 == 0 else 176, lambda x, y: 128)
write('grey420p10.yuv', 10, True, lambda x, y: 509, lambda x, y: 512, lambda x, y: 512)
write('stripes444p10.yuv', 10, False, lambda x, y: 509, lambda x, y: 320 if x % 2 == 0 else 704, lambda x, y: 512)
PY

raw() { echo -f rawvideo -pix_fmt "$1" -s 128x96 -r 60 -i "$tmp/$2"; }
ff() { ffmpeg -hide_banner -loglevel error -y "$@"; }
# BT.2020 primaries, D65, 1000/0.005 cd/m² mastering display; MaxCLL 1000, MaxFALL 400
# (platform/format.zig's HdrMetadata.default_hdr10).
md='G(8500,39850)B(6550,2300)R(35400,14600)WP(15635,16450)L(10000000,50)'
hdr_color=(-color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc -color_range tv)
aom=(-c:v libaom-av1 -usage realtime -cpu-used 8 -lag-in-frames 0 -crf 4 -g 600 -f obu)

ff $(raw yuv420p solid420.yuv) "${aom[@]}" solid_128x96.av1
ff $(raw yuv444p stripes444.yuv) "${aom[@]}" stripes_128x96_444.av1
ff $(raw yuv444p stripes444.yuv) -c:v libx265 -preset ultrafast -tune zerolatency \
    -x265-params "qp=4:keyint=600:bframes=0:repeat-headers=1:log-level=error" -f hevc stripes_128x96_444.h265
ff $(raw yuv420p10le grey420p10.yuv) "${hdr_color[@]}" -c:v libx265 -preset ultrafast -tune zerolatency \
    -x265-params "qp=4:keyint=600:bframes=0:repeat-headers=1:hdr10=1:hdr10-opt=0:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:master-display=$md:max-cll=1000,400:log-level=error" \
    -f hevc hdr10_128x96_main10.h265
ff $(raw yuv444p10le stripes444p10.yuv) "${hdr_color[@]}" -c:v libx265 -preset ultrafast -tune zerolatency \
    -x265-params "qp=4:keyint=600:bframes=0:repeat-headers=1:hdr10=1:hdr10-opt=0:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:master-display=$md:max-cll=1000,400:log-level=error" \
    -f hevc hdr10_128x96_444_10.h265
ff $(raw yuv420p10le grey420p10.yuv) "${hdr_color[@]}" -c:v libsvtav1 -preset 12 -qp 4 -g 600 \
    -svtav1-params "pred-struct=1:color-primaries=9:transfer-characteristics=16:matrix-coefficients=9:mastering-display=G(0.17,0.797)B(0.131,0.046)R(0.708,0.292)WP(0.3127,0.329)L(1000,0.005):content-light=1000,400" \
    -f obu hdr10_128x96_10bit.av1
ls -l ./*.av1 ./stripes*.h265 ./hdr10*.h265
