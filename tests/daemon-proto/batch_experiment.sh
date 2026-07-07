#!/bin/bash
# N-vs-1 batch experiment for the compile-daemon prototype (Track 2, Part B).
#
# Proves the structural win: when N independent modules that all import
# `system` are processed in ONE `nimsem m` invocation, the process-local
# interner `pool` stays warm, so system's index is parsed+interned ONCE
# instead of once-per-module. Requires an instrumented nimsem built with
# `-d:idxProfile` (see docs/daemon-prototype-findings.md).
#
# Usage: batch_experiment.sh <N> <nimcache-dir> <base-dir> <modlist-file>
set -uo pipefail

N="${1:-16}"
NC="${2:-/tmp/tall_nc2}"
BASE="${3:-tests/nimony/stdlib}"
MODLIST="${4:-/tmp/mods_all.txt}"
NIMSEM="$(cd "$(dirname "$0")/../.." && pwd)/bin/nimsem"

mapfile -t MODS < <(head -n "$N" "$MODLIST")
echo "# experiment: N=$N modules, nimsem=$NIMSEM"
echo "# modules:"; printf '  %s\n' "${MODS[@]}"

sys_cold() { grep -h 'sysvq0asl' "$1" 2>/dev/null | grep -v TOTAL | \
  awk '{for(i=1;i<=NF;i++)if($i~/^cold=/){split($i,a,"=");c+=a[2]}}END{print c+0}'; }

# --- A: N separate invocations (today's process-per-module model) -------
sepErr=/tmp/exp_sep.err; : > "$sepErr"
t0=$(date +%s.%N)
for m in "${MODS[@]}"; do
  "$NIMSEM" --base:"$BASE" --nimcache:"$NC" m "$m" 2>> "$sepErr" >/dev/null
done
t1=$(date +%s.%N)
sepWall=$(awk "BEGIN{printf \"%.3f\", $t1-$t0}")
sepSysCold=$(sys_cold "$sepErr")

# --- B: ONE batched invocation (pool stays warm) ------------------------
batErr=/tmp/exp_bat.err; : > "$batErr"
t0=$(date +%s.%N)
"$NIMSEM" --base:"$BASE" --nimcache:"$NC" m "${MODS[@]}" 2>> "$batErr" >/dev/null
t1=$(date +%s.%N)
batWall=$(awk "BEGIN{printf \"%.3f\", $t1-$t0}")
batSysCold=$(sys_cold "$batErr")

echo
echo "=== RESULTS (N=$N) ==="
printf "%-28s %10s %10s\n" "" "wall(s)" "sys-cold"
printf "%-28s %10.3f %10s\n" "A: N separate invocations" "$sepWall" "$sepSysCold"
printf "%-28s %10.3f %10s\n" "B: 1 batched invocation"   "$batWall" "$batSysCold"
echo
speedup=$(awk "BEGIN{printf \"%.2f\", $sepWall/$batWall}")
echo "wall-time speedup (A/B): ${speedup}x"
