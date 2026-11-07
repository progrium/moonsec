#!/usr/bin/env bash
# S4 rerun against the noq-proto pipe. Usage: scripts/jitter.sh [outdir]  (root, for SCHED_FIFO)
# Same scenarios as spikes/s4-ffi-jitter/run_matrix.sh: media thread on CPU 0 at SCHED_FIFO 80,
# network thread (where used) on CPU 1 at SCHED_FIFO 79, 6 busy threads for "loaded".
# Modes:  inline        the media thread drives QUIC and calls sendto() itself (no handoff)
#         thread        SPSC ring + eventfd to a dedicated pinned RT network thread
#         thread_noprio same, network thread unpinned at normal priority
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$D/../results/jitter}; mkdir -p "$OUT"
B=$D/../harness/zig-out/bin/s10
A=$D/../../s4-ffi-jitter/analyze.py
CERT=$(mktemp -u /tmp/s10jcert.XXXX)
run() { local tag=$1; shift; echo "== $tag"; rm -f "$CERT"
  "$B" recv bind=127.0.0.1:7600 cert="$CERT" net_cpu=3 net_prio=0 >> "$OUT/recv.log" 2>&1 &
  local rp=$!
  "$B" jitter to=127.0.0.1:7600 bind=127.0.0.1:0 cert="$CERT" size=1150 "$@" out="$OUT/$tag" 2>&1 | sed 's/^/   /'
  wait $rp || true
  python3 "$A" "$OUT/$tag" 500 > "$OUT/$tag.json"; }
for load in 0 6; do for pat in iso burst; do
  if [ $pat = iso ]; then P="n=20000 interval_us=1000 burst=1"; else P="n=43200 interval_us=16667 burst=36"; fi
  run "inline.$pat.load$load"       mode=inline $P load=$load gen_cpu=0 gen_prio=80
  run "thread.$pat.load$load"       mode=thread $P load=$load gen_cpu=0 gen_prio=80 net_cpu=1 net_prio=79
  run "thread_noprio.$pat.load$load" mode=thread $P load=$load gen_cpu=0 gen_prio=80 net_cpu=-1 net_prio=0
done; done
rm -f "$OUT"/*.csv.gz; gzip -f "$OUT"/*.csv
