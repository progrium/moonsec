#!/usr/bin/env bash
# Runs the S4 matrix. Usage: ./run_matrix.sh [outdir]
# Linux: needs root or CAP_SYS_NICE for SCHED_FIFO.
# macOS: no root needed; policies are QoS / Mach time-constraint (see shim pin_and_prio).
set -euo pipefail
cd "$(dirname "$0")"
OUT=${1:-results/$(hostname -s)}
mkdir -p "$OUT"
BIN=harness/zig-out/bin/s4
NAMES=(raw_direct raw_tokio_mt raw_tokio_ct iroh_mt iroh_ct raw_thread raw_spin)
if [ "$(uname)" = Darwin ]; then
  # prio codes on macOS: 0 none, 1 QoS user-interactive, 2 time-constraint, 3 SCHED_FIFO max
  SENDER="prio=2"
  DED="rt_prio=2"
  LOAD=${LOAD:-$(( $(sysctl -n hw.ncpu) * 3 / 2 ))}   # 1.5x oversubscribed, as on Linux (6 on 4)
else
  SENDER="cpu=0 prio=80"
  DED="rt_cpu=1 rt_prio=79"
  LOAD=${LOAD:-6}
fi
run() { # tag args...
  local tag=$1; shift
  echo "== $tag"
  $BIN "$@" out="$OUT/$tag" 2>&1 | sed 's/^/   /'
  python3 analyze.py "$OUT/$tag" > "$OUT/$tag.json"
}
MODES=${MODES:-0 1 2 3 4 5 6}
for load in 0 $LOAD; do
  for pat in iso burst; do
    if [ $pat = iso ]; then P="n=20000 interval_us=1000 burst=1"; else P="n=43200 interval_us=16667 burst=36"; fi
    for m in $MODES; do
      D=$DED; [ $m = 6 ] && D="rt_cpu=1"  # SCHED_FIFO spinning gets RT-throttled; spin at normal prio
      run "${NAMES[$m]}.$pat.load$load" mode=$m $P load=$load $SENDER $D
    done
    # dedicated runtime thread without pinning / RT priority, for contrast
    [ -n "${SKIP_NOPRIO:-}" ] || run "iroh_ct_noprio.$pat.load$load" mode=4 $P load=$load $SENDER
    if [ "$(uname)" = Darwin ]; then
      # the other macOS policies for the dedicated runtime thread
      run "iroh_ct_qos.$pat.load$load" mode=4 $P load=$load $SENDER rt_prio=1
      run "iroh_ct_fifo.$pat.load$load" mode=4 $P load=$load $SENDER rt_prio=3
      # stock multi-thread runtime, but every worker at QoS user-interactive
      S4_MT_PRIO=1 run "iroh_mt_qos.$pat.load$load" mode=3 $P load=$load $SENDER
    fi
  done
done
rm -f "$OUT"/*.csv.gz; gzip -f "$OUT"/*.csv
