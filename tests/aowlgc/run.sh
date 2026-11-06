#!/usr/bin/env bash
# aowlgc test runner: every tests/aowlgc/t*.nim is compiled with -d:aowlgc and
# run three ways, each compared with t*.output:
#   plain                       default collection policy
#   AOWLGC_STRESS=$STRESS        collect every N allocations, poisoned frees
#     + AOWLGC_VERIFY=1          check every precise edge after each mark
# Usage: tests/aowlgc/run.sh [test-name...]   (STRESS defaults to 50)
set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
nimony="$root/bin/nimony"
stress="${STRESS:-50}"
cd "$here"
if [ $# -gt 0 ]; then tests=("$@"); else tests=(t*.nim); fi
pass=0; fail=0
for t in "${tests[@]}"; do
  t="${t%.nim}"
  if ! out=$("$nimony" c -d:aowlgc "$t.nim" 2>&1); then
    echo "FAIL(compile) $t"; echo "$out" | grep -v Warning | tail -5; fail=$((fail+1)); continue
  fi
  exe=$(ls -d nimcache/*/"$t" 2>/dev/null | head -1)
  for mode in plain stress; do
    if [ $mode = plain ]; then got=$(timeout 300 "$exe" 2>&1); rc=$?
    else got=$(AOWLGC_STRESS=$stress AOWLGC_VERIFY=1 timeout 600 "$exe" 2>&1); rc=$?; fi
    if [ $rc -ne 0 ] || [ "$got" != "$(cat "$t.output")" ]; then
      echo "FAIL($mode, rc=$rc) $t"; diff <(echo "$got") "$t.output" | head -10; fail=$((fail+1))
    else
      pass=$((pass+1))
    fi
  done
done
echo "aowlgc: $pass passed, $fail failed"
[ $fail -eq 0 ]
