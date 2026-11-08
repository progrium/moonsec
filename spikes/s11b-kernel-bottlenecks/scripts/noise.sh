# Guest: timing noise floor of the emulated kernel and a quick sanity pass.
D=$(dirname $0); . $D/topo.sh; O=${OUT:-/tmp/s11b-noise}; mkdir -p $O
cat /sys/devices/system/clocksource/clocksource0/current_clocksource
topo_up 10; bottleneck 1000 bfifo:500000
ip netns exec rcv $S11 recv --port 9711 >/dev/null 2>&1 &
ip netns exec rcv iperf3 -s -D
sleep 1
echo "== fixed 10 Mbit/s, no bottleneck (1 Gbit/s)"
ip netns exec snd $S11 send --to 10.0.2.2:9711 --ctl fixed --mbps 10 --seconds 10 --csv $O/fixed10.csv 2>&1 | grep RESULT
echo "== fixed 40 Mbit/s, no bottleneck"
ip netns exec snd $S11 send --to 10.0.2.2:9711 --ctl fixed --mbps 40 --seconds 10 --csv $O/fixed40.csv 2>&1 | grep RESULT
bottleneck 50 bfifo:500000
echo "== fixed 40 Mbit/s into 50 Mbit/s bfifo"
ip netns exec snd $S11 send --to 10.0.2.2:9711 --ctl fixed --mbps 40 --seconds 10 --csv $O/fixed40b.csv 2>&1 | grep RESULT
echo "== cubic alone, 50 Mbit/s bfifo"
ip netns exec snd iperf3 -c 10.0.2.2 -C cubic -t 8 2>&1 | grep -E "sender|receiver"
echo "== bbr alone, 50 Mbit/s bfifo"
ip netns exec snd iperf3 -c 10.0.2.2 -C bbr -t 8 2>&1 | grep -E "sender|receiver"
echo "== gcc-hybrid, 50 Mbit/s bfifo, 15 s"
ip netns exec snd $S11 send --to 10.0.2.2:9711 --ctl gcc-hybrid --seconds 15 --csv $O/hyb.csv 2>&1 | grep RESULT
topo_down
