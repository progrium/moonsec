#!/usr/bin/env python3
"""Summarize S5c runs. Usage: analyze.py <out-root>  -> per-blackout CSV + markdown tables.

All namespaces share one clock, so host and client timestamps compare directly.
Per blackout (host firewall drops the host's direct UDP for `ms`):
  closed     the client saw its direct path Closed between blackout start and 2 s after it ended
  detect     blackout start -> client Closed(direct)
  gap        longest gap between media datagrams received by the client around the blackout
  lost       media datagrams sent from 0.2 s before the blackout to 5 s after it that never arrived
  back       blackout end -> client Selected(direct) again (only when it closed)
  relay_s    time spent on the relay (client Selected(relay) -> Selected(direct))
"""
import csv, os, sys, statistics, bisect, glob, re


def rd(p):
    if not os.path.exists(p):
        return []
    with open(p) as f:
        return list(csv.DictReader(f))


def med(v):
    return statistics.median(v) if v else None


def fmt(x, nd=0):
    if x is None:
        return "–"
    return f"{x:.{nd}f}"


def run(d):
    bos = rd(f"{d}/blackouts.csv")
    ev = rd(f"{d}/client_events.csv")
    hev = rd(f"{d}/host_events.csv")
    rx = rd(f"{d}/client_rx.csv")
    marks = rd(f"{d}/marks.csv")
    for e in ev + hev:
        e["t"] = float(e["t"])
    rxt = sorted(float(r["t"]) for r in rx)
    sent = sorted((float(r["host_t"]), int(r["seq"])) for r in rx)
    got = set(int(r["seq"]) for r in rx)
    host_t = [s[0] for s in sent]
    seqs = [s[1] for s in sent]

    def first(evs, kind, relay, a, b=1e18):
        for e in evs:
            if e["kind"] == kind and e["relay"] == relay and a <= e["t"] < b:
                return e["t"]
        return None

    def gap(a, b):
        i = bisect.bisect_left(rxt, a)
        j = bisect.bisect_right(rxt, b)
        w = rxt[max(0, i - 1) : j + 1]
        return max((y - x for x, y in zip(w, w[1:])), default=0) * 1e3

    def lost(a, b):
        # seq range the host sent in [a, b]: interpolate from received datagrams' send times
        i = bisect.bisect_left(host_t, a)
        j = bisect.bisect_right(host_t, b) - 1
        if i >= len(seqs) or j < 0:
            return 0
        lo, hi = seqs[max(0, i - 1)] + 1 if i > 0 else seqs[0], seqs[min(j + 1, len(seqs) - 1)] - 1
        return sum(1 for s in range(lo, hi + 1) if s not in got)

    rows = []
    for b in bos:
        ms, t_on = int(b["ms"]), float(b["t_on"])
        t_off = t_on + ms / 1e3
        nxt = [float(x["t_on"]) for x in bos if float(x["t_on"]) > t_on]
        end = min(nxt) - 3.0 if nxt else 1e18  # the client waits 3 s on direct before each blackout
        tc = first(ev, "closed", "false", t_on, t_off + 2.0)
        th = first(hev, "closed", "false", t_on, t_off + 2.0)
        tr = first(ev, "selected", "true", t_on, end) if tc else None
        tb = first(ev, "selected", "false", tc, end + 3.0) if tc else None
        rows.append(
            dict(
                idx=int(b["idx"]),
                ms=ms,
                valid=b["direct_before"] == "true",
                closed=tc is not None,
                host_closed=th is not None,
                detect=(tc - t_on) * 1e3 if tc else None,
                gap=gap(t_on - 0.2, (tb or t_off) + 2.0),
                lost=lost(t_on - 0.2, t_off + 5.0),
                back=(tb - t_off) * 1e3 if tb else None,
                relay_s=(tb - tr) if (tb and tr) else None,
            )
        )
    # hard block
    blk = {}
    m = {x["cmd"]: x for x in marks}
    if "block" in m and "unblock" in m:
        tb0, tu = float(m["block"]["host_apply"]), float(m["unblock"]["host_apply"])
        tc = first(ev, "closed", "false", tb0, tu)
        ts = first(ev, "selected", "true", tb0, tu)
        td = first(ev, "selected", "false", tu)
        blk = dict(
            detect=(tc - tb0) * 1e3 if tc else None,
            to_relay=(ts - tb0) * 1e3 if ts else None,
            gap=gap(tb0 - 0.2, tb0 + 3.0),
            unblock_direct=(td - tu) * 1e3 if td else None,
        )
    meta = dict(l.split("=", 1) for l in open(f"{d}/meta.txt").read().split("\n") if "=" in l) if os.path.exists(f"{d}/meta.txt") else {}
    if meta.get("first_direct"):
        blk["first_direct"] = (float(meta["first_direct"]) - float(meta["t_connect"])) * 1e3
    return rows, blk


