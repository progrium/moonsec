#!/usr/bin/env python3
"""Split noq runs' one-way delay at the hand-off to QUIC (stamped by the Zig network thread):
queue = Zig queue + pacer wait; rest = QUIC + sendto + delay line + bottleneck + receiver.
Usage: split.py RUNDIR...   (steady state after WARM=4 s)"""
import csv, sys, os, json
WARM = float(os.environ.get('WARM', '4'))
def pct(v, p): return v[min(len(v) - 1, int(round(p / 100 * (len(v) - 1))))] if v else float('nan')
for d in sys.argv[1:]:
    h = os.path.join(d, 'recv.csv.handoff')
    if not os.path.exists(h): continue
    ho = {int(a): int(b) for a, b in list(csv.reader(open(h)))[1:]}
    rows = [list(map(int, r)) for r in list(csv.reader(open(os.path.join(d, 'recv.csv'))))[1:]]
    t0 = min(r[1] for r in rows)
    rows = [r for r in rows if r[1] - t0 >= WARM * 1e9 and ho.get(r[0])]
    q = sorted((ho[r[0]] - r[1]) / 1e3 for r in rows)
    rest = sorted((r[4] - ho[r[0]]) / 1e3 for r in rows)
    print(json.dumps({'run': os.path.basename(d.rstrip('/')), 'queue_p50_us': round(pct(q, 50), 1), 'queue_p99_us': round(pct(q, 99), 1),
                      'queue_max_us': round(q[-1], 1), 'rest_p50_us': round(pct(rest, 50), 1), 'rest_p99_us': round(pct(rest, 99), 1), 'rest_max_us': round(rest[-1], 1)}))
