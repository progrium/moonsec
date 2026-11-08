
### Frames: one-way delay p99 (ms)

| case | UDP | AppRate (S10 config) | + 10 ms credit | + 20 ms credit | no credit, pace 1.2x |
|---|---|---|---|---|---|
| 100 cap, 50 Mbit, 20 ms RTT | 15.87–15.89 | 18.30–18.39 | 16.37–16.37 | 16.39–16.40 | 16.38–16.41 |
| 100 cap, 80 Mbit, 20 ms RTT | 20.93–20.95 | 23.23–23.27 | 21.26–21.34 | 21.07–21.17 | 21.47–21.52 |
| 100 cap, 85 Mbit, 20 ms RTT | 21.70–21.75 | 24.09–24.20 | 21.89–21.95 | 21.74–21.95 | 22.35–22.36 |
| 160 cap, 100 Mbit, 20 ms RTT | 18.78–18.81 | 19.79–19.86 | 19.06–19.23 | 18.89–19.08 | 19.26–19.34 |
| 100 cap, 50 Mbit, 1 ms RTT | 6.39–6.40 | 8.71–8.74 | 6.87–6.89 | 6.89–6.89 | 6.90–6.99 |
| 100 cap, 80 Mbit, 1 ms RTT | 11.43–11.46 | 14.08–14.08 | 11.77–11.88 | 11.94–11.96 | 12.05–12.07 |
| 100 cap, 85 Mbit, 1 ms RTT | 12.22–12.26 | 14.85–14.92 | 12.56–12.79 | 12.70–12.71 | 12.86–12.90 |
| 160 cap, 100 Mbit, 1 ms RTT | 9.26–9.28 | 10.30–10.46 | 9.80–9.92 | 9.82–9.89 | 9.90–9.93 |

Added p99 over UDP, per kind: median (min–max) over the cases above

- AppRate (S10 config): **2.37 ms** (1.03 to 2.64, 8 cases)
- + 10 ms credit: **0.41 ms** (0.20 to 0.59, 8 cases)
- + 20 ms credit: **0.48 ms** (0.12 to 0.58, 8 cases)
- no credit, pace 1.2x: **0.59 ms** (0.51 to 0.65, 8 cases)

### Frames: frame-done p99 (ms, frame start to last datagram)

| case | UDP | AppRate (S10 config) | + 10 ms credit | + 20 ms credit | no credit, pace 1.2x |
|---|---|---|---|---|---|
| 100 cap, 50 Mbit, 20 ms RTT | 16.55–17.45 | 19.12–19.73 | 17.08–17.94 | 18.34–18.64 | 17.27–17.70 |
| 100 cap, 80 Mbit, 20 ms RTT | 21.78–22.15 | 24.45–25.12 | 22.19–23.13 | 22.34–22.62 | 22.71–22.84 |
| 100 cap, 85 Mbit, 20 ms RTT | 22.30–23.27 | 25.51–26.62 | 23.35–23.41 | 23.36–24.38 | 24.24–24.99 |
| 160 cap, 100 Mbit, 20 ms RTT | 19.88–20.70 | 21.01–22.45 | 20.84–21.11 | 20.21–21.32 | 19.95–22.63 |
| 100 cap, 50 Mbit, 1 ms RTT | 6.78–7.12 | 9.36–9.71 | 8.22–8.68 | 7.88–8.43 | 7.30–7.55 |
| 100 cap, 80 Mbit, 1 ms RTT | 11.97–13.54 | 14.65–15.63 | 12.53–12.67 | 13.21–13.23 | 13.02–13.20 |
| 100 cap, 85 Mbit, 1 ms RTT | 12.91–13.42 | 16.49–17.05 | 13.78–14.59 | 13.99–14.74 | 14.33–14.85 |
| 160 cap, 100 Mbit, 1 ms RTT | 9.83–10.81 | 11.16–11.85 | 11.15–11.77 | 10.39–10.75 | 10.54–11.84 |

Added p99 over UDP, per kind: median (min–max) over the cases above

- AppRate (S10 config): **2.50 ms** (1.19 to 3.61, 8 cases)
- + 10 ms credit: **0.69 ms** (-0.15 to 1.50, 8 cases)
- + 20 ms credit: **0.80 ms** (0.25 to 1.49, 8 cases)
- no credit, pace 1.2x: **0.84 ms** (0.36 to 1.83, 8 cases)

