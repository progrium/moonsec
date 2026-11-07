"""Median across seeds of each metric, per scenario x variant. Usage: table.py results/matrix/summary.csv [variants...]"""
import csv, sys, statistics
from collections import defaultdict
rows = list(csv.DictReader(open(sys.argv[1])))
want = sys.argv[2:] or None
g = defaultdict(list)
for r in rows:
    g[(r['scenario'], r['variant'])].append(r)
cols = [('est_p50','est/avail'),('util_p50','util'),('train_p50','train/cap'),('net_p50','q p50'),('net_p99','q p99'),
        ('frame_p50','frame p50'),('frame_p99','frame p99'),('frames_lost','lost fr'),('startup_ms','start ms'),
        ('down_react_ms','down ms'),('down_peak_ms','down peak'),('down_drain_ms','drain ms'),('up_ms','up ms')]
print('| scenario | variant | ' + ' | '.join(c[1] for c in cols) + ' |')
print('|' + '---|' * (len(cols) + 2))
scen_order = []
for r in rows:
    if r['scenario'] not in scen_order: scen_order.append(r['scenario'])
var_order = want or list(dict.fromkeys(r['variant'] for r in rows))
for s in scen_order:
    for v in var_order:
        rs = g.get((s, v))
        if not rs: continue
        out = []
        for k, _ in cols:
            vals = [float(r[k]) for r in rs]
            m = statistics.median(vals)
            if k in ('est_p50','util_p50','train_p50'): out.append(f'{m:.2f}')
            elif k.endswith('_ms') and k not in ('net_p50',): out.append('–' if m < 0 else f'{m:.0f}')
            elif k == 'frames_lost': out.append(f'{m:.0f}')
            else: out.append(f'{m:.1f}')
        print(f'| {s} | {v} | ' + ' | '.join(out) + ' |')
