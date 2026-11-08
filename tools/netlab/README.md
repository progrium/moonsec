# netlab: path changes and reconnects through two NATs

Spike S5c's network-namespace lab ([`spikes/s5c-idle-timeout`](../../spikes/s5c-idle-timeout/README.md)),
made reusable: two Linux NATs that forward no port, a local iroh-relay with QUIC address
discovery, and a userspace delay line, so the direct and the relay path both see the RTT.
[`run.sh`](run.sh) streams the synthetic test pattern between a `moonsec` host and client
through it and breaks the path while they run.

```
x3h host 172.16.5.2 -- x3hn NAT ------------------------- x3i router (relay 10.80.9.1)
x3c client 192.168.9.2 -- x3cn NAT -- x3d delay line -- x3i
```

```sh
zig build install-moonsec delayline -Doptimize=ReleaseSafe
sudo IROH_RELAY=$(which iroh-relay) tools/netlab/run.sh all      # ~2 minutes; CI runs it on linux-x86_64
sudo tools/netlab/run.sh switch                                    # one scenario
sudo ONEWAY_MS=125 tools/netlab/run.sh blackouts                   # 250 ms RTT
sudo PEER_ARGS=--no-stall-pause tools/netlab/run.sh flaps          # without holding video on a stall
```

Needs Linux, root, iproute2, iptables, ethtool, openssl, and `iroh-relay` 1.4.1
(`cargo install iroh-relay@1.4.1 --features server --locked`). `lab.sh up|down` brings the
lab up and down on its own; the relay's TLS comes from a throwaway CA in `$LAB_DIR`
(default `/tmp/moonsec-netlab`), which the peers trust with `--relay-ca`.

[`delayline.zig`](delayline.zig) is `s5c delayline` in Zig: AF_PACKET sockets on two
interfaces, every frame forwarded `oneway_ms` later. The cloud VMs (and S5c's) have no
`sch_netem`.

## Scenarios

Outages block the host's direct UDP port in both directions, as S5c does; the relay is TCP
and stays up. A drop cuts the host's whole link.

| Scenario | Path idle timeout | What happens | Checks |
| --- | --- | --- | --- |
| `blackouts` | 1000 ms | outages of 200, 500, 800 ms, 3 s apart | video holds on the stalls; gap < 1.3 s + 4 RTT; no reconnect |
| `switch` | 300 ms | a 4 s outage | the direct path closes, the relay carries the stream; gap < 1.2 s + 2 RTT; no reconnect |
| `flaps` | 1000 ms | six outages of 300-700 ms, 1.2 s apart | video holds and resumes; gap < 1.2 s + 4 RTT |
| `drop` | 300 ms, connection idle 3 s | the host's link cut for 6 s | the connection dies; the client redials until the link is back; both sides move to the new connection |

Every scenario also needs both peers to pass: a clean end, every presented frame's pattern
read back, no corrupt access unit, and a share of the frames presented (60% for
`blackouts`, 80% for `switch`, 40% for `flaps`, 50% for `drop`).

## Results (75 ms RTT, this branch)

| Scenario | Longest picture gap | Path log (host) |
| --- | --- | --- |
| `blackouts` | 1016 ms | direct; stall 4.23 → resume 4.31; stall 7.48 → 7.94; stall 11.02 → 11.78 |
| `switch` | 434 ms | direct; stall 4.23; relay 4.39; direct again 9.36 (1.3 s after the outage) |
| `flaps` | 933 ms | six stall/resume pairs, 0.08-0.67 s each |
| `drop` | 6515 ms | stall 4.22; relay 4.38; reconnected 10.49 (client: redial 6.16, 8.17, 10.17; up 10.50) |

Holding video on a stall shortened the longest gap by 130-150 ms (two runs each):
`blackouts` 1150-1166 → 1015-1017 ms and `flaps` 1056-1072 → 933 ms, `--no-stall-pause`
→ default. The likely reason: without the hold, the frames encoded during the outage wait
in iroh's send buffer behind the dead path and go out late when it comes back (not
measured directly).

In `switch`, stock iroh went direct again 1.3 s after the outage ended, in both runs, not
the 21-57 s S5c measured with the same iroh. Why is not established: the harness differs
(S5c's own Rust host and client, Cubic), the outage here is 4 s, and the relay carries
10 Mbit/s of media. Worth a closer look before the idle-timeout decision leans on the
re-punch delay.

At 250 ms RTT (`ONEWAY_MS=125`) all four pass too: longest gap 1666 ms in `blackouts`,
1238 ms in `switch`, 1350 ms in `flaps`, and 7349 ms in `drop` (with the reconnect).
