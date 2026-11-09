#!/bin/sh
# Regenerates the H.264 fixture the web test host replays (platform/synthetic/fixture.zig).
# Constrained Baseline, no B-frames, an IDR every 30 frames (the fixture encoder answers a
# keyframe request by jumping to the next one), one access unit delimiter per frame (where
# the encoder splits the stream), SPS/PPS before every IDR.
set -e
cd "$(dirname "$0")"
ffmpeg -loglevel error -y -f lavfi -i "testsrc2=size=640x360:rate=60:duration=2" \
  -c:v libx264 -profile:v baseline -level 3.1 -tune zerolatency -preset veryfast \
  -g 30 -keyint_min 30 -sc_threshold 0 -bf 0 -b:v 1M -maxrate 1M -bufsize 33k \
  -x264-params aud=1:repeat-headers=1 -pix_fmt yuv420p -f h264 testsrc_640x360_60.h264
