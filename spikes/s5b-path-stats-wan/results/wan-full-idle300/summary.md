# S5b run wan-full-idle300

plan=full, cfg=300:100, pps=2000, hold_scale=1

clock offset host-client +35.8 ms (from 298 min-RTT probes, min RTT 70.9 ms)

## Connect (dialed by key + relay URL only)
- connect to first direct Selected: 531 ms, addr Ip(54.149.165.58:47001)

## Steps
| step | window s | probe RTT p10/p50/p90 ms | client stats rtt p50 (sel) | host stats rtt p50 (sel) | host direct lost/sent | client media loss | max media gap ms | client path events | host path events |
|---|---|---|---|---|---|---|---|---|---|
| block | 45.8 | 1132.5/2371.7/2922.4 | 1991.1 | 1976.5 | 0/446 (0.00%) | 51.91% | 309 | Cd@340 Sr@340 | Cd@301 Sr@301 |
| unblock | 23.9 | 72.4/74.0/2612.1 | 73.4 | 73.5 | 0/32347 (0.00%) | 24.42% | 246 | Od@8802 Sd@8802 | Od@8839 Sd@8839 |
| loss_2 | 10.1 | 73.2/514.0/516.0 | 72.9 | 72.9 | 59/3598 (1.64%) | 82.36% | 40 |  |  |
| loss_0 | 4.1 | 513.6/514.8/516.7 | 72.8 | 72.8 | 0/1916 (0.00%) | 75.86% | 32 |  |  |
| loss_5 | 10.1 | 514.0/515.2/516.9 | 73.2 | 73.2 | 45/1142 (3.94%) | 95.18% | 65 |  |  |
| loss_0 | 4.1 | 513.4/514.5/515.8 | 72.7 | 72.6 | 0/1498 (0.00%) | 81.33% | 34 |  |  |
| loss_20 | 10.2 | 514.4/515.3/516.9 | 73.4 | 73.6 | 127/553 (22.97%) | 98.26% | 286 |  |  |
| loss_0 | 4.1 | 513.4/514.6/515.8 | 72.8 | 72.8 | 0/1221 (0.00%) | 82.39% | 46 |  |  |
| delay_25_0 | 12.1 | 72.1/74.0/513.7 | 72.8 | 72.8 | 0/22244 (0.00%) | 13.33% | 28 |  |  |
| delay_50_0 | 12.1 | 72.0/73.1/74.8 | 72.9 | 72.8 | 0/25707 (0.00%) | 0.00% | 19 |  |  |
| delay_100_0 | 12.1 | 71.9/73.0/74.6 | 72.8 | 72.7 | 0/25697 (0.00%) | 0.00% | 12 |  |  |
| delay_150_0 | 12.1 | 71.9/73.1/74.8 | 72.9 | 72.8 | 0/25699 (0.00%) | 0.00% | 14 |  |  |
| delay_250_0 | 12.1 | 72.0/73.1/74.7 | 72.8 | 72.8 | 0/25699 (0.00%) | 0.00% | 15 |  |  |
| delay_400_0 | 12.1 | 72.0/73.1/74.7 | 72.8 | 72.8 | 0/25708 (0.00%) | 0.00% | 15 |  |  |
| delay_0_0 | 5.1 | 71.9/73.0/74.6 | 72.9 | 72.8 | 0/10787 (0.00%) | 0.00% | 16 |  |  |
| delay_20_10 | 12.1 | 72.0/73.2/74.9 | 72.8 | 72.8 | 0/25690 (0.00%) | 0.00% | 14 |  |  |
| delay_40_30 | 12.1 | 72.3/73.7/75.9 | 73.2 | 73.1 | 0/25717 (0.00%) | 0.00% | 22 |  |  |
| delay_0_0 | 5.1 | 72.1/73.5/75.6 | 73.0 | 73.0 | 0/10808 (0.00%) | 0.00% | 11 |  |  |
| blackout_50 | 0.1 | 73.5/77.4/83.2 | 72.6 | 76.6 | 0/245 (0.00%) | 0.00% | 85 |  |  |
| blackout_100 | 6.1 | 72.3/73.8/76.0 | 73.1 | 73.1 | 168/12939 (1.30%) | 0.00% | 19 |  |  |
| blackout_150 | 0.2 | 165.1/178.8/189.6 | 73.1 | 72.8 | 0/47 (0.00%) | 0.00% | 5 |  |  |
| blackout_200 | 5.8 | 72.3/73.8/76.0 | 73.0 | 73.0 | 53/12673 (0.42%) | 0.00% | 25 |  |  |
| blackout_250 | 0.2 | 72.4/73.6/76.6 | 73.0 | 74.2 | 0/471 (0.00%) | 0.00% | 182 |  |  |
| blackout_300 | 5.8 | 72.3/73.8/75.9 | 73.0 | 73.1 | 363/12292 (2.95%) | 0.00% | 14 |  |  |
| blackout_400 | 0.3 | 457.8/486.4/516.1 | 72.8 | 73.2 | 0/236 (0.00%) | 0.00% | 4 |  |  |
| blackout_600 | 25.8 | 205.0/2843.8/3084.8 | 2484.2 | 2448.8 | 0/0 (0.00%) | 47.73% | 104 | Cd@74 Sr@74 | Cd@113 Sr@113 |
| block | 0.3 | 2744.4/2794.8/2844.7 | 2512.8 | 2485.3 | 0/0 (0.00%) | 36.36% | 101 |  |  |
| unblock | 150.9 | 1074.3/2373.5/2704.8 | 1945.6 | 1965.8 | 0/13751 (0.00%) | 55.56% | 1250 | Od@30862 Sd@30862 Cd@32029 Sr@32029 Od@130918 Sd@130918 Cd@136354 Sr@136354 … | Od@30899 Sd@30899 Cd@31985 Sr@31985 Od@130957 Sd@130957 |

## Wire (host tcpdump, peer 71.116.60.17) after unblock
- unblock@1794095006.6: first in +8690 ms, first out +8617 ms, host Selected(direct) +8839 ms, client Selected(direct) +8802 ms
- unblock@1794095224.5: first in +30752 ms, first out +30753 ms, host Selected(direct) +30899 ms, client Selected(direct) +30862 ms

## Path switches by step (client / host)
- block: client ['selected-closed', 'sel->relay'], host ['selected-closed', 'sel->relay']
- unblock: client ['sel->direct'], host ['sel->direct']
- blackout_600: client ['selected-closed', 'sel->relay'], host ['selected-closed', 'sel->relay']
- unblock: client ['sel->direct', 'selected-closed', 'sel->relay', 'sel->direct', 'selected-closed', 'sel->relay'], host ['sel->direct', 'selected-closed', 'sel->relay', 'sel->direct']

client stats poll cost p50 4.1 us, p99 569.8 us
