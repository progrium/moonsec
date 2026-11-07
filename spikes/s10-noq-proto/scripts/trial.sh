#!/usr/bin/env bash
# One S2-style trial over the S2 netns topology (../s2-datagram-queueing/scripts/netns.sh up).
# Env: KIND=noq|iroh|udp CAP=100mbit MBPS=80 DELAY_US=10000 PATTERN=smooth|frames SECS=10 OUT=dir
#      EXTRA_SEND="" (noq: key=value args to `s10 send`; iroh: s2bench flags)
#      RT=1 pins and gives SCHED_FIFO to the network threads (noq) / current-thread runtime (iroh)
# CPUs: receiver 0, sender media/generator 1, sender network 2, delay line 3.
set -euo pipefail
D=$(cd "$(dirname "$0")" && pwd)
S2=$D/../../s2-datagram-queueing
S2B=${S2B:-$S2/target/release/s2bench}
S10=${S10:-$D/../harness/zig-out/bin/s10}
: "${KIND:=noq}" "${CAP:=100mbit}" "${MBPS:=80}" "${DELAY_US:=10000}" "${PATTERN:=smooth}" "${SECS:=10}" "${RT:=1}"
: "${OUT:?}" "${EXTRA_SEND:=}"
mkdir -p "$OUT"
if [ "$CAP" = none ]; then $S2/scripts/netns.sh uncap; else $S2/scripts/netns.sh cap "$CAP"; fi
ip netns exec s2m taskset -c 3 "$S2B" proxy --a-bind 10.71.0.2:7000 --b-bind 10.72.0.2:7001 --b 10.72.0.1:7000 --delay-us "$DELAY_US" &
PP=$!
trap 'kill $PP 2>/dev/null || true' EXIT
sleep 0.3
PRIO=0; [ "$RT" = 1 ] && PRIO=50
case $KIND in
noq)
  CERT=$(mktemp -u /tmp/s10cert.XXXX)
  ip netns exec s2b "$S10" recv bind=10.72.0.1:7000 csv="$OUT/recv.csv" out="$OUT/recv.json" cert="$CERT" net_cpu=0 net_prio=$PRIO &
  RP=$!; sleep 0.3
  ip netns exec s2a "$S10" send bind=10.71.0.1:7100 to=10.71.0.2:7000 cert="$CERT" mbps="$MBPS" secs="$SECS" \
    pattern="$PATTERN" gen_cpu=1 net_cpu=2 net_prio=$PRIO out="$OUT/send.json" $EXTRA_SEND
  wait $RP; rm -f "$CERT" ;;
iroh)
  CT=(); CTS=()
  if [ "$RT" = 1 ]; then CT=(env S2_CT_CPU=0 S2_CT_PRIO=$PRIO); CTS=(env S2_CT_CPU=2 S2_CT_PRIO=$PRIO S2_GEN_CPU=1); fi
  ip netns exec s2b "${CT[@]}" taskset -c 0 "$S2B" recv --bind 10.72.0.1:7000 --csv "$OUT/recv.csv" --out "$OUT/recv.json" &
  RP=$!; sleep 0.5
  ip netns exec s2a "${CTS[@]}" taskset -c 1,2 "$S2B" send --bind 10.71.0.1:7100 --to 10.71.0.2:7000 --mbps "$MBPS" --secs "$SECS" \
    --pattern "$PATTERN" --out "$OUT/send.json" $EXTRA_SEND
  wait $RP ;;
udp)
  ip netns exec s2b taskset -c 0 "$S2B" udp-recv --bind 10.72.0.1:7000 --csv "$OUT/recv.csv" --secs "$(echo "$SECS + 4" | bc)" &
  RP=$!; sleep 0.3
  ip netns exec s2a taskset -c 1,2 "$S2B" udp-send --bind 10.71.0.1:7100 --to 10.71.0.2:7000 --mbps "$MBPS" --secs "$SECS" \
    --pattern "$PATTERN" --out "$OUT/send.json"
  wait $RP ;;
esac
ip netns exec s2m tc -s qdisc show dev vmb > "$OUT/qdisc.txt" || true
