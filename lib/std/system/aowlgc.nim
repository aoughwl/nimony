# `-d:aowlgc`: the tracing-heap memory mode (aowlvm DESIGN D1, P2).
#
# Under aowlgc a `ref T` points into a non-moving, traced heap: the `heap`
# library (agentwork/heap, vendored as `system/aowlheap/`), driven by the
# runtime module `system/aowlgcrt.nim`. The compiler (hexer) emits:
#   * `aowlgcNew(addr slot, sizeof box, boxTracer, boxFinalizer)` for every
#     `new`/object construction of a ref (duplifier.trNewobj); `slot` is a
#     zero-initialized global int32 per allocated type and module that caches
#     the heap type id (registered by the first allocation);
#   * `aowlgcMark(env, p)` in the lifted `=trace` of every `ref` (lifter);
#   * a constant for every `aowlgcTraits(cast[ptr T](0))` (duplifier);
# and refs have no `=destroy`/`=copy`/`=dup`/`=wasMoved` at all.
#
# These are plain C-level declarations: system cannot import the runtime
# module (it imports system), so the build graph adds `aowlgcrt` to every
# `-d:aowlgc` program (nimony/deps.nim) and the linker connects the two.

type
  AowlgcTracer* = nil proc (env: pointer; p: pointer) {.nimcall.}
    ## A heap object's tracer: reports every traced pointer it holds with
    ## `aowlgcMark(env, ...)`.
  AowlgcFinalizer* = nil proc (p: pointer) {.nimcall.}
    ## Runs when the object is found dead (lazily, in no particular order).
    ## Releases only non-GC resources; must not read other GC objects.

proc aowlgcNew*(slot: ptr int32; size: int; trace, fin: pointer): pointer {.importc: "aowlgcNew".}
  ## Compiler hook: a zeroed heap object of `size` bytes whose type is cached
  ## in `slot` (registered with `trace`/`fin`, either may be nil, on first
  ## use). May collect.
proc aowlgcNewStore*(slot: ptr int32; bytes: int; trace: AowlgcTracer;
                     fin: AowlgcFinalizer): pointer {.importc: "aowlgcNewStore".}
  ## A zeroed variable-size backing store (seq buffers of traced elements).
proc aowlgcMark*(env, p: pointer) {.importc: "aowlgcMark".}
  ## Compiler hook: reports the edge to `p` while tracing (`env` is the
  ## visitor the collector passed to the tracer). nil and pointers that are
  ## not into the heap are ignored.
proc aowlgcMayRelease*(): bool {.importc: "aowlgcMayRelease".}
  ## False while the collector runs a finalizer (or any GC callback): a
  ## finalizer must leave other heap objects alone.
proc aowlgcFree*(p: pointer) {.importc: "aowlgcFree".}
  ## Explicitly releases a uniquely owned heap object (seq stores) without
  ## finalizing it. Ignored outside the idle phase.
proc aowlgcUsableSize*(p: pointer): int {.importc: "aowlgcUsableSize".}
proc aowlgcAllocPinned*(size: int): pointer {.importc: "aowlgcAllocPinned".}
  ## A zeroed object that is a root until `aowlgcFreePinned` and is scanned
  ## conservatively (coroutine frames, whose layout is only known after lifting).
proc aowlgcFreePinned*(p: pointer) {.importc: "aowlgcFreePinned".}
proc aowlgcPin*(p: pointer) {.importc: "aowlgcPin".}
proc aowlgcUnpin*(p: pointer) {.importc: "aowlgcUnpin".}
proc aowlgcIsLive*(p: pointer): bool {.importc: "aowlgcIsLive".}
proc aowlgcStat*(which: int): int {.importc: "aowlgcStat".}
proc GC_fullCollect*() {.importc: "aowlgcCollect".}
  ## Runs a full stop-the-world collection now and finishes sweeping (every
  ## finalizer of a dead object has run when it returns).

func aowlgcTraits*[T](p: ptr T): int =
  ## Compile-time traits of T for the memory manager: bit 0 = T holds traced
  ## pointers, bit 1 = T needs destruction. Every call is replaced by a
  ## constant in hexer; this body (all bits) is never used.
  result = 3

proc GC_collections*(): int = aowlgcStat(0)
proc GC_allocations*(): int = aowlgcStat(1)
proc GC_frees*(): int = aowlgcStat(2)
proc GC_finalized*(): int = aowlgcStat(3)
proc GC_liveObjects*(): int = aowlgcStat(4)
