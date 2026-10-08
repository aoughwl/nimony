# The memory-manager half of seq: buffer allocation, capacity, =destroy and
# (under -d:aowlgc) =trace. Included by seqimpl.nim; kept apart so the
# memory modes do not shift seqimpl.nim's line numbers (golden test outputs
# quote them).

when defined(aowlgc):
  # aowlgc (aowlvm DESIGN D1): a seq whose elements hold traced pointers
  # (refs, closures, seqs of those) keeps them in a *traced backing store* in
  # the GC heap; every other seq ("POD" for the GC: ints, strings, objects
  # without refs) keeps an owner-held malloc'd buffer exactly as under ARC.
  # Which one is a compile-time constant: `aowlgcTraits` is replaced by the
  # lifter's verdict on T (hexer/duplifier.trGcTraits). The choice was
  # benchmarked (aowlvm/P2-PLAN.md, P2b): POD seqs in the heap cost GC budget
  # and mark/sweep work for no benefit; `-d:aowlgcTracedPod` restores the
  # all-traced variant for comparison.
  #
  # A traced store traces its elements itself (all `usable div sizeof(T)`
  # slots; slots past `len` are kept zeroed), so a seq held anywhere the
  # collector only scans conservatively -- a native stack frame, a global --
  # keeps its elements alive through its one `data` word. The seq still owns
  # its store: destruction and reallocation release it explicitly (no
  # finalizer runs then). A store that dies with its (dead) owner instead is
  # finalized by the heap: its finalizer destroys its elements (strings, POD
  # buffers they own). Finalizers must not touch other GC objects, so a
  # seq's `=destroy` running inside a finalizer leaves a traced store alone:
  # it finalizes itself.
  template seqTraced[T](): bool =
    when defined(aowlgcTracedPod): true
    else: (aowlgcTraits(cast[ptr T](0)) and 1) != 0

  proc traceSeqBuf[T](env: pointer; p: pointer) {.nimcall.} =
    let a = cast[ptr UncheckedArray[T]](p)
    let n = aowlgcUsableSize(p) div sizeof(T)
    var i = 0
    while i < n:
      `=trace`(a[i], env)
      inc i

  proc finSeqBuf[T](p: pointer) {.nimcall.} =
    let a = cast[ptr UncheckedArray[T]](p)
    let n = aowlgcUsableSize(p) div sizeof(T)
    var i = 0
    while i < n:
      `=destroy`(a[i])
      inc i

  func seqAlloc[T](bytes: int): pointer {.inline.} =
    if seqTraced[T]():
      var slot {.global.}: int32
      let tracer: AowlgcTracer = traceSeqBuf[T]
      let fin: AowlgcFinalizer = if (aowlgcTraits(cast[ptr T](0)) and 2) != 0: finSeqBuf[T] else: nil
      {.cast(noSideEffect).}:
        result = aowlgcNewStore(addr slot, bytes, tracer, fin)
    else:
      result = alloc(bytes)

  func seqRealloc[T](old: pointer; usedBytes, bytes: int): pointer =
    if seqTraced[T]():
      result = seqAlloc[T](bytes)
      if result != nil and old != nil:
        copyMem(result, old, min(usedBytes, bytes))
        {.cast(noSideEffect).}:
          aowlgcFree(old)
    else:
      result = realloc(old, bytes)

  func seqZero[T](s: seq[T]; a, b: int) {.inline.} =
    ## zero the vacated slots `a ..< b` (their contents were destroyed or moved)
    if seqTraced[T]():
      if b > a and s.data != nil:
        zeroMem(addr s.data[a], (b - a) * sizeof(T))

  func capInBytes[T](s: seq[T]): int {.inline.} =
    if s.data == nil: result = 0
    elif seqTraced[T]():
      {.cast(noSideEffect).}:
        result = aowlgcUsableSize(s.data)
    else:
      result = allocatedSize(s.data)

  proc `=trace`*[T](s: var seq[T]; env: pointer) =
    if seqTraced[T]() and s.data != nil:
      aowlgcMark(env, s.data)

  func `=destroy`*[T](s: seq[T]) =
    if s.data != nil:
      if seqTraced[T]():
        var mine = false
        {.cast(noSideEffect).}:
          mine = aowlgcMayRelease()
        if mine:
          var i = 0
          while i < s.len:
            `=destroy`(s.data[i])
            inc i
          {.cast(noSideEffect).}:
            aowlgcFree(s.data)
      else:
        var i = 0
        while i < s.len:
          `=destroy`(s.data[i])
          inc i
        dealloc s.data
else:
  func seqAlloc[T](bytes: int): pointer {.inline.} = alloc(bytes)
  func seqRealloc[T](old: pointer; usedBytes, bytes: int): pointer {.inline.} = realloc(old, bytes)
  func seqZero[T](s: seq[T]; a, b: int) {.inline.} = discard

  func capInBytes[T](s: seq[T]): int {.inline.} =
    result = if s.data != nil: allocatedSize(s.data) else: 0

  func `=destroy`*[T](s: seq[T]) =
    if s.data != nil:
      var i = 0
      while i < s.len:
        `=destroy`(s.data[i])
        inc i
      dealloc s.data

