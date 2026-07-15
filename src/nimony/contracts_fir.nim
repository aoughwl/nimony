#       Nimony
# (c) Copyright 2025 Andreas Rumpf
#
# See the file "license.txt", included in this
# distribution, for details about the copyright.

##[
Contract analysis over the **Final IR** (`doc/final_ir.md`).

Tries to prove or disprove `.requires` and `.ensures` annotations and to
verify initialization and not-nil properties.

Where the older `contracts_njvl.nim` eliminated jumps and tracked "did we
already leave" with materialized control-flow flags (`mflag`/`jtrue`) and an
`Implications` lattice, this analysis runs directly on the structured Final IR:

- `(ite cond then else)` for branching
- `(loop body)` — infinite loop; the body ends in `(continue .)` and every
  forward exit is a `(jmp loopExit)`
- `(lab L)` / `(jmp L)` — the structured multi-exit
- `(try body (except ...)* (fin ...)?)`, `(ret ...)`, `(raise ...)`
- `(store value dest)` for assignments

"Did we already leave" is now positional: the `Tracker` (`njvl/tracker.nim`)
carries fall-through reachability and the per-target exit summaries, and a
`(lab)` multi-join resolves them in one forward pass. Per the chosen design the
state is *hybrid*: `inferle` facts stay imperative (`save`/`restore` at branch
points, snapshotted per-exit for the multi-join), while the **Tracker** owns
init-tracking and fall-through.

In order to not be too annoying in the case of a contract violation, the
compiler emits a warning (that can be suppressed or turned into an error).
]##

import std / [assertions, tables, hashes, sets, strutils, syncio]

include ".." / lib / nifprelude
include ".." / lib / compat2

import ".." / models / tags
import ".." / lib / symparser
import ".." / njvl / [njvl_model, finalir, tracker]
import ".." / hexer / passes
import nimony_model, programs, decls, typenav, sembasics, reporters,
  renderer, typeprops, inferle, xints, builtintypes

type
  BorrowableCheck = enum
    IsBorrowable       ## simple path: symbols, dots, array access
    IsBorrowableFromConst
    IsBorrowableFromGlobal
    HasAddr            ## path contains explicit `addr` — unsafe escape hatch
    NotBorrowable      ## deref in middle of path or function call

  BorrowInfo = object
    borrower: SymId   ## variable holding the borrow; upon `(kill borrower)` the borrow ends
    mode: BorrowableCheck
    path: seq[SymId]  ## root :: field1 :: field2 :: ...
    info: PackedLineInfo

  InitSet = HashSet[SymId]    ## locals proven initialized at a program point

  NjvlContext = object
    facts: Facts           # From inferle.nim - tracks le/notnil facts
    typeCache: TypeCache
    tr: Tracker[InitSet, SymId]        # fall-through + per-exit init summaries;
                                        # `tr.state` is the init-set at the
                                        # current (reachable) point.
    errors: TokenBuf
    procCanRaise: bool
    moduleSuffix: string
    nestedProcs: int
    loopExitLabels: HashSet[SymId]     # `(lab)`s emitted right after a `(loop)`.
                                       # Their post-join facts are the pre-loop
                                       # set `traverseLoop` rolled back to (via
                                       # the inferle journal), not "know nothing".
    labelFacts: Table[SymId, Facts]    # facts snapshotted at each forward `(jmp L)`,
                                       # joined (meet) per label. Materialised at
                                       # `(lab L)` so a guard's refinements survive
                                       # the jmp/label join instead of collapsing to
                                       # "know nothing" (finalir doesn't snapshot
                                       # facts per jmp). Bridges the `or`-with-early-
                                       # return lowering; see `bindKeyBoth`.
    condTrue: Table[SymId, Facts]      # facts guaranteed to hold when a lowered
                                       # `and`/`or` boolean temp is true ...
    condFalse: Table[SymId, Facts]     # ... or false. The short-circuit lowering of
                                       # `a and b` / `a or b` spills the operands into
                                       # a bool temp assigned in both arms of an
                                       # `(ite cond ...)`; these record the per-operand
                                       # facts so the later `(ite temp ...)` can refine
                                       # (e.g. `x != nil and x.f`). See `traverseIte`.
    inlineVars: Table[SymId, Cursor] # var -> to its init expression
    resultSym: SymId                   # symId of the `result` local for the current proc, or NoSymId
    activeBorrows: seq[BorrowInfo]
    verbose: bool                      # --verbose: dump final IR on init/contract
                                       # failures for easier debugging
    rangeChecks: bool                  # RangeCheck mode active: an unprovable
                                       # conversion to `range[lo..hi]` is caught
                                       # at runtime (hexer/desugar inserts a
                                       # `nimIRcheck`), so the static prover
                                       # defers the undecidable case instead of
                                       # rejecting it at compile time.
    currentProcStart: Cursor           # cursor at the start of the proc whose
                                       # body we are currently analysing (used
                                       # for the --verbose dump)

proc isectInits(a, b: InitSet): InitSet =
  ## Intersection join for the definite-assignment lattice.
  ##
  ## Deliberately hand-rolled instead of `std/sets.intersection`: that sizes
  ## its result from `data.len` (the internal slot-array capacity, which a
  ## HashSet never shrinks) rather than from the element count, so once a proc
  ## has touched many locals every control-flow merge allocates an oversized
  ## table and large procs OOM. Iterate the smaller operand and let the result
  ## grow to the (small) number of shared elements.
  result = initHashSet[SymId]()
  if a.len <= b.len:
    for x in a:
      if x in b: result.incl x
  else:
    for x in b:
      if x in a: result.incl x

proc newInitTracker(): Tracker[InitSet, SymId] =
  initTracker[InitSet, SymId](initHashSet[SymId](), isectInits)

proc markInit(c: var NjvlContext; symId: SymId) {.inline.} =
  c.tr.state.incl symId

proc isInitialized(c: NjvlContext; symId: SymId): bool {.inline.} =
  symId in c.tr.state

proc dumpCurrentProc(c: var NjvlContext; info: PackedLineInfo; msg: string) =
  ## Dump the NJ IR of the proc currently under analysis to stderr. Used
  ## by `--verbose` so the user can see the lowered form that caused
  ## a contract/init failure. Gated on `c.verbose` — callers still invoke
  ## it unconditionally; this proc is the single decision point.
  if not c.verbose: return
  if cursorIsNil(c.currentProcStart): return
  stderr.writeLine "--- NJ IR (--verbose) for: " & msg
  stderr.writeLine "--- at " & infoToStr(info) & ":"
  stderr.writeLine toString(c.currentProcStart, false)
  stderr.writeLine "--- end NJ IR dump ---"

proc userSymName(s: string): string =
  ## Render a local symbol for a user-facing diagnostic: drop the internal
  ## disambiguator suffix (`result.0` -> `result`, `x.14` -> `x`) so a mangling
  ## artifact isn't mistaken for something meaningful — e.g. a tuple field index.
  var base = ""
  var disamb = 0
  result = if splitLocalSymName(s, base, disamb): base else: s

proc buildErr(c: var NjvlContext; info: PackedLineInfo; msg: string) =
  when defined(debug):
    writeStackTrace()
    echo infoToStr(info) & " Error: " & msg
    quit msg
  dumpCurrentProc(c, info, msg)
  var hintedMsg = msg
  if not c.verbose:
    hintedMsg.add " [pass --verbose for the NJ IR]"
  c.errors.buildTree ErrT, info:
    c.errors.addDotToken()
    c.errors.add strToken(pool.strings.getOrIncl(hintedMsg), info)

proc contractViolation(c: var NjvlContext; orig: Cursor; fact: LeXplusC; report: bool) =
  if report:
    echo "known facts in this context: "
    for i in 0 ..< c.facts.len:
      echo $c.facts[i]
    echo "canonical fact: ", $fact
  error "contract violation: ", orig

# Forward declarations
proc traverseStmt(c: var NjvlContext; n: var Cursor)
proc traverseExpr(c: var NjvlContext; pc: var Cursor)
proc analyseCall(c: var NjvlContext; n: var Cursor)
proc invalidateCondFlags(c: var NjvlContext; symId: SymId)

proc extractSymId(n: Cursor): SymId {.inline.} =
  var n = n
  if n.exprKind in {HaddrX, HderefX}: inc n

  if n.kind == Symbol:
    result = n.symId
  elif n.kind == ParLe and n.tagEnum == VTagId:
    result = n.firstSon.symId
  else:
    result = NoSymId

proc extractSymIdForStore(n: Cursor): SymId =
  # idea both (etupat result.0 +0) and (etupat result.0 +1) create
  # a full store to `result.0`.
  var n = n
  if n.njvlKind == EtupatV:
    inc n
  result = extractSymId(n)

proc skipSymbol(r: var Cursor): SymId {.inline.} =
  ## Consume a bare Symbol or (v sym version) node and return its SymId.
  ## Returns NoSymId (without advancing) if r is neither.
  var n = r
  while n.exprKind in {HconvX, ConvX, BaseobjX}:
    inc n
    skip n # type
  result = extractSymId(n)
  if result != NoSymId:
    skip r

# --- Borrow checking ---

