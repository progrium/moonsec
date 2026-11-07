#!/usr/bin/env bash
# One trial. Env: KIND=iroh|udp CAP=100mbit MBPS=80 DELAY_US=10000 PATTERN=smooth|frames
#   MODE=drop|wait SECS=10 OUT=dir EXTRA_SEND="" EXTRA_RECV=""
set -euo pipefail
B=${B:-$(dirname "$0")/../target/release/s2bench}
: "${KIND:=iroh}" "${CAP:=100mbit}" "${MBPS:=80}" "${DELAY_US:=10000}" "${PATTERN:=smooth}" "${MODE:=drop}" "${SECS:=10}"
: "${OUT:?}" "${EXTRA_SEND:=}" "${EXTRA_RECV:=}"
mkdir -p "$OUT"
D=$(dirname "$0")
if [ "$CAP" = none ]; then $D/netns.sh uncap; else $D/netns.sh cap "$CAP"; fi
ip netns exec s2m taskset -c 3 "$B" proxy --a-bind 10.71.0.2:7000 --b-bind 10.72.0.2:7001 --b 10.72.0.1:7000 --delay-us "$DELAY_US" &
PP=$!
trap 'kill $PP 2>/dev/null || true' EXIT
sleep 0.3
if [ "$KIND" = iroh ]; then
  ip netns exec s2b taskset -c 0 "$B" recv --bind 10.72.0.1:7000 --csv "$OUT/recv.csv" --out "$OUT/recv.json" $EXTRA_RECV &
  RP=$!; sleep 0.5
  ip netns exec s2a taskset -c 1,2 "$B" send --bind 10.71.0.1:7100 --to 10.71.0.2:7000 --mbps "$MBPS" --secs "$SECS" \
    --pattern "$PATTERN" --mode "$MODE" --out "$OUT/send.json" $EXTRA_SEND
  wait $RP
else
  ip netns exec s2b taskset -c 0 "$B" udp-recv --bind 10.72.0.1:7000 --csv "$OUT/recv.csv" --secs "$(echo "$SECS + 4" | bc)" &
  RP=$!; sleep 0.3
  ip netns exec s2a taskset -c 1,2 "$B" udp-send --bind 10.71.0.1:7100 --to 10.71.0.2:7000 --mbps "$MBPS" --secs "$SECS" \
    --pattern "$PATTERN" --out "$OUT/send.json"
  wait $RP
fi
ip netns exec s2m tc -s qdisc show dev vmb > "$OUT/qdisc.txt" || true
