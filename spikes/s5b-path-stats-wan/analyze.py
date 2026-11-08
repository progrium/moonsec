#!/usr/bin/env python3
"""Summarize an S5b run directory. Usage: analyze.py <run-dir> [...]

Clocks: host_* files use the host clock, client_* the client clock. The offset
(host - client) comes from the min-RTT RTT probes, so it is good to about the
path asymmetry (a few ms at most).
"""
import csv, statistics, sys, os


def rd(path):
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return list(csv.DictReader(f))


def pct(v, q):
    if not v:
        return float("nan")
    v = sorted(v)
    return v[min(len(v) - 1, int(q * (len(v) - 1) + 0.5))]


def summarize(d):
    marks = rd(f"{d}/marks.csv")
    cev = rd(f"{d}/client_events.csv")
    hev = rd(f"{d}/host_events.csv")
    cst = rd(f"{d}/client_stats.csv")
    hst = rd(f"{d}/host_stats.csv")
    probes = rd(f"{d}/client_probes.csv")
    wire = rd(f"{d}/host_wire.csv")
    meta = open(f"{d}/meta.txt").read().strip().replace("\n", ", ") if os.path.exists(f"{d}/meta.txt") else ""
    out = [f"# S5b run {os.path.basename(d.rstrip('/'))}", "", meta, ""]
    P = lambda *a: out.append(" ".join(str(x) for x in a))

    for e in cev + hev:
        e["t"] = float(e["t"])
    for p in probes:
        p["ts"], p["tr"], p["ht"] = float(p["t_send"]), float(p["t_recv"]), float(p["host_t"])
        p["rtt"] = (p["tr"] - p["ts"]) * 1e3
    best = sorted(probes, key=lambda p: p["rtt"])[: max(1, len(probes) // 100)]
    off = statistics.median(p["ht"] - (p["ts"] + p["tr"]) / 2 for p in best) if best else 0.0
    P(f"clock offset host-client {off*1e3:+.1f} ms (from {len(best)} min-RTT probes, min RTT {best[0]['rtt']:.1f} ms)" if best else "no probes")
    h2c = lambda t: t - off  # host time -> client time

    # Timeline of commands in client time; host apply time where available.
    steps = []
    for m in marks:
        ht = float(m["host_t"]) if m["host_t"] not in ("", "0") else 0.0
        t = h2c(ht) if ht else float(m["t_send"])
        steps.append((m["cmd"], t, float(m["t_send"])))
    t_end = max([e["t"] for e in cev] + [float(m["t_reply"]) for m in marks])
    windows = []
    for i, (c, t, _) in enumerate(steps):
        nxt = steps[i + 1][1] if i + 1 < len(steps) else t_end
        windows.append((c, t, nxt))

    def ev(evs, side_kind, relay, a, b):
        return [e for e in evs if e["kind"] == side_kind and e["relay"] == ("true" if relay else "false") and a <= e["t"] < b]

    cev_h = [dict(e, t=h2c(e["t"])) for e in hev]  # host events in client time

    # Natural connect and punch
    con = next((s for s in steps if s[0] == "connect"), None)
    if con:
        sel = ev(cev, "selected", False, con[1], con[1] + 30)
        P(f"\n## Connect (dialed by key + relay URL only)")
        P(f"- connect to first direct Selected: {((sel[0]['t'] - con[1]) * 1e3):.0f} ms, addr {sel[0]['addr']}" if sel else "- never went direct")

    # stats helpers
    def stats_rows(rows, a, b, relay=None, selected=None):
        r = []
        for x in rows:
            t = float(x["t"])
            if a <= t < b and (relay is None or x["relay"] == relay) and (selected is None or x["selected"] == selected):
                r.append(x)
        return r

    P("\n## Steps")
    P("| step | window s | probe RTT p10/p50/p90 ms | client stats rtt p50 (sel) | host stats rtt p50 (sel) | host direct lost/sent | client media loss | max media gap ms | client path events | host path events |")
    P("|---|---|---|---|---|---|---|---|---|---|")
    rx = rd(f"{d}/client_rx.csv")
    rxt = [(float(r["t"]), int(r["seq"]), h2c(float(r["host_t"]))) for r in rx]
    for c, a, b in windows:
        if c in ("bind", "connect", "sample_1") or c.startswith("media"):
            continue
        pr = [p["rtt"] for p in probes if a <= p["ts"] < b]
        cs = [int(x["rtt_us"]) / 1e3 for x in stats_rows(cst, a, b, selected="true")]
        hs = [int(x["rtt_us"]) / 1e3 for x in stats_rows(hst, a + off, b + off, selected="true")]
        hd = stats_rows(hst, a + off, b + off, relay="false")
        lost = sent = 0
        by_id = {}
        for x in hd:
            by_id.setdefault(x["id"], []).append(x)
        for rows in by_id.values():
            sent += int(rows[-1]["sent"]) - int(rows[0]["sent"])
            lost += int(rows[-1]["lost"]) - int(rows[0]["lost"])
        # media loss: packets the host sent during the window (by host send time)
        seqs = [s for (_, s, hs_t) in rxt if a <= hs_t < b]
        mloss = f"{100 * (1 - len(seqs) / (max(seqs) - min(seqs) + 1)):.2f}%" if len(seqs) > 1 else "-"
        rts = [t for (t, _, _) in rxt if a <= t < b]
        gap = max((y - x for x, y in zip(rts, rts[1:])), default=0) * 1e3
        ce = [f"{e['kind'][0].upper()}{'r' if e['relay']=='true' else 'd'}@{(e['t']-a)*1e3:.0f}" for e in cev if a <= e["t"] < b and e["kind"] in ("opened", "selected", "closed")]
        he = [f"{e['kind'][0].upper()}{'r' if e['relay']=='true' else 'd'}@{(e['t']-a)*1e3:.0f}" for e in cev_h if a <= e["t"] < b and e["kind"] in ("opened", "selected", "closed")]
        P(f"| {c} | {b-a:.1f} | {pct(pr,.1):.1f}/{pct(pr,.5):.1f}/{pct(pr,.9):.1f} | {pct(cs,.5):.1f} | {pct(hs,.5):.1f} | {lost}/{sent} ({100*lost/max(sent,1):.2f}%) | {mloss} | {gap:.0f} | {' '.join(ce[:8])}{' …' if len(ce)>8 else ''} | {' '.join(he[:8])}{' …' if len(he)>8 else ''} |")

    # Wire: first direct packets after each unblock (host clock)
    if wire:
        # Only packets to/from the client's NAT address; the same socket also carries
        # iroh's QAD probes to relay servers.
        from collections import Counter
        peer_ip = Counter(w["peer"].rsplit(".", 1)[0] for w in wire if int(w["len"]) >= 1000).most_common(1)
        peer_ip = peer_ip[0][0] if peer_ip else ""
        wire = [w for w in wire if w["peer"].rsplit(".", 1)[0] == peer_ip]
        P(f"\n## Wire (host tcpdump, peer {peer_ip}) after unblock")
        for c, a, b in windows:
            if c != "unblock":
                continue
            ws = [w for w in wire if a + off <= float(w["t"]) < b + off]
            fi = next((float(w["t"]) for w in ws if w["dir"] == "in"), None)
            fo = next((float(w["t"]) for w in ws if w["dir"] == "out"), None)
            hs = next((e["t"] for e in cev_h if e["kind"] == "selected" and e["relay"] == "false" and a <= e["t"] < b), None)
            cs = next((e["t"] for e in cev if e["kind"] == "selected" and e["relay"] == "false" and a <= e["t"] < b), None)
            f = lambda x: f"{x:+.0f} ms" if x is not None else "never"
            P(f"- unblock@{a:.1f}: first in {f((fi - off - a) * 1e3 if fi else None)}, first out {f((fo - off - a) * 1e3 if fo else None)}, host Selected(direct) {f((hs - a) * 1e3 if hs else None)}, client Selected(direct) {f((cs - a) * 1e3 if cs else None)}")

    # Path switches: Selected events, and closes of the path that was selected at the
    # time (closes of never-selected candidate paths are just failed probes).
    def switches(evs):
        cur, res = None, []
        for e in sorted(evs, key=lambda e: e["t"]):
            if e["kind"] == "selected":
                if cur is not None and e["id"] != cur:
                    res.append((e["t"], f"sel->{'relay' if e['relay']=='true' else 'direct'}"))
                cur = e["id"]
            elif e["kind"] == "closed" and e["id"] == cur:
                res.append((e["t"], "selected-closed"))
        return res
    sc, sh_ = switches(cev), switches(cev_h)
    P("\n## Path switches by step (client / host)")
    for c, a, b in windows:
        x = [k for t, k in sc if a <= t < b]
        y = [k for t, k in sh_ if a <= t < b]
        if x or y:
            P(f"- {c}: client {x}, host {y}")

    polls = sorted(int(x["poll_ns"]) for x in cst)
    if polls:
        P(f"\nclient stats poll cost p50 {pct(polls,.5)/1e3:.1f} us, p99 {pct(polls,.99)/1e3:.1f} us")
    return "\n".join(out)


def punch(d):
    rows = rd(f"{d}/punch.csv")
    if not rows:
        return ""
    sel = [float(r["selected_direct_ms"]) for r in rows if r["selected_direct_ms"] != "never"]
    con = [float(r["connect_ms"]) for r in rows]
    out = [f"# Punch trials {os.path.basename(d.rstrip('/'))}", "",
           f"{len(rows)} trials, {len(sel)} went direct",
           f"- connect (relay) p50 {pct(con,.5):.0f} ms, max {max(con):.0f} ms",
           f"- connect start -> Selected(direct) p50 {pct(sel,.5):.0f} ms, min {min(sel, default=0):.0f}, max {max(sel, default=0):.0f} ms",
           f"- direct addrs: {sorted(set(r['direct_addr'] for r in rows))}"]
    return "\n".join(out)


if __name__ == "__main__":
    for d in sys.argv[1:]:
        s = punch(d) if os.path.exists(f"{d}/punch.csv") else summarize(d)
        print(s + "\n")
        with open(f"{d}/summary.md", "w") as f:
            f.write(s + "\n")