proc extractBorrowPath(c: var NjvlContext; n: Cursor; result: var BorrowInfo; followInlineVars=true) =
  ## Extract a path (root :: field1 :: field2 :: ...) from an expression,
  ## expanding inline variables.
  if n.kind == ParLe:
    let ek = n.exprKind
    if ek in {DotX, DdotX}:
      if ek == DdotX and result.mode != HasAddr:
        result.mode = NotBorrowable
      var r = n
      inc r
      extractBorrowPath(c, r, result, followInlineVars)
      skip r # skip object subtree
      if r.kind == Symbol:
        result.path.add r.symId
    elif ek == AddrX:
      result.mode = HasAddr
      var r = n
      inc r
      extractBorrowPath(c, r, result, followInlineVars)
    elif ek == DerefX:
      if result.mode != HasAddr:
        result.mode = NotBorrowable
      var r = n
      inc r
      extractBorrowPath(c, r, result, followInlineVars)
    elif ek in {HaddrX, HderefX}:
      var r = n
      inc r
      extractBorrowPath(c, r, result, followInlineVars)
    elif ek in {TupatX, ArratX, AtX, PatX}:
      # Array/tuple access: recurse into container, don't distinguish indices
      var r = n
      inc r
      extractBorrowPath(c, r, result, followInlineVars)
    elif ek in ConvKinds:
      var r = n
      inc r
      skip r # type
      extractBorrowPath(c, r, result, followInlineVars)
    elif ek == BaseobjX:
      var r = n
      inc r
      skip r # type
      skip r # intlit
      extractBorrowPath(c, r, result, followInlineVars)
    elif ek in CallKinds:
      # we borrow from the first argument of the call:
      var r = n
      inc r
      skip r # fn
      extractBorrowPath(c, r, result, followInlineVars)
    elif ek in {AconstrX, SetconstrX, TupconstrX, OconstrX, NilX, TrueX, FalseX}:
      result.mode = IsBorrowableFromConst
    elif n.njvlKind == EtupatV:
      var r = n
      inc r
      extractBorrowPath(c, r, result, followInlineVars)
    elif n.njvlKind == VV:
      extractBorrowPath(c, n.firstSon, result, followInlineVars)
  elif n.kind in {IntLit, UIntLit, CharLit, FloatLit, StringLit}:
    result.mode = IsBorrowableFromConst
  elif n.kind == Symbol:
    let s = n.symId
    if (followInlineVars or getType(c.typeCache, n).typeKind in {MutT, OutT, LentT}) and s in c.inlineVars:
      extractBorrowPath(c, c.inlineVars.getOrQuit(s), result, followInlineVars)
    else:
      if result.mode != HasAddr:
        result.mode = IsBorrowable
        let res = tryLoadSym(s)
        if res.status == LacksNothing:
          let local = asLocal(res.decl)
          if local.kind in {GvarY, TvarY}:
            result.mode = IsBorrowableFromGlobal
      result.path.add s

proc extractPath(c: var NjvlContext; n: Cursor; followInlineVars=true): BorrowInfo =
  result = BorrowInfo(path: @[], mode: NotBorrowable, info: n.info)
  extractBorrowPath(c, n, result, followInlineVars)

proc `$`(b: BorrowInfo): string =
  result = "BorrowInfo(mode: " & $b.mode & ", path: "
  for i in 0 ..< b.path.len:
    result.add " :: " & pool.syms[b.path[i]]
  result.add ")"

proc pathsOverlap(a, b: BorrowInfo): bool =
  ## Two paths overlap if one is a prefix of the other (or they are equal).
  ## Disjoint siblings (e.g. a.b vs a.c) do not overlap.
  if a.path.len == 0 or b.path.len == 0: return false
  let minLen = min(a.path.len, b.path.len)
  for i in 0 ..< minLen:
    if a.path[i] != b.path[i]:
      return false
  result = true

proc checkBorrowConflict(c: var NjvlContext; mutPath: BorrowInfo; info: PackedLineInfo) =
  for b in c.activeBorrows:
    if pathsOverlap(mutPath, b):
      buildErr c, info, "'" & pool.syms[mutPath.path[0]] & "' is borrowed and cannot be mutated"
      return

proc endBorrow(c: var NjvlContext; sym: SymId) =
  var i = 0
  while i < c.activeBorrows.len:
    if c.activeBorrows[i].borrower == sym:
      # order of active borrows is irrelevant, so swap-delete is fine
      c.activeBorrows.del(i)
    else:
      inc i

template getVarId(c: var NjvlContext; symId: SymId): VarId = VarId(symId)

# --- Range (`range[lo..hi]`) checking ---
#
# Following Araq's design: a value flowing into a `range[lo..hi]` slot carries
# the proof obligation `lo <= value <= hi`. We ask the inferle engine to
# discharge it from the facts known on this path; whatever cannot be proven is
# rejected at compile time. No runtime check is ever emitted (zero runtime cost,
# no new dynamic failure modes). A `range`-typed location, once bound, is itself
# a fact (`lo <= x <= hi`), which is what makes proper subtyping such as
# `range[2..5]` -> `range[0..10]` provable.

proc staticRangeBounds(typ: Cursor; lo, hi: var xint): bool =
  ## Extract the statically-known integer bounds of a `range[lo..hi]` type,
  ## resolving a named range type (a `Symbol`) to its definition. Returns false
  ## for non-range or non-static ranges (which the caller leaves untouched).
  var t = typ
  var guard = 0
  while t.kind == Symbol and guard < 8:
    let s = tryLoadSym(t.symId)
    if s.status != LacksNothing or s.decl.symKind != TypeY: return false
    t = asTypeDecl(s.decl).body
    inc guard
  if t.typeKind != RangetypeT: return false
  var r = t
  inc r        # skip rangetype tag
  skip r       # skip base type
  case r.kind
  of IntLit: lo = createXint(pool.integers[r.intId])
  of UIntLit: lo = createXint(pool.uintegers[r.uintId])
  else: return false
  inc r
  case r.kind
  of IntLit: hi = createXint(pool.integers[r.intId])
  of UIntLit: hi = createXint(pool.uintegers[r.uintId])
  else: return false
  result = lo <= hi

proc checkRangeAssign(c: var NjvlContext; targetType, value: Cursor;
                      runtimeChecked = false) =
  ## Emit and discharge the `lo <= value <= hi` obligation for a value bound to a
  ## `range[lo..hi]`-typed target. Value conversions are handled at the
  ## conversion site (see the `ConvX`/`HconvX` case in `traverseExpr`), so we
  ## skip them here to avoid double-reporting.
  ##
  ## `runtimeChecked` is set at the conversion site when the RangeCheck mode is
  ## active: hexer/desugar will wrap the value in a `nimIRcheck` that aborts at
  ## runtime, so an *undecidable* obligation (a value we cannot prove in range)
  ## is discharged at runtime rather than reported here. A *decidable* violation
  ## (an out-of-range literal) is still a compile-time error either way, since it
  ## can never succeed at runtime.
  if value.exprKind in {ConvX, HconvX, CastX, BaseobjX}: return
  var lo = zero()
  var hi = zero()
  if not staticRangeBounds(targetType, lo, hi): return

  # 1. The value's own *declared type* may already be a `range` that fits: a
  #    subset `range[aLo..aHi]` with `lo <= aLo` and `aHi <= hi` is provably in
  #    range. This is the type acting as its own proof (proper subtyping such as
  #    `range[2..5]` -> `range[0..10]`), and it is robust across control-flow
  #    joins where flow-derived facts would be intersected away.
  var aLo = zero()
  var aHi = zero()
  if staticRangeBounds(getType(c.typeCache, value), aLo, aHi):
    if lo <= aLo and aHi <= hi: return

  # 2. Otherwise, discharge `lo <= value <= hi` from the facts known on this
  #    path (e.g. a preceding `if a >= 0 ... a <= 10` guard, or a `range`-typed
  #    parameter whose bounds were seeded on entry).
  var v = VarId(0)
  var off = zero()
  var isLit = false
  var r = value
  let sym = skipSymbol(r)
  if sym != NoSymId:
    v = getVarId(c, sym)
  else:
    case value.kind
    of IntLit: off = createXint(pool.integers[value.intId]); isLit = true
    of UIntLit: off = createXint(pool.uintegers[value.uintId]); isLit = true
    else:
      # A value we cannot model cannot be proven in range. Reject it, unless a
      # runtime range check will catch it (see `runtimeChecked`).
      if not runtimeChecked:
        buildErr c, value.info, "cannot prove value is in range " & $lo & ".." & $hi
      return

  # lo <= v + off   <=>   0 <= v + (off - lo)
  let lower = query(VarId(0), v, off - lo)
  # v + off <= hi   <=>   v <= 0 + (hi - off)
  let upper = query(v, VarId(0), hi - off)
  if not (implies(c.facts, lower) and implies(c.facts, upper)):
    if isLit:
      # Decidably out of range: can never succeed, so a compile-time error even
      # when a runtime check is present.
      buildErr c, value.info, "value out of range: " & $off & " notin " & $lo & ".." & $hi
    elif runtimeChecked:
      # Undecidable statically, but a runtime `nimIRcheck` will guard it.
      discard
    elif sym != NoSymId:
      buildErr c, value.info, "cannot prove '" & pool.syms[sym] &
        "' is in range " & $lo & ".." & $hi
    else:
      buildErr c, value.info, "cannot prove value is in range " & $lo & ".." & $hi

proc seedRangeFacts(c: var NjvlContext; sym: SymId; typ: Cursor) =
  ## Record that a `range[lo..hi]`-typed parameter holds a value within its
  ## bounds on entry, so obligations that pass it on to an equal-or-wider range
  ## are provable from facts even when the value's static type is erased (e.g.
  ## after arithmetic). Range-to-range narrowing itself is proven structurally
  ## in `checkRangeAssign` and does not depend on this.
  var lo = zero()
  var hi = zero()
  if staticRangeBounds(typ, lo, hi):
    let v = getVarId(c, sym)
    c.facts.add query(VarId(0), v, -lo)  # lo <= v
    c.facts.add query(v, VarId(0), hi)   # v <= hi

# --- Fact extraction from conditions ---

