#!/usr/bin/env bash
# S10b matrix: iroh + AppRate on the pinned current-thread runtime, with and without burst
# credit, against raw UDP. S10's topology, CPUs, traffic and trial script. ~20 min per rep.
set -uo pipefail
D=$(cd "$(dirname "$0")" && pwd)
TRIAL=$D/../../s10-noq-proto/scripts/trial.sh
ROOT=${ROOT:?}; SECS=${SECS:-10}; mkdir -p "$ROOT"
run() { local name=$1; shift
  [ -f "$ROOT/$name/recv.csv" ] && return
  env "$@" OUT="$ROOT/$name" SECS=$SECS "$TRIAL" > "$ROOT/$name.log" 2>&1 || echo "FAIL $name"; }
# 1. Below the cap, paced at a capacity estimate (90 on the 100 cap, 145 on 160), as in S10.
for delay in 10000 500; do for pat in frames smooth; do
  for combo in 100:50:90 100:80:90 100:85:90 160:100:145; do
    IFS=: read cap mbps tgt <<< "$combo"; c="cap${cap}_tx${mbps}_${pat}_d${delay}"
    A=(KIND=iroh CAP=${cap}mbit MBPS=$mbps PATTERN=$pat DELAY_US=$delay)
    run "udp_$c" KIND=udp CAP=${cap}mbit MBPS=$mbps PATTERN=$pat DELAY_US=$delay
    run "iroh_${c}_base" "${A[@]}" EXTRA_SEND="--cc apprate --target-mbps $tgt"
    run "iroh_${c}_b20" "${A[@]}" EXTRA_SEND="--cc apprate --target-mbps $tgt --burst-us 20000"
    if [ $pat = frames ]; then
      run "iroh_${c}_b10" "${A[@]}" EXTRA_SEND="--cc apprate --target-mbps $tgt --burst-us 10000"
      # the other cheap lever S10 named: no credit, pace 20% above the capacity estimate
      run "iroh_${c}_over" "${A[@]}" EXTRA_SEND="--cc apprate --target-mbps $(echo "$tgt * 1.2" | bc)"
      # burst credit with the design's 64 KiB send buffer (S10: base evicts 60% of frames at 85)
      [ $delay = 10000 ] && run "iroh_${c}_b20sb64k" "${A[@]}" EXTRA_SEND="--cc apprate --target-mbps $tgt --burst-us 20000 --sbuf 65536"
    fi
  done
done; done
# 2. Encoder outruns the target (90): credit must not lift the sustained rate above the target.
for mbps in 95 110; do c="cap100_tx${mbps}_smooth_d10000"
  run "iroh_${c}_over90" KIND=iroh CAP=100mbit MBPS=$mbps DELAY_US=10000 EXTRA_SEND="--cc apprate --target-mbps 90"
  run "iroh_${c}_over90b20" KIND=iroh CAP=100mbit MBPS=$mbps DELAY_US=10000 EXTRA_SEND="--cc apprate --target-mbps 90 --burst-us 20000"
done
echo DONE
