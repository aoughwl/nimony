#!/usr/bin/env bash
# rebuild-devel.sh — regenerate the `devel` integration branch.
#
# devel = current upstream master
#       + every OPEN pull request authored by us (fetched live from GitHub)
#       + our local-only patches that aren't PRs yet
# then build the toolchain and smoke-test it.
#
# We push PRs faster than upstream merges them, and most are load-bearing for
# aoughwl. This gives us ONE branch with all of it, regenerable on demand: when
# a PR merges upstream it simply drops out of the "open" list (its work arrives
# via master instead), and when we open a new PR it joins automatically.
#
# Usage:  ./rebuild-devel.sh            # full: merge + build + smoke-test
#         ./rebuild-devel.sh --no-build # just regenerate the branch
set -euo pipefail

REPO="${REPO:-$HOME/nimony}"                 # main checkout (branch namespace)
WORKTREE="${WORKTREE:-$HOME/nimony-devel}"   # where devel is built
UPSTREAM="nim-lang/nimony"
# A clean upstream Nim devel — NOT ~/Nim (that checkout carries JS copy-elision
# patches that miscompile nimony's runtime). Override with NIM_BIN=...
NIM_BIN="${NIM_BIN:-$HOME/.choosenim/toolchains/nim-#devel/bin}"

# Local-only patch branches (not upstream PRs). Each is merged only if its work
# isn't already in master, so they self-retire once upstreamed.
LOCAL_PATCHES=(
  fix-empty-variant-branch-hang   # #2102-class: empty `of X: discard` variant hang
  fix-renderer-int16-len          # RenderTok.length int16->int32 (>32KB string literals)
  aoughwl-integration             # .aowl module resolution + implicit `aoughwl` import
)

say() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mFAIL: %s\033[0m\n' "$*" >&2; exit 1; }

cd "$REPO"

say "Fetching upstream master and our fork"
git fetch origin --quiet
git fetch fork   --quiet

say "Discovering our OPEN PRs on $UPSTREAM"
TOKEN=$(grep -m1 'github.com' "$HOME/.git-credentials" | sed -E 's#https://[^:]*:([^@]*)@.*#\1#')
mapfile -t PR_BRANCHES < <(
  curl -s -H "Authorization: token $TOKEN" \
    "https://api.github.com/repos/$UPSTREAM/pulls?state=open&per_page=100" \
  | python3 -c "import sys,json
for p in json.load(sys.stdin):
    if p['user']['login']=='savannt':
        print(p['head']['ref'], p['number'])" | sort -k2 -n | awk '{print $1}'
)
[ "${#PR_BRANCHES[@]}" -gt 0 ] || die "no open PRs found (auth or network problem?)"
printf '  open PR branches: %s\n' "${PR_BRANCHES[*]}"

say "Resetting devel to origin/master"
git worktree list | grep -q "$WORKTREE" || git worktree add "$WORKTREE" devel
cd "$WORKTREE"
git checkout --quiet devel 2>/dev/null || git checkout --quiet -b devel
git reset --hard --quiet origin/master

SKIPPED=()
merge_one() {  # $1 = ref to merge, $2 = human label
  local ref="$1" label="$2"
  if git merge-base --is-ancestor "$ref" HEAD 2>/dev/null; then
    printf '  skip  %s (already in devel/master)\n' "$label"; return
  fi
  if git merge --no-edit -m "devel: merge $label" "$ref" >/tmp/devel-merge.log 2>&1; then
    printf '  merge %s\n' "$label"
  else
    # A conflict between two in-flight branches shouldn't sink the whole
    # toolchain: abort this one, note it, keep going. The pair needs a manual
    # rebase, but devel still builds with everything else.
    git merge --abort 2>/dev/null || true
    SKIPPED+=("$label")
    printf '  \033[1;33mSKIP  %s (merge conflict — needs manual rebase)\033[0m\n' "$label"
  fi
}

say "Merging open PRs"
for b in "${PR_BRANCHES[@]}"; do
  git rev-parse --verify --quiet "fork/$b" >/dev/null \
    && merge_one "fork/$b" "PR:$b" \
    || printf '  WARN  fork/%s not found locally (git fetch fork)\n' "$b"
done

say "Merging local patches"
for b in "${LOCAL_PATCHES[@]}"; do
  git rev-parse --verify --quiet "$b" >/dev/null \
    && merge_one "$b" "local:$b" \
    || printf '  WARN  local branch %s missing\n' "$b"
done

say "devel assembled:"
git --no-pager log --oneline origin/master..HEAD | sed 's/^/  /'

if [ "${#SKIPPED[@]}" -gt 0 ]; then
  printf '\n\033[1;33m⚠ SKIPPED (merge conflict, not in devel): %s\033[0m\n' "${SKIPPED[*]}"
  echo '  These branches conflict with something already merged; rebase them to include.'
fi

if [ "${1:-}" = "--no-build" ]; then
  say "Skipping build (--no-build)."; exit 0
fi

say "Building toolchain with clean Nim ($NIM_BIN)"
[ -x "$NIM_BIN/nim" ] || die "nim not found at $NIM_BIN (set NIM_BIN=...)"
export PATH="$NIM_BIN:$PATH"
"$NIM_BIN/nim" c -o:bin/hastur src/hastur.nim >/tmp/devel-hastur.log 2>&1 || die "hastur build (see /tmp/devel-hastur.log)"
rm -rf nimcache
./bin/hastur build all >/tmp/devel-buildall.log 2>&1 || die "toolchain build (see /tmp/devel-buildall.log)"

say "Smoke-testing the compiler"
printf 'import std/syncio\necho "devel ok"\n' > /tmp/devel-smoke.nim
if out=$(./bin/nimony c -r /tmp/devel-smoke.nim 2>&1) && printf '%s' "$out" | grep -q 'devel ok'; then
  printf '\n\033[1;32mSUCCESS — devel builds and runs.\033[0m  bin at %s/bin\n' "$WORKTREE"
else
  printf '%s\n' "$out" | tail -8
  die "smoke test crashed (this is the WSL2 alloc bug if it's addToSharedFreeList — ensure #2103 is in master or add -d:useMalloc)"
fi
