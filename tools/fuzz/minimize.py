#!/usr/bin/env python3
"""Shrink a fuzz input while it still fails the same way.

usage: minimize.py <fuzz-repro> <harness> <input> <output> [--seconds N]

Runs `fuzz-repro <harness> <file>` on candidates. A candidate counts when it fails with
the same signature as the original (the panic message or error name, digits ignored).
Tries removing chunks (halves down to single bytes), then zeroing bytes.
"""
import os, re, subprocess, sys, tempfile, time

def signature(out):
    for line in out.splitlines():
        m = re.search(r"panic: (.*)", line) or re.search(r"(error\.\w+)", line) or re.search(r"(leaked memory)", line)
        if m:
            return re.sub(r"\d+", "N", m.group(1))
    return None

def run(repro, harness, data, tmp):
    with open(tmp, "wb") as f:
        f.write(data)
    try:
        p = subprocess.run([repro, harness, tmp], capture_output=True, text=True, errors="replace", timeout=20)
    except subprocess.TimeoutExpired:
        return "timeout"
    if p.returncode in (0, 2):
        return None
    return signature(p.stdout + p.stderr) or f"exit {p.returncode}"

def main():
    args = sys.argv[1:]
    seconds = 120
    if "--seconds" in args:
        i = args.index("--seconds")
        seconds = float(args[i + 1])
        del args[i:i + 2]
    repro, harness, inp, outp = args
    data = open(inp, "rb").read()
    fd, tmp = tempfile.mkstemp(prefix="fuzz-min-")
    os.close(fd)
    try:
        want = run(repro, harness, data, tmp)
        if want is None:
            print(f"minimize: {inp} does not fail; kept as is", file=sys.stderr)
            open(outp, "wb").write(data)
            return 1
        deadline = time.time() + seconds
        chunk = max(1, len(data) // 2)
        while chunk >= 1 and time.time() < deadline:
            i = 0
            changed = False
            while i < len(data) and time.time() < deadline:
                cand = data[:i] + data[i + chunk:]
                if run(repro, harness, cand, tmp) == want:
                    data = cand
                    changed = True
                else:
                    i += chunk
            if not changed:
                chunk //= 2
        for i in range(len(data)):
            if time.time() >= deadline:
                break
            if data[i] != 0:
                cand = data[:i] + b"\0" + data[i + 1:]
                if run(repro, harness, cand, tmp) == want:
                    data = cand
        open(outp, "wb").write(data)
        print(f"minimize: {harness}: {want}: {os.path.getsize(inp)} -> {len(data)} bytes", file=sys.stderr)
        return 0
    finally:
        os.unlink(tmp)

if __name__ == "__main__":
    sys.exit(main())
