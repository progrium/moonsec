#!/usr/bin/env bash
# Topology:  ns s2a (10.71.0.1) --veth-- ns s2m (10.71.0.2 | 10.72.0.2) --veth-- ns s2b (10.72.0.1)
# s2m runs the userspace delay line; the bandwidth cap is a TBF on s2m's egress toward s2b.
# Usage: netns.sh up | down | cap <rate e.g. 100mbit> [burst] [latency]
set -euo pipefail
case "${1:-}" in
up)
  for n in s2a s2m s2b; do ip netns add $n; ip -n $n link set lo up; done
  ip link add va0 netns s2a type veth peer name vma netns s2m
  ip link add vb0 netns s2b type veth peer name vmb netns s2m
  ip -n s2a addr add 10.71.0.1/24 dev va0; ip -n s2m addr add 10.71.0.2/24 dev vma
  ip -n s2b addr add 10.72.0.1/24 dev vb0; ip -n s2m addr add 10.72.0.2/24 dev vmb
  ip -n s2a link set va0 up; ip -n s2m link set vma up; ip -n s2m link set vmb up; ip -n s2b link set vb0 up
  ;;
down) for n in s2a s2m s2b; do ip netns del $n 2>/dev/null || true; done ;;
cap)
  ip netns exec s2m tc qdisc del dev vmb root 2>/dev/null || true
  ip netns exec s2m tc qdisc add dev vmb root tbf rate "$2" burst "${3:-32kb}" latency "${4:-50ms}"
  ;;
uncap) ip netns exec s2m tc qdisc del dev vmb root 2>/dev/null || true ;;
*) echo "usage: $0 up|down|cap RATE [BURST] [LATENCY]|uncap"; exit 1 ;;
esac
