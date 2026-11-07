#!/usr/bin/env bash
# Punch-demo topology, both peers behind their own NAT:
#   s10h 172.16.5.2 -- s10hn [172.16.5.1 | 10.80.1.3] -- s10i (router) -- [10.80.0.2 | 192.168.9.1] s10cn -- s10c 192.168.9.2
# The router hop in the middle lets a TTL=2 probe open the sender's own NAT mapping and die
# before it reaches (and poisons) the other NAT. The host NAT forwards only the host's iroh port (7500), standing in for "iroh reached the
# host somehow" (relay + its own hole punch). The media ports are never forwarded: media must punch.
# Usage: natns.sh up [preserve|random] | down
#   preserve: MASQUERADE (keeps the source port when free: endpoint-independent, port-preserving)
#   random:   client NAT maps to a random port per flow (MASQUERADE --to-ports 20000-60000 --random), symmetric-like
set -euo pipefail
MODE=${2:-preserve}
case "${1:-}" in
up)
  for n in s10h s10hn s10i s10cn s10c; do ip netns add $n; ip -n $n link set lo up; done
  ip link add vh0 netns s10h type veth peer name vhi netns s10hn
  ip link add vhn netns s10hn type veth peer name vih netns s10i
  ip link add vcn netns s10cn type veth peer name vic netns s10i
  ip link add vc0 netns s10c type veth peer name vci netns s10cn
  ip -n s10h addr add 172.16.5.2/24 dev vh0; ip -n s10hn addr add 172.16.5.1/24 dev vhi
  ip -n s10hn addr add 10.80.1.3/24 dev vhn; ip -n s10i addr add 10.80.1.1/24 dev vih
  ip -n s10cn addr add 10.80.0.2/24 dev vcn; ip -n s10i addr add 10.80.0.1/24 dev vic
  ip -n s10c addr add 192.168.9.2/24 dev vc0; ip -n s10cn addr add 192.168.9.1/24 dev vci
  for l in "s10h vh0" "s10hn vhi" "s10hn vhn" "s10i vih" "s10i vic" "s10cn vcn" "s10cn vci" "s10c vc0"; do set -- $l; ip -n $1 link set $2 up; done
  ip -n s10h route add default via 172.16.5.1
  ip -n s10c route add default via 192.168.9.1
  ip -n s10hn route add default via 10.80.1.1; ip -n s10cn route add default via 10.80.0.1
  for n in s10hn s10i s10cn; do ip netns exec $n sysctl -qw net.ipv4.ip_forward=1; done
  crand=""; [ "$MODE" = random ] && crand="--to-ports 20000-60000 --random"
  ip netns exec s10hn iptables -t nat -A POSTROUTING -o vhn -j MASQUERADE
  ip netns exec s10hn iptables -t nat -A PREROUTING -i vhn -p udp --dport 7500 -j DNAT --to-destination 172.16.5.2:7500
  if [ -n "$crand" ]; then
    ip netns exec s10cn iptables -t nat -A POSTROUTING -o vcn -p udp -j MASQUERADE $crand
  fi
  ip netns exec s10cn iptables -t nat -A POSTROUTING -o vcn -j MASQUERADE
  for n in "s10hn vhn vhi" "s10cn vcn vci"; do set -- $n
    ip netns exec $1 iptables -A FORWARD -i $2 -o $3 -m conntrack --ctstate ESTABLISHED,RELATED,DNAT -j ACCEPT
    ip netns exec $1 iptables -A FORWARD -i $2 -o $3 -j DROP
  done
  ;;
down) for n in s10h s10hn s10i s10cn s10c; do ip netns del $n 2>/dev/null || true; done ;;
*) echo "usage: $0 up [preserve|random] | down"; exit 1 ;;
esac
