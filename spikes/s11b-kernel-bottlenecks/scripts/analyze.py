"""Summarise results/raw into results/summary.csv and results/table.md (medians across reps).
Usage: analyze.py results/raw results"""
import csv, gzip, json, os, re, statistics as st, sys
from collections import defaultdict

raw, out = sys.argv[1], sys.argv[2]
UDP = 1200 / 1242   # media goodput per wire byte (HTB counts Ethernet+IP+UDP headers)
TCP = 1448 / 1514   # TCP payload per wire byte (timestamps on)

def cap(scen, t):
    if scen != 'steps': return 50.0
    return 25.0 if t < 20 else 10.0 if t < 40 else 40.0

def mean(xs): return sum(xs) / len(xs) if xs else float('nan')
def pct(xs, p):
    xs = sorted(xs); return xs[min(len(xs) - 1, int(len(xs) * p / 100))] if xs else float('nan')

def iperf_series(path):
    """[(t_start, mbps)] per 100 ms interval, relative to that iperf3's own start."""
    if os.path.exists(path + '.gz'): path += '.gz'
    if not os.path.exists(path): return []
    try: j = json.load(gzip.open(path) if path.endswith('.gz') else open(path))
    except Exception: return []
    return [(iv['sum']['start'], iv['sum']['bits_per_second'] / 1e6) for iv in j.get('intervals', [])]

results = {}
for line in open(os.path.join(raw, 'results.txt')):
    m = re.match(r'RESULT (\S+) qdelay_ms p50/95/99=([\d.]+)/([\d.]+)/([\d.]+) frames_lost=(\d+)/(\d+).*?lost=(\d+).*frame_ms p50/95/99=([\d.]+)/([\d.]+)/([\d.]+)', line)
    if m:
        g = m.groups()
        results[g[0]] = dict(q50=float(g[1]), q95=float(g[2]), q99=float(g[3]), flost=int(g[4]), pkts_lost=int(g[6]),
                             f50=float(g[7]), f99=float(g[9]))

rows = []
for fn in sorted(os.listdir(raw)):
    m = re.match(r'(steps|cubic|bbr)-(\w+)-(.+)-r(\d+)\.(csv|us\.json)(?:\.gz)?$', fn)
    if not m: continue
    scen, aqm, ctl, rep, kind = m.groups()
    name = f'{scen}-{aqm}-{ctl}-r{rep}'
    r = dict(scen=scen, aqm=aqm, ctl=ctl, rep=int(rep))
    if kind == 'csv':
        d = list(csv.DictReader(open(os.path.join(raw, fn))))
        t = [float(x['t']) for x in d]
        recv = [float(x['recv_mbps']) for x in d]
        tgt = [float(x['target']) for x in d]
        q50 = [float(x['q50_ms']) for x in d]; q95 = [float(x['q95_ms']) for x in d]
        lost = [int(x['lost']) for x in d]
        sel = lambda a, b: [i for i, x in enumerate(t) if a <= x < b]
        def util(a, b): return mean([recv[i] / (cap(scen, t[i]) * UDP) for i in sel(a, b)])
        def est(a, b): return mean([tgt[i] / (cap(scen, t[i]) * UDP) for i in sel(a, b)])
        r.update(results.get(name, {}))
        r['util_a'] = util(5, 20); r['est_a'] = est(5, 20)
        r['q50_a'] = st.median([q50[i] for i in sel(5, 20)]); r['q95_a'] = pct([q95[i] for i in sel(5, 20)], 95)
        r['start_ms'] = next((round(t[i] * 1000) for i in range(len(t)) if recv[i] >= 0.8 * cap(scen, t[i]) * UDP), None)
        if scen == 'steps':
            r['util_b'] = util(25, 40); r['util_c'] = util(45, 60)
            r['q95_b'] = pct([q95[i] for i in sel(25, 40)], 95)
            r['down_ms'] = next((round((t[i] - 20) * 1000) for i in sel(20, 40) if tgt[i] <= 10 * UDP), None)
            r['peak_ms'] = max(q95[i] for i in sel(20, 25))
            # drained: the median of the 100 ms p95s over the next 1 s is under 20 ms
            ix = sel(20, 39)
            r['drain_ms'] = next((round((t[i] - 20) * 1000) for i in ix if st.median(q95[i:i + 10]) < 20), None)
            r['up_ms'] = next((round((t[i] - 40) * 1000) for i in sel(40, 60) if recv[i] >= 0.8 * 40 * UDP), None)
            r['lost_b'] = sum(lost[i] for i in sel(20, 25))
        else:
            tcp = iperf_series(os.path.join(raw, f'{name}.tcp.json'))
            fair = 25.0
            r['share_b'] = mean([recv[i] for i in sel(25, 40)]) / (fair * UDP)
            r['tcp_b'] = mean([b for s, b in tcp if 5 <= s < 20]) / (fair * TCP) if tcp else float('nan')
            r['q50_b'] = st.median([q50[i] for i in sel(25, 40)]); r['q95_b'] = pct([q95[i] for i in sel(25, 40)], 95)
            r['util_c'] = util(45, 60)
            r['recover_ms'] = next((round((t[i] - 40) * 1000) for i in sel(40, 60) if recv[i] >= 0.8 * 50 * UDP), None)
    else:  # reference: a Cubic flow in our place
        us = iperf_series(os.path.join(raw, fn.removesuffix('.gz'))); tcp = iperf_series(os.path.join(raw, f'{name}.tcp.json'))
        r['util_a'] = mean([b for s, b in us if 5 <= s < 20]) / (50 * TCP)
        r['share_b'] = mean([b for s, b in us if 25 <= s < 40]) / (25 * TCP)
        r['tcp_b'] = mean([b for s, b in tcp if 5 <= s < 20]) / (25 * TCP) if tcp else float('nan')
        r['util_c'] = mean([b for s, b in us if 45 <= s < 60]) / (50 * TCP)
    rows.append(r)

