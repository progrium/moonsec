# S5b run wan-soak-idle300

plan=soak:600, cfg=300:100, pps=2000, hold_scale=1

clock offset host-client +34.6 ms (from 664 min-RTT probes, min RTT 73.5 ms)

## Connect (dialed by key + relay URL only)
- connect to first direct Selected: 539 ms, addr Ip(54.149.165.58:47001)

## Steps
| step | window s | probe RTT p10/p50/p90 ms | client stats rtt p50 (sel) | host stats rtt p50 (sel) | host direct lost/sent | client media loss | max media gap ms | client path events | host path events |
|---|---|---|---|---|---|---|---|---|---|
| mark_soak | 659.6 | 75.3/76.7/84.9 | 76.2 | 76.1 | 28/1275098 (0.00%) | 0.09% | 72 | Cd@600556 Sr@600556 Od@659572 |  |

## Wire (host tcpdump, peer 71.116.60.17) after unblock

## Path switches by step (client / host)
- mark_soak: client ['selected-closed', 'sel->relay'], host []

client stats poll cost p50 5.7 us, p99 580.0 us
