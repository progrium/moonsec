#!/bin/sh
# usage: run.sh NAME SECONDS [probe args...]   (env vars pass through)
n=$1; s=$2; shift 2
./zig-out/bin/s7probe --source display --seconds "$s" --csv "results/$n.csv" "$@" > "results/$n.txt" 2>&1
grep -E "encoder id|RESULT|encode  |glass2enc|frames:" "results/$n.txt" | sed "s/^/[$n] /"
