#!/usr/bin/env python3
"""S10 tables: per case, median over repetitions of each kind's p99 one-way delay, plus drop
accounting. Usage: report.py REPDIR [REPDIR...] > table.md  (steady state after WARM=4 s)."""
import sys, os, json, glob, statistics, re
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '../../s2-datagram-queueing/scripts'))
from analyze import summarize
WARM = float(os.environ.get('WARM', '4'))
runs = {}  # name -> [summary per rep]
for root in sys.argv[1:]:
    for d in sorted(glob.glob(os.path.join(root, '*/'))):
        d = d.rstrip('/'); name = os.path.basename(d)
        try:
            s = summarize(d, WARM)
            send = json.load(open(os.path.join(d, 'send.json')))
            s['zig_dropped'] = send.get('zig_queue_dropped')
            s['ring_dropped'] = send.get('ring_full_dropped')
        except Exception as e:
            print('skip', name, e, file=sys.stderr); continue
        runs.setdefault(name, []).append(s)
def med(name, key):
    v = [r[key] for r in runs.get(name, []) if r.get(key) is not None]
    return statistics.median(v) if v else None
def ms(x): return '-' if x is None else '%.2f' % (x / 1e3)
def rng(name, key):
    v = [r[key] for r in runs.get(name, []) if r.get(key) is not None]
    return '-' if not v else ('%.2f' % (min(v)/1e3) if len(v) == 1 else '%.2f–%.2f' % (min(v)/1e3, max(v)/1e3))
cases = sorted({re.sub(r'^(udp|iroh|noq|noqrate)_', '', n).rsplit('_', 1)[0] if not n.startswith('udp') else re.sub(r'^udp_', '', n) for n in runs})
def section(title, variant, kinds, key='owd_p99'):
    print(f'\n### {title}\n')
    print('| case | UDP | ' + ' | '.join(k[1] for k in kinds) + ' |')
    print('|---|---|' + '---|' * len(kinds))
    for c in cases:
        names = [f'{k[0]}_{c}_{variant if k[2] is None else k[2]}' for k in kinds]
        if not any(n in runs for n in names): continue
        u = f'udp_{c}'
        cells = [rng(u, key)] + [rng(n, key) for n in names]
        print(f'| {c} | ' + ' | '.join(cells) + ' |')
K = [('iroh', 'iroh + AppRate, pinned RT runtime', None), ('noq', 'noq-proto, Zig pacer', None), ('noqrate', 'noq-proto, noq pacer', None)]
section('Below the cap, paced at capacity: one-way delay p99 (ms, range over reps)', 'cap', K)
section('Below the cap, paced at capacity: frame-done p99 (ms)', 'cap', K + [('noq', 'noq-proto, Zig pacer, 20 ms credit', 'capburst')], 'frame_done_p99')
section('At/above the cap, paced at 1.05x offered: one-way delay p99 (ms)', 'enc', K[:2])
# drop accounting
print('\n### Drop accounting (per run)\n')
print('| run | sent | received | sender-side drops (counted) | sent − frame_tx (true sender loss) | QUIC lost | TBF dropped | all accounted? |')
print('|---|---|---|---|---|---|---|---|')
for n in sorted(runs):
    if n.startswith('udp'): continue
    if not any(v in n for v in ('_enc', '_over90', 'tx85', 'tx110', 'tx95', 'tx150')): continue
    for r in runs[n]:
        sd = r.get('zig_dropped')
        truth = r.get('send_buf_evicted')
        counted = sd if sd is not None else 0  # iroh counts nothing on the send side
        lost = r.get('quic_lost_pkts'); tbf = r.get('tbf_dropped')
        missing = r['sent'] - r['unique']
        ok = (counted == truth) and (missing == truth + (lost or 0) + (r.get('recv_buf_dropped') or 0))
        print(f"| {n} | {r['sent']} | {r['unique']} | {sd if sd is not None else 'not counted'} | {truth} | {lost} | {tbf} | {'yes' if ok else 'no'} |")
