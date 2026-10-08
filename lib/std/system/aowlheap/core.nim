# VENDORED from the heap library (p2b @ bff58a4): src/heap/core.nim.
# Do not edit here; change the heap repo and run tools/sync_aowlheap.sh.
## The heap: cage, page table, type-family spaces, allocation, marking,
## weak processing, finalization, sweeping and the verifier.
##
## See README.md for the API contract and the invariants. In short:
## * one virtual range (the cage) per heap, carved into 256 KiB pages; a page
##   table (`descs`) and a mark bitmap (one bit per 16-byte granule) live in
##   separate side reservations, so object memory holds only objects;
## * every object = 8-byte header + payload. Pointers handed out and stored in
##   `Member`s point at the PAYLOAD; the header is at `p - 8`;
## * a page belongs to exactly one type family for its whole life (freed pages
##   go back to that family's pool), so a freed slot is only ever reused by an
##   object of the same family;
## * collection is stop-the-world mark (explicit worklist) + lazy sweep.

import osmem
export osmem.fatal

proc heapNowNs*(): int64 = osNowNs()
  ## Monotonic clock (ns), as used for the pause statistics.

const
  PageShift* = 18
  PageSize* = 1 shl PageShift            ## 256 KiB
  PageMask = PageSize - 1
  HeaderSize* = 8
  GranuleShift = 4                       ## mark bit granularity: 16 bytes
  MarkWords = (PageSize shr GranuleShift) div 64   ## 256 words = 2 KiB per page
  MaxFamilies* = 64
  MaxTypes* = 65536
  MaxSmallSlot* = 16384                  ## larger objects go to the large-object space
  NumClasses* = 36
  heapChecks* = not (defined(release) or defined(danger)) or defined(heapChecks)
    ## precise-edge validation while marking; poisoning is on by default too
  PoisonByte* = 0xDB'u8
  HeaderMagic = 0x5A'u64 shl 24
  HdrTypeMask = 0xFFFF'u64
  HdrEphKey = 1'u64 shl 16               ## object is a pending ephemeron key
  HdrMagicMask = 0xFF'u64 shl 24
  AllFamilies* = not 0'u64
  RingSize = 16                          ## marking prefetch distance

  SlotSizes: array[NumClasses, int] = [16, 32, 48, 64, 80, 96, 112, 128,
    160, 192, 224, 256, 320, 384, 448, 512, 640, 768, 896, 1024,
    1280, 1536, 1792, 2048, 2560, 3072, 3584, 4096, 5120, 6144, 7168, 8192,
    10240, 12288, 14336, 16384]

  pkUnused = 0'u8     # never handed out (above highWater)
  pkFree = 1'u8       # in its family's free-page pool
  pkNormal = 2'u8     # size-class page
  pkLargeHead = 3'u8  # first page of a large object
  pkLargeCont = 4'u8  # continuation page of a large object

  pfSwept = 1'u8      # liveness = header type id != 0 (else: = mark bit)
  pfZero = 2'u8       # (free page) contents known to be zero
  pfProtected = 4'u8  # (free page) PROT_NONE quarantine (debug)
  pfFinalizable = 8'u8 # (normal page) holds or held objects with a finalizer

type
  TypeId* = uint16
  FamilyId* = uint8

  HeapPhase* = enum
    hpIdle, hpMarking, hpWeak, hpPrefinalizing, hpVerifying, hpFinalizing, hpTearDown

  StackState* = enum
    ssScan,              ## the native stack may hold heap pointers: scan it
    ssNoHeapPointers     ## caller guarantees no raw heap pointer is on the stack

  VisitMode = enum
    vmMark, vmVerify

  HeapError* = enum
    heOutOfMemory,       ## the cage is exhausted even after a collection
    heAllocDuringGc,     ## allocation from a finalizer/prefinalizer/weak callback
    heCollectDuringGc,   ## collect() re-entered from a GC callback
    heBadType,           ## alloc with an unregistered type id
    heVerifyFailed       ## a verifier / marking check failed (`onVerifyError`)

  VisitorObj* = object
    heap*: Heap
    mode: VisitMode
    src: pointer         # object being traced (verify mode), 0 for roots
    srcFamily: int       # -1 for roots
    weakOk: bool

  Visitor* = ptr VisitorObj

  TraceProc* = nil proc (v: Visitor; obj: pointer) {.cdecl.}
    ## Must visit every heap pointer stored in `obj` (strong, weak, ephemeron).
  FinalizeProc* = nil proc (obj: pointer) {.cdecl.}
    ## Finalizer: runs during sweep. MUST NOT touch other GC objects, allocate,
    ## or store `obj` anywhere. Prefinalizers (same signature) run before any
    ## sweeping, may read other (even dead) objects, but must not allocate or
    ## make a dead object reachable.
  RootProc* = nil proc (v: Visitor; data: pointer) {.cdecl.}
  WeakSlotProc* = nil proc (data: pointer; slot: ptr pointer) {.cdecl.}
    ## Called (instead of clearing) when a weak slot's target died.
  WeakCallbackProc* = nil proc (h: Heap; data: pointer) {.cdecl.}
    ## Runs after marking; use `isMarked` to inspect liveness (WeakMap compaction).
  ErrorProc* = nil proc (h: Heap; e: HeapError; msg: cstring) {.cdecl.}
    ## If it returns, the failing allocation returns nil.

  TypeInfo* = object
    trace*: TraceProc
    finalize*: FinalizeProc
    prefinalize*: FinalizeProc
    size*: int                 ## default payload bytes
    space: ptr Space           ## size-class space for `size` (nil: large)
    family*: FamilyId
    used: bool
    nameOff, nameLen: int

  TypeDesc* = object
    name*: string
    family*: FamilyId
    size*: int
    trace*: TraceProc
    finalize*: FinalizeProc
    prefinalize*: FinalizeProc

  PageDesc = object
    kind, family, cls, flags: uint8
    cellSize: uint32
    recip: uint32              # ceil(2^32 / cellSize): slot = off * recip >> 32
    cellCount: uint32
    carved: uint32             # slots ever handed out (bump high water)
    liveCount: uint32          # marked slots (set when marking ends)
    objCount: uint32           # allocated slots (exact after a sweep + flush)
    freeCount: uint32
    next, prev: int32          # list links (unswept/avail/pool/large lists)
    headPage: int32            # large continuation: index of the head page
    nPages: int32              # large head: pages spanned
    freeHead: uint             # swept page's free list (header addresses)
    largeSize: int             # large head: payload bytes

  Space = object
    family: int
    cls: int
    cellSize: int
    freeList: uint             # header address; next link at header+8
    bump, limit: uint
    curPage: int32
    unswept: int32             # pages to sweep lazily
    avail: int32               # swept pages that still have free slots
    allocs: uint32             # allocations on curPage not yet added to its objCount

  Family = object
    used: bool
    allowed: uint64            # families this family's objects may point to
    pool: int32                # free pages owned by this family (doubly linked)
    poolCount: int
    pages: int                 # pages currently in use (normal + large)
    nameOff, nameLen: int
    spaces: array[NumClasses, Space]

  Buf*[T] = object
    data: ptr UncheckedArray[T]
    len*, cap: int

  WeakSlot = object
    slot: ptr pointer
    cb: WeakSlotProc
    data: pointer

  WeakCb = object
    cb: WeakCallbackProc
    data: pointer

  EphPair = object
    key, val: pointer
    next: int

  RootProv = object
    cb: RootProc
    data: pointer
    id: int
    live: bool

  PNode* = object
    obj*: pointer
    heap*: Heap
    nextFree: ptr PNode
    kind*: uint8               # 0 free, 1 strong, 2 weak

  PChunk = object
    next: ptr PChunk
    nodes: array[256, PNode]

  HeapConfig* = object
    cageBytes*: int            ## virtual reservation (multiple of PageSize)
    minBudget*: int            ## bytes allocated between collections, at least
    growth*: float             ## next budget = max(minBudget, live * (growth-1))
    autoCollect*: bool         ## collect from the allocation slow path
    conservativeStack*: bool   ## scan the native stack + registers
    stripNanBox*: bool         ## also try the low 48 bits of stack words
    stressEvery*: int          ## >0: collect every N allocations (gc-stress)
    verifyEachGc*: bool        ## run the verifier inside every collection
    verifyPayloads*: bool      ## verifier also scans payloads for dangling words
    poison*: bool              ## poison freed slots, check poison on reuse
    quarantine*: bool          ## PROT_NONE freed pages until reused
    retainFreePages*: int      ## committed free pages kept per family
    onError*: ErrorProc
    onVerifyError*: ErrorProc  ## called for every verifier / marking-check
                               ## message (nil: only recorded); may abort

  HeapStats* = object
    collections*: int64
    allocations*: int64
    bytesAllocated*: int64      ## cumulative, slot sizes
    liveBytes*: int64           ## marked bytes at the last collection
    liveObjects*: int64
    freedObjects*: int64
    freedBytes*: int64
    finalizersRun*: int64
    prefinalizersRun*: int64
    weakCleared*: int64
    ephemeronsWoken*: int64
    conservativeHits*: int64    ## last collection
    largeObjects*: int64        ## live large objects
    pagesInUse*: int64
    pagesFree*: int64
    committedBytes*: int64
    markNs*, sweepNs*: int64    ## cumulative
    lastPauseNs*, maxPauseNs*, totalPauseNs*: int64
    verifyErrors*: int64        ## cumulative errors found by the verifier
    explicitFrees*: int64       ## objects released with `freeObject`

  HeapObj* = object
    cage*: uint
    cageEnd*: uint
    cageBytes: int
    pageCount: int
    highWater: int             # pages [0, highWater) have been handed out
    descs: ptr UncheckedArray[PageDesc]
    marks: ptr UncheckedArray[uint64]
    types: ptr UncheckedArray[TypeInfo]
    typeCount: int
    families: ptr UncheckedArray[Family]
    familyCount: int
    names: Buf[char]
    classOf: array[MaxSmallSlot div 16 + 1, uint8]
    largeList: int32
    budget: int
    stressCount: int
    noGcDepth: int
    gcDue: bool
    phase*: HeapPhase
    config*: HeapConfig
    stackBase*: pointer
    visitor: VisitorObj
    work: Buf[pointer]
    ephPending: Buf[pointer]
    weakSlots: Buf[WeakSlot]
    weakCbs: Buf[WeakCb]
    ephPairs: Buf[EphPair]
    ephKeys: ptr UncheckedArray[uint]
    ephHeads: ptr UncheckedArray[int]
    ephCap, ephCount: int
    prefinal: Buf[pointer]
    providers: Buf[RootProv]
    nextProvId: int
    pchunks: ptr PChunk
    pfree: ptr PNode
    persistents: int
    markedBytes: int64
    markedObjects: int64
    consHits: int64
    stats*: HeapStats
    regSlot: int

  Heap* = ptr HeapObj

