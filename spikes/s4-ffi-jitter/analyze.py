#!/usr/bin/env python3
"""Turn s4 probe dumps into latency/jitter stats.

handoff = t3 - t0: Zig stamps t0, calls s4_send; t3 is entry to the sendmsg/sendto/send
syscall wrapper for the packet carrying that datagram. This is the S4 pass metric.
In iroh modes, packets are encrypted, so packets >= payload size are matched to datagrams
in FIFO order (a GSO send of k segments consumes k datagrams); handshake packets sent
before the first datagram are ignored.
"""
import csv, sys, json

def pct(xs, p):
    if not xs: return float('nan')
    i = min(len(xs) - 1, max(0, int(round(p / 100 * (len(xs) - 1)))))
    return xs[i]

def stats(vals):
    v = sorted(vals)
    us = lambda x: round(x / 1000, 1)
    return dict(n=len(v), p50=us(pct(v, 50)), p90=us(pct(v, 90)), p99=us(pct(v, 99)),
                p999=us(pct(v, 99.9)), max=us(v[-1]) if v else None)

def load(prefix, warmup):
    rows = [list(map(int, r)) for r in list(csv.reader(open(prefix + '.seq.csv')))[1:]]
    ev = [list(map(int, r)) for r in list(csv.reader(open(prefix + '.ev.csv')))[1:]]
    if ev and all(r[4] == 0 for r in rows):  # iroh: match by FIFO
        ev.sort()
        q = 0
        for t3, t4, ln, segs in ev:
            for _ in range(segs):
                if q < len(rows) and rows[q][2] <= t3:
                    rows[q][4], rows[q][5] = t3, t4
                    q += 1
    rows = rows[warmup:]
    missing = sum(1 for r in rows if r[4] == 0)
    rows = [r for r in rows if r[4]]
    out = dict(
        ffi_entry=stats([r[2] - r[1] for r in rows]),
        handoff=stats([r[4] - r[1] for r in rows]),
        shim_to_socket=stats([r[4] - r[2] for r in rows]),
        syscall=stats([r[5] - r[4] for r in rows]),
        unmatched=missing,
    )
    if any(r[3] for r in rows):
        out['task_pickup'] = stats([r[3] - r[2] for r in rows])
    return out

if __name__ == '__main__':
    warmup = int(sys.argv[2]) if len(sys.argv) > 2 else 500
    print(json.dumps(load(sys.argv[1], warmup)))