proc rightHandSide(c: var NjvlContext; pc: var Cursor; fact: var LeXplusC): bool =
  result = false
  if pc.exprKind in {AddX, SubX}:
    inc pc
    skip pc # type
    let symId2 = skipSymbol(pc)
    if symId2 != NoSymId:
      fact.b = getVarId(c, symId2)
      if pc.kind == IntLit:
        fact.c = fact.c + createXint(pool.integers[pc.intId])
        result = true
        inc pc
      elif pc.kind == UIntLit:
        fact.c = fact.c + createXint(pool.uintegers[pc.uintId])
        result = true
        inc pc
      else:
        traverseExpr c, pc
    else:
      traverseExpr c, pc
      traverseExpr c, pc
    skipParRi pc
  elif (let symId2 = skipSymbol(pc); symId2 != NoSymId):
    fact.b = getVarId(c, symId2)
    result = true
  elif pc.kind == IntLit:
    fact.b = VarId(0)
    fact.c = fact.c + createXint(pool.integers[pc.intId])
    result = true
    inc pc
  elif pc.kind == UIntLit:
    fact.b = VarId(0)
    fact.c = fact.c + createXint(pool.uintegers[pc.uintId])
    result = true
    inc pc
  elif pc.exprKind == NilX:
    fact.b = VarId(0)
    fact.c = fact.c + createXint(0'i32)
    result = true
    skip pc
  else:
    traverseExpr c, pc

proc translateCond(c: var NjvlContext; pc: var Cursor; wasEquality: var bool): LeXplusC =
  var r = pc
  result = LeXplusC(a: InvalidVarId, b: VarId(0), c: createXint(0'i32))

  var negations = 0
  while r.exprKind == NotX:
    inc negations
    inc r

  let xk = r.exprKind
  if xk in {LeX, LtX}:
    inc r
    skip r # skip type
  elif xk == EqX:
    wasEquality = negations == 0  # negated equality is inequality, not equality
    inc r
    skip r # skip type
  elif xk == InstanceofX:
    # `(instanceof x T)` truthy: x is not nil (and is at least T at runtime).
    # We don't model the type-narrowing here, just the not-nil consequence.
    var probe = r
    inc probe
    let sa = extractSymId(probe)
    if sa != NoSymId:
      result = isNotNil(getVarId(c, sa))
    else:
      traverseExpr c, pc
      return result
    skip r
    while negations > 0:
      negateFact(result)
      dec negations
      skipParRi r
    pc = r
    return result
  else:
    # Check for a bare symbol/hderef/haddr (truthy ref check: `if x:` means `x != nil`)
    let sa = extractSymId(r)
    if sa != NoSymId:
      result = isNotNil(getVarId(c, sa))
      skip r
      while negations > 0:
        negateFact(result)
        dec negations
        skipParRi r
      pc = r
    else:
      traverseExpr c, pc
    return result

  if r.kind == IntLit:
    result.a = VarId(0)
    result.c = -createXint(pool.integers[r.intId])
    inc r
  elif r.kind == UIntLit:
    result.a = VarId(0)
    result.c = -createXint(pool.uintegers[r.uintId])
    inc r
  elif (let sa = skipSymbol(r); sa != NoSymId):
    result.a = getVarId(c, sa)
  elif r.exprKind == NilX:
    result.a = VarId(0)
    skip r
  else:
    traverseExpr c, pc
    return result
  if r.exprKind == NilX:
    wasEquality = false
  if not rightHandSide(c, r, result):
    result.a = InvalidVarId
  # a < b  --> a <= b - 1:
  if xk == LtX:
    result.c = result.c - createXint(1'i32)
  skipParRi r

  while negations > 0:
    negateFact(result)
    dec negations
    skipParRi r

  pc = r

proc analyseCondition(c: var NjvlContext; pc: var Cursor): int =
  ## Returns number of facts added
  var wasEquality = false
  let fact = translateCond(c, pc, wasEquality)
  if fact.isValid:
    c.facts.add fact
    if wasEquality:
      c.facts.add fact.geXplusC
      result = 2
    else:
      result = 1
  else:
    result = 0

# --- Not-nil checking ---

proc markedAs(t: Cursor; mark: NimonyOther): bool =
  # Look through value-passing wrappers like `sink`/`mut`/`lent`/`out`:
  # they don't change a value's nilability, only how it's passed. Without
  # this, a `sink (ref T notnil)` parameter looked nilable, and NJ asked
  # for a non-nil proof on a value the type system already guarantees.
  var t = t
  while t.typeKind in {SinkT, MutT, LentT, OutT}:
    inc t
  result = false
  case t.typeKind
  of PtrT, RefT:
    var e = t.firstSon
    skip e # base type
    if e.hasMore and e.substructureKind == mark:
      result = true
  of CstringT, PointerT:
    let e = t.firstSon
    # no base type
    if e.hasMore and e.substructureKind == mark:
      result = true
  of ProctypeT:
    # New layout: `(proctype <NilTag> (params) RetType <Pragmas>)`. The
    # nilability marker is at slot 0.
    let e = t.firstSon
    if e.substructureKind == mark:
      result = true
  else:
    discard

proc analysableRoot(c: var NjvlContext; n: Cursor): SymId =
  var n = n
  while true:
    case n.exprKind
    of DotX, TupatX, ArratX, HderefX:
      inc n
    of ConvKinds:
      inc n
      skip n # type part
    of BaseobjX:
      inc n
      skip n # type part
      skip n # skip intlit
    else:
      break
  let s = extractSymId(n)
  if s != NoSymId:
    result = s
    let x = getLocalInfo(c.typeCache, result)
    if x.kind == GvarY:
      # assume sharing of global variables between threads
      result = NoSymId
  else:
    result = NoSymId

proc isNonNilExpr(c: var NjvlContext; n: Cursor): bool =
  ## Check if an expression is trivially non-nil without needing dataflow analysis.
  case n.exprKind
  of AddrX, HaddrX:
    # `(haddr …)` is the synthesised hidden-address form (e.g. emitted
    # for `var V` return lowering); semantically identical to `addr`.
    result = true
  of ConvKinds:
    # e.g. cstring("abc") — a conversion from a non-nil value is non-nil
    var inner = n
    inc inner
    skip inner # skip type part
    result = isNonNilExpr(c, inner)
  of BaseobjX:
    # A base-object upcast (e.g. a derived `ref Dog` widened to `ref Animal`)
    # of a non-nil value is itself non-nil. The operand's static type still
    # carries the `notnil` marker even though the widened result type drops it,
    # so consult the operand's type as well as recursing structurally.
    var inner = n
    inc inner
    skip inner # skip type part
    skip inner # skip inheritance-depth intlit
    result = markedAs(getType(c.typeCache, inner), NotnilU) or isNonNilExpr(c, inner)
  of SufX:
    # suffixed literal, e.g. (suf "abc" "R") — still a literal value
    result = true
  else:
    if n.kind == StringLit:
      result = true
    else:
      let s = extractSymId(n)
      if s != NoSymId:
        let sk = fetchSymKind(c.typeCache, s)
        result = isRoutine(sk)
      else:
        result = false

proc wantNotNil(c: var NjvlContext; n: Cursor) =
  case n.exprKind
  of NilX:
    buildErr(c, n.info, "expected non-nil value")
  of AddrX, HaddrX:
    discard "fine, addresses (incl. hidden-addr from var-return lowering) are not nil"
  else:
    let t = getType(c.typeCache, n)
    if markedAs(t, NotnilU):
      discard "fine, per type we know it is not nil"
    elif isNonNilExpr(c, n):
      discard "fine, expression is trivially not nil"
    elif t.typeKind in RoutineTypes and not markedAs(t, NilU):
      discard "fine, proc values are not nil unless explicitly marked nil"
    else:
      let r = analysableRoot(c, n)
      if r == NoSymId:
        # account for the fact that NJ already introduced tuples for the error handling:
        var n = n
        if n.exprKind == TupconstrX:
          inc n
          skip n # skip type
          if n.kind == Symbol and pool.syms[n.symId] == ("Success.0." & SystemModuleSuffix):
            inc n
        if n.exprKind == NewobjX and c.procCanRaise:
          discard "fine, nil value is mapped to OOM by the compiler"
        else:
          buildErr c, n.info, "cannot analyze expression is not nil: " & asNimCode(n)
      else:
        let fact = inferle.isNotNil(VarId r)
        if implies(c.facts, fact):
          discard "fine, did prove access correct"
        else:
          buildErr c, n.info, "cannot prove expression is not nil: " & asNimCode(n)

proc checkNilMatch(c: var NjvlContext; n: Cursor; expected: Cursor) =
  if markedAs(expected, NotnilU):
    wantNotNil c, n

proc wantNotNilDeref(c: var NjvlContext; n: Cursor) =
  let e = getType(c.typeCache, n)
  if markedAs(e, NilU):
    wantNotNil c, n

# --- .requires checking ---

type
  ProofRes = enum
    Unprovable, Disproven, Proven

proc `and`(a, b: ProofRes): ProofRes =
  if a == Proven and b == Proven:
    Proven
  elif a == Disproven or b == Disproven:
    Disproven
  else:
    Unprovable

proc `or`(a, b: ProofRes): ProofRes =
  if a == Proven or b == Proven:
    Proven
  elif a == Disproven and b == Disproven:
    Disproven
  else:
    Unprovable

proc `not`(a: ProofRes): ProofRes =
  if a == Unprovable:
    Unprovable
  elif a == Proven:
    Disproven
  else:
    Proven

proc argAt(call: Cursor; pos: int): Cursor =
  result = call
  inc result
  for i in 0 ..< pos: skip result

proc mapSymbol(c: var NjvlContext; paramMap: Table[SymId, int]; call: Cursor; symId: SymId): VarId =
  result = VarId(0)
  let pos = paramMap.getOrDefault(symId)
  if pos > 0:
    let arg = call.argAt(pos)
    let sid = extractSymId(arg)
    if sid != NoSymId:
      result = getVarId(c, sid)

proc compileCmp(c: var NjvlContext; paramMap: Table[SymId, int]; req, call: Cursor): LeXplusC =
  var r = req
  var a = InvalidVarId
  var b = InvalidVarId
  var cnst = createXint(0'i32)
  let sid = extractSymId(r)
  if sid != NoSymId:
    a = mapSymbol(c, paramMap, call, sid)
    inc r
  let rid = extractSymId(r)
  if rid != NoSymId:
    b = mapSymbol(c, paramMap, call, rid)
    inc r
  elif r.kind == IntLit:
    b = VarId(0)
    cnst = createXint(pool.integers[r.intId])
    inc r
  elif r.kind == UIntLit:
    b = VarId(0)
    cnst = createXint(pool.uintegers[r.uintId])
    inc r
  elif (let op = r.exprKind; op in {AddX, SubX}):
    inc r
    skip r # type
    let cid = extractSymId(r)
    if cid != NoSymId:
      b = mapSymbol(c, paramMap, call, cid)
      inc r
      if r.kind == IntLit:
        cnst = createXint(pool.integers[r.intId])
      elif r.kind == UIntLit:
        cnst = createXint(pool.uintegers[r.uintId])
      else:
        error "expected integer literal but got: ", r
    else:
      error "expected symbol but got: ", r
    skipParRi r
  result = query(a, b, cnst)

proc checkReq(c: var NjvlContext; paramMap: Table[SymId, int]; req, call: Cursor): ProofRes =
  case req.exprKind
  of AndX:
    var r = req
    inc r
    let a = checkReq(c, paramMap, r, call)
    skip r
    let b = checkReq(c, paramMap, r, call)
    result = a and b
  of OrX:
    var r = req
    inc r
    let a = checkReq(c, paramMap, r, call)
    skip r
    let b = checkReq(c, paramMap, r, call)
    result = a or b
  of NotX:
    var r = req
    inc r
    result = not checkReq(c, paramMap, r, call)
  of EqX:
    var r = req
    inc r
    skip r # skip type
    let cm = compileCmp(c, paramMap, r, call)
    let cm2 = cm.geXplusC
    if not cm.isValid:
      result = Unprovable
    elif implies(c.facts, cm) and implies(c.facts, cm2):
      result = Proven
    else:
      result = Disproven
  of LeX:
    var r = req
    inc r
    skip r # skip type
    let cm = compileCmp(c, paramMap, r, call)
    if not cm.isValid:
      result = Unprovable
    elif implies(c.facts, cm):
      result = Proven
    else:
      result = Disproven
  of LtX:
    var r = req
    inc r
    skip r # skip type
    let cm = compileCmp(c, paramMap, r, call)
    if not cm.isValid:
      result = Unprovable
    elif implies(c.facts, cm.ltXplusC):
      result = Proven
    else:
      result = Disproven
  of ExprX:
    var r = req
    while r.exprKind == ExprX:
      inc r
      while r.hasMore and not isLastSon(r): skip r
    result = checkReq(c, paramMap, r, call)
  else:
    result = Unprovable

# --- Expression analysis ---

proc analyseOconstr(c: var NjvlContext; n: var Cursor) =
  inc n
  let objType = n
  skip n # type
  while n.hasMore:
    assert n.substructureKind == KvU
    inc n
    assert n.kind == Symbol
    let expected = lookupField(c.typeCache, objType, n.symId)
    assert not cursorIsNil(expected), "could not lookup type for " & pool.syms[n.symId]
    skip n # field name
    checkNilMatch c, n, expected
    skip n # value
    if n.hasMore:
      # optional inheritance
      skip n
    skipParRi n
  skipParRi n

proc analyseArrayConstr(c: var NjvlContext; n: var Cursor) =
  inc n
  let expected = n.firstSon # element type of the array
  skip n # type
  while n.hasMore:
    checkNilMatch c, n, expected
    skip n
  skipParRi n

proc analyseTupConstr(c: var NjvlContext; n: var Cursor) =
  inc n
  var expected = n.firstSon # type of the first field
  skip n # type
  while n.hasMore:
    assert expected.hasMore
    let fieldType = getTupleFieldType(expected)
    var val = n
    if val.substructureKind == KvU:
      inc val # skip kv tag
      skip val # skip field name
    checkNilMatch c, val, fieldType
    skip n
    skip expected # type of the next field
  skipParRi n

proc traverseExpr(c: var NjvlContext; pc: var Cursor) =
  var nested = 0
  while true:
    case pc.kind
    of Symbol:
      let symId = pc.symId
      let x = getLocalInfo(c.typeCache, symId)
      if x.kind in {VarY, LetY, CursorY, PatternvarY, ResultY}:
        if c.tr.live and not isInitialized(c, symId):
          buildErr(c, pc.info, "cannot prove that " & userSymName(pool.syms[symId]) & " has been initialized")
          # don't report the same symbol twice from later references
          markInit(c, symId)
      inc pc
    of SymbolDef:
      # SymbolDef can appear inside type expressions embedded in expressions
      # (e.g., `proc(x: int)` within `seq[proc(x: int)]` in `@[]`). The NJVL
      # converter passes them through; simply skip them here.
      inc pc
    of EofToken, DotToken, Ident, StringLit, CharLit, IntLit, UIntLit, FloatLit, UnknownToken:
      inc pc
    of ParRi:
      assert nested > 0
      dec nested
      inc pc
    of ParLe:
      case pc.exprKind
      of CallKinds:
        analyseCall c, pc
      of DotX:
        inc pc
        traverseExpr c, pc # object
        skip pc # field name
        if pc.hasMore: skip pc # inheritance depth
        if pc.hasMore: skip pc # optional access-token string lit
        skipParRi pc
      of DdotX:
        inc pc
        wantNotNilDeref c, pc
        traverseExpr c, pc # object
        skip pc # field name
        if pc.hasMore: skip pc # inheritance depth
        if pc.hasMore: skip pc # optional access-token string lit
        skipParRi pc
      of DerefX:
        inc pc
        wantNotNilDeref c, pc
        traverseExpr c, pc
        skipParRi pc
      of OconstrX, NewobjX:
        analyseOconstr c, pc
      of AconstrX:
        analyseArrayConstr c, pc
      of TupconstrX:
        analyseTupConstr c, pc
      of CastX, ConvX, HconvX:
        let isCast = pc.exprKind == CastX
        inc pc
        let convType = pc
        skip pc # skips type
        # A checked conversion to a `range[lo..hi]` carries the same obligation
        # as an assignment. `cast` is an unchecked escape hatch and is exempt.
        # When RangeCheck is active the conversion is also guarded at runtime
        # (hexer/desugar inserts a `nimIRcheck`), so an unprovable value is
        # deferred to that runtime check rather than rejected here.
        if not isCast:
          checkRangeAssign c, convType, pc, runtimeChecked = c.rangeChecks
        traverseExpr c, pc
        skipParRi pc
      of NilX:
        # `(nil)` / `(nil <Type>)` / `(nil <Type> <arg>)` — nil literal,
        # possibly carrying its formal type subtree (which for itertype /
        # closure-proctype contains raw param SymbolDefs that the generic
        # expression walk would mis-classify). Nothing in here can hold
        # free variables we'd want to track, so skip the whole subtree.
        skip pc
      else:
        inc nested
        inc pc
    if nested == 0: break

proc borrowCheckForCall(c: var NjvlContext; args: Cursor) =
  var mutPaths: seq[BorrowInfo] = @[]
  var immPaths: seq[BorrowInfo] = @[]
  var n = args
  while n.hasMore:
    let isMut = n.exprKind == HaddrX
    # Validate borrowable path for haddr arguments (call-scoped borrows)
    var inner = n
    if isMut:
      inner = n.firstSon
      let m = extractPath(c, inner)
      if m.mode == NotBorrowable:
        buildErr c, n.info, "cannot borrow from '" & asNimCode(inner) &
          "': path is not borrowable; use 'addr' to override or a temporary move"
      else:
        mutPaths.add m
    else:
      let m = extractPath(c, n, followInlineVars = false)
      if m.mode in {IsBorrowable, IsBorrowableFromGlobal}:
        immPaths.add m

    skip n
  # Check aliasing: a mutable argument must not overlap with any other argument:
  for i in 0 ..< mutPaths.len:
    for j in 0 ..< immPaths.len:
      if pathsOverlap(mutPaths[i], immPaths[j]):
        when false:
          echo "mutPaths[i]: ", mutPaths[i]
          echo "immPaths[j]: ", immPaths[j]
        buildErr c, mutPaths[i].info, "mutable argument aliases with immutable parameter"
        break
  # Mutable argument must not overlap with any other mutable argument:
  for i in 0 ..< mutPaths.len:
    for j in 0 ..< mutPaths.len:
      if i != j and pathsOverlap(mutPaths[i], mutPaths[j]):
        when false:
          echo "mutPaths[i]: ", mutPaths[i]
          echo "mutPaths[j]: ", mutPaths[j]
        buildErr c, mutPaths[i].info, "mutable argument aliases with mutable parameter"
        break

proc analyseCallArgs(c: var NjvlContext; n: var Cursor) =
  let callCursor = n
  let tt = getType(c.typeCache, n)
  let calleeKind = tt.stmtKind
  var fnType = skipProcTypeToParams(tt)
  var fnPragmas = fnType
  skip fnPragmas # params
  skip fnPragmas # return type
  let effect = whichEffect(calleeKind, fnPragmas)
  traverseExpr c, n # the `fn` itself
  assert fnType.isParamsTag
  inc fnType
  var paramMap = initTable[SymId, int]()
  # Collect argument paths for aliasing check
  let args = n
  var needsBorrowCheck = false
  while n.hasMore:
    if fnType.kind == ParRi:
      # All formal params consumed but args remain (e.g. varargs that were
      # consumed without a matching VarargsT param, or similar edge cases).
      # Traverse remaining args for their side effects.
      while n.hasMore:
        traverseExpr c, n
      break
    let previousFormalParam = fnType
    let param = takeLocal(fnType, SkipFinalParRi)
    paramMap[param.name.symId] = paramMap.len+1
    let pk = param.typ.typeKind
    # Save arg info before traverseExpr advances n
    let isMut = n.exprKind == HaddrX
    # Validate borrowable path for haddr arguments (call-scoped borrows)
    if isMut:
      var inner = n
      inc inner # skip haddr tag
      needsBorrowCheck = true
    if pk == OutT:
      let s = extractSymId(n)
      if s != NoSymId:
        markInit(c, s)
    elif pk == VarargsT:
      fnType = previousFormalParam
    checkNilMatch c, n, param.typ
    traverseExpr c, n
  if needsBorrowCheck:
    borrowCheckForCall c, args
  while fnType.hasMore: skip fnType
  inc fnType # skip ParRi
  skip fnType # skip return type
  # now we have the pragmas:
  let req = extractPragma(fnType, RequiresP)
  if not cursorIsNil(req):
    let res = checkReq(c, paramMap, req, callCursor)
    when isMainModule:
      if res != Proven:
        error "contract violation: ", req

proc analyseCall(c: var NjvlContext; n: var Cursor) =
  inc n # skip call instruction
  # A `{.noreturn.}` callee (e.g. `quit`, an out-of-range raiser) does not fall
  # through. Mark the path dead after it, so a sibling branch that assigns
  # `result` is correctly seen as the only way out (matches nj.nim, which emits
  # a leave after noreturn calls). The init-set on this dead path contributes to
  # no exit, exactly as a `raise`/`return` would.
  var isNoReturn = false
  block:
    var pragmas = skipProcTypeToParams(getType(c.typeCache, n))
    if pragmas.isParamsTag:
      skip pragmas # params
      skip pragmas # return type
      isNoReturn = hasPragma(pragmas, NoreturnP)
  analyseCallArgs(c, n)
  skipParRi n
  if isNoReturn:
    c.tr.live = false

# --- Assignment fact tracking ---

proc addAsgnFact(c: var NjvlContext; fact: LeXplusC) =
  if fact.isValid:
    c.facts.add fact
    c.facts.add fact.geXplusC

proc cannotBeNil(c: var NjvlContext; n: Cursor): bool {.inline.} =
  let t = getType(c.typeCache, n)
  result = markedAs(t, NotnilU) or isNonNilExpr(c, n)

# --- NJVL-specific traversal ---

proc traverseStore(c: var NjvlContext; n: var Cursor) =
  ## Handle (store value dest) - note reversed order from asgn
  inc n # skip store tag

  # First analyze the value (source)
  let valueStart = n
  traverseExpr c, n

  # Check borrow conflicts for the destination
  let destMutPath = extractPath(c, n)
  if destMutPath.mode in {IsBorrowable, IsBorrowableFromGlobal}:
    checkBorrowConflict(c, destMutPath, n.info)

  # Now handle the destination (Symbol or NJVL versioned variable (v symId version))
  let destSymId = extractSymIdForStore(n)
  if destSymId != NoSymId:
    let symId = destSymId
    let x = getLocalInfo(c.typeCache, symId)
    if x.kind in {LetY, GletY, TletY}:
      if isInitialized(c, symId):
        c.buildErr n.info, "invalid reassignment to `let` variable"

    var fact = query(getVarId(c, symId), InvalidVarId, createXint(0'i32))
    markInit(c, symId)
    # Reassigning a variable drops any `and`/`or` flag implication keyed on it or
    # mentioning it as an operand (the recorded facts no longer hold). The store
    # of the flag itself in the lowering re-records via `traverseIte`.
    invalidateCondFlags(c, symId)

    # Check for not-nil type match
    let expected = getType(c.typeCache, n)
    checkNilMatch c, valueStart, expected
    checkRangeAssign c, expected, valueStart

    # Try to extract facts from the value
    var valueForFact = valueStart
    if rightHandSide(c, valueForFact, fact):
      if fact.a == fact.b:
        variableChangedByDiff(c.facts, fact.a, fact.c)
      else:
        invalidateFactsAbout(c.facts, fact.a)
        addAsgnFact c, fact
    else:
      invalidateFactsAbout(c.facts, fact.a)

    # Check if the rhs is known to be not nil
    if (valueStart.exprKind == NewobjX and c.procCanRaise) or cannotBeNil(c, valueStart):
      c.facts.add isNotNil(fact.a)
    else:
      # Also check: the destination type might have notnil (e.g. proctype)
      if markedAs(expected, NotnilU):
        # The nil-match check already passed, so the value IS non-nil
        c.facts.add isNotNil(fact.a)

    # The (re)assigned location again holds an in-range value; the fact
    # bookkeeping above may have invalidated its range facts, so restore them.
    seedRangeFacts c, symId, expected

    skip n
  else:
    checkRangeAssign c, getType(c.typeCache, n), valueStart
    traverseExpr c, n

  skipParRi n

# --- Exit-summary plumbing (facts ride alongside the Tracker's init-set) ---

proc setFactsTo(c: var NjvlContext; cp: int; target: Facts) =
  ## Make `c.facts` equal `target` *journaled* — roll back to the checkpoint
  ## (the pre-branch base), then add/remove only the cells that differ. No
  ## whole-`Facts` replacement, so an enclosing checkpoint stays valid.
  c.facts.rollbackTo cp
  var want = initTable[(VarId, VarId), xint]()
  for k in 0 ..< target.len:
    let m = target[k]
    want[(m.a, m.b)] = m.c
  var i = 0
  while i < c.facts.len:
    let f = c.facts[i]
    let key = (f.a, f.b)
    if key in want and want.getOrDefault(key) == f.c:
      want.del key
      inc i
    else:
      removeFactAt(c.facts, i)          # journaled removal; rechecks slot i
  for key, cc in want:
    c.facts.add LeXplusC(a: key[0], b: key[1], c: cc)

proc retKey(): ExitKey[SymId] {.inline.} = ExitKey[SymId](kind: ekReturn)
proc raiseKey(): ExitKey[SymId] {.inline.} = ExitKey[SymId](kind: ekRaise)
proc contKey(): ExitKey[SymId] {.inline.} = ExitKey[SymId](kind: ekContinue)

proc leaveToLabel(c: var NjvlContext; label: SymId) =
  # Snapshot the facts live at this forward `jmp` and join (meet) them into the
  # label's accumulator, mirroring the Tracker's per-exit init join. A `(lab)`
  # reached only by jmps then restores the meet of its predecessors' facts rather
  # than collapsing to "know nothing" — which is what lets a nil-guard's
  # `a != nil`/`b != nil` survive the `or`-with-early-return lowering (see
  # `bindKeyBoth`). Guarded on `tr.live` to match `Tracker.leaveVia`, so
  # `labelFacts.hasKey` stays in lock-step with `tr.pending`.
  if c.tr.live:
    let snap = snapshotFacts(c.facts)
    if c.labelFacts.hasKey(label):
      c.labelFacts[label] = merge(snap, 0, c.labelFacts[label], false)
    else:
      c.labelFacts[label] = snap
  gotoLabel(c.tr, label)

proc leaveToReturn(c: var NjvlContext) =
  # `return` facts are never consumed (the proc root only checks *init*, via the
  # Tracker), so we don't snapshot them — capturing them per-return is both
  # useless and quadratic (each return re-`merge`s into one accumulator).
  gotoReturn(c.tr)

proc leaveToRaise(c: var NjvlContext) =
  # `raise` facts are never consumed either: an `except` handler conservatively
  # assumes the pre-`try` state (see `traverseTry`). So we don't snapshot them.
  gotoRaise(c.tr)

proc leaveToContinue(c: var NjvlContext) =
  # The back-edge state is discarded by a one-pass forward analysis, so we do
  # not snapshot facts; we only stop falling through.
  gotoContinue(c.tr)

proc bindKeyBoth(c: var NjvlContext; key: ExitKey[SymId]) =
  ## The multi-join. **Init** is joined precisely by the Tracker (a key keeps
  ## its value iff every predecessor agrees). **Facts** are numeric `inferle`
  ## relations that aren't snapshotted per exit; a `(lab)` reached by a `jmp`
  ## therefore collapses facts to "know nothing" — sound (facts are positive
  ## knowledge, so dropping is conservative) and exactly what a loop exit wants
  ## (e.g. `while x < 10: …` proves nothing about `x` *after* the loop).
  let hadExit = c.tr.pending(key)
  case key.kind
  of ekLabel:
    let preLive = c.tr.live   # was fall-through *into* the `(lab)` reachable?
    bindLabel(c.tr, key.label)
    # A loop-exit label keeps the journal-restored pre-loop facts (see
    # `traverseLoop`). A *general* forward-jump join used to collapse to "know
    # nothing" since finalir doesn't snapshot facts per `jmp`; instead restore the
    # meet of the label's predecessors — the per-`jmp` snapshots (from
    # `leaveToLabel`) joined with the fall-through facts, if any. Sound (a meet of
    # incoming edges) and monotonic (only adds facts that hold on *every* path in).
    if hadExit and not c.loopExitLabels.contains(key.label):
      let cp = c.facts.checkpoint()
      var incoming = default(Facts)
      var have = false
      if c.labelFacts.hasKey(key.label):
        incoming = c.labelFacts[key.label]
        have = true
      if preLive:
        let ft = snapshotFacts(c.facts)
        incoming = if have: merge(ft, 0, incoming, false) else: ft
        have = true
      if have:
        setFactsTo(c, cp, incoming)
      else:
        c.facts.clearJournaled()
    if c.labelFacts.hasKey(key.label):
      c.labelFacts.del key.label
  of ekReturn: bindReturn(c.tr)
  of ekRaise: bindRaise(c.tr)
  of ekContinue: dropContinue(c.tr)

# --- `and`/`or` short-circuit flag conditioned facts ---
#
# A short-circuit `a and b` / `a or b` used as a *value* is lowered to a bool
# temp assigned in both arms of an `(ite cond ...)`:
#   `a and b`  ->  (ite a (store b flag) (store false flag))
#   `a or  b`  ->  (ite a (store true flag) (store b flag))
# and a later `(ite flag ...)` tests it. The per-operand nil facts are intersected
# away at the arm merge, so without help the `(ite flag ...)` cannot prove them.
# We record, structurally and soundly, the implication the *literal* arm makes
# unambiguous — `and` pins `flag == true` to a single arm (=> its conjuncts hold),
# `or` pins `flag == false` — and re-inject it when the flag is later tested. This
# is the Final-IR analogue of the njvl cfvar-conditioned-fact layer.

proc pureCondFact(c: var NjvlContext; pc: Cursor; ok: var bool): LeXplusC =
  ## Side-effect-free translation of a *simple* boolean condition into one linear
  ## fact (a subset of `translateCond` with no `traverseExpr` fallback, so it can
  ## be run on a peeked cursor without double-reporting). Handles `not`-wrapping,
  ## `x == <nil|int|y>` and bare truthy `x` (`x != nil`); `ok=false` otherwise.
  ok = false
  result = LeXplusC(a: InvalidVarId, b: VarId(0), c: createXint(0'i32))
  var r = pc
  var negs = 0
  while r.exprKind == NotX:
    inc negs; inc r
  if r.exprKind == EqX:
    inc r
    skip r # type
    let sa = extractSymId(r)
    if sa == NoSymId: return
    result.a = getVarId(c, sa)
    skip r
    if r.exprKind == NilX:
      result.b = VarId(0); result.c = createXint(0'i32)
    elif r.kind == IntLit:
      result.b = VarId(0); result.c = createXint(pool.integers[r.intId])
    elif r.kind == UIntLit:
      result.b = VarId(0); result.c = createXint(pool.uintegers[r.uintId])
    else:
      let sb = extractSymId(r)
      if sb == NoSymId: return
      result.b = getVarId(c, sb); result.c = createXint(0'i32)
    ok = true
  else:
    let sa = extractSymId(r)
    if sa != NoSymId:
      result = isNotNil(getVarId(c, sa))
      ok = true
    else:
      return
  for _ in 0 ..< negs:
    negateFact(result)

proc singleStoreArm(arm: Cursor; flag: var SymId; val: var Cursor): bool =
  ## Peek: is `arm` a `(store val flag)` (possibly wrapped in one
  ## `(stmts …)`/`(scope …)`)? Reports the stored value cursor and destination.
  var a = arm
  if a.kind == ParLe and a.stmtKind in {StmtsS, ScopeS}:
    inc a
  if a.njvlKind != StoreV: return false
  inc a          # skip store tag
  val = a
  skip a         # skip value
  let dest = extractSymIdForStore(a)
  if dest == NoSymId: return false
  flag = dest
  result = true

type FlagForm = enum ffNone, ffAnd, ffOr

proc peekFlagLowering(c: var NjvlContext; iteStart: Cursor;
                      flag: var SymId; operand: var Cursor): FlagForm =
  ## Peek an `(ite cond then else)` for the `and`/`or` value lowering. On a match,
  ## report the shared flag temp and the *conditional* operand's cursor (`cond`
  ## for the shared conjunct/disjunct is taken separately by the caller).
  result = ffNone
  var p = iteStart
  inc p               # skip ite tag
  skip p              # skip condition
  var thenFlag, elseFlag: SymId
  var thenVal, elseVal: Cursor
  if not singleStoreArm(p, thenFlag, thenVal): return
  skip p              # skip then arm
  if p.kind == DotToken: return
  if not singleStoreArm(p, elseFlag, elseVal): return
  if thenFlag != elseFlag: return
  flag = thenFlag
  if elseVal.exprKind == FalseX and thenVal.exprKind notin {TrueX, FalseX}:
    operand = thenVal; result = ffAnd
  elif thenVal.exprKind == TrueX and elseVal.exprKind notin {TrueX, FalseX}:
    operand = elseVal; result = ffOr

proc dropCondFlagsMentioning(c: var NjvlContext; v: VarId) =
  ## A store to `v` (or the flag itself) invalidates any flag implication keyed
  ## on it or mentioning it as an operand.
  var kills: seq[SymId] = @[]
  for k, fs in c.condTrue:
    for i in 0 ..< fs.len:
      if fs[i].a == v or fs[i].b == v: kills.add k; break
  for k in kills: c.condTrue.del k
  kills.setLen 0
  for k, fs in c.condFalse:
    for i in 0 ..< fs.len:
      if fs[i].a == v or fs[i].b == v: kills.add k; break
  for k in kills: c.condFalse.del k

proc invalidateCondFlags(c: var NjvlContext; symId: SymId) =
  c.condTrue.del symId
  c.condFalse.del symId
  dropCondFlagsMentioning(c, getVarId(c, symId))

proc materializeCondFlags(c: var NjvlContext; tbl: Table[SymId, Facts]; flag: SymId) =
  ## Inject the facts recorded for `flag` having a known truth value.
  if tbl.hasKey(flag):
    let fs = tbl[flag]
    for i in 0 ..< fs.len:
      let f = fs[i]
      if f.isValid and not (f.a == VarId(0) and f.b == VarId(0)):
        c.facts.add f

proc traverseIte(c: var NjvlContext; n: var Cursor) =
  ## `(ite cond then else)`. Each arm is analyzed under the condition's
  ## polarity; the branch summaries are merged via the Tracker (init/fall-through)
  ## and the facts by liveness — a branch that always leaves drops out of the
  ## merge, unifying guard-clause and if-else style. Facts use the journaled
  ## checkpoint/rollback, so per-frame cost is O(writes), not a whole-set copy.
  let iteStart = n
  inc n # skip ite/itec tag

  # Is the condition a bare bool that carries recorded `and`/`or` flag facts?
  let condSym = extractSymId(n)
  # Does this ite *itself* lower `a and b` / `a or b` into a bool temp?
  var flagSym = NoSymId
  var flagOperand = default(Cursor)
  let flagForm = peekFlagLowering(c, iteStart, flagSym, flagOperand)
  let condCursor = n

  let cp = c.facts.checkpoint()
  let savedBorrowsLen = c.activeBorrows.len
  let condFacts = analyseCondition(c, n)

  # Single-fact conditions can be negated for the else-branch's `assume(¬c)`.
  var condFactsList: seq[LeXplusC] = @[]
  if condFacts == 1:
    condFactsList.add c.facts[c.facts.len - 1]

  # then-branch (under assume(c)):
  var b = splitBranch(c.tr)
  # Testing a lowered `and`/`or` temp: re-inject its recorded conjuncts here so
  # `if a != nil and b != nil: <use a,b>` proves both operands non-nil.
  if condSym != NoSymId: materializeCondFlags(c, c.condTrue, condSym)
  traverseStmt c, n
  let thenLive = c.tr.live
  # snapshot the then-path facts *only* when it falls through (needed for the
  # merge); a leaving branch (the common `ret`/`raise` case) copies nothing.
  let thenFacts = if thenLive: snapshotFacts(c.facts) else: default(Facts)
  commitThen(c.tr, b)
  c.activeBorrows.setLen(savedBorrowsLen)

  # else-branch (under assume(¬c)):
  c.facts.rollbackTo cp
  for f in condFactsList:
    var negated = f
    negateFact(negated)
    c.facts.add negated
  if condSym != NoSymId: materializeCondFlags(c, c.condFalse, condSym)
  if n.kind == DotToken:
    inc n
  else:
    traverseStmt c, n
  let elseLive = c.tr.live
  mergeBranches(c.tr, b)
  c.activeBorrows.setLen(savedBorrowsLen)

  # Post-ite facts survive only along arms that fall through.
  if thenLive and elseLive:
    setFactsTo(c, cp, merge(thenFacts, 0, c.facts, false))
  elif thenLive:
    setFactsTo(c, cp, thenFacts)
  elif not elseLive:
    c.facts.rollbackTo cp           # both arms left — unreachable; reset to base
  # elif elseLive: keep c.facts (the else-path under assume(¬c))

  # If this ite lowered `a and b` / `a or b`, record the flag's conditioned facts
  # for the later `(ite flag ...)`. Sound because the *literal* arm makes one
  # truth value of the flag reachable through a single arm:
  #   `and` (else stores false): flag==true only via the then-arm => both the
  #         shared condition and the operand hold => record on `condTrue`;
  #   `or`  (then stores true):  flag==false only via the else-arm => both
  #         negations hold => record on `condFalse`.
  if flagForm != ffNone:
    invalidateCondFlags(c, flagSym)   # fresh (re)assignment of the flag temp
    var okA = false
    var okB = false
    let factA = pureCondFact(c, condCursor, okA)
    var factB = pureCondFact(c, flagOperand, okB)
    var fs = default(Facts)
    if flagForm == ffAnd:
      if okA: fs.add factA
      if okB: fs.add factB
      if fs.len > 0: c.condTrue[flagSym] = fs
    else: # ffOr: flag==false => ¬condA ∧ ¬operand
      if okA:
        var na = factA; negateFact(na); fs.add na
      if okB:
        negateFact(factB); fs.add factB
      if fs.len > 0: c.condFalse[flagSym] = fs

  skipParRi n

proc traverseLoop(c: var NjvlContext; n: var Cursor) =
  ## `(loop body)` — infinite; the body ends in `(continue .)` and exits
  ## forward via `(jmp loopExit)`. The while-condition is the leading guard
  ## `(ite (not cond) (jmp loopExit) .)` *inside* the body, so it needs no
  ## special handling here. Iteration-gained facts/inits flow only to the
  ## break sites (captured) and to the back-edge (discarded); the loop never
  ## falls through. The `(lab loopExit)` that follows installs the merged
  ## break state via `bindKeyBoth`.
  inc n # skip loop tag
  let cp = c.facts.checkpoint()
  let savedBorrows = c.activeBorrows.len
  traverseStmt c, n        # the body `(stmts ...)`; ends by leaving
  bindKeyBoth(c, contKey()) # the loop header consumes the back-edge
  # The loop never falls through; reset working facts to the pre-loop base. A
  # following `(lab loopExit)` collapses them to "know nothing" (sound: a loop
  # proves nothing about its mutated vars afterwards).
  c.facts.rollbackTo cp
  # Borrows taken *inside* the body are loop-local (a `var p = addr coll[i]`
  # cannot outlive the iteration), so drop them — otherwise a later mutation of
  # the borrowed container after the loop is wrongly seen as still-borrowed.
  c.activeBorrows.setLen(savedBorrows)
  skipParRi n
  # The trailing `(lab loopExit)` (emitted iff a `break`/guard targeted it) is
  # *this* loop's exit. Its facts are the pre-loop set we just rolled back to —
  # a `dirp != nil` established before the loop and never reassigned inside it
  # still holds. Record it so `bindKeyBoth` keeps those facts instead of
  # collapsing the join to "know nothing".
  if n.kind == ParLe and n.njvlKind == LabV:
    var peek = n
    inc peek
    c.loopExitLabels.incl peek.symId

proc traverseLabel(c: var NjvlContext; n: var Cursor) =
  ## `(lab L)` — the multi-join. Every forward `jmp L` has already been seen.
  inc n
  let label = n.symId
  inc n # symdef
  skipParRi n
  bindKeyBoth(c, labelKey(label))

proc traverseJmp(c: var NjvlContext; n: var Cursor) =
  ## `(jmp L)` — a forward structural transfer (loop-`break` included).
  inc n
  let label = n.symId
  inc n # symuse
  skipParRi n
  leaveToLabel(c, label)

proc traverseRet(c: var NjvlContext; n: var Cursor) =
  ## `(ret .X)` — primitive return, bound by the proc root. A `return value`
  ## with a non-`result` operand *provides* the result directly (the NJVL path
  ## rewrote this to `result = value`), so it initializes `result` on this exit.
  inc n
  if n.kind == DotToken:
    inc n
  else:
    let providesResult = c.resultSym != NoSymId and
      not (n.kind == Symbol and n.symId == c.resultSym)
    traverseExpr c, n
    if providesResult:
      markInit(c, c.resultSym)
  skipParRi n
  leaveToReturn(c)

proc traverseRaise(c: var NjvlContext; n: var Cursor) =
  ## `(raise .X)` — primitive raise, bound by the nearest enclosing `except`.
  inc n
  if n.kind == DotToken:
    inc n # bare re-raise
  else:
    traverseExpr c, n
  skipParRi n
  leaveToRaise(c)

proc addCaseFacts(c: var NjvlContext; selSym: SymId; ranges: Cursor) =
  ## Inside an `of` branch the selector is known to lie in `ranges`. When the
  ## branch lists exactly one value/range and the selector is a plain variable,
  ## add the corresponding bound facts (`sel == v`, or `lo <= sel <= hi`).
  if selSym == NoSymId or ranges.substructureKind != RangesU: return
  var r = ranges
  inc r # into 'ranges'
  var cnt = 0
  var first = r
  while r.hasMore:
    inc cnt
    skip r
  if cnt != 1: return # a disjunction of values yields no single bound fact
  let a = getVarId(c, selSym)
  r = first
  if r.substructureKind == RangeU:
    inc r
    if r.kind == IntLit:
      var lo = query(a, VarId(0), createXint(pool.integers[r.intId]))
      c.facts.add lo.geXplusC # sel >= lo
    skip r
    if r.kind == IntLit:
      c.facts.add query(a, VarId(0), createXint(pool.integers[r.intId])) # sel <= hi
  elif r.kind == IntLit:
    var f = query(a, VarId(0), createXint(pool.integers[r.intId]))
    c.facts.add f            # sel <= v
    c.facts.add f.geXplusC   # sel >= v

proc traverseCase(c: var NjvlContext; n: var Cursor) =
  ## `(case selector (of (ranges...) body)+ (else body)?)`. An N-way merge:
  ## every branch starts from the pre-case state, plus the bound facts implied
  ## by its `ranges`; the post-case fall-through is the intersection of the
  ## init-sets (and a fact-join) over the arms that fall through.
  inc n # skip 'case'
  let selCursor = n
  let selSym = extractSymId(selCursor)
  traverseExpr c, n # selector (init-checked)

  # Collect (ranges, body) per branch, walking past the whole case.
  var branches: seq[tuple[ranges, body: Cursor]] = @[]
  while n.substructureKind == OfU:
    inc n          # into 'of'
    let ranges = n
    skip n         # ranges
    branches.add (ranges, n)
    skip n         # body
    skipParRi n    # close 'of'
  if n.substructureKind == ElseU:
    inc n
    branches.add (default(Cursor), n)
    skip n
    skipParRi n
  skipParRi n       # close 'case'

  let cp = c.facts.checkpoint()
  let savedBorrows = c.activeBorrows.len
  let baseState = c.tr.state
  let baseLive = c.tr.live

  var mergedLive = false
  var mergedState = baseState
  var mergedFacts = default(Facts)
  var haveFacts = false

  for br in branches:
    # Each branch resumes from the pre-case state (the selector chose this arm).
    c.tr.state = baseState
    c.tr.live = baseLive
    c.facts.rollbackTo cp
    c.activeBorrows.setLen(savedBorrows)
    if not cursorIsNil(br.ranges):
      addCaseFacts(c, selSym, br.ranges)
    var bc = br.body
    traverseStmt c, bc
    if c.tr.live:
      if not haveFacts:
        mergedState = c.tr.state; mergedFacts = snapshotFacts(c.facts); haveFacts = true
      else:
        mergedState = isectInits(mergedState, c.tr.state)
        mergedFacts = merge(mergedFacts, 0, c.facts, false)
      mergedLive = true

  # A case with no `else` is exhaustive (sem guarantees this), so the selector
  # always matches some branch — there is no implicit fall-through to add.
  c.tr.state = mergedState
  c.tr.live = mergedLive
  if haveFacts: setFactsTo(c, cp, mergedFacts) else: c.facts.rollbackTo cp
  c.activeBorrows.setLen(savedBorrows)

proc traverseTry(c: var NjvlContext; n: var Cursor) =
  ## `(try body (except ...)* (fin ...)?)`. Conservative: an `except` handler
  ## may run after *any* point of the body, so it can only assume the pre-try
  ## state; a `fin` is analyzed on the merged fall-through (its inits are not
  ## propagated onto exit paths — sound, since that only withholds knowledge).
  inc n # skip 'try'
  let cp = c.facts.checkpoint()
  let savedBorrows = c.activeBorrows.len
  let baseState = c.tr.state
  let baseLive = c.tr.live

  traverseStmt c, n # try body

  var mergedLive = c.tr.live
  var mergedState = c.tr.state
  var mergedFacts = if c.tr.live: snapshotFacts(c.facts) else: default(Facts)
  var haveFacts = c.tr.live

  if n.substructureKind == ExceptU:
    # The excepts catch the body's raises.
    discard takeRaise(c.tr)

  while n.substructureKind == ExceptU:
    inc n # into 'except'
    var boundExc = NoSymId
    while n.hasMore and n.stmtKind notin {StmtsS, ScopeS}:
      if isLocal(n.symKind):
        let local = asLocal(n)
        c.typeCache.registerLocal(local.name.symId, n.symKind, local.typ)
        boundExc = local.name.symId
      skip n
    # handler entry = pre-try state (a raise may interrupt the body anywhere):
    c.tr.state = baseState
    c.tr.live = baseLive
    c.facts.rollbackTo cp
    c.activeBorrows.setLen(savedBorrows)
    # The bound exception value is initialized *in the handler* — mark it after
    # resetting to the pre-try state, which would otherwise discard the init.
    if boundExc != NoSymId:
      markInit(c, boundExc)
    if n.stmtKind in {StmtsS, ScopeS}:
      traverseStmt c, n
    if c.tr.live:
      if not haveFacts:
        mergedState = c.tr.state; mergedFacts = snapshotFacts(c.facts); haveFacts = true
      else:
        mergedState = isectInits(mergedState, c.tr.state)
        mergedFacts = merge(mergedFacts, 0, c.facts, false)
      mergedLive = true
    skipParRi n # close 'except'

  c.tr.state = mergedState
  c.tr.live = mergedLive
  if haveFacts: setFactsTo(c, cp, mergedFacts) else: c.facts.rollbackTo cp
  c.activeBorrows.setLen(savedBorrows)

  if n.substructureKind == FinU:
    inc n
    traverseStmt c, n # finally body, on the merged fall-through
    skipParRi n
  skipParRi n # close 'try'

proc traverseLocal(c: var NjvlContext; n: var Cursor) =
  let kind = n.symKind
  inc n
  let name = n.symId
  skip n # name
  skip n # export marker
  let skipInitCheck = hasPragma(n, NoinitP)
  let isInline = hasPragma(n, InlineP)
  skip n # pragmas
  c.typeCache.registerLocal(name, kind, n)
  let localType = n
  skip n # type
  if n.kind != DotToken or skipInitCheck:
    markInit(c, name)
  if kind == ResultY:
    c.resultSym = name
  if isInline:
    c.inlineVars[name] = n
  # Detect borrow: (haddr X) as init expression starts a borrow.
  # Validate that the path is borrowable (no deref in the middle, no calls).
  # Explicit `addr` in the path is an escape hatch ("unchecked").
  if n.kind == ParLe and n.exprKind == HaddrX:
    var inner = n
    inc inner # skip haddr tag
    var path = extractPath(c, inner)
    if path.mode in {IsBorrowable, IsBorrowableFromGlobal}:
      path.borrower = name
      c.activeBorrows.add path
    elif path.mode == NotBorrowable:
      buildErr c, n.info, "cannot borrow from '" & asNimCode(inner) &
        "': path is not borrowable; use 'addr' to override or a temporary move"
  if n.kind != DotToken and localType.typeKind in {PtrT, RefT, CstringT, PointerT, ProctypeT}:
    checkNilMatch c, n, localType
  if n.kind != DotToken:
    checkRangeAssign c, localType, n
  traverseExpr c, n
  skipParRi n
  # The local now holds a value proven to be within its range (if any), so
  # record that for downstream obligations that reference this symbol.
  seedRangeFacts c, name, localType

proc traverseAssume(c: var NjvlContext; n: var Cursor) =
  inc n
  var wasEquality = false
  let fact = translateCond(c, n, wasEquality)
  if not fact.isValid:
    error "invalid assume: ", n
  else:
    c.facts.add fact
    if wasEquality:
      c.facts.add fact.geXplusC
  skipParRi n

proc traverseAssert(c: var NjvlContext; n: var Cursor) =
  let orig = n
  inc n
  var report = false
  var shouldError = false
  if n.pragmaKind == ReportP:
    report = true
    inc n
    skipParRi n
  if n.pragmaKind == ErrorP:
    shouldError = true
    inc n
    skipParRi n

  var wasEquality = false
  let fact = translateCond(c, n, wasEquality)
  if not fact.isValid:
    error "invalid assert: ", orig
  elif implies(c.facts, fact):
    if shouldError:
      contractViolation(c, orig, fact, report)
    elif wasEquality:
      if implies(c.facts, fact.geXplusC):
        if report: echo "OK ", $fact
      else:
        if shouldError:
          if report: echo "OK (could indeed not prove) ", $fact
        else:
          contractViolation(c, orig, fact, report)
    else:
      if report: echo "OK ", $fact
  else:
    if shouldError:
      if report: echo "OK (could indeed not prove) ", $fact
    else:
      contractViolation(c, orig, fact, report)
  skipParRi n

proc traverseProc(c: var NjvlContext; n: var Cursor) =
  let decl = n
  # Fresh, journaling fact set for this proc; the enclosing proc's facts (with
  # its live checkpoints) are restored on the way out.
  let oldFacts = move c.facts
  c.facts = createFacts()
  c.facts.enableJournaling()
  c.procCanRaise = false
  let oldTr = move c.tr
  c.tr = newInitTracker()
  # Seed with the enclosing init-set ONLY for genuinely nested procs (closures),
  # so a captured outer local stays initialized inside the closure body. A
  # top-level proc must NOT inherit the whole module-level init-set: those syms
  # are globals/consts that are never init-checked, and carrying them makes the
  # tracker's per-branch copies O(module) — which blows up on deeply-nested
  # `if/elif` chains. `nestedProcs >= 2` means "inside another proc's body".
  if c.nestedProcs >= 2:
    c.tr.state = oldTr.state
  let oldResultSym = c.resultSym
  let oldInlineVars = move c.inlineVars
  let oldBorrows = move c.activeBorrows
  # Labels and lowered `and`/`or` temps are proc-local; start each proc fresh.
  let oldLabelFacts = move c.labelFacts
  let oldCondTrue = move c.condTrue
  let oldCondFalse = move c.condFalse
  c.labelFacts = initTable[SymId, Facts]()
  c.condTrue = initTable[SymId, Facts]()
  c.condFalse = initTable[SymId, Facts]()
  let oldProcStart = c.currentProcStart
  c.currentProcStart = decl
  c.resultSym = NoSymId
  inc n
  let symId = n.symId
  var isGeneric = false
  var isExternProc = false
  var outParams: seq[SymId] = @[]
  for i in 0 ..< BodyPos:
    if i == ProcPragmasPos:
      c.procCanRaise = hasPragma(n, RaisesP)
      isExternProc = hasPragma(n, ImportcP) or hasPragma(n, ImportcppP)
    elif i == TypevarsPos:
      isGeneric = n.substructureKind == TypevarsU
    elif i == ParamsPos:
      if n.kind == ParLe:
        var p = n
        inc p
        while p.hasMore:
          let r = takeLocal(p, SkipFinalParRi)
          c.typeCache.registerLocal(r.name.symId, ParamY, r.typ)
          if r.typ.typeKind == OutT and not hasPragma(r.pragmas, NoinitP):
            outParams.add r.name.symId
          # A `range[lo..hi]`-typed parameter is known to be within bounds.
          seedRangeFacts c, r.name.symId, r.typ
      c.typeCache.registerLocal(symId, ProcY, decl)
    skip n

  # Analyze body. Generic procs are only checked once instantiated. Extern
  # (importc/importcpp) procs satisfy their contract at the C level and have no
  # meaningful Nim body — and the lowered body of an extern func with a doc /
  # `runnableExamples` body still ends in an implicit `(ret result)` that reads
  # the never-initialized `result`, so we must skip the *traversal*, not merely
  # the final init check.
  if not isGeneric and not isExternProc:
    traverseStmt c, n
    # Join every `return` into the natural fall-through: the result init-set at
    # proc exit is the intersection over all exit paths. The init-check below
    # then reads `c.tr.state` directly — `result`/out-params must be init on
    # every path that leaves the proc.
    bindKeyBoth(c, retKey())
    let info = decl.info
    # Only when control can actually leave the proc *normally* (fall-through or a
    # `return`) must `result`/out-params be initialized. A proc whose every path
    # raises or otherwise never returns (`c.tr.live == false` here) has no normal
    # exit, so the init obligation is vacuous — e.g. `proc f: string = raise X`.
    if c.tr.live:
      if c.resultSym != NoSymId and not isInitialized(c, c.resultSym):
        buildErr c, info, "cannot prove that " & userSymName(pool.syms[c.resultSym]) & " has been initialized"
      for sym in outParams:
        if not isInitialized(c, sym):
          buildErr c, info, "cannot prove that " & userSymName(pool.syms[sym]) & " has been initialized"
  else:
    skip n
  skipParRi n
  c.tr = ensureMove oldTr
  c.facts = ensureMove oldFacts
  c.resultSym = oldResultSym
  c.inlineVars = ensureMove oldInlineVars
  c.activeBorrows = ensureMove oldBorrows
  c.labelFacts = ensureMove oldLabelFacts
  c.condTrue = ensureMove oldCondTrue
  c.condFalse = ensureMove oldCondFalse
  c.currentProcStart = oldProcStart

proc traverseStmt(c: var NjvlContext; n: var Cursor) =
  case n.njvlKind
  of IteV, ItecV:
    traverseIte c, n
  of LoopV:
    traverseLoop c, n
  of StoreV:
    traverseStore c, n
  of AssumeV:
    traverseAssume c, n
  of AssertV:
    traverseAssert c, n
  of LabV:
    traverseLabel c, n
  of JmpV:
    traverseJmp c, n
  of MflagV, VflagV:
    # A control-flow flag declaration may still arrive from xelim; the bool
    # storage is harmless. Register it so its later use is not flagged.
    inc n
    let s = n.symId
    skip n # symdef
    skipParRi n
    markInit(c, s)
  of JtrueV:
    # Final IR has no `jtrue`; if one survives from xelim, it is inert here.
    skip n
  of KillV:
    # Variable going out of scope - end any active borrows
    n.into:
      while n.hasMore:
        let s = extractSymId(n)
        if s != NoSymId:
          endBorrow(c, s)
        skip n
  of UnknownV:
    # Unknown instruction - variable's contents become unknown after a call.
    # Check borrow conflicts: passing a borrowed path to a var param is a mutation.
    inc n
    let unknownPath = extractPath(c, n)
    if unknownPath.mode in {IsBorrowable, IsBorrowableFromGlobal}:
      checkBorrowConflict(c, unknownPath, n.info)
    skip n # the unknown location
    skipParRi n
  of ContinueV:
    # The loop back-edge.
    skip n
    leaveToContinue(c)
  of VV:
    # Versioned variable reference - should not appear as statement
    skip n
  of EtupatV:
    traverseExpr c, n
  of NoVTag:
    case n.stmtKind
    of StmtsS, ScopeS, BlockS:
      n.into:
        while n.hasMore:
          traverseStmt c, n
    of CaseS:
      traverseCase c, n
    of TryS:
      traverseTry c, n
    of RetS:
      traverseRet c, n
    of RaiseS:
      traverseRaise c, n
    of LocalDecls:
      traverseLocal c, n
    of ProcS, FuncS, IteratorS, ConverterS, MethodS, MacroS:
      # Nested routine - analyze and advance past it
      c.typeCache.openScope()
      inc c.nestedProcs
      traverseProc c, n
      dec c.nestedProcs
      c.typeCache.closeScope()
    of TemplateS, TypeS, CommentS, PragmasS:
      skip n
    of CallKindsS:
      analyseCall c, n
    of DiscardS, YldS:
      inc n
      traverseExpr c, n
      skipParRi n
    of EmitS, InclS, ExclS:
      skip n
    of PragmaxS:
      inc n
      skip n # pragmas
      while n.hasMore:
        traverseStmt c, n
      skipParRi n
    of NoStmt:
      if n.exprKind in CallKinds:
        analyseCall c, n
      elif n.exprKind == PragmaxX:
        inc n
        skip n
        traverseStmt c, n
        skipParRi n
      elif n.exprKind in {DestroyX, CopyX, WasmovedX, SinkhX, TraceX}:
        inc n
        traverseExpr c, n
        while n.hasMore:
          traverseExpr c, n
        skipParRi n
      else:
        traverseExpr c, n
    else:
      # Unknown statement - try to traverse children
      inc n
      var nested = 1
      while nested > 0:
        case n.kind
        of ParLe:
          inc nested
          inc n
        of ParRi:
          dec nested
          inc n
        else:
          inc n

proc traverseToplevel(c: var NjvlContext; n: var Cursor) =
  case n.stmtKind
  of StmtsS:
    n.into:
      while n.hasMore:
        traverseToplevel c, n
  of PragmaxS:
    inc n
    skip n # pragmas
    # A pragma block (e.g. `{.cast(uncheckedAccess).}:`) carries a whole body,
    # not a single statement — traverse every child before closing, as the
    # non-toplevel `traverseStmt` already does. Consuming only one left the
    # cursor on the next statement and tripped `skipParRi`.
    while n.hasMore:
      traverseToplevel c, n
    skipParRi n
  of ProcS, FuncS, IteratorS, ConverterS, MethodS:
    inc c.nestedProcs
    traverseProc c, n
    dec c.nestedProcs
  of MacroS, TemplateS, TypeS, CommentS, PragmasS,
     ImportasS, ExportexceptS, BindS, MixinS, UsingS,
     ExportS,
     IncludeS, ImportS, FromimportS, ImportexceptS:
    skip n
  else:
    # Toplevel statements - analyze them
    traverseStmt c, n

proc lowerToFinalIr(input: var TokenBuf; moduleSuffix: string): TokenBuf =
  ## Run the Final-IR lowering (`finalir.nim`, which itself runs xelim first).
  var n = beginRead(input)
  var buf = createTokenBuf(input.len)
  buf.addSubtree n
  endRead input
  var pass = initPass(move buf, moduleSuffix, "xelim_finalir", 0)
  toFinalIr(pass)
  result = ensureMove pass.dest

proc analyzeContractsFinalIr*(input: var TokenBuf; moduleSuffix: string;
                             verbose = false; rangeChecks = true): TokenBuf =
  ## Main entry point: lowers `input` to the Final IR and analyzes contracts.
  ## When `verbose` is true, every contract/init failure dumps the enclosing
  ## proc's IR to stderr to aid debugging. When `rangeChecks` is true the
  ## RangeCheck runtime mode is active, so unprovable range conversions defer to
  ## the runtime `nimIRcheck` instead of failing to compile.
  var finalBuf = lowerToFinalIr(input, moduleSuffix)

  var c = NjvlContext(
    typeCache: createTypeCache(),
    moduleSuffix: moduleSuffix,
    tr: newInitTracker(),
    loopExitLabels: initHashSet[SymId](),
    labelFacts: initTable[SymId, Facts](),
    condTrue: initTable[SymId, Facts](),
    condFalse: initTable[SymId, Facts](),
    facts: createFacts(),
    verbose: verbose,
    rangeChecks: rangeChecks
  )
  c.facts.enableJournaling()
  c.typeCache.openScope()

  var fin = beginRead(finalBuf)
  traverseToplevel c, fin
  endRead finalBuf

  c.typeCache.closeScope()
  result = ensureMove c.errors

when isMainModule:
  import std / [syncio, os]
  proc main(infile: string) =
    var input = parseFromFile(infile)
    discard analyzeContractsFinalIr(input, "main")

  main(paramStr(1))
