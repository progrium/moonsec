# S5b run wan-full-default

plan=full, cfg=-, pps=200, hold_scale=1

clock offset host-client +44.0 ms (from 150 min-RTT probes, min RTT 70.4 ms)

## Connect (dialed by key + relay URL only)
- connect to first direct Selected: 533 ms, addr Ip(54.149.165.58:47003)

## Steps
| step | window s | probe RTT p10/p50/p90 ms | client stats rtt p50 (sel) | host stats rtt p50 (sel) | host direct lost/sent | client media loss | max media gap ms | client path events | host path events |
|---|---|---|---|---|---|---|---|---|---|
| block | 20.6 | 74.6/1883.3/7290.5 | 72.0 | 71.5 | 0/32 (0.00%) | 1.99% | 15012 | Cd@15032 Sr@15032 | Cd@15002 Sr@15002 |
| unblock | 32.7 | 71.5/74.0/77.2 | 75.1 | 74.9 | 0/5234 (0.00%) | 0.00% | 54 | Od@17605 Sd@17605 | Od@17641 Sd@17641 |
| loss_2 | 10.1 | 96.4/3352.0/3949.7 | 72.1 | 72.2 | 30/1417 (2.12%) | 1.49% | 53 |  |  |
| loss_0 | 4.1 | 545.9/1594.9/2576.8 | 72.0 | 72.0 | 1/1490 (0.07%) | 0.61% | 38 |  |  |
| loss_5 | 10.1 | 329.9/3811.2/4398.6 | 72.2 | 72.3 | 56/1120 (5.00%) | 18.10% | 72 |  |  |
| loss_0 | 4.1 | 1721.1/2440.9/3155.7 | 72.0 | 72.3 | 0/1253 (0.00%) | 19.07% | 39 |  |  |
| loss_20 | 10.2 | 3715.0/4356.2/4404.4 | 72.5 | 72.8 | 135/611 (22.09%) | 55.89% | 295 |  |  |
| loss_0 | 4.1 | 1903.1/2803.2/3279.3 | 72.2 | 72.2 | 0/1515 (0.00%) | 0.00% | 41 |  |  |
| blackout_100 | 6.5 | 71.5/72.9/1225.3 | 72.2 | 72.1 | 2/2928 (0.07%) | 0.00% | 311 |  |  |
| blackout_150 | 6.4 | 71.4/72.4/74.9 | 72.3 | 72.1 | 31/2206 (1.41%) | 0.00% | 245 |  |  |
| blackout_200 | 6.4 | 71.4/72.3/74.1 | 72.3 | 72.0 | 36/2220 (1.62%) | 0.00% | 274 |  |  |
| blackout_250 | 6.4 | 71.4/72.4/74.2 | 72.2 | 72.0 | 36/2213 (1.63%) | 0.00% | 282 |  |  |
| blackout_300 | 6.7 | 71.3/72.3/74.8 | 72.2 | 72.1 | 40/2264 (1.77%) | 0.00% | 491 |  |  |
| blackout_400 | 6.8 | 71.4/72.3/77.3 | 72.1 | 72.0 | 72/2288 (3.15%) | 0.00% | 461 |  |  |
| blackout_600 | 7.4 | 71.5/72.4/481.2 | 72.2 | 72.0 | 43/2416 (1.78%) | 0.00% | 891 |  |  |
| block | 18.6 | 74.8/2630.3/7199.5 | 72.0 | 72.2 | 0/40 (0.00%) | 0.00% | 15012 | Cd@15030 Sr@15030 | Cd@15001 Sr@15001 |
| unblock | 1.3 | 73.8/74.8/76.6 | 75.1 | 75.1 | 0/0 (0.00%) | - | 0 | Od@1263 |  |

## Wire (host tcpdump, peer 71.116.60.17) after unblock
- unblock@1794096377.8: first in +17497 ms, first out +17497 ms, host Selected(direct) +17641 ms, client Selected(direct) +17605 ms
- unblock@1794096518.3: first in +1157 ms, first out +1085 ms, host Selected(direct) never, client Selected(direct) never

## Path switches by step (client / host)
- block: client ['selected-closed', 'sel->relay'], host ['selected-closed', 'sel->relay']
- unblock: client ['sel->direct'], host ['sel->direct']
- block: client ['selected-closed', 'sel->relay'], host ['selected-closed', 'sel->relay']

client stats poll cost p50 4.7 us, p99 227.5 us
