# Sourced inside the guest. Three namespaces:
#   snd (10.0.1.1) --s0/r0-- rtr --r1/c0-- rcv (10.0.2.2)
# Forward propagation: netem on s0 egress. Reverse: netem on c0 egress.
# Bottleneck: r1 egress, HTB class at RATE with a leaf of AQM (bfifo:<bytes> | fq_codel).
S11=${S11:-/home/claude/moonsec/spikes/s11-capacity-estimation/zig-out-v2/bin/s11net}
export TMPDIR=/run
X() { "$@" || echo "FAILED: $*" >&2; }

topo_up() { # owd_ms
  local owd=${1:-10}
  for m in veth sch_htb sch_netem sch_fq_codel tcp_bbr; do modprobe $m 2>/dev/null; done
  for n in snd rtr rcv; do ip netns add $n; ip -n $n link set lo up; done
  ip link add s0 netns snd type veth peer name r0 netns rtr
  ip link add r1 netns rtr type veth peer name c0 netns rcv
  ip -n snd addr add 10.0.1.1/24 dev s0; ip -n rtr addr add 10.0.1.2/24 dev r0
  ip -n rtr addr add 10.0.2.1/24 dev r1; ip -n rcv addr add 10.0.2.2/24 dev c0
  for p in "snd s0" "rtr r0" "rtr r1" "rcv c0"; do set -- $p
    ip -n $1 link set $2 up
    ip netns exec $1 ethtool -K $2 tso off gso off gro off >/dev/null 2>&1
  done
  ip -n snd route add default via 10.0.1.2; ip -n rcv route add default via 10.0.2.1
  ip netns exec rtr sysctl -qw net.ipv4.ip_forward=1
  [ "$owd" = 0 ] && return
  X tc -n snd qdisc add dev s0 root netem delay ${owd}ms limit 100000
  X tc -n rcv qdisc add dev c0 root netem delay ${owd}ms limit 100000
}

bottleneck() { # rate_mbit aqm   (aqm: bfifo:BYTES | fq_codel | none)
  tc -n rtr qdisc del dev r1 root 2>/dev/null
  X tc -n rtr qdisc add dev r1 root handle 1: htb default 1
  X tc -n rtr class add dev r1 parent 1: classid 1:1 htb rate ${1}mbit ceil ${1}mbit burst 3000 cburst 3000
  case $2 in
    bfifo:*) X tc -n rtr qdisc add dev r1 parent 1:1 handle 10: bfifo limit ${2#bfifo:} ;;
    fq_codel) X tc -n rtr qdisc add dev r1 parent 1:1 handle 10: fq_codel ;;
  esac
}

set_rate() { X tc -n rtr class change dev r1 parent 1: classid 1:1 htb rate ${1}mbit ceil ${1}mbit burst 3000 cburst 3000; }

topo_down() { for n in snd rtr rcv; do ip netns del $n 2>/dev/null; done; }
