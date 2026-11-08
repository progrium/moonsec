#!/bin/bash
# Builds /tmp/vm: a stock Ubuntu 6.8 kernel plus a busybox initramfs that mounts the
# host's / over 9p and runs one guest script in a chroot. Needed because the cloud
# container's own kernel has no fq_codel, netem or fq (only htb, tbf and fifo).
set -e
K=${K:-6.8.0-149-generic}; W=/tmp/vm; H=$(cd $(dirname $0) && pwd)
apt-get install -y qemu-system-x86 busybox-static zstd kmod cpio iproute2 iperf3 ethtool >/dev/null
mkdir -p $W/deb $W/ir/{bin,mods,proc,sys,dev,mnt} /lib/modules
(cd $W/deb && apt-get download linux-image-unsigned-$K linux-modules-$K linux-modules-extra-$K && for d in *.deb; do dpkg-deb -x $d root; done)
cp -a $W/deb/root/lib/modules/$K /lib/modules/ && depmod $K       # guest modprobe reads these over 9p
cp $W/deb/root/boot/vmlinuz-$K $W/vmlinuz
cp /bin/busybox $W/ir/bin/
for m in fs/netfs/netfs net/9p/9pnet fs/9p/9p net/9p/9pnet_virtio; do
  zstd -qdf /lib/modules/$K/kernel/$m.ko.zst -o $W/ir/mods/$(basename $m).ko
done
cp $H/init $W/ir/init; chmod +x $W/ir/init
(cd $W/ir && find . | cpio -o -H newc 2>/dev/null | gzip > ../initrd.gz)
# s11net for a CPU that QEMU's TCG can run
(cd $H/../../s11-capacity-estimation && zig build --release=fast -Dcpu=x86_64_v2 -p zig-out-v2)   # gitignored via zig-out*
