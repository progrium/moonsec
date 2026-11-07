# Spike S4: FFI and tokio handoff jitter

**Question:** how much jitter does the Zig→Rust FFI call and the hop onto tokio add between "Zig hands a datagram to the shim" and "the datagram hits the socket"?
**Pass:** handoff p99 under 0.5 ms.
**Fallback named in the design doc:** dedicated current-thread runtime in the shim.

## Verdict

**Pass, but only with the fallback.** iroh datagrams on a dedicated current-thread tokio runtime, on a pinned SCHED_FIFO thread, meet p99 < 0.5 ms in every condition measured (worst case 398 µs; 102 to 183 µs under CPU load). The default shape (iroh on a shared multi-thread runtime) passes when the box is idle but **fails under CPU load, with p99 of 1.0 to 4.0 ms**. So the dedicated runtime should be the shim's default design, not a fallback.

- **The FFI call itself is free.** Zig send → shim entry is p99 ≤ 0.4 µs in every run.
- **All the cost is the cross-thread wakeup.** A plain OS thread on a blocking channel, with no tokio at all, sees roughly the same numbers as tokio current-thread (p50 25 to 115 µs, p99 110 to 290 µs). tokio itself adds little; *which thread it wakes, and whether that thread can run*, is what matters.
- **Pinning + RT priority is what buys the loaded-case pass.** The same dedicated runtime without pinning or RT priority fails under load just like the multi-thread runtime (p99 1.0 to 5.5 ms).
- **The p99.9 tail is 1 to 3 ms everywhere a wakeup is involved**, even for the plain-thread baseline, and even when idle. It does not appear in the synchronous path (p99.9 ≤ 44 µs). That points at the cloud VM's vCPU wake path, not at tokio or iroh, and should be rechecked on bare metal (see "Caveats").

## Results (cloud VM, 4 vCPU Xeon @ 2.1 GHz, Linux 6.18.44-fc-v310)

Handoff = Zig `t0` (just before `s4_send`) → entry of the `sendmsg`/`sendto`/`send` that carries the datagram. Cells are **p50 / p99 / p99.9 in µs**; ✅/❌ is p99 against 0.5 ms.

| Path | idle, isolated | idle, burst | loaded, isolated | loaded, burst |
| --- | --- | --- | --- | --- |
| Sync send in the FFI call (floor, no handoff) | ✅ 1 / **2** / 18 | ✅ 2 / **6** / 44 | ✅ 0 / **2** / 18 | ✅ 1 / **3** / 19 |
| Plain OS thread, blocking channel (no tokio) | ✅ 54 / **157** / 664 | ✅ 114 / **290** / 1768 | ✅ 23 / **111** / 3077 | ✅ 37 / **168** / 2468 |
| Plain OS thread busy-polling (normal prio) | ✅ 3 / **36** / 1529 | ✅ 9 / **65** / 3008 | ❌ 3 / **4920** / 5967 | ❌ 8 / **4000** / 7222 |
| Raw UDP, tokio multi-thread runtime | ✅ 82 / **203** / 1877 | ✅ 151 / **450** / 2129 | ❌ 25 / **3963** / 8960 | ❌ 44 / **4643** / 10046 |
| Raw UDP, dedicated current-thread runtime, pinned + RT | ✅ 51 / **186** / 1445 | ✅ 135 / **311** / 2517 | ✅ 24 / **72** / 956 | ✅ 44 / **109** / 280 |
| iroh datagram, tokio multi-thread runtime | ✅ 98 / **242** / 1007 | ✅ 189 / **413** / 1118 | ❌ 26 / **1040** / 3055 | ❌ 81 / **4024** / 5612 |
| iroh datagram, dedicated current-thread runtime, pinned + RT | ✅ 86 / **213** / 1588 | ✅ 171 / **398** / 1395 | ✅ 36 / **102** / 1043 | ✅ 90 / **183** / 1069 |
| iroh datagram, dedicated current-thread runtime, no pin/RT | ✅ 88 / **242** / 2468 | ✅ 186 / **486** / 3728 | ❌ 26 / **1046** / 3032 | ❌ 83 / **5470** / 10204 |