keys = ['scen', 'aqm', 'ctl', 'rep', 'util_a', 'est_a', 'q50_a', 'q95_a', 'start_ms', 'util_b', 'q95_b', 'down_ms', 'peak_ms', 'drain_ms',
        'up_ms', 'lost_b', 'util_c', 'share_b', 'tcp_b', 'q50_b', 'recover_ms', 'q50', 'q95', 'q99', 'f50', 'f99', 'flost', 'pkts_lost']
os.makedirs(out, exist_ok=True)
with open(os.path.join(out, 'summary.csv'), 'w') as f:
    w = csv.DictWriter(f, keys, extrasaction='ignore'); w.writeheader(); [w.writerow(r) for r in rows]

groups = defaultdict(list)
for r in rows: groups[(r['scen'], r['aqm'], r['ctl'])].append(r)
def med(rs, k, fmt='{:.2f}'):
    v = [r[k] for r in rs if r.get(k) is not None and r.get(k) == r.get(k)]
    if not v: return '–'
    return fmt.format(st.median(v))
order = {'gcc': 0, 'gcc-hybrid': 1, 'qdelay-probe': 2, 'tcp-cubic': 3}
md = []
md.append('### Capacity steps (25 → 10 → 40 Mbit/s), alone\n')
md.append('| aqm | ctl | n | util 25 | est 25 | util 10 | util 40 | q p50 | q p99 | start ms | down ms | peak ms | drain ms | up ms | lost after drop | frame p50 | frame p99 | frames lost |')
md.append('|' + '---|' * 18)
for (s, a, c), rs in sorted(groups.items(), key=lambda kv: (kv[0][0], kv[0][1], order.get(kv[0][2], 9))):
    if s != 'steps': continue
    md.append(f"| {a} | {c} | {len(rs)} | {med(rs,'util_a')} | {med(rs,'est_a')} | {med(rs,'util_b')} | {med(rs,'util_c')} | {med(rs,'q50','{:.1f}')} | {med(rs,'q99','{:.1f}')} | "
              f"{med(rs,'start_ms','{:.0f}')} | {med(rs,'down_ms','{:.0f}')} | {med(rs,'peak_ms','{:.0f}')} | {med(rs,'drain_ms','{:.0f}')} | {med(rs,'up_ms','{:.0f}')} | {med(rs,'lost_b','{:.0f}')} | "
              f"{med(rs,'f50','{:.1f}')} | {med(rs,'f99','{:.0f}')} | {med(rs,'flost','{:.0f}')} |")
md.append('\n### 50 Mbit/s with a competing TCP flow (t = 20–40 s)\n')
md.append('| competitor | aqm | ctl | n | util alone | our share | TCP share | q p50 alone | q p50 with TCP | q p95 with TCP | util after | recover ms | frame p50 | frame p99 | frames lost |')
md.append('|' + '---|' * 15)
for (s, a, c), rs in sorted(groups.items(), key=lambda kv: (kv[0][0], kv[0][1], order.get(kv[0][2], 9))):
    if s == 'steps': continue
    md.append(f"| {s} | {a} | {c} | {len(rs)} | {med(rs,'util_a')} | {med(rs,'share_b')} | {med(rs,'tcp_b')} | {med(rs,'q50_a','{:.1f}')} | {med(rs,'q50_b','{:.1f}')} | {med(rs,'q95_b','{:.1f}')} | "
              f"{med(rs,'util_c')} | {med(rs,'recover_ms','{:.0f}')} | {med(rs,'f50','{:.1f}')} | {med(rs,'f99','{:.0f}')} | {med(rs,'flost','{:.0f}')} |")
open(os.path.join(out, 'table.md'), 'w').write('\n'.join(md) + '\n')
print('\n'.join(md))
