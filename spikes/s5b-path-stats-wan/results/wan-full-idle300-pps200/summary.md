# S5b run wan-full-idle300-pps200

plan=full, cfg=300:100, pps=200, hold_scale=1

clock offset host-client +39.5 ms (from 289 min-RTT probes, min RTT 73.6 ms)

## Connect (dialed by key + relay URL only)
- connect to first direct Selected: 548 ms, addr Ip(54.149.165.58:47001)

## Steps
| step | window s | probe RTT p10/p50/p90 ms | client stats rtt p50 (sel) | host stats rtt p50 (sel) | host direct lost/sent | client media loss | max media gap ms | client path events | host path events |
|---|---|---|---|---|---|---|---|---|---|
| block | 5.9 | 74.8/76.1/110.3 | 77.8 | 76.3 | 0/27 (0.00%) | 0.00% | 323 | Cd@358 Sr@358 | Cd@317 Sr@317 |
| unblock | 30.0 | 74.8/75.8/78.7 | 76.2 | 75.9 | 0/5292 (0.00%) | 0.00% | 52 | Od@14898 Sd@14898 Od@14980 Sd@14980 Cd@14980 | Od@14936 Sd@14936 Od@15020 Cd@15024 Sd@15024 |
| loss_2 | 10.1 | 80.8/1747.6/3181.5 | 75.9 | 75.7 | 27/1605 (1.68%) | 1.29% | 66 |  |  |
| loss_0 | 4.1 | 466.4/1482.8/2339.0 | 75.9 | 75.6 | 0/1371 (0.00%) | 0.37% | 64 |  |  |
| loss_5 | 10.1 | 830.4/3969.8/4404.6 | 75.9 | 76.1 | 56/836 (6.70%) | 24.90% | 105 | Od@4436 Cd@4436 Od@4553 Cd@4553 | Od@4474 Cd@4475 Od@4590 Cd@4591 |
| loss_0 | 4.1 | 1413.4/2183.2/2816.2 | 75.7 | 75.6 | 0/1376 (0.00%) | 3.78% | 69 |  |  |
| loss_20 | 10.1 | 74.9/76.7/1097.5 | 77.4 | 76.3 | 28/186 (15.05%) | 0.00% | 471 | Cd@1681 Sr@1681 | Cd@1718 Sr@1718 |
| loss_0 | 4.1 | 74.6/75.9/79.8 | 76.7 | 76.0 | 0/0 (0.00%) | 0.00% | 52 |  |  |
| blackout_100 | 26.3 | 74.7/75.9/80.5 | 76.6 | 76.1 | 0/0 (0.00%) | 0.00% | 51 |  |  |
| blackout_150 | 9.8 | 74.8/75.9/78.3 | 76.4 | 76.1 | 0/6 (0.00%) | 0.00% | 14 | Od@9750 Sd@9750 | Od@9787 Sd@9787 |
| blackout_200 | 26.4 | 74.8/75.9/78.0 | 76.4 | 76.1 | 0/12 (0.00%) | 0.00% | 292 | Od@9 Sd@10 Cd@10 Cd@763 Sr@763 | Cd@361 Sr@361 |
| blackout_250 | 26.4 | 74.8/75.8/77.6 | 76.4 | 76.0 | 0/0 (0.00%) | 0.00% | 19 |  |  |
| blackout_300 | 7.2 | 74.9/76.0/78.4 | 76.5 | 76.2 | 0/4 (0.00%) | 0.00% | 17 | Od@7152 Sd@7153 | Od@7191 Sd@7191 |
| blackout_400 | 26.7 | 74.4/75.6/77.8 | 76.2 | 75.9 | 0/14 (0.00%) | 0.00% | 664 | Od@17 Sd@17 Cd@17 Cd@770 Sr@770 | Cd@726 Sr@726 |
| blackout_600 | 26.8 | 74.7/75.8/77.7 | 76.3 | 76.1 | 0/0 (0.00%) | 0.00% | 20 |  |  |
| block | 43.2 | 74.7/75.8/77.7 | 76.4 | 76.1 | 0/0 (0.00%) | 0.00% | 26 |  |  |
| unblock | 9.4 | 74.6/75.8/78.3 | 76.2 | 76.2 | 0/9 (0.00%) | 0.00% | 15 | Od@9376 Sd@9376 Od@9448 Sd@9449 | Od@9416 Sd@9416 |

## Wire (host tcpdump, peer 71.116.60.17) after unblock
- unblock@1794095501.2: first in +14784 ms, first out +14784 ms, host Selected(direct) +14936 ms, client Selected(direct) +14898 ms
- unblock@1794095766.5: first in +9261 ms, first out +9259 ms, host Selected(direct) +9416 ms, client Selected(direct) +9376 ms

## Path switches by step (client / host)
- block: client ['selected-closed', 'sel->relay'], host ['selected-closed', 'sel->relay']
- unblock: client ['sel->direct', 'sel->direct'], host ['sel->direct', 'selected-closed', 'sel->direct']
- loss_20: client ['selected-closed', 'sel->relay'], host ['selected-closed', 'sel->relay']
- blackout_150: client ['sel->direct'], host ['sel->direct']
- blackout_200: client ['sel->direct', 'selected-closed', 'sel->relay'], host ['selected-closed', 'sel->relay']
- blackout_300: client ['sel->direct'], host ['sel->direct']
- blackout_400: client ['sel->direct', 'selected-closed', 'sel->relay'], host ['selected-closed', 'sel->relay']
- unblock: client ['sel->direct', 'sel->direct'], host ['sel->direct']

client stats poll cost p50 4.1 us, p99 218.6 us
