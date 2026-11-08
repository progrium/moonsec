#!/usr/bin/env bash
# Path changes and drops through the S5c lab (lab.sh): a moonsec host and client streaming
# the synthetic test pattern over iroh through two NATs and the lab relay, while the host's
# direct UDP port is blacked out (as S5c does) or its whole link is cut.
#
#   run.sh [all|blackouts|switch|flaps|drop]...      (root; brings the lab up and down)
#
# Scenarios (RTT = 2 x ONEWAY_MS, default 75 ms):
#   blackouts  direct-path outages of 200, 500 and 800 ms at the 1 s idle timeout: video holds
#              on the stall and resumes with a recovery frame.
#   switch     a 4 s direct-path outage at the 300 ms idle timeout: the direct path closes and
#              the relay carries the stream (stock iroh re-punches only after ~1 min, S5c).
#   flaps      six outages of 300-700 ms, 1.2 s apart, at the 1 s idle timeout.
#   drop       the host's link cut for 6 s with a 3 s connection idle timeout: the connection
#              dies, the client redials until the link is back, and the session carries on.
# Each prints both reports (with the path logs) and a summary line, and fails on a peer
# failure or a missed expectation. Env: MOONSEC (zig-out/bin/moonsec), DELAYLINE,
# IROH_RELAY, LAB_DIR (see lab.sh), ONEWAY_MS, KEEP_LAB=1 (leave the lab up), PEER_ARGS
# (extra moonsec peer options for both sides, e.g. "--no-stall-pause").
set -uo pipefail
D=$(cd "$(dirname "$0")" && pwd)
MOONSEC=${MOONSEC:-zig-out/bin/moonsec}
LAB_DIR=${LAB_DIR:-/tmp/moonsec-netlab}
ONEWAY_MS=${ONEWAY_MS:-37.5}
RELAY=https://10.80.9.1:3443
PORT=47300
export LAB_DIR
FAILS=0

fw() { ip netns exec x3h iptables "$@"; }
block_direct()   { fw -I INPUT -p udp --dport $PORT -j DROP; fw -I OUTPUT -p udp --sport $PORT -j DROP; }
unblock_direct() { fw -D INPUT -p udp --dport $PORT -j DROP; fw -D OUTPUT -p udp --sport $PORT -j DROP; }
block_all()      { fw -I INPUT -i vh0 -j DROP; fw -I OUTPUT -o vh0 -j DROP; }
unblock_all()    { fw -D INPUT -i vh0 -j DROP; fw -D OUTPUT -o vh0 -j DROP; }
ms() { sleep "$(awk "BEGIN{print $1/1000}")"; }
RTT_MS=$(awk "BEGIN{print int(2 * $ONEWAY_MS)}")
# Picture-gap bounds: <base> ms plus <k> RTTs (recovery after an outage takes a few RTTs).
bound() { echo $(( $1 + $2 * RTT_MS )); }

# start <name> <seconds> <host/client args...>: both peers in the background.
start() {
  local name=$1 secs=$2; shift 2
  OUT=$LAB_DIR/$name; mkdir -p "$OUT"; rm -f "$OUT/ticket"
  local common=(--ticket-file "$OUT/ticket" --relay-url $RELAY --relay-ca "$LAB_DIR/ca.pem" --seconds "$secs" "$@" ${PEER_ARGS:-})
  ip netns exec x3h "$MOONSEC" peer iroh host --bind 0.0.0.0:$PORT "${common[@]}" > "$OUT/host.log" 2>&1 &
  HOST_PID=$!
  ip netns exec x3c "$MOONSEC" peer iroh client "${common[@]}" > "$OUT/client.log" 2>&1 &
  CLIENT_PID=$!
  # Two seconds of the host's failed sends, for diag (strace is optional).
  if command -v strace >/dev/null; then
    (sleep 1.5; timeout 2 strace -f -qq -e trace=sendmsg,sendmmsg,sendto -e status=failed -p $HOST_PID 2> "$OUT/strace.log" >/dev/null) &
  fi
  # Let it connect, hole-punch (S5c: direct ~0.3 s after dialing) and settle.
  sleep 5
}

# finish: wait for both peers, print their reports, set HOST_OK/CLIENT_OK.
finish() {
  wait $CLIENT_PID; CLIENT_OK=$?
  wait $HOST_PID; HOST_OK=$?
  echo "--- host ($HOST_OK)"; cat "$OUT/host.log"
  echo "--- client ($CLIENT_OK)"; cat "$OUT/client.log"
}

num() { grep -o "$2 [0-9.]*" "$OUT/$1.log" | head -1 | awk '{print $NF}'; }
gap_ms() { grep -o "longest gap [0-9.]*" "$OUT/client.log" | head -1 | awk '{print int($3)}'; }

expect() { # expect <description> <condition...>
  local what=$1; shift
  if "$@"; then echo "  ok: $what"; else echo "  FAIL: $what"; FAILS=$((FAILS + 1)); fi
}

