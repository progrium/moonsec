# Guest: one (scenario, aqm) cell, all controllers, REPS repetitions.
#   SCEN=steps|cubic|bbr  AQM=bfifo:BYTES|fq_codel  REPS=n  OUT=dir
# steps : 25 -> 10 (t=20 s) -> 40 Mbit/s (t=40 s), alone. Half S11's 50/20/80: the emulated
#         sender tops out near 65 Mbit/s, so an 80 Mbit/s phase measures the emulator, not the controller.
# cubic : 50 Mbit/s, one TCP Cubic flow from t=20 s to t=40 s
# bbr   : same with BBR (v1, the 6.8 kernel's tcp_bbr)
# CTLS  : s11net controllers, plus "tcp-cubic" = a 60 s Cubic flow in our place (reference)
D=$(dirname $0); . $D/topo.sh
CTLS=${CTLS:-"gcc gcc-hybrid qdelay-probe tcp-cubic"}
tag=$SCEN-${AQM/:/}; mkdir -p $OUT
topo_up ${OWD:-10}
ip netns exec rcv $S11 recv --port 9711 >/dev/null 2>&1 &
ip netns exec rcv iperf3 -s -p 5201 -D; ip netns exec rcv iperf3 -s -p 5202 -D
sleep 1
for rep in $(seq 1 $REPS); do for ctl in $CTLS; do
  [ "$SCEN" = steps ] && [ "$ctl" = tcp-cubic ] && continue
  if [ "$SCEN" = steps ]; then bottleneck 25 $AQM; else bottleneck 50 $AQM; fi
  name=$tag-$ctl-r$rep
  if [ "$ctl" = tcp-cubic ]; then
    ip netns exec snd iperf3 -c 10.0.2.2 -p 5202 -C cubic -t 60 -i 0.1 -J --logfile $OUT/$name.us.json &
  else
    ip netns exec snd $S11 send --to 10.0.2.2:9711 --ctl $ctl --seconds 60 --csv $OUT/$name.csv --tag $name 2>&1 | grep RESULT >> $OUT/results.txt &
  fi
  P=$!
  sleep 20
  case $SCEN in
    steps) set_rate 10; sleep 20; set_rate 40; sleep 20 ;;
    cubic|bbr) ip netns exec snd iperf3 -c 10.0.2.2 -p 5201 -C $SCEN -t 20 -i 0.1 -J --logfile $OUT/$name.tcp.json; sleep 20 ;;
  esac
  wait $P
  tc -n rtr -s qdisc show dev r1 > $OUT/$name.qdisc.txt
  sleep 1
done; done
topo_down
