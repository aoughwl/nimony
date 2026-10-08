#!/usr/bin/env bash
# Vendor the `heap` library (agentwork/heap) into lib/std/system/aowlheap/,
# the tracing heap behind -d:aowlgc. Usage: tools/sync_aowlheap.sh [HEAP_REPO]
# (default: $AOWL_HEAP or /mnt/c/Users/savant/agentwork/heap). Only osmem and
# core are needed (system code never uses Member/Persistent).
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
src="${1:-${AOWL_HEAP:-/mnt/c/Users/savant/agentwork/heap}}"
dst="$root/lib/std/system/aowlheap"
rev=$(git -C "$src" rev-parse --short HEAD)
branch=$(git -C "$src" rev-parse --abbrev-ref HEAD)
mkdir -p "$dst"
for f in osmem core; do
  { echo "# VENDORED from the heap library ($branch @ $rev): src/heap/$f.nim."
    echo "# Do not edit here; change the heap repo and run tools/sync_aowlheap.sh."
    cat "$src/src/heap/$f.nim"; } > "$dst/$f.nim"
done
echo "aowlheap <- $src ($branch @ $rev)"