# ---------------------------------------------------------------------------
# small utilities

proc c_memset(p: pointer; v: cint; n: csize_t) {.importc: "memset", header: "<string.h>".}
proc fillMem(p: pointer; n: int; b: uint8) {.inline.} = c_memset(p, cint(b), csize_t(n))
proc prefetchRead(p: pointer) {.importc: "__builtin_prefetch", nodecl.}
proc popcount64(x: uint64): cint {.importc: "__builtin_popcountll", nodecl.}

template isNilP(p: pointer): bool = cast[uint](p) == 0'u
template toP(u: uint): pointer = cast[pointer](u)
template toU(p: pointer): uint = cast[uint](p)
template hdrWord(hdr: uint): ptr uint64 = cast[ptr uint64](hdr)

proc grow[T](b: var Buf[T]) {.noinline.} =
  let nc = if b.cap < 64: 64 else: b.cap * 2
  let p = realloc(cast[pointer](b.data), nc * sizeof(T))
  if isNilP(p): fatal("heap: out of memory growing an internal buffer")
  b.data = cast[ptr UncheckedArray[T]](p)
  b.cap = nc

proc push*[T](b: var Buf[T]; x: T) {.inline.} =
  if b.len == b.cap: grow(b)
  b.data[b.len] = x
  inc b.len

proc pop*[T](b: var Buf[T]): T {.inline.} =
  dec b.len
  result = b.data[b.len]

proc `[]`*[T](b: Buf[T]; i: int): T {.inline.} = b.data[i]
proc at[T](b: var Buf[T]; i: int): ptr T {.inline.} = addr b.data[i]
proc setAt[T](b: var Buf[T]; i: int; x: T) {.inline.} = b.data[i] = x
proc clear[T](b: var Buf[T]) {.inline.} = b.len = 0
proc release[T](b: var Buf[T]) =
  if not isNilP(cast[pointer](b.data)): dealloc(cast[pointer](b.data))
  b.data = cast[ptr UncheckedArray[T]](0)
  b.len = 0
  b.cap = 0