- *isolated*: one 1150-byte datagram every 1 ms, 20 000 samples.
- *burst*: 36 back-to-back datagrams every 16.7 ms (≈1080p60 at 20 Mbit/s), 1 200 frames. The number is for the **first datagram of each burst**; later datagrams also wait for the previous ones' syscalls, which is serialization and not handoff (all-packet p99s are in the JSON files).
- *loaded*: 6 cache-thrashing busy threads at normal priority on 4 vCPUs.
- Zig sender thread: pinned to CPU 0, SCHED_FIFO 80. Dedicated shim thread (where used): CPU 1, SCHED_FIFO 79. Multi-thread runtime: tokio defaults (4 workers), unpinned, normal priority, as a stock shim would be.
- The busy-poll row has spin thread at normal priority (a SCHED_FIFO spinner gets RT-throttled for 50 ms/s, which produced 25 to 40 ms p99s). Under load it gets preempted by the load threads. Busy-polling is not worth pursuing: it burns a core and still needs RT priority.

Raw numbers: `results/cloud-4vcpu/*.json` (stats) and `*.csv.gz` (every probe timestamp).

## Recommendation for the shim

1. Run the iroh endpoint on its own `current_thread` runtime, on one OS thread created by the shim. Expose a hook (or config fields) so the host app can pin that thread and give it the same real-time class as the media thread (`SCHED_FIFO`/`SCHED_RR` on Linux, `THREAD_PRIORITY_TIME_CRITICAL` + MMCSS "Pro Audio"/"Games" on Windows, `QOS_CLASS_USER_INTERACTIVE` or a time-constraint policy on macOS).
2. Have `send_datagram` call `Connection::send_datagram` directly from the caller's thread (it's thread-safe and costs ~nothing); don't add an extra channel. The only handoff is noq waking its connection driver.
3. Keep everything else iroh does (relay, discovery, DNS) off that thread if iroh allows a second runtime for it, so the media runtime never runs long tasks.
4. Budget ~0.1 to 0.4 ms p99 for this hop in the latency model, and treat the ms-scale p99.9 as platform noise to recheck on target hardware.

## Caveats

- **Cloud VM, not target hardware.** The 1 to 3 ms p99.9 tail on every wakeup path looks like vCPU halt/wake cost in the hypervisor. Rerun on bare-metal Linux and on Windows/macOS hosts (S6/S7 machines) before closing the spike: `./run_matrix.sh` takes about 12 minutes.
- **Loopback only, Linux only.** Windows and macOS have different wake latencies and RT models; this harness is Linux-specific (`SCHED_FIFO`, `sendmsg` interposition).
- **iroh matching is inferred.** QUIC packets are encrypted, so in iroh modes each datagram is matched to the next large (≥ payload size) `sendmsg` segment in FIFO order (GSO sends counted per segment, PMTU probes disabled). Zero datagrams were left unmatched, and received counts equal sent counts.
- The isolated-send idle numbers are *worse* than loaded ones because idle vCPUs go into a deeper halt; a real host streaming at 60 fps is closer to the loaded case.

## How it works

```
Zig sender (pinned, RT)                  Rust shim (staticlib)
  t0 = now; write t0 into header  ──►  s4_send(): t1 = now
                                         ├─ raw_direct: send() inline
                                         ├─ raw_*: channel → task/thread (t2 = pickup) → send_to()
                                         └─ iroh_*: Connection::send_datagram() → noq driver task
                                        libc sendmsg/sendto/send interposer: t3 = entry, t4 = return
```

- `shim/`: Rust staticlib exposing a C ABI (`s4_init`, `s4_send`, `s4_dump`, ...). It defines `sendmsg`, `sendto` and `send` itself and forwards them via `dlsym(RTLD_NEXT)`, so the socket-write timestamp is taken at the real syscall boundary inside noq-udp/mio/std without patching iroh. Probes go into preallocated atomics; nothing allocates on the hot path except the `Bytes` copy a real shim would also make.
- `harness/`: Zig 0.16 executable (links the staticlib). One pinned RT sender thread, optional busy-load threads.
- `analyze.py`: turns the probe dumps into the stats above.

### Running

```
# Zig 0.16: if ziglang.org is unreachable, `pip install ziglang==0.16.0` ships the same binary.
cd shim && cargo build --release && cd ..
cd harness && zig build -Doptimize=ReleaseFast && cd ..
sudo ./run_matrix.sh                 # writes results/$(hostname)/
# single run: harness/zig-out/bin/s4 mode=4 n=20000 interval_us=1000 cpu=0 prio=80 rt_cpu=1 rt_prio=79 load=6 out=/tmp/x
#             python3 analyze.py /tmp/x
```

Modes: 0 raw_direct, 1 raw_tokio_mt, 2 raw_tokio_ct, 3 iroh_mt, 4 iroh_ct, 5 raw_thread, 6 raw_spin.
