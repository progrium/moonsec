#!/usr/bin/env bash
# Full S5c matrix: for each RTT, four clients in parallel (stock and patched iroh, idle
# 300 ms and 1000 ms), each running the `sweep` plan against its own host endpoint.
# Usage: scripts/sweep.sh <out-root> [rtts_ms...]   (root; lab.sh up first)
set -uo pipefail
D=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:?out root}; shift
RTTS=${*:-75 150 250}
S=$D/target/release/s5c
P=$D/patched/target/release/s5c
mkdir -p "$OUT"
pkill -f "s5c (relay|host)" 2>/dev/null; sleep 0.5
ip netns exec x3i "$S" relay 10.80.9.1 > "$OUT/relay.log" 2>&1 &
sleep 1
(cd /tmp && S5C_ID_FILE=$OUT/ids-stock ip netns exec x3h "$S" host > "$OUT/host-stock.log" 2>&1 &)
(cd /tmp && S5C_BASE_PORT=47011 S5C_CONFIGS=idle300=300:100,idle1000=1000:200 S5C_ID_FILE=$OUT/ids-patched ip netns exec x3h "$P" host > "$OUT/host-patched.log" 2>&1 &)
sleep 4
for rtt in $RTTS; do
  "$D/scripts/lab.sh" delay "$(python3 -c "print($rtt/2)")"
  sleep 2
  pids=()
  for build in stock patched; do
    bin=$S; [ $build = patched ] && bin=$P
    while read -r name id cfg; do
      dir=$OUT/rtt${rtt}-$build-$name
      S5C_CFG=$cfg ip netns exec x3c "$bin" client "$id" "$dir" sweep > "$dir.log" 2>&1 &
      pids+=($!)
      sleep 1
    done < "$OUT/ids-$build"
  done
  wait "${pids[@]}"
  echo "rtt $rtt done $(date)"
done
pkill -f "s5c (relay|host)"