def main(root):
    runs = sorted(d for d in glob.glob(f"{root}/rtt*-*-idle*") if os.path.isdir(d))
    allrows = []
    blocks = {}
    for d in runs:
        mt = re.match(r"rtt(\d+)-(\w+)-idle(\d+)", os.path.basename(d))
        rtt, build, idle = int(mt[1]), mt[2], int(mt[3])
        rows, blk = run(d)
        for r in rows:
            allrows.append(dict(rtt=rtt, build=build, idle=idle, **r))
        blocks[(rtt, build, idle)] = blk
    with open(f"{root}/blackouts_all.csv", "w") as f:
        w = csv.DictWriter(f, fieldnames=list(allrows[0].keys()))
        w.writeheader()
        w.writerows(allrows)

    out = []
    P = out.append
    keys = sorted(blocks, key=lambda k: (k[0], k[2], k[1] != "stock"))
    P("## Hard block (direct path dropped until unblocked)\n")
    P("| RTT | idle | build | dial → direct ms | block → Closed(direct) ms | block → Selected(relay) ms | media gap ms | unblock → direct ms |")
    P("|---|---|---|---|---|---|---|---|")
    for k in keys:
        b = blocks[k]
        P(f"| {k[0]} | {k[2]} | {k[1]} | {fmt(b.get('first_direct'))} | {fmt(b.get('detect'))} | {fmt(b.get('to_relay'))} | {fmt(b.get('gap'))} | {fmt(b.get('unblock_direct'))} |")

    mss = sorted(set(r["ms"] for r in allrows))
    P("\n## Blackouts: direct path closed (closes / valid trials)\n")
    P("| RTT | idle | build | " + " | ".join(f"{m}" for m in mss) + " |")
    P("|---|---|---|" + "---|" * len(mss))
    for k in keys:
        cells = []
        for m in mss:
            rs = [r for r in allrows if (r["rtt"], r["build"], r["idle"]) == k and r["ms"] == m and r["valid"]]
            cells.append(f"{sum(r['closed'] for r in rs)}/{len(rs)}")
        P(f"| {k[0]} | {k[2]} | {k[1]} | " + " | ".join(cells) + " |")

    P("\n## Blackouts: longest media gap, median ms (includes the blackout itself)\n")
    P("| RTT | idle | build | " + " | ".join(f"{m}" for m in mss) + " |")
    P("|---|---|---|" + "---|" * len(mss))
    for k in keys:
        cells = []
        for m in mss:
            rs = [r["gap"] for r in allrows if (r["rtt"], r["build"], r["idle"]) == k and r["ms"] == m and r["valid"]]
            cells.append(fmt(med(rs)))
        P(f"| {k[0]} | {k[2]} | {k[1]} | " + " | ".join(cells) + " |")

    P("\n## Blackouts: media datagrams lost, median (200 pkt/s)\n")
    P("| RTT | idle | build | " + " | ".join(f"{m}" for m in mss) + " |")
    P("|---|---|---|" + "---|" * len(mss))
    for k in keys:
        cells = []
        for m in mss:
            rs = [r["lost"] for r in allrows if (r["rtt"], r["build"], r["idle"]) == k and r["ms"] == m and r["valid"]]
            cells.append(fmt(med(rs)))
        P(f"| {k[0]} | {k[2]} | {k[1]} | " + " | ".join(cells) + " |")

    P("\n## After a close: blackout end → direct again, s (min–max over closes)\n")
    P("| RTT | idle | build | closes | back to direct after outage, s | time on relay, s |")
    P("|---|---|---|---|---|---|")
    for k in keys:
        rs = [r for r in allrows if (r["rtt"], r["build"], r["idle"]) == k and r["valid"] and r["closed"]]
        bk = [r["back"] / 1e3 for r in rs if r["back"] is not None]
        rl = [r["relay_s"] for r in rs if r["relay_s"] is not None]
        never = sum(1 for r in rs if r["back"] is None)
        rng = lambda v: f"{min(v):.2f}–{max(v):.2f} (median {med(v):.2f})" if v else "–"
        P(f"| {k[0]} | {k[2]} | {k[1]} | {len(rs)} | {rng(bk)}{f'; {never} not back in window' if never else ''} | {rng(rl)} |")

    P("\n## Detection: blackout start → Closed(direct), ms (median over closes)\n")
    P("| RTT | idle | build | median | min | max |")
    P("|---|---|---|---|---|---|")
    for k in keys:
        v = [r["detect"] for r in allrows if (r["rtt"], r["build"], r["idle"]) == k and r["valid"] and r["closed"]]
        P(f"| {k[0]} | {k[2]} | {k[1]} | {fmt(med(v))} | {fmt(min(v) if v else None)} | {fmt(max(v) if v else None)} |")
    inv = sum(1 for r in allrows if not r["valid"])
    P(f"\n{len(allrows)} blackouts, {inv} skipped because the path was not direct when they started.")
    s = "\n".join(out)
    open(f"{root}/summary.md", "w").write(s + "\n")
    print(s)


if __name__ == "__main__":
    main(sys.argv[1])