### Smooth: one-way delay p99 (ms)

| case | UDP | AppRate (S10 config) | + 20 ms credit |
|---|---|---|---|
| 100 cap, 50 Mbit, 20 ms RTT | 10.07–10.74 | 10.78–11.22 | 10.59–10.82 |
| 100 cap, 80 Mbit, 20 ms RTT | 10.06–10.08 | 10.21–10.39 | 10.30–10.80 |
| 100 cap, 85 Mbit, 20 ms RTT | 10.15–11.60 | 10.75–19.48 | 11.17–11.36 |
| 160 cap, 100 Mbit, 20 ms RTT | 10.07–11.39 | 10.24–10.64 | 10.19–11.57 |
| 100 cap, 50 Mbit, 1 ms RTT | 0.54–0.55 | 1.09–2.39 | 0.70–0.97 |
| 100 cap, 80 Mbit, 1 ms RTT | 0.70–1.04 | 1.65–1.78 | 1.24–1.52 |
| 100 cap, 85 Mbit, 1 ms RTT | 0.91–0.96 | 0.78–0.94 | 0.81–1.36 |
| 160 cap, 100 Mbit, 1 ms RTT | 0.55–0.87 | 0.74–1.11 | 0.93–2.95 |

Added p99 over UDP, per kind: median (min–max) over the cases above

- AppRate (S10 config): **0.41 ms** (-0.28 to 4.24, 8 cases)
- + 20 ms credit: **0.35 ms** (0.15 to 1.23, 8 cases)

### Send buffer: 64 KiB with 20 ms credit, frames, 20 ms RTT (per run)

| run | sent | evicted (sent − frame_tx) | lost | p99 ms |
|---|---|---|---|---|
| iroh_cap100_tx50_frames_d10000_b20sb64k | 68400 | 26211 | 0 | 13.77 |
| iroh_cap100_tx50_frames_d10000_b20sb64k | 68400 | 26877 | 0 | 12.93 |
| iroh_cap100_tx80_frames_d10000_b20sb64k | 109440 | 56399 | 0 | 19.33 |
| iroh_cap100_tx80_frames_d10000_b20sb64k | 109440 | 61254 | 0 | 19.24 |
| iroh_cap100_tx85_frames_d10000_b20sb64k | 115920 | 60760 | 0 | 19.95 |
| iroh_cap100_tx85_frames_d10000_b20sb64k | 115920 | 63682 | 0 | 19.90 |
| iroh_cap160_tx100_frames_d10000_b20sb64k | 136080 | 79379 | 0 | 16.99 |
| iroh_cap160_tx100_frames_d10000_b20sb64k | 136080 | 81409 | 0 | 17.01 |

### Encoder above the 90 Mbit/s target, without and with 20 ms credit (per run)

| run | delivered Mbit/s (payload) | evicted | TBF dropped | p99 ms |
|---|---|---|---|---|
| iroh_cap100_tx110_smooth_d10000_over90 | 89.9 | 26465 | 0 | 86.39 |
| iroh_cap100_tx110_smooth_d10000_over90 | 89.9 | 26850 | 0 | 86.60 |
| iroh_cap100_tx110_smooth_d10000_over90b20 | 90.0 | 26178 | 0 | 87.22 |
| iroh_cap100_tx110_smooth_d10000_over90b20 | 90.0 | 26183 | 0 | 86.60 |
| iroh_cap100_tx95_smooth_d10000_over90 | 89.9 | 6020 | 0 | 97.78 |
| iroh_cap100_tx95_smooth_d10000_over90 | 89.8 | 6065 | 0 | 97.24 |
| iroh_cap100_tx95_smooth_d10000_over90b20 | 90.0 | 5726 | 0 | 99.72 |
| iroh_cap100_tx95_smooth_d10000_over90b20 | 90.0 | 5726 | 0 | 100.55 |

### Unexpected loss below the cap (runs with any missing datagram)

- udp_cap160_tx100_smooth_d10000: missing 44, evicted None, lost None, TBF 0
- udp_cap160_tx100_smooth_d500: missing 42, evicted None, lost None, TBF 0
