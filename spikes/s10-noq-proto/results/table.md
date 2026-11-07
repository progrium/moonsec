
### Below the cap, paced at capacity: one-way delay p99 (ms, range over reps)

| case | UDP | iroh + AppRate, pinned RT runtime | noq-proto, Zig pacer | noq-proto, noq pacer |
|---|---|---|---|---|
| cap100_tx50_frames_d10000 | 15.86–15.95 | 18.21–18.22 | 17.19–17.19 | 17.28–17.30 |
| cap100_tx50_frames_d500 | 6.36–6.39 | 8.46–8.60 | 7.67–7.69 | 7.79–7.81 |
| cap100_tx50_smooth_d10000 | 10.05–10.07 | 10.09–10.17 | 10.10–10.10 | 10.10–10.18 |
| cap100_tx50_smooth_d500 | 0.54–0.55 | 0.68–0.74 | 0.58–0.72 | 0.62–0.63 |
| cap100_tx80_frames_d10000 | 20.97–28.02 | 23.26–23.48 | 22.68–22.68 | 22.79–22.80 |
| cap100_tx80_frames_d500 | 11.47–11.48 | 13.88–13.96 | 13.16–13.26 | 13.28–13.58 |
| cap100_tx80_smooth_d10000 | 10.05–10.09 | 10.19–12.35 | 10.09–15.36 | 10.09–10.27 |
| cap100_tx80_smooth_d500 | 0.56–0.57 | 0.93–2.28 | 0.74–1.00 | 0.57–1.03 |
| cap100_tx85_frames_d10000 | 21.79–21.79 | 23.90–24.08 | 23.54–23.55 | 23.67–23.67 |
| cap100_tx85_frames_d500 | 12.24–12.30 | 14.80–14.83 | 14.05–14.05 | 14.16–14.17 |
| cap100_tx85_smooth_d10000 | 10.06–10.66 | 10.22–10.64 | 10.13–13.58 | 10.39–10.84 |
| cap100_tx85_smooth_d500 | 0.58–0.59 | 0.61–1.59 | 1.00–12.16 | 0.58–1.13 |
| cap160_tx100_frames_d10000 | 18.86–18.91 | 19.58–19.79 | 19.41–19.46 | 19.41–19.43 |
| cap160_tx100_frames_d500 | 9.28–9.33 | 10.09–10.20 | 9.89–9.91 | 9.92–9.93 |
| cap160_tx100_smooth_d10000 | 10.08–10.48 | 10.16–11.08 | 10.13–10.19 | 10.07–10.20 |
| cap160_tx100_smooth_d500 | 0.54–0.69 | 0.60–0.65 | 0.58–0.59 | 0.58–0.69 |

### Below the cap, paced at capacity: frame-done p99 (ms)

