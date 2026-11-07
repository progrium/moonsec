#!/usr/bin/env bash
# AppRate pacing at a capacity estimate (not at the encoder rate): target 90 Mbit/s payload
# (~96% of a 100 Mbit/s cap on the wire) with the encoder at 50-85, and 145 on a 160 cap.
set -uo pipefail
D=$(cd "$(dirname "$0")" && pwd)
ROOT=${ROOT:?}; SECS=${SECS:-10}; mkdir -p "$ROOT"
run() { local name=$1; shift
  [ -f "$ROOT/$name/recv.csv" ] && return
  env "$@" OUT="$ROOT/$name" SECS=$SECS "$D/trial.sh" > "$ROOT/$name.log" 2>&1 || echo "FAIL $name"
  python3 "$D/analyze.py" "$ROOT/$name" | sed "s/^{/{\"name\": \"$name\", /" >> "$ROOT/results.jsonl"; }
for delay in 10000 500; do for pat in smooth frames; do
  for mbps in 50 80 85; do
    run "iroh_cap100_tx${mbps}_${pat}_d${delay}_apprateCap" KIND=iroh CAP=100mbit MBPS=$mbps PATTERN=$pat DELAY_US=$delay EXTRA_SEND="--cc apprate --target-mbps 90"
  done
  run "iroh_cap160_tx100_${pat}_d${delay}_apprateCap" KIND=iroh CAP=160mbit MBPS=100 PATTERN=$pat DELAY_US=$delay EXTRA_SEND="--cc apprate --target-mbps 145"
done; done
echo DONE
