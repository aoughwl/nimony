## The runtime of nimony's `-d:aowlgc` memory mode (aowlvm DESIGN D1, P2b):
## the C-level entry points declared in `system/aowlgc.nim`, implemented on
## the `heap` library (agentwork/heap, vendored in `system/aowlheap/`).
##
## Not imported by anything: `nimony/deps.nim` adds this module to the build
## graph of every `-d:aowlgc` program, and the linker resolves system's
## `importc` declarations against the `exportc` procs below.
##
## Model:
## * one heap per process, created by the first allocation (on that thread:
##   its stack is the one scanned; DESIGN D8, single-threaded heap);
## * three type families (isolation: a freed slot of one is never reused by
##   another): `nimony` (ref boxes), `nimony.store` (seq backing stores) and
##   `nimony.frame` (coroutine frames);
## * every allocated ref type registers once, through the per-type id slot
##   the compiler passes (`aowlgcNew(addr slot, ...)`): the fast path is one
##   load, a compare and the heap's inline allocation;
## * roots: the native stack + registers (the heap's conservative scan), the
##   static data and thread-locals of the image this module is linked into
##   (`addImageRoots`: module globals and threadvars, conservatively), and
##   the pin table (`GC_ref`, coroutine frames) through a root provider;
## * environment: `AOWLGC_STRESS=N` collect every N allocations,
##   `AOWLGC_VERIFY=1` run the heap verifier inside every collection (`=2`:
##   also scan payloads for dangling words), `AOWLGC_POISON=0/1` force
##   poisoning + page quarantine off/on (default: on in debug builds),
##   `AOWLGC_CAGE_MB` the virtual reservation (default 16 GiB),
##   `AOWLGC_STATS=1` print statistics at exit. A verifier or marking-check
##   failure prints the message and aborts.

import aowlheap/core

proc c_getenv(name: cstring): cstring {.importc: "getenv", header: "<stdlib.h>".}
proc c_atoll(s: cstring): int64 {.importc: "atoll", header: "<stdlib.h>".}
proc c_abort() {.importc: "abort", header: "<stdlib.h>", noreturn.}
proc c_atexit(f: proc () {.cdecl.}): cint {.importc: "atexit", header: "<stdlib.h>".}
proc c_fputs(s: cstring; f: pointer): cint {.importc: "fputs", header: "<stdio.h>".}
proc c_fflush(f: pointer): cint {.importc: "fflush", header: "<stdio.h>".}
var c_stderr {.importc: "stderr", header: "<stdio.h>".}: pointer

template isNilP(p: pointer): bool = cast[uint](p) == 0'u

type
  PinEntry = object
    p: pointer
    count: int

var gHeap: Heap = cast[Heap](0)
var gFamRef, gFamStore, gFamFrame: FamilyId
var gFrameTid: TypeId
var gPins: ptr UncheckedArray[PinEntry] = cast[ptr UncheckedArray[PinEntry]](0)
var gPinCap = 0
var gPinCount = 0      # live entries
var gPinUsed = 0       # live + tombstones
var gTypeNo = 0
var gStatsAtExit = false

proc errLine(s: string) =
  var m = s
  m.add "\n"
  discard c_fputs(toCString(m), c_stderr)
  discard c_fflush(c_stderr)

proc envInt(name: cstring; dflt: int64): int64 =
  let v = c_getenv(name)
  if isNilP(cast[pointer](v)): dflt else: c_atoll(v)

proc onVerifyError(h: Heap; e: HeapError; msg: cstring) {.cdecl.} =
  discard c_fputs(cstring"aowlgc: heap verification failed: ", c_stderr)
  discard c_fputs(msg, c_stderr)
  errLine("")
  c_abort()

proc onHeapError(h: Heap; e: HeapError; msg: cstring) {.cdecl.} =
  discard c_fputs(cstring"aowlgc: ", c_stderr)
  discard c_fputs(msg, c_stderr)
  errLine("")
  c_abort()

# --- pins ---------------------------------------------------------------------
# Open addressing (linear probing) over raw memory: the table must not live in
# the heap it roots, and its storage is invisible to the conservative scans
# (malloc'd), so only the root provider below makes pinned objects live.

const Tombstone = 1'u

