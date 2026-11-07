#!/bin/sh
# Run the S5b host side on a Linux machine. Everything lives under /tmp/moonsec-spikes.
# Needs: git, curl, a C toolchain (cc), sudo for iptables/tc/tcpdump.
set -eu
W=/tmp/moonsec-spikes
mkdir -p $W && cd $W
export RUSTUP_HOME=$W/rustup CARGO_HOME=$W/cargo PATH=$W/cargo/bin:$PATH
if ! command -v cargo >/dev/null 2>&1; then
  curl -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile minimal
fi
[ -d s5b-src ] || git clone -q --depth 1 -b s5b-wan-harness https://github.com/progrium/moonsec s5b-src
cd s5b-src && git pull -q && cd spikes/s5b-path-stats-wan
cargo build --release
for t in iptables tc tcpdump; do command -v $t >/dev/null || echo "MISSING: $t"; done
lsmod | grep -q sch_netem || sudo modprobe sch_netem || echo "MISSING: sch_netem kernel module"
sudo ./target/release/s5b-path-stats-wan host 2>&1 | tee $W/s5b-host.log
