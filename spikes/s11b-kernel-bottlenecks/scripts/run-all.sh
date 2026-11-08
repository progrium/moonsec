#!/bin/bash
# Host: boots the emulated kernel once per (scenario, aqm) cell. Results in results/raw/.
cd $(dirname $0)/..; R=$PWD/results/raw; mkdir -p $R
REPS=${REPS:-3}
for cell in ${CELLS:-"steps,fq_codel steps,bfifo:250000 steps,bfifo:62500 cubic,fq_codel cubic,bfifo:500000 bbr,fq_codel bbr,bfifo:500000 cubic,bfifo:125000 bbr,bfifo:125000"}; do
  IFS=, read scen aqm <<< "$cell"
  g=$PWD/vm/cell.$scen.${aqm/:/}.sh
  printf 'SCEN=%s AQM=%s REPS=%s OUT=%s CTLS="%s" bash %s/scripts/matrix.sh\n' $scen $aqm $REPS $R "${CTLS:-gcc gcc-hybrid qdelay-probe tcp-cubic}" $PWD > $g
  echo "$(date +%T) cell $scen $aqm"
  timeout 3600 vm/run-vm.sh $g 2>&1 | grep -E "FAILED|Error|GUEST-DONE" 
done
