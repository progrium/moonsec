"""Tiny SVG timeseries plot (no matplotlib): capacity/available vs target and train estimate,
plus p95 delay, for one or more sim CSVs. Usage: plot.py out.svg title csv [csv...]"""
import csv, sys
out, title, paths = sys.argv[1], sys.argv[2], sys.argv[3:]
W, H, PAD, GAP = 900, 230, 50, 40
svg = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{(H+GAP)*len(paths)+30}" font-family="sans-serif" font-size="11">',
       f'<rect width="100%" height="100%" fill="white"/><text x="{PAD}" y="18" font-size="14" font-weight="bold">{title}</text>']
for i, p in enumerate(paths):
    rows = list(csv.DictReader(open(p)))
    y0 = 30 + i * (H + GAP)
    t = [float(r['t']) for r in rows]
    series = {k: [float(r[k]) for r in rows] for k in ('avail', 'target', 'train', 'media', 'p95_ms')}
    tmax = max(t); rmax = max(max(series['avail']), max(series['target']), 1) * 1.15
    dmax = 200.0
    X = lambda v: PAD + (W - 2 * PAD) * v / tmax
    Yr = lambda v: y0 + H - (H - 20) * min(v, rmax) / rmax
    Yd = lambda v: y0 + H - (H - 20) * min(v, dmax) / dmax
    name = p.rsplit('/', 1)[-1].removesuffix('.csv')
    svg.append(f'<text x="{PAD}" y="{y0+12}" font-weight="bold">{name}</text>')
    svg.append(f'<rect x="{PAD}" y="{y0+20}" width="{W-2*PAD}" height="{H-20}" fill="none" stroke="#ccc"/>')
    for frac in (0.25, 0.5, 0.75, 1.0):
        v = rmax * frac
        svg.append(f'<text x="{PAD-4}" y="{Yr(v)+4}" text-anchor="end" fill="#555">{v:.0f}</text>')
        svg.append(f'<text x="{W-PAD+4}" y="{Yd(dmax*frac)+4}" fill="#b45">{dmax*frac:.0f}ms</text>')
    for s in range(0, int(tmax) + 1, 10):
        svg.append(f'<text x="{X(s)}" y="{y0+H+14}" text-anchor="middle" fill="#555">{s}s</text>')
    def line(vals, color, yf, width=1.5, dash=''):
        pts = ' '.join(f'{X(a):.1f},{yf(b):.1f}' for a, b in zip(t, vals))
        svg.append(f'<polyline points="{pts}" fill="none" stroke="{color}" stroke-width="{width}" {dash}/>')
    line(series['p95_ms'], '#e8a0a8', Yd, 1)
    line(series['avail'], '#222', Yr, 2)
    line(series['train'], '#2a9d8f', Yr, 1, 'stroke-dasharray="3,2"')
    line(series['target'], '#1d4ed8', Yr, 1.8)
    lx = W - PAD - 520
    for k, (lab, col) in enumerate([('available Mbit/s', '#222'), ('target', '#1d4ed8'), ('train estimate', '#2a9d8f'), ('p95 delay (right axis)', '#e8a0a8')]):
        svg.append(f'<rect x="{lx+k*105}" y="{y0+5}" width="10" height="3" fill="{col}"/><text x="{lx+k*105+14}" y="{y0+10}">{lab}</text>')
svg.append('</svg>')
open(out, 'w').write('\n'.join(svg))
