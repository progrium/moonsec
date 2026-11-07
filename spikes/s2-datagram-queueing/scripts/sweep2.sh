#!/usr/bin/env bash
# Follow-up: rates just under the cap, buffer tuning, and backpressure mode.
set -uo pipefail
D=$(cd "$(dirname "$0")" && pwd)
ROOT=${ROOT:?}; SECS=${SECS:-10}; mkdir -p "$ROOT"
run() { local name=$1; shift
  [ -f "$ROOT/$name/recv.csv" ] && return
  env "$@" OUT="$ROOT/$name" SECS=$SECS "$D/trial.sh" > "$ROOT/$name.log" 2>&1 || echo "FAIL $name"
  python3 "$D/analyze.py" "$ROOT/$name" | sed "s/^{/{\"name\": \"$name\", /" >> "$ROOT/results.jsonl"; }
for delay in 10000 500; do for pat in smooth frames; do for mbps in 85 92; do for kind in udp iroh; do
  run "${kind}_cap100_tx${mbps}_${pat}_d${delay}" KIND=$kind CAP=100mbit MBPS=$mbps PATTERN=$pat DELAY_US=$delay
done; done; done; done
for sb in 262144 65536; do for mbps in 92 95 110; do
  run "iroh_cap100_tx${mbps}_smooth_d10000_sbuf${sb}" KIND=iroh CAP=100mbit MBPS=$mbps DELAY_US=10000 EXTRA_SEND="--sbuf $sb"
done; done
for mbps in 95 110; do
  run "iroh_cap100_tx${mbps}_smooth_d10000_wait" KIND=iroh CAP=100mbit MBPS=$mbps DELAY_US=10000 MODE=wait
done
echo DONE
