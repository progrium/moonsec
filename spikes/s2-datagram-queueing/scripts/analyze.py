#!/usr/bin/env python3
"""Summarize one trial dir: one-way delay percentiles (post-warm-up) and drop accounting."""
import csv, json, sys, os

def pct(xs, p):
    if not xs: return float('nan')
    k = min(len(xs) - 1, max(0, int(round(p / 100 * (len(xs) - 1)))))
    return xs[k]

def load(d):
    rows = []
    with open(os.path.join(d, 'recv.csv')) as f:
        r = csv.reader(f); next(r)
        for seq, s, fr, fns, rns in r:
            rows.append((int(seq), int(s), int(fr), int(fns), int(rns)))
    return rows

def summarize(d, warm_secs=2.0):
    rows = load(d)
    send = json.load(open(os.path.join(d, 'send.json')))
    sent = send['app_sent']
    if not rows:
        return {'dir': d, 'received': 0, 'sent': sent}
    t0 = min(r[1] for r in rows)
    meas = [r for r in rows if r[1] - t0 >= warm_secs * 1e9]
    owd = sorted((r[4] - r[1]) / 1e3 for r in meas)  # us, from send call
    fdl = sorted((r[4] - r[3]) / 1e3 for r in meas)  # us, from frame start
    seqs = set(r[0] for r in rows)
    # missing seqs whose neighbours were sent in the steady-state window
    import bisect
    ks = sorted((r[0], r[1]) for r in rows)
    kseq = [k[0] for k in ks]
    miss_steady = 0
    for s_ in range(sent):
        if s_ in seqs: continue
        i = max(0, bisect.bisect(kseq, s_) - 1)
        if ks[i][1] - t0 >= warm_secs * 1e9: miss_steady += 1
    out = {
        'dir': os.path.basename(d), 'sent': sent, 'received': len(rows), 'unique': len(seqs),
        'missing': sent - len(seqs), 'missing_steady': miss_steady,
        'owd_min': owd[0], 'owd_p50': pct(owd, 50), 'owd_p99': pct(owd, 99), 'owd_p999': pct(owd, 99.9), 'owd_max': owd[-1],
        'fdl_p50': pct(fdl, 50), 'fdl_p99': pct(fdl, 99),
    }
    # last-packet-of-frame delay: when the whole frame is in
    last = {}
    for r in meas:
        last[r[2]] = max(last.get(r[2], 0), r[4] - r[3])
    fc = sorted(v / 1e3 for v in last.values())
    out['frame_done_p50'] = pct(fc, 50); out['frame_done_p99'] = pct(fc, 99)
    c = send.get('conn')
    if c:
        rj = json.load(open(os.path.join(d, 'recv.json')))
        out.update({
            'tx_dgram_frames': c['frame_tx_datagram'],
            'send_buf_evicted': sent - c['frame_tx_datagram'],
            'quic_lost_pkts': c['lost_packets'],
            'rx_dgram_frames': rj['conn']['frame_rx_datagram'],
            'recv_buf_dropped': rj['conn']['frame_rx_datagram'] - rj['app_received'],
            'cong_events': sum(p['congestion_events'] for p in c['paths']),
            'would_drop': send['send_buffer_would_drop'],
            'wire_overhead': (c.get('udp_tx_bytes', 0) / max(1, c['udp_tx'])) - 0,
        })
    q = os.path.join(d, 'qdisc.txt')
    if os.path.exists(q):
        import re
        m = re.search(r'dropped (\d+)', open(q).read())
        out['tbf_dropped'] = int(m.group(1)) if m else None
    return out

if __name__ == '__main__':
    for d in sys.argv[1:]:
        print(json.dumps(summarize(d)))
