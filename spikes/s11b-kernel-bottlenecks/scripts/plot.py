"""SVG timeseries (no matplotlib) for s11net runs in results/raw.
Usage: plot.py out.svg title raw_dir run_name [run_name...]   (run_name = file stem, e.g. steps-fq_codel-gcc-hybrid-r1)
Lines (rates as 500 ms means): capacity (grey), target (blue), media received (green), competing TCP (orange); p95 queueing (pink, right axis)."""
import csv, gzip, json, os, sys
out, title, raw, names = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
W, H, PAD, GAP = 900, 230, 50, 40
svg = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{(H+GAP)*len(names)+50}" font-family="sans-serif" font-size="11">',
       f'<rect width="100%" height="100%" fill="white"/><text x="{PAD}" y="18" font-size="14" font-weight="bold">{title}</text>']
leg = [('capacity', '#999'), ('target', '#2b6cb0'), ('media recv', '#2f855a'), ('TCP', '#dd6b20'), ('q p95 (right)', '#e8a0a8')]
for k, (lab, col) in enumerate(leg):
    svg.append(f'<rect x="{PAD+k*120}" y="28" width="12" height="3" fill="{col}"/><text x="{PAD+k*120+16}" y="33">{lab}</text>')
for i, name in enumerate(names):
    rows = list(csv.DictReader(open(os.path.join(raw, name + '.csv'))))
    scen = name.split('-')[0]
    y0 = 50 + i * (H + GAP)
    t = [float(r['t']) for r in rows]
    capf = (lambda x: 25 if x < 20 else 10 if x < 40 else 40) if scen == 'steps' else (lambda x: 50)
    tcp = []
    p = os.path.join(raw, name + '.tcp.json')
    if os.path.exists(p + '.gz'): p += '.gz'
    if os.path.exists(p):
        try: tcp = [(20 + iv['sum']['start'], iv['sum']['bits_per_second'] / 1e6) for iv in json.load(gzip.open(p) if p.endswith('.gz') else open(p))['intervals']]
        except Exception: pass
    tmax, rmax, dmax = 60.0, 100.0, 100.0
    X = lambda v: PAD + (W - 2 * PAD) * v / tmax
    Yr = lambda v: y0 + H - (H - 20) * min(max(v, 0), rmax) / rmax
    Yd = lambda v: y0 + H - (H - 20) * min(max(v, 0), dmax) / dmax
    svg.append(f'<text x="{PAD}" y="{y0+12}" font-weight="bold">{name}</text>')
    svg.append(f'<rect x="{PAD}" y="{y0+20}" width="{W-2*PAD}" height="{H-20}" fill="none" stroke="#ccc"/>')
    for frac in (0.25, 0.5, 0.75, 1.0):
        svg.append(f'<text x="{PAD-4}" y="{Yr(rmax*frac)+4}" text-anchor="end" fill="#555">{rmax*frac:.0f}</text>')
        svg.append(f'<text x="{W-PAD+4}" y="{Yd(dmax*frac)+4}" fill="#b45">{dmax*frac:.0f}ms</text>')
    for s in range(0, 61, 10):
        svg.append(f'<text x="{X(s)}" y="{y0+H+14}" text-anchor="middle" fill="#555">{s}s</text>')
    def line(ts, vals, color, yf, width=1.5):
        pts = ' '.join(f'{X(a):.1f},{yf(b):.1f}' for a, b in zip(ts, vals))
        svg.append(f'<polyline points="{pts}" fill="none" stroke="{color}" stroke-width="{width}"/>')
    line(t, [float(r['q95_ms']) for r in rows], '#e8a0a8', Yd, 1)
    line(t, [capf(x) for x in t], '#999', Yr, 1.5)
    sm = lambda v: [sum(v[max(0, k - 4):k + 1]) / len(v[max(0, k - 4):k + 1]) for k in range(len(v))]  # 500 ms mean
    if tcp: line([a for a, _ in tcp], sm([b for _, b in tcp]), '#dd6b20', Yr, 1)
    line(t, sm([float(r['recv_mbps']) for r in rows]), '#2f855a', Yr, 1)
    line(t, [float(r['target']) for r in rows], '#2b6cb0', Yr, 1.5)
svg.append('</svg>')
open(out, 'w').write('\n'.join(svg))
