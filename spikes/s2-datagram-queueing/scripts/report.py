#!/usr/bin/env python3
"""Build the S2 results table (markdown) from sweep dirs. Steady state = after WARM seconds."""
import sys, os, json, glob
sys.path.insert(0, os.path.dirname(__file__))
from analyze import summarize
WARM = float(os.environ.get('WARM', '4'))
rows = {}
for root in sys.argv[1:]:
    for d in sorted(glob.glob(os.path.join(root, '*/'))):
        name = os.path.basename(d.rstrip('/'))
        try: rows[name] = summarize(d.rstrip('/'), WARM)
        except Exception as e: print('skip', name, e, file=sys.stderr)
def ms(x): return '%.2f' % (x / 1e3)
print('| case | wire load | iroh p50 | iroh p99 | UDP p99 | added p99 | iroh frame-done p99 | UDP frame-done p99 | missing (startup / steady) | QUIC lost | send-buf evicted |')
print('|---|---|---|---|---|---|---|---|---|---|---|')
def key(n):
    p = n.split('_'); return (p[4], p[3], int(p[1][3:]), int(p[2][2:]), n)
for n in sorted((n for n in rows if n.startswith('iroh')), key=key):
    r = rows[n]; base = n.replace('iroh', 'udp', 1).split('_sbuf')[0].replace('_wait', '')
    u = rows.get(base.split('_apprate')[0])
    p = n.split('_'); cap = int(p[1][3:]); tx = int(p[2][2:])
    wire = tx * (1100 + 30 + 28 + 14) / 1100 / cap * 100  # % of TBF rate incl. QUIC+UDP/IP+eth
    added = ms(r['owd_p99'] - u['owd_p99']) if u else '-'
    steady_missing = r.get('missing_steady', '?')
    print(f"| {n[5:]} | {wire:.0f}% | {ms(r['owd_p50'])} | {ms(r['owd_p99'])} | {ms(u['owd_p99']) if u else '-'} | {added} | "
          f"{ms(r['frame_done_p99'])} | {ms(u['frame_done_p99']) if u else '-'} | {r['missing']-steady_missing} / {steady_missing} | {r['quic_lost_pkts']} | {r['send_buf_evicted']} |")
