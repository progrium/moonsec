# S5b run wan-full-idle1000

plan=full, cfg=1000:200, pps=200, hold_scale=1

clock offset host-client +42.1 ms (from 173 min-RTT probes, min RTT 69.8 ms)

## Connect (dialed by key + relay URL only)
- connect to first direct Selected: 528 ms, addr Ip(54.149.165.58:47002)

## Steps
| step | window s | probe RTT p10/p50/p90 ms | client stats rtt p50 (sel) | host stats rtt p50 (sel) | host direct lost/sent | client media loss | max media gap ms | client path events | host path events |
|---|---|---|---|---|---|---|---|---|---|
| block | 6.5 | 73.2/74.3/103.3 | 74.7 | 74.6 | 0/20 (0.00%) | 0.00% | 1012 | Cd@1035 Sr@1035 | Cd@1000 Sr@1000 |
| unblock | 63.1 | 71.5/74.1/76.7 | 74.8 | 74.8 | 0/5234 (0.00%) | 0.00% | 53 | Od@48059 Sd@48059 | Od@48096 Sd@48096 |
| loss_2 | 10.1 | 112.7/1243.6/3161.7 | 71.8 | 71.8 | 25/1517 (1.65%) | 1.14% | 68 |  |  |
| loss_0 | 4.1 | 102.1/1161.2/2099.8 | 71.6 | 71.4 | 0/1517 (0.00%) | 0.00% | 52 |  |  |
| loss_5 | 10.1 | 382.0/3822.5/4398.8 | 71.9 | 72.0 | 44/1127 (3.90%) | 12.85% | 58 |  |  |
| loss_0 | 4.1 | 1620.0/2399.1/3105.4 | 71.8 | 71.6 | 0/1269 (0.00%) | 14.16% | 52 |  |  |
| loss_20 | 10.1 | 3697.1/4319.2/4404.5 | 72.4 | 72.8 | 115/615 (18.70%) | 56.25% | 386 |  |  |
| loss_0 | 4.2 | 1753.0/2581.9/3267.9 | 71.8 | 71.6 | 1/1572 (0.06%) | 2.14% | 57 |  |  |
| blackout_100 | 6.3 | 71.0/72.7/1137.1 | 72.0 | 71.6 | 27/2840 (0.95%) | 0.00% | 228 |  |  |
| blackout_150 | 6.4 | 70.8/71.7/73.6 | 71.7 | 71.4 | 27/2190 (1.23%) | 0.00% | 237 |  |  |
| blackout_200 | 6.3 | 70.7/71.7/73.4 | 71.7 | 71.4 | 49/2197 (2.23%) | 0.00% | 229 |  |  |
| blackout_250 | 6.5 | 70.8/71.7/75.3 | 71.7 | 71.4 | 36/2212 (1.63%) | 0.00% | 424 |  |  |
| blackout_300 | 6.5 | 70.7/71.7/74.0 | 71.7 | 71.6 | 37/2213 (1.67%) | 0.00% | 434 |  |  |
| blackout_400 | 6.6 | 70.9/71.8/76.7 | 71.8 | 71.6 | 43/2214 (1.94%) | 0.00% | 564 |  |  |
| blackout_600 | 6.9 | 70.8/71.6/245.8 | 71.5 | 71.5 | 71/2304 (3.08%) | 0.00% | 713 |  |  |
| block | 4.5 | 73.5/74.8/126.3 | 75.0 | 74.8 | 0/43 (0.00%) | 0.00% | 1005 | Cd@1033 Sr@1034 | Cd@995 Sr@995 |
| unblock | 12.2 | 73.5/74.6/86.2 | 74.9 | 75.0 | 0/0 (0.00%) | 0.00% | 53 | Od@12214 |  |

## Wire (host tcpdump, peer 71.116.60.17) after unblock
- unblock@1794096171.6: first in +47950 ms, first out +47950 ms, host Selected(direct) +48096 ms, client Selected(direct) +48059 ms
- unblock@1794096327.5: first in +12066 ms, first out +12066 ms, host Selected(direct) never, client Selected(direct) never

## Path switches by step (client / host)
- block: client ['selected-closed', 'sel->relay'], host ['selected-closed', 'sel->relay']
- unblock: client ['sel->direct'], host ['sel->direct']
- block: client ['selected-closed', 'sel->relay'], host ['selected-closed', 'sel->relay']

client stats poll cost p50 3.9 us, p99 202.0 us
