### Capacity steps (25 → 10 → 40 Mbit/s), alone

| aqm | ctl | n | util 25 | est 25 | util 10 | util 40 | q p50 | q p99 | start ms | down ms | peak ms | drain ms | up ms | lost after drop | frame p50 | frame p99 | frames lost |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| bfifo250000 | gcc-hybrid | 1 | 0.82 | 0.82 | 0.69 | 0.89 | 1.8 | 13.1 | 700 | 300 | 94 | 400 | 1800 | 0 | 12.6 | 101 | 0 |
| bfifo250000 | qdelay-probe | 1 | 0.91 | 0.90 | 0.94 | 0.93 | 3.6 | 26.8 | 300 | 300 | 200 | 500 | 1800 | 55 | 19.8 | 97 | 7 |

### 50 Mbit/s with a competing TCP flow (t = 20–40 s)

| competitor | aqm | ctl | n | util alone | our share | TCP share | q p50 alone | q p50 with TCP | q p95 with TCP | util after | recover ms | frame p50 | frame p99 | frames lost |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
