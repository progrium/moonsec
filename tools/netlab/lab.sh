#!/usr/bin/env bash
# The netns lab from spike S5c (spikes/s5c-idle-timeout): two NATs, a local relay with QUIC
# address discovery, and a delay line, so the direct and relay paths both see the RTT.
#
#   x3h host 172.16.5.2 -- x3hn NAT [172.16.5.1 | 10.80.1.3] ----------------------- x3i router
#   x3c client 192.168.9.2 -- x3cn NAT [192.168.9.1 | 10.80.0.2] -- x3d delay -- x3i (relay 10.80.9.1)
#
# Both NATs are Linux MASQUERADE (port-preserving) and neither forwards a port, so the host
# is reachable only through the relay until hole punching opens a direct path, as on the
# internet (S5b). Unsolicited inbound UDP to a NAT is dropped in INPUT, which keeps
# conntrack from making MASQUERADE pick another port for the outgoing punch (S10).
#
# The relay is iroh-relay 1.4.1 with TLS from a lab CA ($LAB_DIR/ca.pem, which the peers
# trust through --relay-ca) on https://10.80.9.1:3443, and QUIC address discovery on 7842.
#
# Usage: lab.sh up <oneway_ms> | down | delay <oneway_ms>
# Env: DELAYLINE (default zig-out/bin/delayline), IROH_RELAY (default iroh-relay on PATH),
#      LAB_DIR (default /tmp/moonsec-netlab). Linux, root, iproute2, iptables, openssl.
set -euo pipefail
OW=${2:-0}
DELAYLINE=${DELAYLINE:-zig-out/bin/delayline}
IROH_RELAY=${IROH_RELAY:-$(command -v iroh-relay || echo iroh-relay)}
LAB_DIR=${LAB_DIR:-/tmp/moonsec-netlab}
NS="x3h x3hn x3i x3d x3cn x3c"

veth() { ip link add name "$2" type veth peer name "$4"; ip link set "$2" netns "$1"; ip link set "$4" netns "$3"; }

start_delay() {
  pkill -f "delayline dc di" 2>/dev/null || true; sleep 0.2
  ip netns exec x3d "$DELAYLINE" dc di "$1" > "$LAB_DIR/delayline.log" 2>&1 &
  sleep 0.3
}

certs() {
  [ -f "$LAB_DIR/relay.crt" ] && return 0
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$LAB_DIR/ca.key" 2>/dev/null
  openssl req -x509 -new -key "$LAB_DIR/ca.key" -days 30 -subj "/CN=moonsec netlab CA" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -out "$LAB_DIR/ca.pem" 2>/dev/null
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$LAB_DIR/relay.key" 2>/dev/null
  openssl req -new -key "$LAB_DIR/relay.key" -subj "/CN=10.80.9.1" -out "$LAB_DIR/relay.csr" 2>/dev/null
  printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=IP:10.80.9.1\n' > "$LAB_DIR/relay.ext"
  openssl x509 -req -in "$LAB_DIR/relay.csr" -CA "$LAB_DIR/ca.pem" -CAkey "$LAB_DIR/ca.key" -CAcreateserial \
    -days 30 -extfile "$LAB_DIR/relay.ext" -out "$LAB_DIR/relay.crt" 2>/dev/null
}

start_relay() {
  cat > "$LAB_DIR/relay.toml" <<TOML
enable_relay = true
http_bind_addr = "10.80.9.1:3340"
enable_quic_addr_discovery = true
enable_metrics = false
[tls]
https_bind_addr = "10.80.9.1:3443"
quic_bind_addr = "10.80.9.1:7842"
cert_mode = "Manual"
manual_cert_path = "$LAB_DIR/relay.crt"
manual_key_path = "$LAB_DIR/relay.key"
TOML
  ip netns exec x3i "$IROH_RELAY" --config-path "$LAB_DIR/relay.toml" > "$LAB_DIR/relay.log" 2>&1 &
  for _ in $(seq 50); do
    ip netns exec x3i bash -c 'exec 3<>/dev/tcp/10.80.9.1/3443' 2>/dev/null && return 0
    sleep 0.1
  done
  echo "relay did not start; see $LAB_DIR/relay.log" >&2; cat "$LAB_DIR/relay.log" >&2; return 1
}

case "${1:-}" in
up)
  command -v ethtool >/dev/null || { echo "lab.sh: needs ethtool (to turn the veth offloads off)" >&2; exit 1; }
  mkdir -p "$LAB_DIR"
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
    # The peers' own interfaces keep their offloads: with checksum offload off, the 6.8
    # kernel (GitHub's runners) fails every UDP GSO send with EIO, which noq-udp drops
    # silently. The first forwarding hop (offloads off) then checksums and segments.
    case "$l" in "x3h vh0" | "x3c vc0") continue ;; esac
    # One feature at a time: ethtool -K gives up on the rest when one can't change, and a
    # GSO or GRO super-packet is more than the delay line can write to the other side.
    for f in tso gso gro lro tx rx tx-udp-segmentation rx-udp-gro-forwarding rx-gro-list; do
      ip netns exec $1 ethtool -K $2 $f off >/dev/null 2>&1 || true
    done
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
  certs
  start_relay
  ;;
delay) start_delay "$2" ;;
down)
  pkill -f "delayline dc di" 2>/dev/null || true
  pkill -f "config-path $LAB_DIR/relay.toml" 2>/dev/null || true
  for n in $NS; do ip netns del $n 2>/dev/null || true; done ;;
*) echo "usage: $0 up <oneway_ms> | down | delay <oneway_ms>"; exit 1 ;;
esac
