# `-d:aowlgc`: the tracing-heap memory mode (aowlvm DESIGN D1, P2).
#
# Under aowlgc a `ref T` points into a non-moving, traced heap. The compiler
# (hexer) emits:
#   * `aowlgcNew(sizeof box, boxTracer, boxFinalizer)` for every `new`/object
#     construction of a ref (duplifier.trNewobj);
#   * `aowlgcMark(env, p)` in the lifted `=trace` of every `ref` (lifter);
# and refs have no `=destroy`/`=copy`/`=dup`/`=wasMoved` at all.
#
# The heap itself is `aowlgc_rt.c` until the `heap` library replaces it; only
# this file and that one know which implementation is in use.
#
# `-d:aowlgcExtern` (aowlvm DESIGN §6 / P11 stage 3): do NOT compile the private
# `aowlgc_rt.c` runtime into this module. The `aowlgc*` symbols below stay
# `importc`-only (undefined in the object), so a single HOST (the titicaca join
# binary, linked -rdynamic) provides them for the whole process over the shared
# `agentwork/heap` instance. A post-build `nm` check (fail-closed) asserts a
# module built with this flag DEFINES no `aowlgc*` symbol, so a second runtime
# can never creep back in.

when not defined(aowlgcExtern):
  {.compile("${path}/aowlgc_rt.c", "-O2").}

proc aowlgcNew*(size: int; trace, fin: pointer): pointer {.importc: "aowlgcNew".}
  ## Compiler hook: a zeroed heap object of `size` bytes whose type-info entry
  ## is identified by its box tracer `trace` and box finalizer `fin` (either
  ## may be nil). May trigger a collection.
type
  AowlgcTracer* = proc (p: pointer; env: pointer) {.nimcall.}
proc aowlgcNewTraced*(size: int; trace: AowlgcTracer): pointer {.importc: "aowlgcNewTraced".}
  ## `aowlgcNew(size, trace, nil)` for library code (backing stores), which
  ## cannot cast a proc to `pointer`.
proc aowlgcMark*(env, p: pointer) {.importc: "aowlgcMark".}
  ## Compiler hook: reports the edge to `p` while tracing (`env` is the
  ## visitor the collector passed to the tracer). nil and pointers that are not
  ## into the heap are ignored.
proc aowlgcFree*(p: pointer) {.importc: "aowlgcFree".}
  ## Explicitly frees a uniquely owned heap block (seq buffers). Ignored while
  ## a collection runs (the sweep frees dead blocks itself).
proc aowlgcUsableSize*(p: pointer): int {.importc: "aowlgcUsableSize".}
proc aowlgcAllocPinned*(size: int): pointer {.importc: "aowlgcAllocPinned".}
  ## A zeroed block that is never collected and is scanned conservatively as a
  ## root (coroutine frames, whose layout is only known after lifting).
proc aowlgcFreePinned*(p: pointer) {.importc: "aowlgcFreePinned".}
proc aowlgcPin*(p: pointer) {.importc: "aowlgcPin".}
proc aowlgcUnpin*(p: pointer) {.importc: "aowlgcUnpin".}
proc aowlgcIsLiveC(p: pointer): cint {.importc: "aowlgcIsLive".}
proc aowlgcIsLive*(p: pointer): bool = aowlgcIsLiveC(p) != 0
proc aowlgcStat*(which: int): int {.importc: "aowlgcStat".}
proc GC_fullCollect*() {.importc: "aowlgcCollect".}
  ## Runs a full stop-the-world collection now.

proc GC_collections*(): int = aowlgcStat(0)
proc GC_allocations*(): int = aowlgcStat(1)
proc GC_frees*(): int = aowlgcStat(2)
proc GC_finalized*(): int = aowlgcStat(3)
proc GC_liveObjects*(): int = aowlgcStat(4)
