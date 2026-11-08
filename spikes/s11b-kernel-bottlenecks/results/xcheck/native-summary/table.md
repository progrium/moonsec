### Capacity steps (25 → 10 → 40 Mbit/s), alone

| aqm | ctl | n | util 25 | est 25 | util 10 | util 40 | q p50 | q p99 | start ms | down ms | peak ms | drain ms | up ms | lost after drop | frame p50 | frame p99 | frames lost |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| bfifo250000 | gcc-hybrid | 1 | 0.80 | 0.78 | 0.72 | 0.85 | 1.7 | 13.2 | 700 | 300 | 168 | 400 | 1600 | 0 | 11.7 | 110 | 0 |
| bfifo250000 | qdelay-probe | 1 | 0.92 | 0.91 | 0.91 | 0.93 | 3.7 | 24.1 | 700 | 300 | 198 | 500 | 1900 | 0 | 18.8 | 104 | 0 |

### 50 Mbit/s with a competing TCP flow (t = 20–40 s)

| competitor | aqm | ctl | n | util alone | our share | TCP share | q p50 alone | q p50 with TCP | q p95 with TCP | util after | recover ms | frame p50 | frame p99 | frames lost |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