| case | UDP | iroh + AppRate, pinned RT runtime | noq-proto, Zig pacer | noq-proto, noq pacer | noq-proto, Zig pacer, 20 ms credit |
|---|---|---|---|---|---|
| cap100_tx50_frames_d10000 | 16.23–17.73 | 19.01–19.19 | 17.62–18.08 | 17.84–17.96 | 16.98–17.20 |
| cap100_tx50_frames_d500 | 6.77–6.78 | 9.08–9.12 | 8.09–8.26 | 7.98–8.06 | 7.35–7.77 |
| cap100_tx50_smooth_d10000 | 10.05–10.11 | 10.10–10.21 | 10.11–10.28 | 10.17–10.23 | - |
| cap100_tx50_smooth_d500 | 0.55–0.56 | 0.72–0.80 | 0.58–0.78 | 0.62–0.68 | - |
| cap100_tx80_frames_d10000 | 22.87–37.04 | 24.14–25.07 | 23.59–23.62 | 23.05–23.94 | 21.87–22.18 |
| cap100_tx80_frames_d500 | 12.06–12.40 | 14.63–15.59 | 13.41–15.82 | 13.55–19.89 | 12.39–13.81 |
| cap100_tx80_smooth_d10000 | 10.07–10.17 | 10.22–12.48 | 10.10–15.36 | 10.11–10.37 | - |
| cap100_tx80_smooth_d500 | 0.57–0.60 | 1.16–2.60 | 0.83–1.12 | 0.57–1.23 | - |
| cap100_tx85_frames_d10000 | 22.18–23.18 | 24.87–27.12 | 23.76–25.08 | 24.35–25.34 | 22.69–23.83 |
| cap100_tx85_frames_d500 | 12.74–13.17 | 15.49–16.45 | 15.12–15.30 | 14.80–15.24 | 13.19–13.27 |
| cap100_tx85_smooth_d10000 | 10.51–10.73 | 10.24–10.74 | 10.16–13.87 | 10.46–10.93 | - |
| cap100_tx85_smooth_d500 | 0.59–0.59 | 0.61–1.89 | 1.05–12.97 | 0.58–1.17 | - |
| cap160_tx100_frames_d10000 | 19.63–20.89 | 20.73–22.03 | 20.53–21.15 | 19.74–20.16 | 19.85–20.79 |
| cap160_tx100_frames_d500 | 9.99–10.29 | 11.01–11.02 | 10.59–11.17 | 10.70–10.83 | 10.21–11.08 |
| cap160_tx100_smooth_d10000 | 10.10–10.66 | 10.22–11.53 | 10.24–10.31 | 10.07–10.30 | - |
| cap160_tx100_smooth_d500 | 0.54–0.79 | 0.61–0.67 | 0.59–0.61 | 0.58–0.76 | - |

### At/above the cap, paced at 1.05x offered: one-way delay p99 (ms)

| case | UDP | iroh + AppRate, pinned RT runtime | noq-proto, Zig pacer |
|---|---|---|---|
| cap100_tx110_frames_d10000 | 62.48–62.50 | 15.10–15.11 | 76.24–76.38 |
| cap100_tx110_smooth_d10000 | 62.58–62.64 | 63.69–64.15 | 62.78–66.09 |
| cap100_tx95_frames_d10000 | 23.56–33.54 | 15.69–15.69 | 76.31–76.41 |
| cap100_tx95_smooth_d10000 | 14.71–15.84 | 62.73–63.02 | 62.70–62.78 |
| cap100_tx95_smooth_d500 | 0.54–3.92 | 53.20–53.93 | 53.19–53.85 |
| cap160_tx150_frames_d10000 | 24.10–24.14 | 13.77–13.78 | 30.15–41.47 |
| cap160_tx150_smooth_d10000 | 10.79–10.85 | 13.30–17.80 | 11.98–33.05 |

### Drop accounting (per run)

