#!/usr/bin/env bash
# Main S2 sweep. Writes one dir per trial under $ROOT and a results.jsonl.
set -uo pipefail
D=$(cd "$(dirname "$0")" && pwd)
ROOT=${ROOT:?}; SECS=${SECS:-10}
mkdir -p "$ROOT"
run() { # name, then env assignments
  local name=$1; shift
  [ -f "$ROOT/$name/recv.csv" ] && return
  env "$@" OUT="$ROOT/$name" SECS=$SECS "$D/trial.sh" > "$ROOT/$name.log" 2>&1 || echo "FAIL $name"
  python3 "$D/analyze.py" "$ROOT/$name" | sed "s/^{/{\"name\": \"$name\", /" >> "$ROOT/results.jsonl"
}
for delay in ${DELAYS:-10000 500}; do
  for pat in smooth frames; do
    for combo in ${COMBOS:-100:50 100:80 100:90 100:95 160:100 160:150 100:110 100:150}; do
      cap=${combo%%:*}; mbps=${combo##*:}
      for kind in udp iroh; do
        run "${kind}_cap${cap}_tx${mbps}_${pat}_d${delay}" KIND=$kind CAP=${cap}mbit MBPS=$mbps PATTERN=$pat DELAY_US=$delay
      done
    done
  done
done
echo DONE
