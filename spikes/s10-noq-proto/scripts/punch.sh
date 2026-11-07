#!/usr/bin/env bash
# Punch demo across two NATs. Usage: scripts/punch.sh preserve|random  (root)
set -uo pipefail
D=$(cd "$(dirname "$0")" && pwd)
B=$D/../harness/zig-out-rv/bin/s10
$D/natns.sh down; $D/natns.sh up "${1:-preserve}"
ip netns exec s10h "$B" punch role=host bind=172.16.5.2:7700 iroh_bind=172.16.5.2:7500 &
HP=$!; sleep 0.5
ip netns exec s10c timeout 20 "$B" punch role=client bind=192.168.9.2:7700 iroh_bind=192.168.9.2:0 peer=10.80.1.3:7500 pings=1000
sleep 0.5; kill $HP 2>/dev/null; wait $HP 2>/dev/null
for n in s10hn s10cn; do echo "$n:"; ip netns exec $n conntrack -L -p udp 2>/dev/null; done
$D/natns.sh down