| run | sent | received | sender-side drops (counted) | sent − frame_tx (true sender loss) | QUIC lost | TBF dropped | all accounted? |
|---|---|---|---|---|---|---|---|
| iroh_cap100_tx110_frames_d10000_enc | 149760 | 49388 | not counted | 100372 | 0 | 0 | no |
| iroh_cap100_tx110_frames_d10000_enc | 149760 | 50073 | not counted | 99687 | 0 | 0 | no |
| iroh_cap100_tx110_smooth_d10000_enc | 150000 | 128524 | not counted | 85 | 21391 | 21391 | no |
| iroh_cap100_tx110_smooth_d10000_enc | 150000 | 128107 | not counted | 138 | 21755 | 21755 | no |
| iroh_cap100_tx110_smooth_d10000_over90 | 150000 | 122667 | not counted | 27333 | 0 | 0 | no |
| iroh_cap100_tx110_smooth_d10000_over90 | 150000 | 122616 | not counted | 27384 | 0 | 0 | no |
| iroh_cap100_tx85_frames_d10000_cap | 115920 | 115920 | not counted | 0 | 0 | 0 | yes |
| iroh_cap100_tx85_frames_d10000_cap | 115920 | 115920 | not counted | 0 | 0 | 0 | yes |
| iroh_cap100_tx85_frames_d10000_cap64k | 115920 | 44286 | not counted | 71634 | 0 | 0 | no |
| iroh_cap100_tx85_frames_d10000_cap64k | 115920 | 45234 | not counted | 70686 | 0 | 0 | no |
| iroh_cap100_tx85_frames_d500_cap | 115920 | 115920 | not counted | 0 | 0 | 0 | yes |
| iroh_cap100_tx85_frames_d500_cap | 115920 | 115920 | not counted | 0 | 0 | 0 | yes |
| iroh_cap100_tx85_smooth_d10000_cap | 115909 | 115909 | not counted | 0 | 0 | 0 | yes |
| iroh_cap100_tx85_smooth_d10000_cap | 115909 | 115909 | not counted | 0 | 0 | 0 | yes |
| iroh_cap100_tx85_smooth_d500_cap | 115909 | 115909 | not counted | 0 | 0 | 0 | yes |
| iroh_cap100_tx85_smooth_d500_cap | 115909 | 115909 | not counted | 0 | 0 | 0 | yes |
| iroh_cap100_tx95_frames_d10000_enc | 129600 | 46945 | not counted | 82655 | 0 | 0 | no |
| iroh_cap100_tx95_frames_d10000_enc | 129600 | 47971 | not counted | 81629 | 0 | 0 | no |
| iroh_cap100_tx95_smooth_d10000_enc | 129545 | 128522 | not counted | 0 | 1023 | 1023 | yes |
| iroh_cap100_tx95_smooth_d10000_enc | 129545 | 128504 | not counted | 0 | 1041 | 1041 | yes |
| iroh_cap100_tx95_smooth_d10000_over90 | 129545 | 122597 | not counted | 6948 | 0 | 0 | no |
| iroh_cap100_tx95_smooth_d10000_over90 | 129545 | 122669 | not counted | 6876 | 0 | 0 | no |
| iroh_cap100_tx95_smooth_d500_enc | 129545 | 128498 | not counted | 0 | 1047 | 1047 | yes |
| iroh_cap100_tx95_smooth_d500_enc | 129545 | 128532 | not counted | 0 | 1013 | 1014 | yes |
| iroh_cap160_tx150_frames_d10000_enc | 204480 | 56391 | not counted | 148089 | 0 | 0 | no |
| iroh_cap160_tx150_frames_d10000_enc | 204480 | 53668 | not counted | 150812 | 0 | 0 | no |
| iroh_cap160_tx150_smooth_d10000_enc | 204545 | 204545 | not counted | 0 | 0 | 0 | yes |
| iroh_cap160_tx150_smooth_d10000_enc | 204545 | 204545 | not counted | 0 | 0 | 0 | yes |
| noq_cap100_tx110_frames_d10000_enc | 149760 | 128510 | 0 | 0 | 21250 | 21250 | yes |
| noq_cap100_tx110_frames_d10000_enc | 149760 | 128509 | 0 | 0 | 21251 | 21251 | yes |
| noq_cap100_tx110_smooth_d10000_enc | 150000 | 128437 | 0 | 0 | 21563 | 21563 | yes |
| noq_cap100_tx110_smooth_d10000_enc | 150000 | 128459 | 0 | 0 | 21541 | 21541 | yes |
| noq_cap100_tx110_smooth_d10000_over90 | 150000 | 122754 | 27246 | 27246 | 0 | 0 | yes |
| noq_cap100_tx110_smooth_d10000_over90 | 150000 | 122756 | 27244 | 27244 | 0 | 0 | yes |
| noq_cap100_tx85_frames_d10000_cap | 115920 | 115920 | 0 | 0 | 0 | 0 | yes |
| noq_cap100_tx85_frames_d10000_cap | 115920 | 115920 | 0 | 0 | 0 | 0 | yes |
| noq_cap100_tx85_frames_d10000_capburst | 115920 | 115920 | 0 | 0 | 0 | 0 | yes |
| noq_cap100_tx85_frames_d10000_capburst | 115920 | 115920 | 0 | 0 | 0 | 0 | yes |
| noq_cap100_tx85_frames_d500_cap | 115920 | 115920 | 0 | 0 | 0 | 0 | yes |
| noq_cap100_tx85_frames_d500_cap | 115920 | 115920 | 0 | 0 | 0 | 0 | yes |
| noq_cap100_tx85_frames_d500_capburst | 115920 | 115920 | 0 | 0 | 0 | 0 | yes |
| noq_cap100_tx85_frames_d500_capburst | 115920 | 115920 | 0 | 0 | 0 | 0 | yes |
| noq_cap100_tx85_smooth_d10000_cap | 115909 | 115909 | 0 | 0 | 0 | 0 | yes |
| noq_cap100_tx85_smooth_d10000_cap | 115909 | 115909 | 0 | 0 | 0 | 0 | yes |
| noq_cap100_tx85_smooth_d500_cap | 115909 | 115909 | 0 | 0 | 0 | 0 | yes |
| noq_cap100_tx85_smooth_d500_cap | 115909 | 115909 | 0 | 0 | 0 | 0 | yes |
| noq_cap100_tx95_frames_d10000_enc | 129600 | 128416 | 0 | 0 | 1184 | 1184 | yes |
| noq_cap100_tx95_frames_d10000_enc | 129600 | 128400 | 0 | 0 | 1200 | 1200 | yes |
| noq_cap100_tx95_smooth_d10000_enc | 129545 | 128520 | 0 | 0 | 1025 | 1025 | yes |
| noq_cap100_tx95_smooth_d10000_enc | 129545 | 128526 | 0 | 0 | 1019 | 1019 | yes |
| noq_cap100_tx95_smooth_d10000_over90 | 129545 | 122756 | 6789 | 6789 | 0 | 0 | yes |
| noq_cap100_tx95_smooth_d10000_over90 | 129545 | 122732 | 6813 | 6813 | 0 | 0 | yes |
| noq_cap100_tx95_smooth_d500_enc | 129545 | 128542 | 0 | 0 | 1003 | 1003 | yes |
| noq_cap100_tx95_smooth_d500_enc | 129545 | 128531 | 0 | 0 | 1014 | 1014 | yes |
| noq_cap160_tx150_frames_d10000_enc | 204480 | 204480 | 0 | 0 | 0 | 0 | yes |
| noq_cap160_tx150_frames_d10000_enc | 204480 | 204480 | 0 | 0 | 0 | 0 | yes |
| noq_cap160_tx150_smooth_d10000_enc | 204545 | 204545 | 0 | 0 | 0 | 0 | yes |
| noq_cap160_tx150_smooth_d10000_enc | 204545 | 204545 | 0 | 0 | 0 | 0 | yes |
| noqrate_cap100_tx85_frames_d10000_cap | 115920 | 115920 | 0 | 0 | 0 | 0 | yes |
| noqrate_cap100_tx85_frames_d10000_cap | 115920 | 115920 | 0 | 0 | 0 | 0 | yes |
| noqrate_cap100_tx85_frames_d500_cap | 115920 | 115920 | 0 | 0 | 0 | 0 | yes |
| noqrate_cap100_tx85_frames_d500_cap | 115920 | 115920 | 0 | 0 | 0 | 0 | yes |
| noqrate_cap100_tx85_smooth_d10000_cap | 115909 | 115909 | 0 | 0 | 0 | 0 | yes |
| noqrate_cap100_tx85_smooth_d10000_cap | 115909 | 115909 | 0 | 0 | 0 | 0 | yes |
| noqrate_cap100_tx85_smooth_d500_cap | 115909 | 115909 | 0 | 0 | 0 | 0 | yes |
| noqrate_cap100_tx85_smooth_d500_cap | 115909 | 115909 | 0 | 0 | 0 | 0 | yes |
