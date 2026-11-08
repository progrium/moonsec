#!/usr/bin/env bash
# S5c lab: S10's two-NAT topology plus a local relay and a delay line.
#
#   x3h 172.16.5.2 -- x3hn [172.16.5.1 | 10.80.1.3] ------------------- x3i (router, relay on 10.80.9.1)
#   x3c 192.168.9.2 -- x3cn [192.168.9.1 | 10.80.0.2] -- x3d (delay line) -- x3i
#
# Both NATs are Linux MASQUERADE (port-preserving, endpoint-independent mapping), and unlike
# S10 neither forwards any port: the host is reachable only through the relay, as in S5b
# (AWS security group + home NAT). Unsolicited inbound UDP to a NAT is dropped in INPUT,
# which keeps conntrack from confirming an entry that would make MASQUERADE pick another
# port for the outgoing punch (the poisoning S10 hit).
# The delay line sits on the client side, so every path (direct and relay) gets the same RTT:
# RTT = 2 x one-way.
#
# Usage: lab.sh up <oneway_ms> | down | delay <oneway_ms>
set -euo pipefail
OW=${2:-0}
D=$(cd "$(dirname "$0")" && pwd)
BIN=${S5C_BIN:-$D/../target/release/s5c}
NS="x3h x3hn x3i x3d x3cn x3c"
veth() { ip link add name "$2" type veth peer name "$4"; ip link set "$2" netns "$1"; ip link set "$4" netns "$3"; }
start_delay() {
  pkill -f "s5c delayline" 2>/dev/null || true; sleep 0.2
  ip netns exec x3d taskset -c 3 "$BIN" delayline dc di "$1" > /tmp/s5c-delayline.log 2>&1 &
  sleep 0.3
}
case "${1:-}" in
up)
  for n in $NS; do ip netns add $n; ip -n $n link set lo up; done
  veth x3h vh0 x3hn vhi
  veth x3hn vhn x3i vih
  veth x3cn vcn x3d dc
  veth x3d di x3i vic
  veth x3c vc0 x3cn vci
  ip -n x3h addr add 172.16.5.2/24 dev vh0; ip -n x3hn addr add 172.16.5.1/24 dev vhi
  ip -n x3hn addr add 10.80.1.3/24 dev vhn; ip -n x3i addr add 10.80.1.1/24 dev vih
  ip -n x3cn addr add 10.80.0.2/24 dev vcn; ip -n x3i addr add 10.80.0.1/24 dev vic
  ip -n x3c addr add 192.168.9.2/24 dev vc0; ip -n x3cn addr add 192.168.9.1/24 dev vci
  ip -n x3i addr add 10.80.9.1/32 dev lo
  for l in "x3h vh0" "x3hn vhi" "x3hn vhn" "x3i vih" "x3i vic" "x3cn vcn" "x3cn vci" "x3c vc0" "x3d dc" "x3d di"; do
    set -- $l; ip -n $1 link set $2 up
    ip netns exec $1 ethtool -K $2 tso off gso off gro off tx off rx off >/dev/null 2>&1 || true
  done
  ip -n x3d link set dc promisc on; ip -n x3d link set di promisc on
  ip -n x3h route add default via 172.16.5.1
  ip -n x3c route add default via 192.168.9.1
  ip -n x3hn route add default via 10.80.1.1; ip -n x3cn route add default via 10.80.0.1
  for n in x3hn x3i x3cn; do ip netns exec $n sysctl -qw net.ipv4.ip_forward=1; done
  for n in "x3hn vhn vhi" "x3cn vcn vci"; do set -- $n
    ip netns exec $1 iptables -t nat -A POSTROUTING -o $2 -j MASQUERADE
    ip netns exec $1 iptables -A FORWARD -i $2 -o $3 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ip netns exec $1 iptables -A FORWARD -i $2 -o $3 -j DROP
    ip netns exec $1 iptables -A INPUT -i $2 -p udp -j DROP
  done
  start_delay "$OW"
  ;;
delay) start_delay "$2" ;;
down)
  pkill -f "s5c delayline" 2>/dev/null || true
  for n in $NS; do ip netns del $n 2>/dev/null || true; done ;;
*) echo "usage: $0 up <oneway_ms> | down | delay <oneway_ms>"; exit 1 ;;
esac
