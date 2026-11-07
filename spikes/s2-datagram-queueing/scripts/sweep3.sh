#!/usr/bin/env bash
# S3 controller rerun: S3's AppRate pacer (target = 1.05x offered load) vs the Cubic results
# from sweep1/sweep2. Also runs with the encoder outrunning a fixed 90 Mbit/s target.
set -uo pipefail
D=$(cd "$(dirname "$0")" && pwd)
ROOT=${ROOT:?}; SECS=${SECS:-10}; mkdir -p "$ROOT"
run() { local name=$1; shift
  [ -f "$ROOT/$name/recv.csv" ] && return
  env "$@" OUT="$ROOT/$name" SECS=$SECS "$D/trial.sh" > "$ROOT/$name.log" 2>&1 || echo "FAIL $name"
  python3 "$D/analyze.py" "$ROOT/$name" | sed "s/^{/{\"name\": \"$name\", /" >> "$ROOT/results.jsonl"; }
for delay in 10000 500; do for pat in smooth frames; do
  for combo in 100:50 100:80 100:90 100:92 100:95 160:150 100:110 100:150; do
    cap=${combo%%:*}; mbps=${combo##*:}
    run "iroh_cap${cap}_tx${mbps}_${pat}_d${delay}_apprate" KIND=iroh CAP=${cap}mbit MBPS=$mbps PATTERN=$pat DELAY_US=$delay EXTRA_SEND="--cc apprate"
  done
done; done
for mbps in 95 110; do
  run "iroh_cap100_tx${mbps}_smooth_d10000_apprate90" KIND=iroh CAP=100mbit MBPS=$mbps DELAY_US=10000 EXTRA_SEND="--cc apprate --target-mbps 90"
  run "iroh_cap100_tx${mbps}_smooth_d10000_apprate90_sbuf65536" KIND=iroh CAP=100mbit MBPS=$mbps DELAY_US=10000 EXTRA_SEND="--cc apprate --target-mbps 90 --sbuf 65536"
done
echo DONE
