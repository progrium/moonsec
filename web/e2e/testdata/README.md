# Browser harness fixtures

60 frames of ffmpeg's `testsrc2` at 320x180, 30 fps, one keyframe then only
predicted frames (no B-frames), as a low-latency encoder sends them. The stub
host replays them so the harness can check WebCodecs decode in each browser
until the real media pipeline (web client phase 6B) streams from a host.

```sh
ffmpeg -f lavfi -i testsrc2=size=320x180:rate=30 -frames:v 60 -c:v libx264 \
  -profile:v baseline -level 3.0 -pix_fmt yuv420p -bf 0 -g 600 \
  -x264-params "keyint=600:scenecut=0:aud=1" -tune zerolatency -b:v 150k \
  -f h264 testsrc_320x180_60f.h264
ffmpeg -f lavfi -i testsrc2=size=320x180:rate=30 -frames:v 60 -c:v libvpx \
  -deadline realtime -g 600 -auto-alt-ref 0 -b:v 150k -f ivf testsrc_320x180_60f.ivf
```

H.264 is Annex B with access unit delimiters (split on them). VP8 is IVF (32-byte
file header, 12-byte frame headers). VP8 is the fallback for browsers whose
build has no H.264 decoder (Playwright's Firefox and WebKit may not).
