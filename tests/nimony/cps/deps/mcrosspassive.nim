import std/syncio

# A `.passive` proc DEFINED here and CALLED from another module. Its
# coroutine helpers (`.init`/`.coro`/`.s<state>`) must be mangled with THIS
# module's suffix and resolvable from the caller's module. See
# hexer/coro_transform.nim (coroSuffix / publishForeignPassiveWrapper).

proc innerStep*() {.passive.} =
  echo "inner a"
  suspend()
  echo "inner b"

proc pingpong*() {.passive.} =
  echo "ping"
  innerStep()
  echo "pong"

proc addUp*(a, b: int): int {.passive.} =
  return a + b