proc pinHash(p: pointer): int {.inline.} =
  int((cast[uint](p) shr 3) * 0x9E3779B97F4A7C15'u shr 1)

proc pinFind(p: pointer): int =
  ## Slot of `p`, or -1.
  if gPinCap == 0: return -1
  var i = pinHash(p) and (gPinCap - 1)
  while true:
    let q = cast[uint](gPins[i].p)
    if q == 0'u: return -1
    if q == cast[uint](p): return i
    i = (i + 1) and (gPinCap - 1)

proc pinInsertRaw(p: pointer; count: int) =
  var i = pinHash(p) and (gPinCap - 1)
  while cast[uint](gPins[i].p) > Tombstone:
    i = (i + 1) and (gPinCap - 1)
  if cast[uint](gPins[i].p) == 0'u: inc gPinUsed
  gPins[i] = PinEntry(p: p, count: count)
  inc gPinCount

proc pinGrow() =
  let old = gPins
  let oldCap = gPinCap
  gPinCap = if oldCap == 0: 64 else: (if gPinCount * 4 >= oldCap: oldCap * 2 else: oldCap)
  gPins = cast[ptr UncheckedArray[PinEntry]](alloc0(gPinCap * sizeof(PinEntry)))
  if isNilP(cast[pointer](gPins)): fatal("aowlgc: out of memory (pin table)")
  gPinCount = 0
  gPinUsed = 0
  for i in 0 ..< oldCap:
    if cast[uint](old[i].p) > Tombstone: pinInsertRaw(old[i].p, old[i].count)
  if oldCap > 0: dealloc(cast[pointer](old))

proc pin(p: pointer) =
  let i = pinFind(p)
  if i >= 0:
    inc gPins[i].count
    return
  if (gPinUsed + 1) * 2 > gPinCap: pinGrow()
  pinInsertRaw(p, 1)

proc unpin(p: pointer) =
  let i = pinFind(p)
  if i < 0: return
  dec gPins[i].count
  if gPins[i].count <= 0:
    gPins[i] = PinEntry(p: cast[pointer](Tombstone), count: 0)
    dec gPinCount

proc visitPins(v: Visitor; data: pointer) {.cdecl.} =
  for i in 0 ..< gPinCap:
    let p = gPins[i].p
    if cast[uint](p) > Tombstone: v.visit(p)

proc traceFrame(v: Visitor; obj: pointer) {.cdecl.} =
  ## Coroutine frames: their layout is only known after hook lifting, so
  ## their contents are scanned conservatively.
  let n = objectSize(heapOfVisitor(v), obj)
  v.visitConservative(obj, cast[pointer](cast[uint](obj) + uint(n)))

# --- heap creation ------------------------------------------------------------

proc printStats() {.cdecl.} =
  let h = gHeap
  if isNilP(cast[pointer](h)): return
  let s = h.stats
  errLine("aowlgc: " & $s.collections & " collections, " & $s.allocations & " allocations, " &
    $s.freedObjects & " freed (" & $s.explicitFrees & " explicitly), " & $s.finalizersRun &
    " finalized, " & $s.liveObjects & " live objects / " & $s.liveBytes & " bytes at the last collection, " &
    "max pause " & $(s.maxPauseNs div 1000) & " us, total pause " & $(s.totalPauseNs div 1000_000) & " ms")

proc initHeap() {.noinline.} =
  var cfg = defaultConfig()
  cfg.cageBytes = int(envInt("AOWLGC_CAGE_MB", 16 * 1024)) * 1024 * 1024
  cfg.stressEvery = int(envInt("AOWLGC_STRESS", 0))
  let verify = envInt("AOWLGC_VERIFY", 0)
  cfg.verifyEachGc = verify >= 1
  cfg.verifyPayloads = verify >= 2
  let poison = envInt("AOWLGC_POISON", -1)
  if poison >= 0:
    cfg.poison = poison != 0
    cfg.quarantine = poison != 0
  cfg.onError = onHeapError
  cfg.onVerifyError = onVerifyError
  let h = newHeap(cfg)
  gFamRef = h.addFamily("nimony")
  gFamStore = h.addFamily("nimony.store")
  gFamFrame = h.addFamily("nimony.frame")
  gFrameTid = h.registerType(TypeDesc(name: "coroutine frame", family: gFamFrame, size: 8,
                                      trace: traceFrame))
  discard h.addImageRoots(addr gHeap)
  discard h.addRootProvider(visitPins, cast[pointer](0))
  gHeap = h
  if envInt("AOWLGC_STATS", 0) != 0 and not gStatsAtExit:
    gStatsAtExit = true
    discard c_atexit(printStats)

template heap(): Heap =
  (if isNilP(cast[pointer](gHeap)): initHeap(); gHeap)

proc registerSlot(slot: ptr int32; size: int; family: FamilyId; trace, fin: pointer): TypeId {.noinline.} =
  let h = heap()
  var tr: TraceProc = nil
  var fi: FinalizeProc = nil
  # nimony cannot cast a pointer to a proc: copy the bits
  if not isNilP(trace): copyMem(addr tr, addr trace, sizeof(pointer))
  if not isNilP(fin): copyMem(addr fi, addr fin, sizeof(pointer))
  inc gTypeNo
  result = h.registerType(TypeDesc(name: (if family == gFamStore: "seq store #" else: "ref type #") & $gTypeNo,
                                   family: family, size: size, trace: tr, finalize: fi))
  slot[] = int32(result)

# --- the entry points -----------------------------------------------------------

proc rtNew(slot: ptr int32; size: int; trace, fin: pointer): pointer {.exportc: "aowlgcNew", cdecl.} =
  var tid = TypeId(slot[])
  if tid == TypeId(0) or isNilP(cast[pointer](gHeap)):
    tid = TypeId(slot[])
    if isNilP(cast[pointer](gHeap)): initHeap()
    if tid == TypeId(0): tid = registerSlot(slot, size, gFamRef, trace, fin)
  result = alloc(gHeap, tid)

proc rtNewStore(slot: ptr int32; bytes: int; trace: AowlgcTracer; fin: AowlgcFinalizer): pointer {.exportc: "aowlgcNewStore", cdecl.} =
  # same C signature as system's importc declaration (one TU may see both)
  var tid = TypeId(slot[])
  if tid == TypeId(0) or isNilP(cast[pointer](gHeap)):
    if isNilP(cast[pointer](gHeap)): initHeap()
    tid = TypeId(slot[])
    if tid == TypeId(0):
      var tp = cast[pointer](0)
      var fp = cast[pointer](0)
      if trace != nil: copyMem(addr tp, addr trace, sizeof(pointer))
      if fin != nil: copyMem(addr fp, addr fin, sizeof(pointer))
      tid = registerSlot(slot, 8, gFamStore, tp, fp)
  result = allocSized(gHeap, tid, bytes)

proc rtMark(env, p: pointer) {.exportc: "aowlgcMark", cdecl.} =
  if inCage(gHeap, p): visit(cast[Visitor](env), p)

proc rtMayRelease(): bool {.exportc: "aowlgcMayRelease", cdecl.} =
  isNilP(cast[pointer](gHeap)) or gHeap.phase == hpIdle

proc rtFree(p: pointer) {.exportc: "aowlgcFree", cdecl.} =
  if not isNilP(cast[pointer](gHeap)): discard freeObject(gHeap, p)

proc rtUsableSize(p: pointer): int {.exportc: "aowlgcUsableSize", cdecl.} =
  objectSize(gHeap, p)

proc rtAllocPinned(size: int): pointer {.exportc: "aowlgcAllocPinned", cdecl.} =
  let h = heap()
  result = allocSized(h, gFrameTid, size)
  pin(result)

proc rtFreePinned(p: pointer) {.exportc: "aowlgcFreePinned", cdecl.} =
  if isNilP(p) or isNilP(cast[pointer](gHeap)): return
  unpin(p)
  discard freeObject(gHeap, p)

proc rtPin(p: pointer) {.exportc: "aowlgcPin", cdecl.} =
  if not isNilP(p): pin(p)

proc rtUnpin(p: pointer) {.exportc: "aowlgcUnpin", cdecl.} =
  if not isNilP(p): unpin(p)

proc rtIsLive(p: pointer): bool {.exportc: "aowlgcIsLive", cdecl.} =
  not isNilP(cast[pointer](gHeap)) and isLive(gHeap, p)

proc rtCollect() {.exportc: "aowlgcCollect", cdecl.} =
  let h = heap()
  collect(h, ssScan)
  completeSweep(h)

proc rtStat(which: int): int {.exportc: "aowlgcStat", cdecl.} =
  if isNilP(cast[pointer](gHeap)): return 0
  let s = gHeap.stats
  result = case which
    of 0: int(s.collections)
    of 1: int(s.allocations)
    of 2: int(s.freedObjects)
    of 3: int(s.finalizersRun)
    of 4: int(s.liveObjects)
    of 5: int(s.explicitFrees)
    of 6: int(s.maxPauseNs)
    of 7: int(s.totalPauseNs)
    else: 0

# Split DCE keeps only what nimony code references: anchor the entry points
# the generated C calls by name.
let gAnchors {.used.} = (rtNew, rtNewStore, rtMark, rtMayRelease, rtFree,
  rtUsableSize, rtAllocPinned, rtFreePinned, rtPin, rtUnpin,
  rtIsLive, rtCollect, rtStat)
