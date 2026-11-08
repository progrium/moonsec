# S5b run wan-full-idle300-kick

plan=full, cfg=300:100, pps=200, hold_scale=1

clock offset host-client +39.7 ms (from 268 min-RTT probes, min RTT 69.7 ms)

## Connect (dialed by key + relay URL only)
- connect to first direct Selected: 531 ms, addr Ip(54.149.165.58:47001)

## Steps
| step | window s | probe RTT p10/p50/p90 ms | client stats rtt p50 (sel) | host stats rtt p50 (sel) | host direct lost/sent | client media loss | max media gap ms | client path events | host path events |
|---|---|---|---|---|---|---|---|---|---|
| block | 5.8 | 73.3/74.3/77.5 | 75.1 | 74.8 | 0/25 (0.00%) | 0.00% | 301 | Cd@332 Sr@332 | Cd@295 Sr@295 |
| unblock | 32.1 | 71.5/73.5/76.2 | 74.5 | 74.5 | 0/5316 (0.00%) | 0.00% | 32 | Od@17010 Sd@17011 Od@17085 Sd@17085 Cd@17086 | Od@17047 Sd@17047 Od@17123 Sd@17123 Cd@17128 |
| loss_2 | 10.1 | 79.7/468.9/1036.0 | 72.0 | 72.0 | 25/1973 (1.27%) | 1.14% | 47 |  |  |
| loss_0 | 4.1 | 71.3/72.2/505.7 | 71.9 | 71.9 | 0/1456 (0.00%) | 0.00% | 27 |  |  |
| loss_5 | 10.1 | 78.8/3733.6/4399.6 | 72.1 | 72.3 | 47/991 (4.74%) | 18.95% | 76 | Od@2504 Cd@2504 Od@2578 Cd@2578 | Od@2541 Cd@2542 Od@2615 Cd@2616 |
| loss_0 | 4.1 | 1368.6/2200.4/3053.5 | 72.1 | 72.1 | 0/1344 (0.00%) | 6.08% | 38 |  |  |
| loss_20 | 10.1 | 3498.7/4360.7/4403.1 | 72.2 | 72.7 | 94/550 (17.09%) | 51.58% | 100 |  |  |
| loss_0 | 4.1 | 1184.1/2016.7/2962.5 | 71.9 | 72.0 | 0/1294 (0.00%) | 2.45% | 42 |  |  |
| blackout_100 | 6.3 | 71.3/72.1/521.7 | 71.9 | 72.0 | 21/2379 (0.88%) | 0.00% | 129 |  |  |
| blackout_150 | 6.4 | 71.3/72.1/73.7 | 71.9 | 72.0 | 28/2221 (1.26%) | 0.00% | 229 |  |  |
| blackout_200 | 6.4 | 71.2/72.0/73.2 | 71.9 | 72.0 | 51/2235 (2.28%) | 0.00% | 245 |  |  |
| blackout_250 | 6.4 | 71.2/71.9/73.3 | 71.9 | 72.0 | 39/2241 (1.74%) | 0.00% | 361 |  |  |
| blackout_300 | 8.7 | 73.4/74.6/78.4 | 75.1 | 74.9 | 0/50 (0.00%) | 0.00% | 315 | Cd@335 Sr@336 Od@8644 Sd@8644 | Cd@301 Sr@301 Od@8680 Sd@8680 |
| blackout_400 | 60.0 | 73.4/74.6/80.0 | 75.2 | 75.0 | 0/13 (0.00%) | 0.00% | 513 | Od@11 Sd@11 Cd@11 Cd@731 Sr@731 Od@59936 Sd@59936 | Cd@502 Sr@502 Od@59972 Sd@59972 |
| blackout_600 | 60.0 | 73.5/74.7/77.4 | 75.2 | 75.0 | 0/10 (0.00%) | 0.00% | 738 | Od@11 Sd@11 Cd@11 Cd@753 Sr@753 Od@59932 Sd@59933 | Cd@727 Sr@727 Od@59969 Sd@59969 |
| block | 12.4 | 73.3/74.5/76.8 | 74.9 | 74.9 | 0/9 (0.00%) | 0.00% | 762 | Od@22 Sd@22 Cd@22 Cd@751 Sr@752 | Cd@745 Sr@745 |
| unblock | 18.4 | 73.4/74.4/76.5 | 74.9 | 74.9 | 0/12 (0.00%) | 0.00% | 13 | Od@18360 Sd@18360 Od@18439 Sd@18439 | Od@18397 Sd@18397 |

## Wire (host tcpdump, peer 71.116.60.17) after unblock
- unblock@1794095867.1: first in +16901 ms, first out +16901 ms, host Selected(direct) +17047 ms, client Selected(direct) +17011 ms
- unblock@1794096108.3: first in +18254 ms, first out +18254 ms, host Selected(direct) +18397 ms, client Selected(direct) +18360 ms

## Path switches by step (client / host)
- block: client ['selected-closed', 'sel->relay'], host ['selected-closed', 'sel->relay']
- unblock: client ['sel->direct', 'sel->direct'], host ['sel->direct', 'sel->direct']
- blackout_300: client ['selected-closed', 'sel->relay', 'sel->direct'], host ['selected-closed', 'sel->relay', 'sel->direct']
- blackout_400: client ['sel->direct', 'selected-closed', 'sel->relay', 'sel->direct'], host ['selected-closed', 'sel->relay', 'sel->direct']
- blackout_600: client ['sel->direct', 'selected-closed', 'sel->relay', 'sel->direct'], host ['selected-closed', 'sel->relay', 'sel->direct']
- block: client ['sel->direct', 'selected-closed', 'sel->relay'], host ['selected-closed', 'sel->relay']
- unblock: client ['sel->direct', 'sel->direct'], host ['sel->direct']

client stats poll cost p50 3.7 us, p99 194.1 us