proc hex*(u: uint): string =
  const digits = "0123456789abcdef"
  result = "0x"
  var started = false
  for i in countdown(15, 0):
    let d = int((u shr (uint(i) * 4'u)) and 15'u)
    if d != 0 or started or i == 0:
      started = true
      result.add digits[d]

proc storeName(h: Heap; s: string): (int, int) =
  let off = h.names.len
  for c in s: h.names.push(c)
  result = (off, s.len)

proc loadName(h: Heap; off, len: int): string =
  result = ""
  for i in 0 ..< len: result.add h.names[off + i]

# ---------------------------------------------------------------------------
# global registry (for the write barrier slow path, which only has a pointer)

var gHeaps: array[64, uint]
var heapIncrementalMarking*: bool = false
  ## Global fast-path flag of the write barrier. False until incremental
  ## marking exists (P7); then set while any heap is marking incrementally.

proc heapOf*(p: pointer): Heap =
  ## The registered heap whose cage contains `p`, or nil.
  let u = toU(p)
  for i in 0 ..< gHeaps.len:
    let hu = gHeaps[i]
    if hu != 0'u:
      let h = cast[Heap](hu)
      if u - h.cage < uint(h.cageBytes): return h
  result = cast[Heap](0)

# ---------------------------------------------------------------------------
# page table helpers

template desc(h: Heap; pi: int): ptr PageDesc = addr h.descs[pi]
template pageBase(h: Heap; pi: int): uint = h.cage + (uint(pi) shl PageShift)
template pageOf(h: Heap; a: uint): int = int((a - h.cage) shr PageShift)

template markWordOf(h: Heap; hdr: uint): ptr uint64 =
  let rel = hdr - h.cage
  addr h.marks[int(rel shr PageShift) * MarkWords + int((rel and uint(PageMask)) shr (GranuleShift + 6))]
template markBitOf(hdr: uint): uint64 =
  1'u64 shl ((hdr shr GranuleShift) and 63'u)

proc isMarkedHdr(h: Heap; hdr: uint): bool {.inline.} =
  (markWordOf(h, hdr)[] and markBitOf(hdr)) != 0'u64

proc testAndMark(h: Heap; hdr: uint): bool {.inline.} =
  let w = markWordOf(h, hdr)
  let b = markBitOf(hdr)
  if (w[] and b) != 0'u64: return false
  w[] = w[] or b
  result = true

proc clearMarks(h: Heap; pi: int) {.inline.} =
  zeroMem(addr h.marks[pi * MarkWords], MarkWords * 8)

proc listPush(h: Heap; head: ptr int32; pi: int) =
  let d = desc(h, pi)
  d.prev = -1
  d.next = head[]
  if head[] >= 0: desc(h, int(head[])).prev = int32(pi)
  head[] = int32(pi)

proc listRemove(h: Heap; head: ptr int32; pi: int) =
  let d = desc(h, pi)
  if d.prev >= 0: desc(h, int(d.prev)).next = d.next
  else: head[] = d.next
  if d.next >= 0: desc(h, int(d.next)).prev = d.prev
  d.next = -1
  d.prev = -1

proc listPop(h: Heap; head: ptr int32): int =
  result = int(head[])
  if result >= 0: listRemove(h, head, result)

# ---------------------------------------------------------------------------
# object resolution

type
  Resolve* = enum
    rsNotInCage, rsFreePage, rsFreeSlot, rsDead, rsLive

proc resolve(h: Heap; a: uint; hdrOut: var uint): Resolve =
  ## Map any address to the object containing it (interior pointers included).
  hdrOut = 0'u
  let rel = a - h.cage
  if rel >= uint(h.highWater) shl PageShift: return rsNotInCage
  let pi = int(rel shr PageShift)
  let d = desc(h, pi)
  case d.kind
  of pkNormal:
    let off = rel and uint(PageMask)
    let slot = (uint64(off) * uint64(d.recip)) shr 32
    if slot >= uint64(d.carved): return rsFreeSlot
    let hdr = pageBase(h, pi) + uint(slot) * uint(d.cellSize)
    hdrOut = hdr
    if (hdrWord(hdr)[] and HdrTypeMask) == 0'u64: return rsFreeSlot
    if (d.flags and pfSwept) == 0'u8 and not isMarkedHdr(h, hdr): return rsDead
    result = rsLive
  of pkLargeHead, pkLargeCont:
    let head = if d.kind == pkLargeHead: pi else: int(d.headPage)
    let hd = desc(h, head)
    let hdr = pageBase(h, head)
    if a >= hdr + uint(HeaderSize + hd.largeSize): return rsFreeSlot
    hdrOut = hdr
    if (hdrWord(hdr)[] and HdrTypeMask) == 0'u64: return rsFreeSlot
    if (hd.flags and pfSwept) == 0'u8 and not isMarkedHdr(h, hdr): return rsDead
    result = rsLive
  else:
    result = rsFreePage

proc slotBytes(h: Heap; hdr: uint): int =
  let d = desc(h, pageOf(h, hdr))
  if d.kind == pkNormal: int(d.cellSize) else: HeaderSize + d.largeSize

# ---------------------------------------------------------------------------
# errors

# The message log is deliberately not a `seq[string]`: the heap must not
# allocate through the memory manager it may itself implement (nimony's
# `-d:aowlgc` mode puts seq buffers in this very heap, and messages are noted
# while marking, when allocating from the heap is refused). Messages are
# appended to one raw `Buf[char]`, NUL-separated, and only turned into a seq
# by `verifyHeap`, outside any collection.
var gMsgText: Buf[char]
var gMsgCount = 0
const MaxMessages = 64

proc note(h: Heap; msg: string) =
  inc h.stats.verifyErrors
  if gMsgCount < MaxMessages:
    for c in msg: gMsgText.push(c)
    gMsgText.push('\0')
    inc gMsgCount
  if h.config.onVerifyError != nil:
    var m = msg
    h.config.onVerifyError(h, heVerifyFailed, toCString(m))

proc clearMessages() =
  gMsgText.clear()
  gMsgCount = 0

proc heapMessages*(): seq[string] =
  ## The verifier / marking-check messages noted since the last verification
  ## (capped at 64). Allocates: never call it from a GC callback.
  result = @[]
  var cur = ""
  for i in 0 ..< gMsgText.len:
    let c = gMsgText[i]
    if c == '\0':
      result.add cur
      cur = ""
    else: cur.add c

proc raiseError(h: Heap; e: HeapError; msg: string) =
  if h.config.onError != nil:
    var m = msg
    h.config.onError(h, e, toCString(m))
  else:
    fatal(msg)

proc typeName*(h: Heap; tid: TypeId): string =
  if int(tid) < h.typeCount and h.types[int(tid)].used:
    loadName(h, h.types[int(tid)].nameOff, h.types[int(tid)].nameLen)
  else: "<type " & $int(tid) & ">"

proc familyName*(h: Heap; f: FamilyId): string =
  if int(f) < h.familyCount: loadName(h, h.families[int(f)].nameOff, h.families[int(f)].nameLen)
  else: "<family " & $int(f) & ">"

# ---------------------------------------------------------------------------
# heap creation

proc defaultConfig*(): HeapConfig =
  HeapConfig(cageBytes: 16 * 1024 * 1024 * 1024, minBudget: 4 * 1024 * 1024,
             growth: 2.0, autoCollect: true, conservativeStack: true,
             stripNanBox: false, stressEvery: 0, verifyEachGc: false,
             verifyPayloads: false, poison: heapChecks, quarantine: heapChecks,
             retainFreePages: 32, onError: nil, onVerifyError: nil)

proc newHeap*(config: HeapConfig): Heap =
  ## Reserve a cage and set up the side tables. The calling thread owns the
  ## heap; its stack is the one scanned conservatively.
  var cfg = config
  if cfg.cageBytes < PageSize * 16: cfg.cageBytes = PageSize * 16
  cfg.cageBytes = (cfg.cageBytes + PageMask) and not PageMask
  let h = cast[Heap](alloc0(sizeof(HeapObj)))
  if isNilP(h): fatal("heap: cannot allocate heap object")
  h.config = cfg
  h.cageBytes = cfg.cageBytes
  h.pageCount = cfg.cageBytes shr PageShift
  let cage = osReserve(cfg.cageBytes, PageSize)
  if isNilP(cage): fatal("heap: cannot reserve the cage")
  h.cage = toU(cage)
  h.cageEnd = h.cage + uint(cfg.cageBytes)
  h.descs = cast[ptr UncheckedArray[PageDesc]](osReserveRW(h.pageCount * sizeof(PageDesc)))
  h.marks = cast[ptr UncheckedArray[uint64]](osReserveRW(h.pageCount * MarkWords * 8))
  h.types = cast[ptr UncheckedArray[TypeInfo]](osReserveRW(MaxTypes * sizeof(TypeInfo)))
  h.families = cast[ptr UncheckedArray[Family]](osReserveRW(MaxFamilies * sizeof(Family)))
  if isNilP(h.descs) or isNilP(h.marks) or isNilP(h.types) or isNilP(h.families):
    fatal("heap: cannot reserve side tables")
  h.typeCount = 1                      # type id 0 = free slot
  h.largeList = -1
  h.budget = if cfg.stressEvery > 0: 0 else: cfg.minBudget
  h.stackBase = osStackBase()
  h.phase = hpIdle
  h.visitor = VisitorObj(heap: h, mode: vmMark, src: cast[pointer](0), srcFamily: -1, weakOk: false)
  # size -> class table (by 16-byte units)
  var c = 0
  for u in 0 .. MaxSmallSlot div 16:
    while SlotSizes[c] < u * 16: inc c
    h.classOf[u] = uint8(c)
  h.regSlot = -1
  for i in 0 ..< gHeaps.len:
    if gHeaps[i] == 0'u:
      gHeaps[i] = toU(h)
      h.regSlot = i
      break
  result = h

proc newHeap*(): Heap = newHeap(defaultConfig())

proc setStackBase*(h: Heap; base: pointer) =
  ## Override the detected stack base (embedders that run the mutator on a
  ## different stack, e.g. a fiber).
  h.stackBase = base

# ---------------------------------------------------------------------------
# families and types

proc addFamily*(h: Heap; name: string; allowedTargets = AllFamilies): FamilyId =
  ## A type family owns its pages forever: freed slots and pages are reused
  ## only by objects of the same family (type isolation).
  if h.familyCount >= MaxFamilies: fatal("heap: too many families")
  let f = h.familyCount
  inc h.familyCount
  let fam = addr h.families[f]
  fam.used = true
  fam.allowed = allowedTargets
  fam.pool = -1
  let (o, l) = storeName(h, name)
  fam.nameOff = o
  fam.nameLen = l
  for c in 0 ..< NumClasses:
    fam.spaces[c] = Space(family: f, cls: c, cellSize: SlotSizes[c], freeList: 0'u,
                          bump: 0'u, limit: 0'u, curPage: -1, unswept: -1, avail: -1)
  result = FamilyId(f)

proc setAllowedTargets*(h: Heap; f: FamilyId; mask: uint64) =
  ## Families whose objects `f`'s objects may reference (checked by the verifier).
  h.families[int(f)].allowed = mask

proc familyBit*(f: FamilyId): uint64 {.inline.} = 1'u64 shl uint64(f)

proc classFor(h: Heap; payload: int): int {.inline.} =
  ## Size class for a payload, -1 if large.
  let total = payload + HeaderSize
  if total > MaxSmallSlot: return -1
  result = int(h.classOf[(total + 15) shr 4])

proc registerType*(h: Heap; d: TypeDesc): TypeId =
  if h.typeCount >= MaxTypes: fatal("heap: too many types")
  if int(d.family) >= h.familyCount: fatal("heap: registerType with an unknown family")
  let t = h.typeCount
  inc h.typeCount
  let ti = addr h.types[t]
  ti.trace = d.trace
  ti.finalize = d.finalize
  ti.prefinalize = d.prefinalize
  ti.size = if d.size < 8: 8 else: d.size     # free slots need a link word
  ti.family = d.family
  ti.used = true
  let (o, l) = storeName(h, d.name)
  ti.nameOff = o
  ti.nameLen = l
  let c = classFor(h, ti.size)
  ti.space = if c < 0: cast[ptr Space](0) else: addr h.families[int(d.family)].spaces[c]
  result = TypeId(t)

proc registerType*(h: Heap; name: string; family: FamilyId; size: int;
                   trace: TraceProc = nil; finalize: FinalizeProc = nil;
                   prefinalize: FinalizeProc = nil): TypeId =
  registerType(h, TypeDesc(name: name, family: family, size: size, trace: trace,
                           finalize: finalize, prefinalize: prefinalize))

proc typeInfo*(h: Heap; tid: TypeId): ptr TypeInfo {.inline.} = addr h.types[int(tid)]
proc numTypes*(h: Heap): int = h.typeCount

# ---------------------------------------------------------------------------
# header access (p = payload pointer)

proc typeIdOf*(p: pointer): TypeId {.inline.} =
  TypeId(cast[ptr uint64](toU(p) - 8'u)[] and HdrTypeMask)

proc headerUser*(p: pointer): uint32 {.inline.} =
  ## 32 bits of the header that belong to the embedder (e.g. a JS class id).
  uint32(cast[ptr uint64](toU(p) - 8'u)[] shr 32)

proc setHeaderUser*(p: pointer; v: uint32) {.inline.} =
  let w = cast[ptr uint64](toU(p) - 8'u)
  w[] = (w[] and 0xFFFF_FFFF'u64) or (uint64(v) shl 32)

proc cageBase*(h: Heap): uint {.inline.} = h.cage
  ## Base of the cage. For a family whose objects all use one slot size 2^k
  ## (e.g. 128-byte JS cells), `(p - 8 - cageBase) shr k` is a dense,
  ## stable 32-bit index of the object and `cageBase + idx shl k + 8` maps back.

template slotIndex*(h: Heap; p: pointer; shift: int): uint =
  (cast[uint](p) - 8'u - h.cage) shr uint(shift)
template fromSlotIndex*(h: Heap; idx: uint; shift: int): pointer =
  cast[pointer](h.cage + (idx shl uint(shift)) + 8'u)

proc inCage*(h: Heap; p: pointer): bool {.inline.} = toU(p) - h.cage < uint(h.cageBytes)

# ---------------------------------------------------------------------------
# page supply

proc commitPages(h: Heap; pi, n: int) =
  if osCommit(toP(pageBase(h, pi)), n * PageSize) != 0:
    fatal("heap: commit failed")

proc freshPages(h: Heap; n: int): int =
  ## Pages from the never-used top of the cage; -1 if the cage is full.
  if h.highWater + n > h.pageCount: return -1
  result = h.highWater
  h.highWater += n
  commitPages(h, result, n)
  h.stats.committedBytes += int64(n * PageSize)
  for i in result ..< result + n:
    let d = desc(h, i)
    d.flags = pfZero
    d.next = -1
    d.prev = -1

proc prepareReuse(h: Heap; pi, n: int) =
  ## A page from a family pool is about to hold objects again. Normal pages
  ## need no zeroing (slots past `carved` are never read; alloc zeroes each
  ## payload); `pfZero` survives so large objects can skip zeroing.
  for i in pi ..< pi + n:
    let d = desc(h, i)
    if (d.flags and pfProtected) != 0'u8:
      commitPages(h, i, 1)
      h.stats.committedBytes += PageSize
      d.flags = pfZero
    else:
      d.flags = d.flags and pfZero

proc releasePage(h: Heap; pi: int) =
  ## Return a page to its family's pool (type isolation: never to another family).
  let d = desc(h, pi)
  let fam = addr h.families[int(d.family)]
  d.kind = pkFree
  d.flags = 0'u8
  d.freeHead = 0'u
  d.liveCount = 0
  d.objCount = 0
  d.carved = 0
  if h.config.quarantine:
    discard osDiscard(toP(pageBase(h, pi)), PageSize)
    discard osProtectNone(toP(pageBase(h, pi)), PageSize)
    d.flags = pfProtected
    h.stats.committedBytes -= PageSize
  listPush(h, addr fam.pool, pi)
  inc fam.poolCount
  dec fam.pages

proc trimPools(h: Heap) =
  ## Keep at most max(`retainFreePages`, budget pages) committed free pages per
  ## family (they will be allocated again before the next collection); give
  ## the rest of the physical memory back (the range stays with the family).
  let keep = max(h.config.retainFreePages, h.budget div PageSize)
  for f in 0 ..< h.familyCount:
    let fam = addr h.families[f]
    var kept = 0
    var pi = int(fam.pool)
    while pi >= 0:
      let d = desc(h, pi)
      if (d.flags and (pfProtected or pfZero)) == 0'u8:
        if kept < keep: inc kept
        else:
          discard osDiscard(toP(pageBase(h, pi)), PageSize)
          d.flags = pfZero
      pi = int(d.next)

proc takeFamilyPages(h: Heap; f, n: int): int =
  ## n contiguous pages for family f: from its pool, else fresh. -1 if none.
  let fam = addr h.families[f]
  if n == 1:
    let pi = listPop(h, addr fam.pool)
    if pi >= 0:
      dec fam.poolCount
      prepareReuse(h, pi, 1)
      inc fam.pages
      return pi
  elif fam.poolCount >= n:
    var run = 0
    var i = 0
    while i < h.highWater:
      let d = desc(h, i)
      if d.kind == pkFree and int(d.family) == f:
        inc run
        if run == n:
          let start = i - n + 1
          for k in start .. i:
            listRemove(h, addr fam.pool, k)
          fam.poolCount -= n
          prepareReuse(h, start, n)
          fam.pages += n
          return start
      else: run = 0
      inc i
  result = freshPages(h, n)
  if result >= 0:
    for i in result ..< result + n:
      desc(h, i).family = uint8(f)
    fam.pages += n

proc initNormalPage(h: Heap; pi: int; sp: ptr Space) =
  let d = desc(h, pi)
  d.kind = pkNormal
  d.family = uint8(sp.family)
  d.cls = uint8(sp.cls)
  d.flags = pfSwept
  d.cellSize = uint32(sp.cellSize)
  d.recip = uint32(((1'u64 shl 32) + uint64(sp.cellSize) - 1'u64) div uint64(sp.cellSize))
  d.cellCount = uint32(PageSize div sp.cellSize)
  d.carved = 0
  d.liveCount = 0
  d.objCount = 0
  d.freeCount = 0
  d.freeHead = 0'u
  clearMarks(h, pi)

proc retireCur(h: Heap; sp: ptr Space) {.inline.} =
  ## The allocation page is being left: record how far its bump got.
  if sp.curPage >= 0:
    let d = desc(h, int(sp.curPage))
    let n = uint32((sp.bump - pageBase(h, int(sp.curPage))) div uint(sp.cellSize))
    if n > d.carved: d.carved = n
    d.objCount += sp.allocs
    sp.allocs = 0
    sp.curPage = -1

proc adopt(h: Heap; sp: ptr Space; pi: int) =
  ## Make page pi the space's allocation page.
  retireCur(h, sp)
  let d = desc(h, pi)
  let base = pageBase(h, pi)
  sp.curPage = int32(pi)
  sp.freeList = d.freeHead
  d.freeHead = 0'u
  d.freeCount = 0
  sp.bump = base + uint(d.carved) * uint(d.cellSize)
  sp.limit = base + uint(d.cellCount) * uint(d.cellSize)

proc syncCarved(h: Heap) =
  ## Record how far the bump pointer of every allocation page got.
  for f in 0 ..< h.familyCount:
    let fam = addr h.families[f]
    for c in 0 ..< NumClasses:
      let sp = addr fam.spaces[c]
      if sp.curPage >= 0:
        let d = desc(h, int(sp.curPage))
        let n = uint32((sp.bump - pageBase(h, int(sp.curPage))) div uint(sp.cellSize))
        if n > d.carved: d.carved = n
        d.objCount += sp.allocs
        sp.allocs = 0

# ---------------------------------------------------------------------------
# sweeping

proc poisonOk(hdr: uint; cell: int): bool =
  let b = cast[ptr UncheckedArray[uint8]](hdr)
  for i in 16 ..< cell:
    if b[i] != PoisonByte: return false
  result = true

proc sweepPage(h: Heap; pi: int) =
  ## Build the free list of a normal page from its mark bits, finalizing the
  ## dead. Liveness is the mark bit; afterwards the page is "swept".
  let d = desc(h, pi)
  let base = pageBase(h, pi)
  let cell = int(d.cellSize)
  if not h.config.poison:
    # O(1) cases, decided by the popcount taken when marking ended:
    if d.liveCount == 0'u32 and (d.flags and pfFinalizable) == 0'u8:
      # nothing survived, nothing to finalize: the page is empty as is
      h.stats.freedObjects += int64(d.objCount)
      h.stats.freedBytes += int64(d.objCount) * int64(cell)
      d.carved = 0
      d.objCount = 0
      d.freeHead = 0'u
      d.freeCount = 0
      d.flags = d.flags or pfSwept
      return
    if d.liveCount == d.carved:
      # every carved slot survived: no free slot, nothing died
      d.objCount = d.liveCount
      d.freeHead = 0'u
      d.freeCount = 0
      d.flags = d.flags or pfSwept
      return
  var head = 0'u
  var live = 0
  var free = 0
  var i = int(d.carved) - 1
  while i >= 0:
    let hdr = base + uint(i * cell)
    let hw = hdrWord(hdr)[]
    let tid = int(hw and HdrTypeMask)
    var isFree = true
    if tid != 0:
      if isMarkedHdr(h, hdr):
        inc live
        isFree = false
      else:
        let ti = addr h.types[tid]
        if ti.finalize != nil:
          let saved = h.phase
          h.phase = hpFinalizing
          ti.finalize(toP(hdr + 8'u))
          h.phase = saved
          inc h.stats.finalizersRun
        inc h.stats.freedObjects
        h.stats.freedBytes += int64(cell)
        if h.config.poison: fillMem(toP(hdr + 8'u), cell - 8, PoisonByte)
        hdrWord(hdr)[] = 0'u64
    if isFree:
      cast[ptr uint](hdr + 8'u)[] = head
      head = hdr
      inc free
    dec i
  d.freeHead = head
  d.freeCount = uint32(free)
  d.liveCount = uint32(live)
  d.objCount = uint32(live)
  d.flags = d.flags or pfSwept

proc sweepNextInto(h: Heap; sp: ptr Space): bool =
  ## Lazily sweep this space's pages until one with free slots is adopted.
  while true:
    var pi = listPop(h, addr sp.avail)
    if pi >= 0:
      adopt(h, sp, pi)
      return true
    pi = listPop(h, addr sp.unswept)
    if pi < 0: return false
    let t0 = osNowNs()
    sweepPage(h, pi)
    h.stats.sweepNs += osNowNs() - t0
    let d = desc(h, pi)
    if d.freeCount > 0'u32 or d.carved < d.cellCount:
      adopt(h, sp, pi)
      return true

proc completeSweep*(h: Heap) =
  ## Sweep everything still pending (runs all pending finalizers). Fully empty
  ## pages go back to their family's pool.
  let t0 = osNowNs()
  for f in 0 ..< h.familyCount:
    let fam = addr h.families[f]
    for c in 0 ..< NumClasses:
      let sp = addr fam.spaces[c]
      while true:
        let pi = listPop(h, addr sp.unswept)
        if pi < 0: break
        sweepPage(h, pi)
        let d = desc(h, pi)
        if d.liveCount == 0'u32 and pi != int(sp.curPage):
          releasePage(h, pi)
        elif d.freeCount > 0'u32:
          listPush(h, addr sp.avail, pi)
  trimPools(h)
  h.stats.sweepNs += osNowNs() - t0

proc sweepLarge(h: Heap) =
  var pi = int(h.largeList)
  var live = 0
  while pi >= 0:
    let d = desc(h, pi)
    let nxt = int(d.next)
    let hdr = pageBase(h, pi)
    if isMarkedHdr(h, hdr):
      inc live
      d.flags = d.flags or pfSwept
    else:
      let tid = int(hdrWord(hdr)[] and HdrTypeMask)
      let ti = addr h.types[tid]
      if ti.finalize != nil:
        let saved = h.phase
        h.phase = hpFinalizing
        ti.finalize(toP(hdr + 8'u))
        h.phase = saved
        inc h.stats.finalizersRun
      inc h.stats.freedObjects
      h.stats.freedBytes += int64(HeaderSize + d.largeSize)
      listRemove(h, addr h.largeList, pi)
      let n = int(d.nPages)
      for k in pi ..< pi + n:
        discard osDiscard(toP(pageBase(h, k)), PageSize)
        let dk = desc(h, k)
        dk.headPage = -1
        dk.nPages = 0
        dk.largeSize = 0
        releasePage(h, k)
        if (desc(h, k).flags and pfProtected) == 0'u8: desc(h, k).flags = pfZero
    pi = nxt
  h.stats.largeObjects = int64(live)

# ---------------------------------------------------------------------------
# allocation

proc collect*(h: Heap; stack = ssScan)

proc takeSlot(sp: ptr Space): uint {.inline.} =
  result = sp.freeList
  if result != 0'u:
    sp.freeList = cast[ptr uint](result + 8'u)[]
  elif sp.bump + uint(sp.cellSize) <= sp.limit:
    result = sp.bump
    sp.bump += uint(sp.cellSize)

proc finishAlloc(h: Heap; tid: TypeId; hdr: uint; cell: int): pointer {.inline.} =
  when heapChecks:
    if h.config.poison and cell > 16 and (hdrWord(hdr)[] and HdrMagicMask) == 0'u64 and
        cast[ptr UncheckedArray[uint8]](hdr)[16] == PoisonByte and not poisonOk(hdr, cell):
      note(h, "write after free detected in a " & $cell & "-byte slot at " & hex(hdr + 8'u))
  if cell <= 256:
    let w = cast[ptr UncheckedArray[uint64]](hdr)
    for i in 1 ..< (cell shr 3): w[i] = 0'u64
  else:
    zeroMem(toP(hdr + 8'u), cell - 8)
  hdrWord(hdr)[] = uint64(tid) or HeaderMagic
  inc h.stats.allocations
  h.stats.bytesAllocated += int64(cell)
  result = toP(hdr + 8'u)
  let ti = addr h.types[int(tid)]
  if ti.finalize != nil:
    let d = desc(h, pageOf(h, hdr))
    d.flags = d.flags or pfFinalizable
  if ti.prefinalize != nil:
    h.prefinal.push(result)

proc allocLarge(h: Heap; tid: TypeId; payload: int): pointer {.noinline.}

proc allocSlow(h: Heap; tid: TypeId; sp: ptr Space): pointer {.noinline.} =
  if h.phase != hpIdle:
    raiseError(h, heAllocDuringGc, "heap: allocation during " & $h.phase)
    return cast[pointer](0)
  let cell = sp.cellSize
  if h.config.stressEvery > 0:
    inc h.stressCount
    if h.stressCount >= h.config.stressEvery and h.noGcDepth == 0:
      h.stressCount = 0
      collect(h, ssScan)
    h.budget = 0
  elif h.budget < cell and h.config.autoCollect:
    if h.noGcDepth == 0:
      h.gcDue = false
      collect(h, ssScan)
    else:
      # collection is due but forbidden: keep allocating on the fast path
      h.gcDue = true
      h.budget = h.config.minBudget
  var hdr = takeSlot(sp)
  if hdr == 0'u:
    if not sweepNextInto(h, sp):
      let pi = takeFamilyPages(h, sp.family, 1)
      if pi >= 0:
        initNormalPage(h, pi, sp)
        adopt(h, sp, pi)
      elif h.noGcDepth == 0 and h.phase == hpIdle:
        collect(h, ssScan)
        completeSweep(h)
        if not sweepNextInto(h, sp):
          let pj = takeFamilyPages(h, sp.family, 1)
          if pj >= 0:
            initNormalPage(h, pj, sp)
            adopt(h, sp, pj)
    hdr = takeSlot(sp)
    if hdr == 0'u:
      raiseError(h, heOutOfMemory, "heap: out of memory (cage exhausted)")
      return cast[pointer](0)
  h.budget -= cell
  inc sp.allocs
  result = finishAlloc(h, tid, hdr, cell)

proc allocIn(h: Heap; tid: TypeId; sp: ptr Space): pointer {.inline.} =
  let cell = sp.cellSize
  if h.budget >= cell:
    let hdr = takeSlot(sp)
    if hdr != 0'u:
      h.budget -= cell
      inc sp.allocs
      return finishAlloc(h, tid, hdr, cell)
  result = allocSlow(h, tid, sp)

proc alloc*(h: Heap; tid: TypeId): pointer {.inline.} =
  ## Allocate a zeroed object of the type's registered size. Returns the
  ## payload pointer. May collect (the native stack is scanned conservatively).
  let sp = h.types[int(tid)].space
  if isNilP(sp):
    if int(tid) == 0 or int(tid) >= h.typeCount:
      raiseError(h, heBadType, "heap: alloc with unregistered type id " & $int(tid))
      return cast[pointer](0)
    return allocLarge(h, tid, h.types[int(tid)].size)
  result = allocIn(h, tid, sp)

proc allocSized*(h: Heap; tid: TypeId; payload: int): pointer =
  ## Allocate `payload` bytes (variable-size objects: backing stores, strings).
  ## The type's trace must derive the length from the object itself.
  if int(tid) == 0 or int(tid) >= h.typeCount:
    raiseError(h, heBadType, "heap: allocSized with unregistered type id " & $int(tid))
    return cast[pointer](0)
  let c = classFor(h, if payload < 8: 8 else: payload)
  if c < 0: return allocLarge(h, tid, payload)
  result = allocIn(h, tid, addr h.families[int(h.types[int(tid)].family)].spaces[c])

proc allocLarge(h: Heap; tid: TypeId; payload: int): pointer =
  if h.phase != hpIdle:
    raiseError(h, heAllocDuringGc, "heap: allocation during " & $h.phase)
    return cast[pointer](0)
  if int(tid) == 0 or int(tid) >= h.typeCount:
    raiseError(h, heBadType, "heap: alloc with unregistered type id " & $int(tid))
    return cast[pointer](0)
  let n = (payload + HeaderSize + PageMask) shr PageShift
  let bytes = n * PageSize
  if h.config.stressEvery > 0:
    inc h.stressCount
    if h.stressCount >= h.config.stressEvery and h.noGcDepth == 0:
      h.stressCount = 0
      collect(h, ssScan)
    h.budget = 0
  elif h.budget < bytes and h.noGcDepth == 0 and h.config.autoCollect:
    collect(h, ssScan)
  let f = int(h.types[int(tid)].family)
  var pi = takeFamilyPages(h, f, n)
  if pi < 0 and h.noGcDepth == 0:
    collect(h, ssScan)
    completeSweep(h)
    pi = takeFamilyPages(h, f, n)
  if pi < 0:
    raiseError(h, heOutOfMemory, "heap: out of memory (large object of " & $payload & " bytes)")
    return cast[pointer](0)
  for k in pi ..< pi + n:
    let d = desc(h, k)
    if (d.flags and pfZero) == 0'u8:
      # recycled page: zero the part the object covers (header + payload)
      let lo = pageBase(h, k)
      let objEnd = pageBase(h, pi) + uint(HeaderSize + payload)
      let hi = if objEnd < lo + uint(PageSize): objEnd else: lo + uint(PageSize)
      zeroMem(toP(lo), int(hi - lo))
    d.kind = pkLargeCont
    d.family = uint8(f)
    d.headPage = int32(pi)
    d.flags = pfSwept
  let d = desc(h, pi)
  d.kind = pkLargeHead
  d.nPages = int32(n)
  d.largeSize = payload
  d.headPage = int32(pi)
  clearMarks(h, pi)
  listPush(h, addr h.largeList, pi)
  let hdr = pageBase(h, pi)
  hdrWord(hdr)[] = uint64(tid) or HeaderMagic
  h.budget -= bytes
  inc h.stats.allocations
  h.stats.bytesAllocated += int64(bytes)
  result = toP(hdr + 8'u)
  if h.types[int(tid)].prefinalize != nil:
    h.prefinal.push(result)

proc objectSize*(h: Heap; p: pointer): int =
  ## Usable payload bytes of the object at `p` (>= the requested size).
  let d = desc(h, pageOf(h, toU(p)))
  if d.kind == pkNormal: int(d.cellSize) - HeaderSize else: desc(h, int(d.headPage)).largeSize

proc freeObject*(h: Heap; p: pointer): bool =
  ## Explicitly release the object at `p` NOW, without running its finalizer
  ## or prefinalizer: for memory with exactly one owner that knows it is done
  ## with it (a seq's backing store on reallocation or destruction). The slot
  ## is reusable immediately (a large object's pages go back to the family).
  ## The caller guarantees no other reference to it exists; a precise edge to
  ## a freed object is reported by the marking checks and the verifier like
  ## any dangling edge. Only allowed while the heap is idle (not from a
  ## finalizer or another GC callback): returns false and does nothing then,
  ## or when `p` is nil / not a live object start of this heap. Objects with
  ## a prefinalizer cannot be freed explicitly (false).
  if h.phase != hpIdle or isNilP(p) or not inCage(h, p): return false
  syncCarved(h)
  var hdr = 0'u
  if resolve(h, toU(p), hdr) != rsLive or hdr + 8'u != toU(p): return false
  let tid = int(hdrWord(hdr)[] and HdrTypeMask)
  if h.types[tid].prefinalize != nil: return false
  let pi = pageOf(h, hdr)
  let d = desc(h, pi)
  let refund = slotBytes(h, hdr)
  if d.kind == pkNormal:
    let cell = int(d.cellSize)
    if h.config.poison: fillMem(toP(hdr + 8'u), cell - 8, PoisonByte)
    hdrWord(hdr)[] = 0'u64
    inc h.stats.freedObjects
    h.stats.freedBytes += int64(cell)
    h.stats.explicitFrees += 1
    if (d.flags and pfSwept) != 0'u8:
      # swept page: the slot joins a free list right away
      dec d.objCount            # (modular: the current page's allocs are added later)
      let sp = addr h.families[int(d.family)].spaces[int(d.cls)]
      if int(sp.curPage) == pi:
        cast[ptr uint](hdr + 8'u)[] = sp.freeList
        sp.freeList = hdr
      else:
        cast[ptr uint](hdr + 8'u)[] = d.freeHead
        d.freeHead = hdr
        if d.freeCount == 0'u32:
          listPush(h, addr sp.avail, pi)   # a full page has free room again
        inc d.freeCount
    # an unswept page: type id 0 already makes the slot free for the lazy
    # sweep (no finalizer runs); it is reused once the page is swept.
  else:
    # large object: give the pages back now
    listRemove(h, addr h.largeList, pi)
    let n = int(d.nPages)
    h.stats.freedObjects += 1
    h.stats.freedBytes += int64(HeaderSize + d.largeSize)
    h.stats.explicitFrees += 1
    hdrWord(hdr)[] = 0'u64
    for k in pi ..< pi + n:
      discard osDiscard(toP(pageBase(h, k)), PageSize)
      let dk = desc(h, k)
      dk.headPage = -1
      dk.nPages = 0
      dk.largeSize = 0
      releasePage(h, k)
      if (desc(h, k).flags and pfProtected) == 0'u8: desc(h, k).flags = pfZero
  if h.config.stressEvery == 0:
    # memory handed back explicitly does not count against the GC budget (a
    # growing seq must not trigger collections by reallocating); not in
    # gc-stress mode, whose slow path is what counts the allocations
    h.budget += refund
  result = true

proc enterNoGc*(h: Heap) {.inline.} =
  ## Allocation never collects until the matching `leaveNoGc`.
  inc h.noGcDepth
proc leaveNoGc*(h: Heap) {.inline.} =
  ## A collection that came due inside the scope happens at the next allocation.
  dec h.noGcDepth
  if h.noGcDepth == 0 and h.gcDue: h.budget = 0

# ---------------------------------------------------------------------------
# marking

proc ephWake(h: Heap; key: pointer) {.noinline.}

proc shade(h: Heap; hdr: uint) {.inline.} =
  ## hdr was just marked: queue it. Its header is NOT read here (that would
  ## be a cache miss per edge); `drain` reads it after a prefetch delay.
  h.work.push(toP(hdr + 8'u))

proc checkEdge(h: Heap; p: pointer; what: string): bool =
  var hdr = 0'u
  let r = resolve(h, toU(p), hdr)
  if r != rsLive:
    note(h, "marking: " & what & " " & hex(toU(p)) & " -> " & $r)
    return false
  if hdr + 8'u != toU(p):
    note(h, "marking: " & what & " " & hex(toU(p)) & " is an interior pointer (object at " & hex(hdr + 8'u) & ")")
    return false
  result = true

proc markObj*(h: Heap; p: pointer) {.inline.} =
  ## Mark a precise pointer (object payload start). Nil is ignored.
  let u = toU(p)
  if u - 8'u - h.cage >= uint(h.cageBytes): return     # nil or not ours
  when heapChecks:
    if not checkEdge(h, p, "edge"): return
  let hdr = u - 8'u
  if testAndMark(h, hdr): shade(h, hdr)

proc markConservative(h: Heap; w: uint) =
  var hdr = 0'u
  if resolve(h, w, hdr) == rsLive:
    inc h.consHits
    if testAndMark(h, hdr): shade(h, hdr)

proc heapConservativeWord(ctx: pointer; w: pointer) {.exportc: "heap_conservative_word", cdecl.} =
  markConservative(cast[Heap](ctx), toU(w))

proc isMarked*(h: Heap; p: pointer): bool =
  ## During weak callbacks / prefinalizers: did the object survive marking?
  let u = toU(p)
  if u - 8'u - h.cage >= uint(h.cageBytes): return true   # not a heap object
  result = isMarkedHdr(h, u - 8'u)

proc isLive*(h: Heap; p: pointer): bool =
  ## Is `p` the start of a live object (any time)?
  syncCarved(h)
  var hdr = 0'u
  result = resolve(h, toU(p), hdr) == rsLive and hdr + 8'u == toU(p)

proc findObject*(h: Heap; p: pointer): pointer =
  ## Payload start of the live object containing address `p` (interior
  ## pointers allowed), or nil.
  syncCarved(h)
  var hdr = 0'u
  if resolve(h, toU(p), hdr) == rsLive: toP(hdr + 8'u) else: cast[pointer](0)

# ephemeron table: key -> chain of values whose liveness waits on the key

proc ephFind(h: Heap; key: uint): int =
  if h.ephCap == 0: return -1
  var i = int((key shr 4) * 0x9E3779B97F4A7C15'u) and (h.ephCap - 1)
  while true:
    let k = h.ephKeys[i]
    if k == key: return i
    if k == 0'u: return -1
    i = (i + 1) and (h.ephCap - 1)

proc ephGrow(h: Heap) =
  let oldCap = h.ephCap
  let oldKeys = h.ephKeys
  let oldHeads = h.ephHeads
  h.ephCap = if oldCap == 0: 256 else: oldCap * 2
  h.ephKeys = cast[ptr UncheckedArray[uint]](alloc0(h.ephCap * sizeof(uint)))
  h.ephHeads = cast[ptr UncheckedArray[int]](alloc0(h.ephCap * sizeof(int)))
  for j in 0 ..< oldCap:
    let k = oldKeys[j]
    if k != 0'u:
      var i = int((k shr 4) * 0x9E3779B97F4A7C15'u) and (h.ephCap - 1)
      while h.ephKeys[i] != 0'u: i = (i + 1) and (h.ephCap - 1)
      h.ephKeys[i] = k
      h.ephHeads[i] = oldHeads[j]
  if oldCap > 0:
    dealloc(cast[pointer](oldKeys))
    dealloc(cast[pointer](oldHeads))

proc ephAdd(h: Heap; key, val: pointer) =
  if (h.ephCount + 1) * 2 > h.ephCap: ephGrow(h)
  let k = toU(key)
  var i = int((k shr 4) * 0x9E3779B97F4A7C15'u) and (h.ephCap - 1)
  while h.ephKeys[i] != 0'u and h.ephKeys[i] != k: i = (i + 1) and (h.ephCap - 1)
  if h.ephKeys[i] == 0'u:
    h.ephKeys[i] = k
    h.ephHeads[i] = -1
    inc h.ephCount
    let w = cast[ptr uint64](k - 8'u)
    w[] = w[] or HdrEphKey
  h.ephPairs.push(EphPair(key: key, val: val, next: h.ephHeads[i]))
  h.ephHeads[i] = h.ephPairs.len - 1

proc ephWake(h: Heap; key: pointer) =
  let i = ephFind(h, toU(key))
  if i < 0: return
  var j = h.ephHeads[i]
  h.ephHeads[i] = -1
  while j >= 0:
    let pr = h.ephPairs[j]
    h.ephPending.push(pr.val)
    inc h.stats.ephemeronsWoken
    j = pr.next

proc ephReset(h: Heap) =
  for i in 0 ..< h.ephCap:
    let k = h.ephKeys[i]
    if k != 0'u:
      let w = cast[ptr uint64](k - 8'u)
      w[] = w[] and not HdrEphKey
      h.ephKeys[i] = 0'u
  h.ephCount = 0
  h.ephPairs.clear()

# ---------------------------------------------------------------------------
# visitor API (used from trace procs and root providers)

proc verifyEdge(v: Visitor; p: pointer)
proc verifyWeak(v: Visitor; slot: ptr pointer; hasCb: bool)
proc verifyEphemeron(v: Visitor; key, val: pointer)

proc visit*(v: Visitor; p: pointer) {.inline.} =
  ## A strong edge to the object whose payload starts at `p` (nil allowed).
  if v.mode == vmMark: markObj(v.heap, p)
  elif not isNilP(p): verifyEdge(v, p)

proc visitWeak*(v: Visitor; slot: ptr pointer; cb: WeakSlotProc = nil; data: pointer = cast[pointer](0)) =
  ## A weak edge: `slot[]` is cleared (or `cb(data, slot)` is called) after
  ## marking if its target did not survive. The slot must stay valid until
  ## the end of the collection (it normally lives in the traced object).
  if v.mode == vmMark:
    if not isNilP(slot[]): v.heap.weakSlots.push(WeakSlot(slot: slot, cb: cb, data: data))
  else: verifyWeak(v, slot, cb != nil)

proc registerWeakCallback*(v: Visitor; cb: WeakCallbackProc; data: pointer) =
  ## Run `cb(heap, data)` once after marking (and ephemeron processing) of
  ## this collection, before prefinalizers. For custom weak containers.
  if v.mode == vmMark: v.heap.weakCbs.push(WeakCb(cb: cb, data: data))

proc visitEphemeron*(v: Visitor; key, val: pointer) =
  ## WeakMap entry semantics: `val` is kept alive iff `key` is alive by other
  ## means (the entry itself never keeps `key` alive). Either may be nil.
  if v.mode == vmMark:
    if isNilP(key) or isNilP(val): return
    let h = v.heap
    if not inCage(h, key):
      markObj(h, val)
    elif isMarkedHdr(h, toU(key) - 8'u):
      markObj(h, val)
    else:
      when heapChecks:
        if not checkEdge(h, key, "ephemeron key"): return
      ephAdd(h, key, val)
  else: verifyEphemeron(v, key, val)

proc visitConservative*(v: Visitor; lo, hi: pointer) =
  ## Treat every word in [lo, hi) as a possible (interior) heap pointer
  ## (fiber stacks, foreign buffers).
  if v.mode == vmMark:
    let h = v.heap
    osScanRange(cast[pointer](h), lo, hi, toP(h.cage), toP(h.cageEnd),
                if h.config.stripNanBox: 0x0000_FFFF_FFFF_FFFF'u64 else: 0'u64)

proc heapOfVisitor*(v: Visitor): Heap {.inline.} = v.heap

# ---------------------------------------------------------------------------
# roots

proc addRootProvider*(h: Heap; cb: RootProc; data: pointer): int =
  ## `cb(visitor, data)` is called at every collection to visit roots (a VM's
  ## value stack, globals). Returns an id for `removeRootProvider`.
  inc h.nextProvId
  h.providers.push(RootProv(cb: cb, data: data, id: h.nextProvId, live: true))
  result = h.nextProvId

proc removeRootProvider*(h: Heap; id: int) =
  for i in 0 ..< h.providers.len:
    if h.providers[i].id == id: h.providers.at(i).live = false

type
  ImageRoots = object
    anchor: pointer            # an address inside the image
    tls: bool
    n: int
    ranges: ptr UncheckedArray[pointer]   # 2*n: [lo, hi) pairs

proc scanImageRoots(v: Visitor; data: pointer) {.cdecl.} =
  let r = cast[ptr ImageRoots](data)
  for i in 0 ..< r.n:
    visitConservative(v, r.ranges[2 * i], r.ranges[2 * i + 1])
  if r.tls:
    var lo = cast[pointer](0)
    var hi = cast[pointer](0)
    osImageTls(r.anchor, addr lo, addr hi)
    if not isNilP(lo): visitConservative(v, lo, hi)

proc addImageRoots*(h: Heap; addrInImage: pointer; threadLocals = true): int =
  ## Register the static data of the executable or shared library containing
  ## `addrInImage` (its writable segments: .data, .bss, ...) and, with
  ## `threadLocals`, the heap thread's thread-local block of that image, as
  ## conservatively scanned roots. For embedders whose module-level globals
  ## may hold heap pointers. Returns the root provider id (-1: image not found).
  var tmp {.noinit.}: array[64, pointer]
  let n = osImageRanges(addrInImage, cast[ptr UncheckedArray[pointer]](addr tmp[0]), 32)
  if n < 0: return -1
  let cnt = if n > 32: 32 else: n
  let r = cast[ptr ImageRoots](alloc0(sizeof(ImageRoots)))
  if isNilP(r): fatal("heap: out of memory (image roots)")
  r.anchor = addrInImage
  r.tls = threadLocals
  r.n = cnt
  r.ranges = cast[ptr UncheckedArray[pointer]](alloc0(max(1, 2 * cnt) * sizeof(pointer)))
  for i in 0 ..< 2 * cnt: r.ranges[i] = tmp[i]
  result = addRootProvider(h, scanImageRoots, cast[pointer](r))

proc newPNode*(h: Heap; obj: pointer; kind: uint8): ptr PNode =
  if isNilP(h.pfree):
    let c = cast[ptr PChunk](alloc0(sizeof(PChunk)))
    if isNilP(c): fatal("heap: out of memory (persistent nodes)")
    c.next = h.pchunks
    h.pchunks = c
    for i in countdown(255, 0):
      c.nodes[i].nextFree = h.pfree
      c.nodes[i].heap = h
      h.pfree = addr c.nodes[i]
  result = h.pfree
  h.pfree = result.nextFree
  result.nextFree = cast[ptr PNode](0)
  result.obj = obj
  result.kind = kind
  inc h.persistents

proc freeHeapMemory(h: Heap)

proc freePNode*(n: ptr PNode) =
  let h = n.heap
  n.obj = cast[pointer](0)
  n.kind = 0
  n.nextFree = h.pfree
  h.pfree = n
  dec h.persistents
  if h.phase == hpTearDown and h.persistents == 0: freeHeapMemory(h)

proc persistentCount*(h: Heap): int = h.persistents

proc markRoots(h: Heap; stack: StackState) =
  var c = h.pchunks
  while not isNilP(c):
    for i in 0 ..< 256:
      if c.nodes[i].kind == 1'u8: markObj(h, c.nodes[i].obj)
    c = c.next
  let v = addr h.visitor
  for i in 0 ..< h.providers.len:
    let pr = h.providers[i]
    if pr.live and pr.cb != nil: pr.cb(v, pr.data)
  if h.config.conservativeStack and stack == ssScan and not isNilP(h.stackBase):
    osScanStack(cast[pointer](h), h.stackBase, toP(h.cage), toP(h.cageEnd),
                if h.config.stripNanBox: 0x0000_FFFF_FFFF_FFFF'u64 else: 0'u64)

proc drain(h: Heap) =
  ## Explicit worklist (LIFO) feeding a 16-entry FIFO ring: an object is
  ## prefetched when it enters the ring and traced 16 objects later, so up
  ## to 16 independent cache misses are in flight (lists, trees).
  let v = addr h.visitor
  var ring: array[RingSize, uint] = [0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u, 0u]
  var head = 0
  var count = 0
  while true:
    while count < RingSize and h.work.len > 0:
      let q = h.work.pop()
      prefetchRead(toP(toU(q) - 8'u))
      ring[(head + count) and (RingSize - 1)] = toU(q)
      inc count
    if count > 0:
      let p = toP(ring[head])
      head = (head + 1) and (RingSize - 1)
      dec count
      let hw = cast[ptr uint64](toU(p) - 8'u)[]
      if (hw and HdrEphKey) != 0'u64: ephWake(h, p)
      let tr = h.types[int(hw and HdrTypeMask)].trace
      if tr != nil: tr(v, p)
    elif h.ephPending.len > 0:
      markObj(h, h.ephPending.pop())
    else: break

# ---------------------------------------------------------------------------
# verifier

proc srcName(v: Visitor): string =
  if isNilP(v.src): "root" else: typeName(v.heap, typeIdOf(v.src)) & " " & hex(toU(v.src))

proc verifyTarget(v: Visitor; p: pointer; what: string; requireLive: bool): bool =
  let h = v.heap
  var hdr = 0'u
  let r = resolve(h, toU(p), hdr)
  if r == rsNotInCage or r == rsFreePage or r == rsFreeSlot or (requireLive and r == rsDead):
    note(h, "verify: " & what & " from " & srcName(v) & " -> " & hex(toU(p)) & ": " & $r)
    return false
  if hdr + 8'u != toU(p):
    note(h, "verify: " & what & " from " & srcName(v) & " -> " & hex(toU(p)) &
            ": interior pointer (object at " & hex(hdr + 8'u) & ")")
    return false
  let tid = int(hdrWord(hdr)[] and HdrTypeMask)
  if tid >= h.typeCount or not h.types[tid].used:
    note(h, "verify: " & what & " from " & srcName(v) & " -> " & hex(toU(p)) & ": bad type id " & $tid)
    return false
  let tf = int(h.types[tid].family)
  if v.srcFamily >= 0 and (h.families[v.srcFamily].allowed and (1'u64 shl uint64(tf))) == 0'u64:
    note(h, "verify: " & what & " from " & srcName(v) & " (family " & familyName(h, FamilyId(v.srcFamily)) &
            ") -> " & typeName(h, TypeId(tid)) & " (family " & familyName(h, FamilyId(tf)) & "): edge not allowed")
    return false
  result = true

proc verifyEdge(v: Visitor; p: pointer) =
  discard verifyTarget(v, p, "edge", true)

proc verifyWeak(v: Visitor; slot: ptr pointer; hasCb: bool) =
  let t = slot[]
  if isNilP(t): return
  discard verifyTarget(v, t, "weak edge", not hasCb)

proc verifyEphemeron(v: Visitor; key, val: pointer) =
  if isNilP(key): return
  if not verifyTarget(v, key, "ephemeron key", false): return
  if isNilP(val): return
  var hdr = 0'u
  if resolve(v.heap, toU(key), hdr) == rsLive:
    discard verifyTarget(v, val, "ephemeron value", true)
  else:
    discard verifyTarget(v, val, "ephemeron value", false)

type
  VerifyReport* = object
    errors*: int
    objects*: int
    messages*: seq[string]

proc verifyObject(h: Heap; v: Visitor; hdr: uint; famOfPage: int; payloadBytes: int) =
  let hw = hdrWord(hdr)[]
  let tid = int(hw and HdrTypeMask)
  if (hw and HdrMagicMask) != HeaderMagic:
    note(h, "verify: corrupt header at " & hex(hdr))
    return
  if tid >= h.typeCount or not h.types[tid].used:
    note(h, "verify: object " & hex(hdr + 8'u) & " has bad type id " & $tid)
    return
  let ti = addr h.types[tid]
  if int(ti.family) != famOfPage:
    note(h, "verify: object " & hex(hdr + 8'u) & " of " & typeName(h, TypeId(tid)) &
            " lives in a page of family " & familyName(h, FamilyId(famOfPage)) & " (isolation broken)")
  v.src = toP(hdr + 8'u)
  v.srcFamily = int(ti.family)
  if ti.trace != nil: ti.trace(v, toP(hdr + 8'u))
  if h.config.verifyPayloads:
    let words = payloadBytes div 8
    let pw = cast[ptr UncheckedArray[uint]](hdr + 8'u)
    for i in 0 ..< words:
      let w = pw[i]
      if w - h.cage < uint(h.highWater) shl PageShift:
        var th = 0'u
        let r = resolve(h, w, th)
        if r == rsDead or r == rsFreeSlot or r == rsFreePage:
          note(h, "verify: dangling word at " & typeName(h, TypeId(tid)) & " " & hex(hdr + 8'u) &
                  "+" & $(i * 8) & " -> " & hex(w) & " (" & $r & "): a missed trace edge?")

proc verifyHeapImpl(h: Heap): VerifyReport =
  let before = h.stats.verifyErrors
  clearMessages()
  let saved = h.phase
  h.phase = hpVerifying
  var vis = VisitorObj(heap: h, mode: vmVerify, src: cast[pointer](0), srcFamily: -1, weakOk: false)
  let v = addr vis
  var objects = 0
  for pi in 0 ..< h.highWater:
    let d = desc(h, pi)
    if d.kind == pkNormal:
      let base = pageBase(h, pi)
      let cell = int(d.cellSize)
      for i in 0 ..< int(d.carved):
        let hdr = base + uint(i * cell)
        let tid = hdrWord(hdr)[] and HdrTypeMask
        if tid != 0'u64:
          if (d.flags and pfSwept) != 0'u8 or isMarkedHdr(h, hdr):
            inc objects
            verifyObject(h, v, hdr, int(d.family), cell - 8)
        elif h.config.poison and (d.flags and pfSwept) != 0'u8 and cell > 16 and
            (hdrWord(hdr)[] and HdrMagicMask) == 0'u64:
          let b = cast[ptr UncheckedArray[uint8]](hdr)
          if b[16] == PoisonByte and not poisonOk(hdr, cell):
            note(h, "verify: free slot " & hex(hdr + 8'u) & " was written after free")
    elif d.kind == pkLargeHead:
      let hdr = pageBase(h, pi)
      if (d.flags and pfSwept) != 0'u8 or isMarkedHdr(h, hdr):
        inc objects
        verifyObject(h, v, hdr, int(d.family), d.largeSize)
  # roots
  v.src = cast[pointer](0)
  v.srcFamily = -1
  var c = h.pchunks
  while not isNilP(c):
    for i in 0 ..< 256:
      let n = addr c.nodes[i]
      if n.kind == 1'u8 and not isNilP(n.obj): discard verifyTarget(v, n.obj, "persistent", true)
      elif n.kind == 2'u8 and not isNilP(n.obj): discard verifyTarget(v, n.obj, "weak persistent", true)
    c = c.next
  for i in 0 ..< h.providers.len:
    let pr = h.providers[i]
    if pr.live and pr.cb != nil: pr.cb(v, pr.data)
  h.phase = saved
  result = VerifyReport(errors: int(h.stats.verifyErrors - before), objects: objects)

proc verifyHeap*(h: Heap): VerifyReport =
  ## Check every live object: header sane, type registered, page family =
  ## type family, every traced edge points at a live object START of a family
  ## the source family may reference, weak/ephemeron edges well-formed, roots
  ## valid; with `config.verifyPayloads`, no payload word dangles into a free
  ## or dead slot; with poisoning, no free slot was written after free.
  ## Callable any time outside a collection (and runs inside one with
  ## `verifyEachGc`, after marking/weak processing, before sweeping).
  syncCarved(h)
  result = verifyHeapImpl(h)
  result.messages = heapMessages()

# ---------------------------------------------------------------------------
# collection

proc processWeak(h: Heap) =
  for i in 0 ..< h.weakSlots.len:
    let ws = h.weakSlots[i]
    let t = ws.slot[]
    if not isNilP(t) and inCage(h, t) and not isMarkedHdr(h, toU(t) - 8'u):
      inc h.stats.weakCleared
      if ws.cb != nil: ws.cb(ws.data, ws.slot)
      else: ws.slot[] = cast[pointer](0)
  h.weakSlots.clear()
  for i in 0 ..< h.weakCbs.len:
    let wc = h.weakCbs[i]
    wc.cb(h, wc.data)
  h.weakCbs.clear()
  var c = h.pchunks
  while not isNilP(c):
    for i in 0 ..< 256:
      let n = addr c.nodes[i]
      if n.kind == 2'u8 and not isNilP(n.obj) and inCage(h, n.obj) and
          not isMarkedHdr(h, toU(n.obj) - 8'u):
        n.obj = cast[pointer](0)
        inc h.stats.weakCleared
    c = c.next
  ephReset(h)

proc runPrefinalizers(h: Heap) =
  ## Newest first. Dead objects with a prefinalizer get it called while every
  ## object (dead or alive) is still intact.
  var keep = 0
  let n = h.prefinal.len
  # process newest -> oldest, then compact preserving allocation order
  var i = n - 1
  while i >= 0:
    let p = h.prefinal[i]
    if not isMarkedHdr(h, toU(p) - 8'u):
      let tid = int(typeIdOf(p))
      h.types[tid].prefinalize(p)
      inc h.stats.prefinalizersRun
      h.prefinal.setAt(i, cast[pointer](0))
    dec i
  for j in 0 ..< n:
    let p = h.prefinal[j]
    if not isNilP(p):
      h.prefinal.setAt(keep, p)
      inc keep
  h.prefinal.len = keep

proc collect*(h: Heap; stack = ssScan) =
  ## Stop-the-world collection. `ssScan` (default) scans the calling thread's
  ## stack and registers conservatively; `ssNoHeapPointers` skips that.
  if h.phase != hpIdle:
    raiseError(h, heCollectDuringGc, "heap: collect() during " & $h.phase)
    return
  let t0 = osNowNs()
  completeSweep(h)                    # last cycle's finalizers run now
  syncCarved(h)
  # reset allocation state; clear marks
  for f in 0 ..< h.familyCount:
    let fam = addr h.families[f]
    for c in 0 ..< NumClasses:
      let sp = addr fam.spaces[c]
      sp.freeList = 0'u
      sp.bump = 0'u
      sp.limit = 0'u
      sp.curPage = -1
      sp.unswept = -1
      sp.avail = -1
  var inUse = 0
  for pi in 0 ..< h.highWater:
    let d = desc(h, pi)
    if d.kind == pkNormal or d.kind == pkLargeHead:
      clearMarks(h, pi)
    if d.kind == pkNormal or d.kind == pkLargeHead or d.kind == pkLargeCont: inc inUse
  h.markedBytes = 0
  h.markedObjects = 0
  h.consHits = 0
  h.phase = hpMarking
  markRoots(h, stack)
  drain(h)
  let t1 = osNowNs()
  # every normal page now waits to be swept: liveness = mark bit
  var freePages = 0
  for pi in 0 ..< h.highWater:
    let d = desc(h, pi)
    if d.kind == pkNormal:
      d.flags = d.flags and not pfSwept
      d.freeHead = 0'u
      d.freeCount = 0
      listPush(h, addr h.families[int(d.family)].spaces[int(d.cls)].unswept, pi)
      var n = 0
      let w0 = pi * MarkWords
      let words = (int(d.carved) * int(d.cellSize) + 1023) shr 10   # 64 granules per word
      for k in 0 ..< words: n += int(popcount64(h.marks[w0 + k]))
      d.liveCount = uint32(n)
      h.markedObjects += int64(n)
      h.markedBytes += int64(n) * int64(d.cellSize)
    elif d.kind == pkLargeHead:
      d.flags = d.flags and not pfSwept
      if isMarkedHdr(h, pageBase(h, pi)):
        inc h.markedObjects
        h.markedBytes += int64(HeaderSize + d.largeSize)
    elif d.kind == pkFree: inc freePages
  h.phase = hpWeak
  processWeak(h)
  h.phase = hpPrefinalizing
  runPrefinalizers(h)
  if h.config.verifyEachGc:
    discard verifyHeapImpl(h)
  h.phase = hpIdle
  let t2 = osNowNs()
  sweepLarge(h)
  h.stats.sweepNs += osNowNs() - t2
  inc h.stats.collections
  h.stats.liveBytes = h.markedBytes
  h.stats.liveObjects = h.markedObjects
  h.stats.conservativeHits = h.consHits
  h.stats.pagesInUse = int64(inUse)
  h.stats.pagesFree = int64(freePages)
  h.stats.markNs += t1 - t0
  let pause = osNowNs() - t0
  h.stats.lastPauseNs = pause
  h.stats.totalPauseNs += pause
  if pause > h.stats.maxPauseNs: h.stats.maxPauseNs = pause
  if h.config.stressEvery > 0:
    h.budget = 0
  else:
    let grown = int(float(h.markedBytes) * (h.config.growth - 1.0))
    h.budget = if grown > h.config.minBudget: grown else: h.config.minBudget

proc collectGarbage*(h: Heap) = collect(h, ssScan)

# ---------------------------------------------------------------------------
# teardown

proc freeHeapMemory(h: Heap) =
  var c = h.pchunks
  while not isNilP(c):
    let nx = c.next
    dealloc(cast[pointer](c))
    c = nx
  h.work.release()
  h.ephPending.release()
  h.weakSlots.release()
  h.weakCbs.release()
  h.ephPairs.release()
  h.prefinal.release()
  h.providers.release()
  h.names.release()
  if h.ephCap > 0:
    dealloc(cast[pointer](h.ephKeys))
    dealloc(cast[pointer](h.ephHeads))
  dealloc(cast[pointer](h))

proc destroyHeap*(h: Heap) =
  ## Finalize every remaining object (persistents and root providers are
  ## dropped first; prefinalizers run for objects that have them), then unmap.
  ## Persistent handles that outlive the heap stay harmless: they read nil,
  ## and the bookkeeping is freed when the last one is destroyed.
  h.providers.clear()
  var c = h.pchunks
  while not isNilP(c):
    for i in 0 ..< 256:
      if c.nodes[i].kind != 0'u8: c.nodes[i].obj = cast[pointer](0)
    c = c.next
  h.config.conservativeStack = false
  h.config.verifyEachGc = false
  collect(h, ssNoHeapPointers)
  completeSweep(h)
  h.phase = hpTearDown
  if h.regSlot >= 0: gHeaps[h.regSlot] = 0'u
  discard osRelease(toP(h.cage), h.cageBytes)
  discard osRelease(cast[pointer](h.descs), h.pageCount * sizeof(PageDesc))
  discard osRelease(cast[pointer](h.marks), h.pageCount * MarkWords * 8)
  discard osRelease(cast[pointer](h.types), MaxTypes * sizeof(TypeInfo))
  discard osRelease(cast[pointer](h.families), MaxFamilies * sizeof(Family))
  if h.persistents == 0: freeHeapMemory(h)