diag() { # where the packets went, when a peer fails
  for n in x3h x3c; do
    echo "  $n udp: $(ip netns exec $n awk '/^Udp:/ { if (h) { for (i = 2; i <= NF; i++) printf "%s=%s ", k[i], $i } else { for (i = 2; i <= NF; i++) k[i] = $i; h = 1 } }' /proc/net/snmp)"
  done
  for l in "x3c vc0" "x3cn vci" "x3cn vcn" "x3d dc" "x3d di" "x3hn vhi" "x3h vh0"; do set -- $l
    echo "  $1 $2: $(ip -n $1 -s -o link show $2 | sed 's/.*RX: *//; s/\\ */ /g' | cut -c1-200)"
  done
  echo "  rmem_max $(sysctl -n net.core.rmem_max) wmem_max $(sysctl -n net.core.wmem_max) default_qdisc $(sysctl -n net.core.default_qdisc) cpus $(nproc) kernel $(uname -r)"
  [ -s "$OUT/strace.log" ] && { echo "  host failed sends ($(grep -c '= -1' "$OUT/strace.log") in 2 s):"; grep '= -1' "$OUT/strace.log" | sed 's/.*= -1/    = -1/' | sort | uniq -c | head -5; }
  for l in "x3h vh0" "x3hn vhn"; do set -- $l
    echo "  $1 $2 qdisc: $(tc -n $1 -s qdisc show dev $2 | tr '\n' ' ' | tr -s ' ' | cut -c1-300)"
  done
}

summary() {
  echo "== $1: host $( [ $HOST_OK = 0 ] && echo pass || echo FAIL ), client $( [ $CLIENT_OK = 0 ] && echo pass || echo FAIL ), longest gap $(gap_ms) ms, host path changes $(num host 'path changes') reconnects $(num host 'reconnects') stalls $(num host 'stalls'), client reconnects $(num client 'reconnects')"
  grep "path log" "$OUT/host.log" "$OUT/client.log" | sed 's/^/  /'
  tail -1 "$LAB_DIR/delayline.log" 2>/dev/null | sed 's/^/  /'
  [ "$HOST_OK" = 0 -a "$CLIENT_OK" = 0 ] || diag
  expect "both peers pass" [ "$HOST_OK" = 0 -a "$CLIENT_OK" = 0 ]
}

blackouts() {
  start blackouts 16 --path-idle-ms 1000 --min-presented 60
  for d in 200 500 800; do block_direct; ms $d; unblock_direct; sleep 3; done
  finish; summary blackouts
  expect "the stream held through every stall" [ "$(num host 'stalls')" -ge 1 ]
  local b; b=$(bound 1300 4)
  expect "longest gap under $b ms" [ "$(gap_ms)" -lt "$b" ]
  expect "no reconnect needed" [ "$(num client 'reconnects')" = 0 ]
}

switch() {
  start switch 16 --path-idle-ms 300
  block_direct; sleep 4; unblock_direct
  finish; summary switch
  expect "moved to the relay" grep -q "relay" <(grep "host path log" "$OUT/host.log")
  local b; b=$(bound 1200 2)
  expect "longest gap under $b ms (the relay took over)" [ "$(gap_ms)" -lt "$b" ]
  expect "no reconnect needed" [ "$(num client 'reconnects')" = 0 ]
}

flaps() {
  start flaps 16 --path-idle-ms 1000 --min-presented 40
  for d in 300 500 700 300 500 700; do block_direct; ms $d; unblock_direct; ms 1200; done
  finish; summary flaps
  expect "stalls seen" [ "$(num host 'stalls')" -ge 3 ]
  local b; b=$(bound 1200 4)
  expect "longest gap under $b ms" [ "$(gap_ms)" -lt "$b" ]
}

drop() {
  start drop 24 --conn-idle-ms 3000 --min-presented 50
  block_all; sleep 6; unblock_all
  finish; summary drop
  expect "client reconnected" [ "$(num client 'reconnects')" -ge 1 ]
  expect "host took the new connection" [ "$(num host 'reconnects')" -ge 1 ]
}

[ "$(id -u)" = 0 ] || { echo "run.sh needs root"; exit 1; }
"$D/lab.sh" down >/dev/null 2>&1
"$D/lab.sh" up "$ONEWAY_MS" || exit 1
[ "${KEEP_LAB:-0}" = 1 ] || trap '"$D/lab.sh" down >/dev/null 2>&1' EXIT
list=("$@"); [ ${#list[@]} = 0 -o "${list[0]:-}" = all ] && list=(blackouts switch flaps drop)
for s in "${list[@]}"; do echo; echo "######## $s (RTT $(awk "BEGIN{print 2*$ONEWAY_MS}") ms)"; $s; done
echo; [ $FAILS = 0 ] && echo "netlab: PASS" || echo "netlab: $FAILS FAILED"
[ $FAILS = 0 ]
