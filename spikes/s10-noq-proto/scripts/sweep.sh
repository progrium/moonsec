#!/usr/bin/env bash
# S10 matrix: raw UDP vs iroh+AppRate on a pinned current-thread runtime vs noq-proto driven
# from Zig. Same topology, CPUs and traffic as S2. ~30 min.
set -uo pipefail
D=$(cd "$(dirname "$0")" && pwd)
ROOT=${ROOT:?}; SECS=${SECS:-10}; mkdir -p "$ROOT"
run() { local name=$1; shift
  [ -f "$ROOT/$name/recv.csv" ] && return
  env "$@" OUT="$ROOT/$name" SECS=$SECS "$D/trial.sh" > "$ROOT/$name.log" 2>&1 || echo "FAIL $name"; }
# 1. Below the cap, paced at a capacity estimate (S2's sweep4): 90 on the 100 cap, 145 on 160.
for delay in 10000 500; do for pat in smooth frames; do
  for combo in 100:50:90 100:80:90 100:85:90 160:100:145; do
    IFS=: read cap mbps tgt <<< "$combo"; c="cap${cap}_tx${mbps}_${pat}_d${delay}"
    run "udp_$c" KIND=udp CAP=${cap}mbit MBPS=$mbps PATTERN=$pat DELAY_US=$delay
    # queue bounds sized so a whole frame fits while it is paced out (S2's sweep4 used iroh's 1 MiB default)
    run "iroh_${c}_cap" KIND=iroh CAP=${cap}mbit MBPS=$mbps PATTERN=$pat DELAY_US=$delay EXTRA_SEND="--cc apprate --target-mbps $tgt"
    run "noq_${c}_cap" KIND=noq CAP=${cap}mbit MBPS=$mbps PATTERN=$pat DELAY_US=$delay EXTRA_SEND="pace_mbps=$tgt maxq_us=30000"
    run "noqrate_${c}_cap" KIND=noq CAP=${cap}mbit MBPS=$mbps PATTERN=$pat DELAY_US=$delay EXTRA_SEND="pace_mbps=$tgt cc=1 maxq_us=30000"
    # the design's 64 KiB iroh send buffer, with frames bigger than 64 KiB
    [ $pat = frames ] && [ $delay = 10000 ] && run "iroh_${c}_cap64k" KIND=iroh CAP=${cap}mbit MBPS=$mbps PATTERN=$pat DELAY_US=$delay EXTRA_SEND="--cc apprate --target-mbps $tgt --sbuf 65536"
    [ $pat = frames ] && run "noq_${c}_capburst" KIND=noq CAP=${cap}mbit MBPS=$mbps PATTERN=$pat DELAY_US=$delay EXTRA_SEND="pace_mbps=$tgt credit_us=20000 maxq_us=30000"
  done
done; done
# 2. At and above the cap, paced at 1.05x the offered load (S2's sweep3): the hidden-queue cases.
for combo in 100:95:smooth:10000 100:95:frames:10000 100:110:smooth:10000 100:110:frames:10000 160:150:smooth:10000 160:150:frames:10000 100:95:smooth:500; do
  IFS=: read cap mbps pat delay <<< "$combo"; c="cap${cap}_tx${mbps}_${pat}_d${delay}"
  run "udp_$c" KIND=udp CAP=${cap}mbit MBPS=$mbps PATTERN=$pat DELAY_US=$delay
  run "iroh_${c}_enc" KIND=iroh CAP=${cap}mbit MBPS=$mbps PATTERN=$pat DELAY_US=$delay EXTRA_SEND="--cc apprate --sbuf 65536"
  run "noq_${c}_enc" KIND=noq CAP=${cap}mbit MBPS=$mbps PATTERN=$pat DELAY_US=$delay EXTRA_SEND="pace_mbps=0 maxq_us=60000"
done
# 3. Encoder outruns the pacer target (90): the queue is on the sender, so drops must be counted there.
for mbps in 95 110; do c="cap100_tx${mbps}_smooth_d10000"
  run "iroh_${c}_over90" KIND=iroh CAP=100mbit MBPS=$mbps DELAY_US=10000 EXTRA_SEND="--cc apprate --target-mbps 90 --sbuf 65536"
  run "noq_${c}_over90" KIND=noq CAP=100mbit MBPS=$mbps DELAY_US=10000 EXTRA_SEND="pace_mbps=90 maxq_us=5000"
done
echo DONE
