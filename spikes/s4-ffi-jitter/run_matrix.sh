#!/usr/bin/env bash
# Runs the S4 matrix. Usage: ./run_matrix.sh [outdir]   (needs root or CAP_SYS_NICE for SCHED_FIFO)
set -euo pipefail
cd "$(dirname "$0")"
OUT=${1:-results/$(hostname)}
mkdir -p "$OUT"
BIN=harness/zig-out/bin/s4
NAMES=(raw_direct raw_tokio_mt raw_tokio_ct iroh_mt iroh_ct raw_thread raw_spin)
SENDER="cpu=0 prio=80"
DED="rt_cpu=1 rt_prio=79"
run() { # tag args...
  local tag=$1; shift
  echo "== $tag"
  $BIN "$@" out="$OUT/$tag" 2>&1 | sed 's/^/   /'
  python3 analyze.py "$OUT/$tag" > "$OUT/$tag.json"
}
for load in 0 6; do
  for pat in iso burst; do
    if [ $pat = iso ]; then P="n=20000 interval_us=1000 burst=1"; else P="n=43200 interval_us=16667 burst=36"; fi
    for m in 0 1 2 3 4 5 6; do
      run "${NAMES[$m]}.$pat.load$load" mode=$m $P load=$load $SENDER $DED
    done
    # dedicated runtime thread without pinning / RT priority, for contrast
    run "iroh_ct_noprio.$pat.load$load" mode=4 $P load=$load $SENDER
  done
done
rm -f "$OUT"/*.csv.gz; gzip -f "$OUT"/*.csv
