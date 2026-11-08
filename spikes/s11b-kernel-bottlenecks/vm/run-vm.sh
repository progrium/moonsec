#!/bin/bash
# usage: run-vm.sh guest-script.sh  (runs inside an emulated Ubuntu 6.8 kernel, host / shared over 9p)
W=/tmp/vm
exec qemu-system-x86_64 -accel tcg,thread=multi -cpu max -smp 4 -m 4G -kernel $W/vmlinuz -initrd $W/initrd.gz \
  -append "console=ttyS0 quiet panic=-1 clocksource=tsc tsc=reliable guestcmd=$1" -nographic -no-reboot \
  -virtfs local,path=/,mount_tag=hostroot,security_model=none,multidevs=remap,id=r -nic none
