#!/usr/bin/env python3
"""S10b tables. Usage: report.py REPDIR [REPDIR...] > table.md  (steady state after WARM=4 s).
Cells are p99 in ms, range over repetitions; 'added' is the median over reps minus UDP's median."""
import sys, os, json, glob, statistics, csv
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '../../s2-datagram-queueing/scripts'))
from analyze import summarize
WARM = float(os.environ.get('WARM', '4'))
runs = {}
def rate_mbps(d):
    t = []
    with open(os.path.join(d, 'recv.csv')) as f:
        r = csv.reader(f); next(r)
        t = [int(x[4]) for x in r]
    t.sort(); t0 = t[0] + WARM * 1e9; t = [x for x in t if x >= t0]
    return len(t) * 1100 * 8 / ((t[-1] - t[0]) / 1e9) / 1e6 if len(t) > 1 else None
for root in sys.argv[1:]:
    for d in sorted(glob.glob(os.path.join(root, '*/'))):
        d = d.rstrip('/'); name = os.path.basename(d)
        try:
            s = summarize(d, WARM); s['rate'] = rate_mbps(d)
        except Exception as e:
            print('skip', name, e, file=sys.stderr); continue
        runs.setdefault(name, []).append(s)
def vals(n, k): return [r[k] for r in runs.get(n, []) if r.get(k) is not None]
def med(n, k): v = vals(n, k); return statistics.median(v) if v else None
def rng(n, k):
    v = vals(n, k)
    if not v: return '-'
    return '%.2f' % (v[0]/1e3) if len(v) == 1 else '%.2f–%.2f' % (min(v)/1e3, max(v)/1e3)
CASES = [f'cap{c}_tx{m}' for c, m in (('100', 50), ('100', 80), ('100', 85), ('160', 100))]
DELAYS = [('d10000', '20 ms RTT'), ('d500', '1 ms RTT')]
def label(c, d): cap, tx = c.split('_'); return f'{cap[3:]} cap, {tx[2:]} Mbit, {d}'
def table(pat, kinds, key, title):
    print(f'\n### {title}\n')
    print('| case | UDP | ' + ' | '.join(k[1] for k in kinds) + ' |')
    print('|---|---|' + '---|' * len(kinds))
    added = {k[0]: [] for k in kinds}
    for dl, dn in DELAYS:
        for c in CASES:
            base = f'{c}_{pat}_{dl}'; u = f'udp_{base}'
            cells = [rng(u, key)]
            for k, _ in kinds:
                n = f'iroh_{base}_{k}'; cells.append(rng(n, key))
                if med(n, key) is not None and med(u, key) is not None: added[k].append((med(n, key) - med(u, key)) / 1e3)
            print(f'| {label(c, dn)} | ' + ' | '.join(cells) + ' |')
    print('\nAdded p99 over UDP, per kind: median (min–max) over the cases above\n')
    for k, t in kinds:
        a = added[k]
        if a: print(f'- {t}: **{statistics.median(a):.2f} ms** ({min(a):.2f} to {max(a):.2f}, {len(a)} cases)')
FK = [('base', 'AppRate (S10 config)'), ('b10', '+ 10 ms credit'), ('b20', '+ 20 ms credit'), ('over', 'no credit, pace 1.2x')]
table('frames', FK, 'owd_p99', 'Frames: one-way delay p99 (ms)')
table('frames', FK, 'frame_done_p99', 'Frames: frame-done p99 (ms, frame start to last datagram)')
table('smooth', FK[:1] + FK[2:3], 'owd_p99', 'Smooth: one-way delay p99 (ms)')
print('\n### Send buffer: 64 KiB with 20 ms credit, frames, 20 ms RTT (per run)\n')
print('| run | sent | evicted (sent − frame_tx) | lost | p99 ms |')
print('|---|---|---|---|---|')
for n in sorted(runs):
    if not n.endswith('b20sb64k'): continue
    for r in runs[n]:
        print(f"| {n} | {r['sent']} | {r.get('send_buf_evicted')} | {r.get('quic_lost_pkts')} | {r['owd_p99']/1e3:.2f} |")
print('\n### Encoder above the 90 Mbit/s target, without and with 20 ms credit (per run)\n')
print('| run | delivered Mbit/s (payload) | evicted | TBF dropped | p99 ms |')
print('|---|---|---|---|---|')
for n in sorted(runs):
    if 'over90' not in n: continue
    for r in runs[n]:
        print(f"| {n} | {r['rate']:.1f} | {r.get('send_buf_evicted')} | {r.get('tbf_dropped')} | {r['owd_p99']/1e3:.2f} |")
print('\n### Unexpected loss below the cap (runs with any missing datagram)\n')
for n in sorted(runs):
    for r in runs[n]:
        if r.get('missing') and 'over90' not in n and 'sb64k' not in n:
            print(f"- {n}: missing {r['missing']}, evicted {r.get('send_buf_evicted')}, lost {r.get('quic_lost_pkts')}, TBF {r.get('tbf_dropped')}")
