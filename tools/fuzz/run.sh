#!/usr/bin/env bash
# Fuzz every harness (fuzz/*.zig) in parallel for a given time, keeping corpora between
# runs, and turn each crash into a minimized regression input under fuzz/corpus/.
#
# usage: tools/fuzz/run.sh [-t SECONDS] [-j JOBS] [-s SLICE] [-o DIR] [HARNESS...]
#
#   -t SECONDS  how long to fuzz in total (default 3600)
#   -j JOBS     harnesses fuzzed at once, one core each (default: all cores)
#   -s SLICE    seconds a harness runs before the next one in line gets its core
#               (default: an even share, so every harness gets about JOBS*SECONDS/N)
#   -o DIR      work directory (default .fuzz): DIR/cache keeps the builds and the
#               corpora (reuse it to continue a campaign), DIR/crashes the raw crashing
#               inputs, DIR/log the fuzzer output
#   HARNESS     only these harnesses (names from `fuzz-repro --list`)
#
# Each harness runs in its own fuzzer process (`zig build fuzz --fuzz=<runs>
# -Dfuzz-filter=<harness>`): Zig 0.16's unlimited mode runs one slow instance behind its
# web UI, so the script does the scheduling itself. A crash stops that harness for the
# rest of the run; the others carry on. Each crash is saved raw, minimized with
# tools/fuzz/minimize.py, and copied to fuzz/corpus/<harness>/crash-<hash>, where
# `zig build test` replays it from then on. Exit status: 0 if nothing crashed, 1 if
# something did (see the summary), 2 on a usage or build error.
#
# The week-of-CPU gate (docs/fuzzing.md) is this script on a dedicated machine, e.g.
# `tools/fuzz/run.sh -t 75600 -j 8` (8 cores for 21 hours), repeated with the same -o
# until it finishes clean.
set -euo pipefail

seconds=3600
jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
slice=
work=.fuzz
while getopts "t:j:s:o:h" opt; do
  case $opt in
    t) seconds=$OPTARG ;;
    j) jobs=$OPTARG ;;
    s) slice=$OPTARG ;;
    o) work=$OPTARG ;;
    *) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
  esac
done
shift $((OPTIND - 1))

root=$(cd "$(dirname "$0")/../.." && pwd)
cd "$root"
mkdir -p "$work/crashes" "$work/log"
work=$(cd "$work" && pwd)
cache="$work/cache"

echo "fuzz: building fuzz-repro"
zig build fuzz-repro --cache-dir "$cache" --prefix "$work/bin" >/dev/null || exit 2
repro="$work/bin/bin/fuzz-repro"

if [ $# -gt 0 ]; then
  harnesses=("$@")
else
  mapfile -t harnesses < <("$repro" --list 2>&1)
fi
for h in "${harnesses[@]}"; do
  "$repro" --list 2>&1 | grep -qx "$h" || { echo "fuzz: no harness named $h" >&2; exit 2; }
done
n=${#harnesses[@]}
[ "$jobs" -gt "$n" ] && jobs=$n
[ -z "$slice" ] && slice=$(( seconds * jobs / n ))
[ "$slice" -lt 60 ] && slice=60

# Compile every harness's fuzzer up front (one binary per filter, JOBS at a time), and
# replay its corpus once, so slices start fuzzing at once.
echo "fuzz: compiling $n fuzzers"
export cache work
printf '%s\n' "${harnesses[@]}" | xargs -P "$jobs" -I{} sh -c \
  'zig build fuzz --cache-dir "$cache" -Dfuzz-filter="$1" >"$work/log/build-$1.log" 2>&1 || { echo "fuzz: $1 does not build or its corpus fails; see $work/log/build-$1.log" >&2; exit 255; }' _ {} ||
  exit 2

start=$(date +%s)
deadline=$(( start + seconds ))
crashed=()
declare -A pids=() logs=()
queue=("${harnesses[@]}")
runs=0

cleanup() { for p in "${pids[@]}"; do kill -- "-$p" 2>/dev/null || true; done; }
trap cleanup EXIT
trap 'exit 130' INT TERM

launch() {
  local h=$1 left=$(( deadline - $(date +%s) ))
  local t=$(( slice < left ? slice : left ))
  runs=$((runs + 1))
  local log="$work/log/$h-$runs.log"
  # setsid: one process group for the build runner and its fuzzer child, killed together.
  setsid bash -c 'sleep "$1" & s=$!; zig build fuzz --fuzz=1000G --cache-dir "$2" -Dfuzz-filter="$3" >"$4" 2>&1 & z=$!; wait -n; kill -- -$$ 2>/dev/null' \
    _ "$t" "$cache" "$h" "$log" &
  pids[$h]=$!
  logs[$h]=$log
}

on_crash() {
  local h=$1 log=$2
  crashed+=("$h")
  local raw
  raw=$(grep -o "input saved to '[^']*'" "$log" | head -1 | sed "s/input saved to '\(.*\)'/\1/")
  case $raw in /*) ;; *) raw="$root/$raw" ;; esac
  local sum
  sum=$(sha1sum "$raw" | cut -c1-12)
  mkdir -p "$work/crashes/$h" "fuzz/corpus/$h"
  cp "$raw" "$work/crashes/$h/crash-$sum"
  echo "fuzz: $h crashed; raw input $work/crashes/$h/crash-$sum"
  grep -E "panic:|failed with error|leak|error logs" "$log" | head -2 | sed 's/^/fuzz:   /'
  python3 "$root/tools/fuzz/minimize.py" "$repro" "$h" "$work/crashes/$h/crash-$sum" "fuzz/corpus/$h/crash-$sum" --seconds 120 || true
  echo "fuzz: regression input fuzz/corpus/$h/crash-$sum (replayed by zig build test)"
}

echo "fuzz: $n harnesses, $jobs at a time, ${slice}s slices, ${seconds}s in total"
while :; do
  now=$(date +%s)
  while [ ${#pids[@]} -lt "$jobs" ] && [ ${#queue[@]} -gt 0 ] && [ "$now" -lt "$deadline" ]; do
    h=${queue[0]}
    queue=("${queue[@]:1}")
    launch "$h"
  done
  [ ${#pids[@]} -eq 0 ] && break
  wait -n "${pids[@]}" 2>/dev/null || true
  for h in "${!pids[@]}"; do
    kill -0 "${pids[$h]}" 2>/dev/null && continue
    unset "pids[$h]"
    if grep -q "input saved to" "${logs[$h]}"; then
      on_crash "$h" "${logs[$h]}"
    else
      queue+=("$h") # slice used up: back of the line
    fi
  done
done

echo
echo "fuzz: done after $(( $(date +%s) - start ))s, $runs slices"
if [ ${#crashed[@]} -gt 0 ]; then
  echo "fuzz: crashed: ${crashed[*]}"
  exit 1
fi
echo "fuzz: no crashes"
