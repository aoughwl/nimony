#
#
#           Hexer Compiler
#        (c) Copyright 2025 Andreas Rumpf
#
#    See the file "license.txt", included in this
#    distribution, for details about the copyright.
#

##[

The lifter "lifts" a hook like `=destroy` or `=copy` from type `T`
to type `(T, T)`, etc.

]##

import std/[assertions, tables, hashes, strutils, syncio]

when defined(nimony):
  {.feature: "lenientnils".}
include ".." / lib / nifprelude
include ".." / lib / compat2
import ".." / lib / [nifindexes, symparser, treemangler]
import ".." / nimony / [nimony_model, decls, programs, typenav, expreval, xints, builtintypes, typekeys, typeprops]

proc isMutFirstParam*(destroyProc: SymId): bool =
  result = false
  let res = tryLoadSym(destroyProc)
  if res.status == LacksNothing:
    let routine = asRoutine(res.decl)
    var params = routine.params
    inc params
    let firstParam = asLocal(params)
    if firstParam.typ.typeKind in {MutT, OutT}:
      result = true

type
  TypeCursor = Cursor

  GenHookRequest = object
    sym: SymId
    typ: TypeCursor
    op: AttachedOp
    gcBox: int ## 0: ordinary hook; 1: aowlgc box tracer; 2: aowlgc box finalizer

  LiftingCtx* = object
    dest*: TokenBuf
    op: AttachedOp
    routineKind: SymKind
    calledErrorHook: PackedLineInfo
    info: PackedLineInfo
    requests: seq[GenHookRequest]
    structuralTypeToHook: array[AttachedOp, Table[string, SymId]]
    nominalTypeToHook: array[AttachedOp, Table[SymId, SymId]]
    hookNames: Table[string, int]
    thisModuleSuffix: string
    bits*: int
    frontendHooks*: ptr Table[SymId, HooksPerType] # hooks from frontend, not yet in type pragmas
    gcBoxHooks: array[2, Table[string, SymId]] # aowlgc: per allocated ref type: tracer, finalizer
    gcBoxTypes: seq[TokenBuf] # aowlgc: owned copies of the requested ref types (cursor lifetime)

var aowlgcMode* = false
  ## `-d:aowlgc`: refs live in the tracing heap. A `ref` is then trivial for
  ## every hook but `=trace` (no refcounting, destroy never frees a target),
  ## and `=trace` of a ref marks its target. Set by hexer (`AowlGc` in the
  ## check flags) and by nimsem's derefs pass (`defined(aowlgc)`), which lift
  ## hooks for nominal types in the frontend and must agree with hexer.

# Phase 1: Determine if the =hook is trivial:

when not defined(nimony):
  proc isTrivial*(c: var LiftingCtx; typ: TypeCursor): bool

proc isGenericHook(hookSym: SymId): bool =
  ## Check if a hook is generic (has type parameters)
  let res = tryLoadSym(hookSym)
  if res.status == LacksNothing:
    let r = asRoutine(res.decl)
    result = r.typevars.substructureKind == TypevarsU
  else:
    result = false

proc loadHook(c: var LiftingCtx; op: AttachedOp; s: SymId): SymId =
  result = c.nominalTypeToHook[op].getOrDefault(s)
  if result == SymId(0):
    # Check frontend hooks first (for current module during derefs pass)
    if c.frontendHooks != nil and c.frontendHooks[].hasKey(s):
      result = c.frontendHooks[].getOrQuit(s).a[op]
    if result == SymId(0):
      result = tryLoadHook(op, s)
    if result != SymId(0):
      # Filter out generic hooks - they need instantiation first
      if isGenericHook(result):
        result = SymId(0)
      else:
        c.nominalTypeToHook[op][s] = result

proc hasDestroyHook*(c: var LiftingCtx; typ: TypeCursor): bool =
  ## Specifically checks whether `typ` has a `=destroy` hook reachable.
  ## Unlike `isTrivial`, this does NOT depend on the lifter's current
  ## `c.op` (which floats with each `getHook` call), so it is safe to
  ## call from the duplifier mid-pass without risk of misclassifying
  ## types that define `=destroy` but no `=dup`/`=copy` (e.g. TokenBuf).
  if typ.kind == Symbol:
    let s = typ.symId
    if c.nominalTypeToHook[attachedDestroy].hasKey(s):
      return true
    if c.frontendHooks != nil and c.frontendHooks[].hasKey(s):
      if c.frontendHooks[].getOrQuit(s).a[attachedDestroy] != SymId(0):
        return true
    if tryLoadHook(attachedDestroy, s) != SymId(0):
      return true
    let saved = c.op
    c.op = attachedDestroy
    result = not isTrivial(c, typ)
    c.op = saved
  else:
    let saved = c.op
    c.op = attachedDestroy
    result = not isTrivial(c, typ)
    c.op = saved

proc lookupHookSym(c: var LiftingCtx; op: AttachedOp; s: SymId): SymId =
  result = SymId(0)
  if c.frontendHooks != nil and c.frontendHooks[].hasKey(s):
    result = c.frontendHooks[].getOrQuit(s).a[op]
  if result == SymId(0):
    result = tryLoadHook(op, s)

proc isErrorHook(s: SymId): bool =
  if s == SymId(0): return false
  let res = tryLoadSym(s)
  if res.status == LacksNothing:
    let r = asRoutine(res.decl)
    return hasPragma(r.pragmas, ErrorP)
  return false

proc hasHook(c: var LiftingCtx; s: SymId): bool =
  result = c.nominalTypeToHook[c.op].hasKey(s) or
           lookupHookSym(c, c.op, s) != SymId(0)
  if not result and c.op in {attachedCopy, attachedDup}:
    # The sibling hook (`=copy` ↔ `=dup`) being `.error` means the user
    # forbade copying. Treat the type as non-trivial so the lifter
    # synthesizes a hook for `c.op` and `genProcDecl`'s sibling check
    # propagates `.error` into it. Without this, a type with only field-
    # trivial layout and only `.error =copy` would silently bit-copy
    # through assignment.
    let siblingOp = if c.op == attachedCopy: attachedDup else: attachedCopy
    result = isErrorHook(lookupHookSym(c, siblingOp, s))

proc siblingHookErrorInfo(c: var LiftingCtx; typ: TypeCursor;
                          siblingOp: AttachedOp): PackedLineInfo =
  ## Returns the sibling `=copy`/`=dup` hook's `name.info` if it is marked
  ## `.error` for the (nominal) type `typ`. Otherwise `NoLineInfo`.
  result = NoLineInfo
  if typ.kind notin {Symbol, SymbolDef}:
    return
  let siblingSym = lookupHookSym(c, siblingOp, typ.symId)
  if not isErrorHook(siblingSym):
    return
  let res = tryLoadSym(siblingSym)
  let r = asRoutine(res.decl)
  result = r.name.info

proc getCompilerProc(c: var LiftingCtx; name: string): SymId =
  result = pool.syms.getOrIncl(name & ".0." & SystemModuleSuffix)

proc isTrivialForFields(c: var LiftingCtx; n: Cursor): bool =
  var n = n
  var iter = initObjFieldIter()
  while nextField(iter, n):
    let field = takeLocal(n, SkipFinalParRi)
    if field.kind in {FldY, GfldY}:
      # `{.cursor.}` fields are non-owning aliases — they're trivially
      # bit-copied/discarded by the auto-derived hooks (see
      # `unravelObjField`). Treat them as trivial here so an object
      # whose only destructor-relevant field is `{.cursor.}` doesn't
      # need a non-empty `=destroy`/`=wasMoved` synthesised for it —
      # which would trip the "empty hook created" assertion in
      # `genProcDecl`.
      if hasPragma(field.pragmas, CursorP):
        continue
      if not isTrivial(c, field.typ):
        return false
    else:
      skip n
  return true

proc isTrivialObjectBody(c: var LiftingCtx; body: Cursor): bool =
  var n = body
  if n.typeKind in {RefT, PtrT}:
    inc n
  inc n # skip `(object` token

  var baseType = n
  if baseType.typeKind in {RefT, PtrT}:
    inc baseType
  skip n # skip basetype
  if n.kind != DotToken:
    result = isTrivialForFields(c, n)
  else:
    result = true
  if result:
    if baseType.kind == DotToken:
      result = true
    else:
      result = isTrivial(c, baseType)

proc isTrivialTypeDecl(c: var LiftingCtx; n: Cursor): bool =
  let r = asTypeDecl(n)
  assert(not r.isGeneric)
  case r.body.typeKind
  of PtrT:
    result = true
  of RefT:
    result = aowlgcMode and c.op != attachedTrace
  of ObjectT:
    result = isTrivialObjectBody(c, r.body)
    if result and c.op == attachedWasMoved and hasRtti(r.pragmas):
      # We set the RTTI field in `=wasMoved` so objects with a vtable are not trivial.
      result = false
  of DistinctT:
    # A `distinct T` with no hooks of its own inherits the triviality of its
    # base type: `distinct string` is non-trivial (it owns the same heap
    # buffer) and needs the base type's `=destroy`/`=dup`. Without this the
    # `else` branch below treated every named distinct as trivial, so the
    # duplifier moved instead of copied — a use-after-free for resource types.
    result = isTrivial(c, r.body.firstSon)
  else:
    result = true

proc isTrivial*(c: var LiftingCtx; typ: TypeCursor): bool =
  if typ.kind == Symbol:
    let res = tryLoadSym(typ.symId)
    if res.status == LacksNothing:
      if hasHook(c, typ.symId): return false
      return isTrivialTypeDecl(c, res.decl)
    else:
      bug "could not load: " & pool.syms[typ.symId]

  case typ.typeKind
  of IntT, UIntT, FloatT, BoolT, CharT, PtrT,
     MutT, OutT, SetT,
     EnumT, HoleyEnumT, AnumT, VoidT, AutoT, SymkindT,
     CstringT, PointerT, OrdinalT,
     UarrayT, VarargsT, RangetypeT, TypedescT,
     RoutineTypes:
    # ItertypeT (part of RoutineTypes) is currently lowered to an opaque
    # pointer (see nifcgen.trType), so trivial. When we promote
    # `Iterator[T]` to a managed ref envelope, ItertypeT needs to split out
    # of this branch and flip to `result = false` so destructor hooks run.
    result = true
  of RefT:
    # aowlgc: a ref is a plain (traced) pointer; only =trace has work to do.
    result = aowlgcMode and c.op != attachedTrace
  of LentT:
    result = true # lent types are borrowed; no hooks needed
  of SinkT, ArrayT:
    result = isTrivial(c, typ.firstSon)
  of ObjectT:
    result = isTrivialObjectBody(c, typ)
  of TupleT:
    var tup = typ
    inc tup
    while tup.hasMore:
      let field = getTupleFieldType(tup)
      if not isTrivial(c, field):
        return false
      skip tup
    result = true
  of NoType, ErrT, NiltT, OrT, AndT, NotT, ConceptT, DistinctT, StaticT, InvokeT,
     TypekindT, UntypedT, TypedT:
    echo "isTrivial: ", toString(typ, false)
    bug "bug in isTrival computation"

# Phase 2: Do the lifting

proc genCallHook(c: var LiftingCtx; s: SymId; paramA, paramB: TokenBuf; forceStatic = false) =
  # forceStatic=true generates (proccall fn args...) for static dispatch;
  # otherwise generates (call fn args...)
  let callKind = if forceStatic: ProccallX else: CallX
  copyIntoKind c.dest, callKind, c.info:
    copyIntoSymUse c.dest, s, c.info
    case c.op
    of attachedWasMoved:
      if paramA[0].kind == Symbol:
        # &*param cancel out to `param`:
        copyTree c.dest, paramA
      else:
        copyIntoKind c.dest, HaddrX, c.info:
          copyTree c.dest, paramA
    of attachedDestroy:
      if isMutFirstParam(s):
        copyIntoKind c.dest, HaddrX, c.info:
          copyTree c.dest, paramA
      else:
        copyTree c.dest, paramA
    of attachedDup:
      copyTree c.dest, paramB
    of attachedTrace:
      if paramA[0].kind == Symbol:
        # &*param cancel out to `param`:
        copyTree c.dest, paramA
      else:
        copyIntoKind c.dest, HaddrX, c.info:
          copyTree c.dest, paramA
      copyTree c.dest, paramB
    of attachedCopy, attachedSink:
      copyTree c.dest, paramA
      copyTree c.dest, paramB

proc genTrivialOp(c: var LiftingCtx; paramA, paramB: TokenBuf) =
  case c.op
  of attachedDestroy, attachedWasMoved: discard
  of attachedCopy, attachedSink, attachedDup:
    copyIntoKind c.dest, AsgnS, c.info:
      copyTree c.dest, paramA
      copyTree c.dest, paramB
  of attachedTrace: discard

proc generateHookName(c: var LiftingCtx; op: AttachedOp; key: string): string =
  result = "=" & hookName(op) & "_" & key
  var counter = addr c.hookNames.mgetOrPut(result, -1)
  counter[] += 1
  result.add '.'
  result.addInt counter[]
  result.add '.'
  result.add c.thisModuleSuffix

proc requestLifting(c: var LiftingCtx; op: AttachedOp; t: TypeCursor): SymId =
  if t.kind in {Symbol, SymbolDef}:
    result = loadHook(c, op, t.symId)
    if result != SymId(0):
      return result

  let key = mangle(t, Frontend, c.bits)
  result = c.structuralTypeToHook[op].getOrDefault(key)
  if result == SymId(0):
    let name = generateHookName(c, op, key)
    result = pool.syms.getOrIncl(name)
    # Check if this hook already exists (e.g., generated by frontend)
    let existing = tryLoadSym(result)
    if existing.status == LacksNothing:
      # Hook already exists, don't regenerate
      c.structuralTypeToHook[op][key] = result
    else:
      c.requests.add GenHookRequest(sym: result, typ: t, op: op)
      c.structuralTypeToHook[op][key] = result

proc maybeCallHook(c: var LiftingCtx; s: SymId; paramA, paramB: TokenBuf; forceStatic = false) =
  ## forceStatic=true generates static dispatch for parent hook calls
  if s != NoSymId:
    let res = tryLoadSym(s)
    if res.status == LacksNothing:
      let r = asRoutine(res.decl)
      if hasPragma(r.pragmas, ErrorP):
        c.calledErrorHook = r.name.info
    if c.op == attachedDup:
      copyIntoKind c.dest, AsgnS, c.info:
        copyTree c.dest, paramA
        genCallHook c, s, paramA, paramB, forceStatic
    else:
      genCallHook c, s, paramA, paramB, forceStatic

proc lift(c: var LiftingCtx; typ: TypeCursor): SymId =
  # Goal: We produce a call to some function. Maybe this function must be
  # synthesized, if so this will be done by calling `requestLifting`.
  if isTrivial(c, typ):
    return NoSymId

  # Speculative `.error` propagation: when the *current* hook being
  # generated is `=copy` or `=dup`, and the sub-type's sibling is `.error`,
  # the sub-hook will end up `.error` once it is generated. The sub-hook
  # may not exist yet (it's only just been queued), so `maybeCallHook`'s
  # pragma check on the sym would miss it. Look at the sub-type's sibling
  # here and propagate `.error` into the *enclosing* hook now.
  if c.op in {attachedCopy, attachedDup} and c.calledErrorHook == NoLineInfo:
    let siblingOp = if c.op == attachedCopy: attachedDup else: attachedCopy
    let info = siblingHookErrorInfo(c, typ, siblingOp)
    if info != NoLineInfo:
      c.calledErrorHook = info

  let orig = typ
  let typ = toTypeImpl typ
  case typ.typeKind
  of PtrT:
    bug "ptr T should have been a 'trivial' type"
  of ObjectT, DistinctT, TupleT, ArrayT, RefT:
    result = requestLifting(c, c.op, orig)
  else:
    result = NoSymId

when not defined(nimony):
  proc unravel(c: var LiftingCtx; typ: TypeCursor; paramA, paramB: TokenBuf)

proc needsDeref(c: var LiftingCtx; obj: TokenBuf; paramPos: int): bool {.inline.} =
  result = (c.op in {attachedTrace, attachedWasMoved} or (c.op in {attachedCopy, attachedSink} and paramPos == 0)) and
    obj[0].kind == Symbol # still access to the parameter directly

proc accessObjField(c: var LiftingCtx; obj: TokenBuf; name: Cursor; paramPos = 0; depth = 0): TokenBuf =
  assert name.kind == SymbolDef
  let nameSym = name.symId
  result = createTokenBuf(4)
  let nd = needsDeref(c, obj, paramPos)
  copyIntoKind(result, DotX, c.info):
    if nd:
      result.addParLe HderefX, c.info
    copyTree result, obj
    if nd:
      result.addParRi()
    copyIntoSymUse result, nameSym, c.info
    result.addIntLit(depth, c.info)

proc accessTupField(c: var LiftingCtx; tup: TokenBuf; idx: int; paramPos = 0): TokenBuf =
  result = createTokenBuf(4)
  let nd = needsDeref(c, tup, paramPos)
  copyIntoKind(result, TupatX, c.info):
    if nd:
      copyIntoKind(result, HderefX, c.info):
        copyTree result, tup
    else:
      copyTree result, tup
    result.add intToken(pool.integers.getOrIncl(idx), c.info)

proc unravelObjField(c: var LiftingCtx; n: var Cursor; paramA, paramB: TokenBuf; depth: int) =
  let r = takeLocal(n, SkipFinalParRi)
  assert r.kind in {FldY, GfldY}
  # create `paramA.field` because we need to do `paramA.field = paramB.field` etc.
  let fieldType = r.typ
  # `.cursor` fields are non-owning. They participate in the lifecycle
  # hooks like a trivial (bit-copy) value: no recursive destroy/trace,
  # no RC bump on copy/dup. See doc/borrowchecking.md.
  let isCursor = hasPragma(r.pragmas, CursorP)
  case c.op
  of attachedDestroy, attachedTrace, attachedWasMoved:
    let a = accessObjField(c, paramA, r.name, depth = depth)
    if isCursor:
      genTrivialOp c, a, paramB
    else:
      unravel c, fieldType, a, paramB
  of attachedCopy, attachedSink, attachedDup:
    let a = accessObjField(c, paramA, r.name, 0, depth = depth)
    let b = accessObjField(c, paramB, r.name, 1, depth = depth)
    if isCursor:
      genTrivialOp c, a, b
    else:
      unravel c, fieldType, a, b

proc unravelObjFieldsForward(c: var LiftingCtx; n: var Cursor; paramA, paramB: TokenBuf; depth: int) =
  while n.hasMore:
    case n.substructureKind
    of CaseU:
      # XXX for now counts each case object field as separate
      if c.op in {attachedCopy, attachedSink}:
        # TODO: `=copy` needs to be special cased like in Nim
        var nCopy = n
        let prevOp = c.op
        c.op = attachedDestroy
        unravelObjFieldsForward(c, nCopy, paramA, paramB, depth)
        c.op = prevOp
      let info = n.info
      inc n
      var selector = n
      if c.op != attachedDestroy:
        # copy the selector before case stmt, but destroy after case stmt
        unravelObjField c, selector, paramA, paramB, depth

      c.dest.addParLe CaseU, info

      var selectorField = takeLocal(n, SkipFinalParRi)
      let dest = accessObjField(c, paramA, selectorField.name)
      c.dest.add dest

      while n.hasMore:
        case n.substructureKind
        of OfU:
          c.dest.takeToken(n)
          c.dest.takeTree(n)
          assert n.stmtKind == StmtsS
          c.dest.takeToken(n)
          unravelObjFieldsForward c, n, paramA, paramB, depth
          takeParRi(c.dest, n)
          takeParRi(c.dest, n)
        of ElseU:
          c.dest.takeToken(n)
          assert n.stmtKind == StmtsS
          c.dest.takeToken(n)
          unravelObjFieldsForward c, n, paramA, paramB, depth
          takeParRi(c.dest, n)
          takeParRi(c.dest, n)
        else:
          error "expected `of` or `else` inside `case`"

      takeParRi(c.dest, n) # end of case

      if c.op == attachedDestroy:
        # destroy the selector after case stmt
        unravelObjField c, selector, paramA, paramB, depth
    of FldU, GfldU:
      unravelObjField c, n, paramA, paramB, depth
    of NilU:
      skip n
    else:
      error "illformed AST inside object: ", n

proc unravelObjFields(c: var LiftingCtx; n: var Cursor; paramA, paramB: TokenBuf; depth: int) =
  if c.op != attachedDestroy:
    unravelObjFieldsForward c, n, paramA, paramB, depth
  else:
    # For destruction, process fields in reverse declaration order.
    # Collect field cursor positions first, then process in reverse.
    var fieldPositions: seq[Cursor] = @[]
    var scan = n
    while scan.hasMore:
      case scan.substructureKind
      of CaseU, FldU, GfldU:
        fieldPositions.add scan
        skip scan
      of NilU:
        skip scan
      else:
        error "illformed AST inside object: ", scan
    for i in countdown(fieldPositions.high, 0):
      var cur = fieldPositions[i]
      case cur.substructureKind
      of CaseU:
        unravelObjFieldsForward c, cur, paramA, paramB, depth
      of FldU, GfldU:
        unravelObjField c, cur, paramA, paramB, depth
      else:
        discard
    n = scan

proc baseobjOf(c: var LiftingCtx; typ: Cursor; x: TokenBuf; paramPos = 0): TokenBuf =
  result = createTokenBuf(6)
  # When `x` is a `var T` parameter (a pointer in the backend) it must be
  # dereferenced before taking its base subobject, exactly like field access in
  # `accessObjField`; otherwise codegen emits `x.Q` on a pointer instead of
  # `x->Q`.
  let nd = needsDeref(c, x, paramPos)
  copyIntoKind result, BaseobjX, c.info:
    copyTree result, typ
    result.add intToken(pool.integers.getOrIncl(+1), c.info)
    if nd:
      result.addParLe HderefX, c.info
    copyTree result, x
    if nd:
      result.addParRi()

proc parentParamB(c: var LiftingCtx; parent: Cursor; paramB: TokenBuf): TokenBuf =
  ## The second argument for the parent (base-object) hook call. For the
  ## two-location hooks (`=copy`/`=sink`/`=dup`) the second parameter is also a
  ## `T`, so it gets the same base-object conversion as the first. For `=trace`
  ## the second parameter is the environment *pointer* and must be passed
  ## through unchanged (wrapping it in `(baseobj ...)` would emit a `.Q` field
  ## access on a `void*`); `=destroy`/`=wasMoved` ignore it.
  if c.op in {attachedCopy, attachedSink, attachedDup}:
    result = baseobjOf(c, parent, paramB, paramPos = 1)
  else:
    result = createTokenBuf(paramB.len)
    copyTree result, paramB

proc unravelObj(c: var LiftingCtx; n: Cursor; paramA, paramB: TokenBuf; depth: int) =
  var n = n
  if n.typeKind in {RefT, PtrT}:
    inc n
  assert n.typeKind == ObjectT
  inc n
  # recurse for the inherited object type, if any:
  var parent = n
  var hasParent = n.kind != DotToken
  if hasParent:
    if parent.typeKind in {RefT, PtrT}:
      inc parent

  if hasParent and c.op != attachedDestroy:
    if c.op == attachedWasMoved:
      # this ensures we don't touch the RTTI field and overwrite it
      # with the wrong v-table pointer!
      unravelObj c, toTypeImpl(parent), paramA, paramB, depth+1
    else:
      let fn = lift(c, parent)
      # Use static dispatch for parent calls to avoid infinite recursion with vtable dispatch
      maybeCallHook c, fn, baseobjOf(c, parent, paramA), parentParamB(c, parent, paramB), forceStatic = true

  skip n # inheritance is gone
  unravelObjFields c, n, paramA, paramB, depth

  if hasParent and c.op == attachedDestroy:
    # For destruction, destroy derived fields first, then the base class.
    let fn = lift(c, parent)
    maybeCallHook c, fn, baseobjOf(c, parent, paramA), parentParamB(c, parent, paramB), forceStatic = true

proc unravelTuple(c: var LiftingCtx;
                  n: Cursor; paramA, paramB: TokenBuf) =
  assert n.typeKind == TupleT
  var n = n
  inc n
  var idx = 0
  while n.hasMore:
    let fieldType = getTupleFieldType(n)
    skip n

    case c.op
    of attachedDestroy, attachedTrace, attachedWasMoved:
      let a = accessTupField(c, paramA, idx)
      unravel c, fieldType, a, paramB
    of attachedCopy, attachedSink, attachedDup:
      let a = accessTupField(c, paramA, idx, 0)
      let b = accessTupField(c, paramB, idx, 1)
      unravel c, fieldType, a, b
    inc idx

proc accessArrayAt(c: var LiftingCtx; arr: TokenBuf; indexVar: SymId; paramPos = 0): TokenBuf =
  result = createTokenBuf(4)
  let nd = needsDeref(c, arr, paramPos)
  copyIntoKind result, ArratX, c.info:
    if nd:
      result.addParLe HderefX, c.info
    copyTree result, arr
    if nd:
      result.addParRi()
    copyIntoSymUse result, indexVar, c.info

proc indexVarLowerThanArrayLen(c: var LiftingCtx; indexVar: SymId; arrayLen: xint) =
  copyIntoKind c.dest, LtX, c.info:
    copyIntoKind c.dest, IntT, c.info:
      c.dest.add intToken(pool.integers.getOrIncl(-1), c.info)
    copyIntoSymUse c.dest, indexVar, c.info
    var err = false
    let alen = asSigned(arrayLen, err)
    if not err:
      c.dest.add intToken(pool.integers.getOrIncl(alen), c.info)
    else:
      err = false
      let ualen = asUnsigned(arrayLen, err)
      assert(not err)
      c.dest.add uintToken(pool.uintegers.getOrIncl(ualen), c.info)

proc addIntType(c: var LiftingCtx) =
  copyIntoKind c.dest, IntT, c.info:
    c.dest.add intToken(pool.integers.getOrIncl(-1), c.info)

proc incIndexVar(c: var LiftingCtx; indexVar: SymId) =
  copyIntoKind c.dest, AsgnS, c.info:
    copyIntoSymUse c.dest, indexVar, c.info
    copyIntoKind c.dest, AddX, c.info:
      addIntType c
      copyIntoSymUse c.dest, indexVar, c.info
      c.dest.add intToken(pool.integers.getOrIncl(+1), c.info)

proc declareIndexVar(c: var LiftingCtx; indexVar: SymId) =
  copyIntoKind c.dest, VarY, c.info:
    addSymDef c.dest, indexVar, c.info
    c.dest.addEmpty2 c.info # not exported, no pragmas
    addIntType c
    c.dest.add intToken(pool.integers.getOrIncl(0), c.info)

proc unravelArray(c: var LiftingCtx;
                  n: Cursor; paramA, paramB: TokenBuf) =
  assert n.typeKind == ArrayT
  let arrayLen = getArrayLen(n)
  var n = n
  inc n
  let baseType = n

  let indexVar = pool.syms.getOrIncl("idx.0")
  declareIndexVar c, indexVar

  copyIntoKind c.dest, WhileS, c.info:
    indexVarLowerThanArrayLen c, indexVar, arrayLen
    copyIntoKind c.dest, StmtsS, c.info:
      case c.op
      of attachedDestroy, attachedTrace, attachedWasMoved:
        let a = accessArrayAt(c, paramA, indexVar)
        #unravel c, fieldType, fieldType, a, paramB
        let fn = lift(c, baseType)
        # =trace: the second argument is the visitor env, not the array
        if c.op == attachedTrace: maybeCallHook c, fn, a, paramB
        else: maybeCallHook c, fn, a, paramA
      of attachedCopy, attachedDup, attachedSink:
        let a = accessArrayAt(c, paramA, indexVar, 0)
        let b = accessArrayAt(c, paramB, indexVar, 1)
        let fn = lift(c, baseType)
        maybeCallHook c, fn, a, b

      incIndexVar c, indexVar

proc derefInner(c: var LiftingCtx; x: TokenBuf): TokenBuf =
  result = createTokenBuf(10)
  copyIntoKind result, DotX, c.info:
    copyIntoKind result, DerefX, c.info:
      copyTree result, x
    copyIntoSymUse result, pool.syms.getOrIncl(DataField), c.info
    result.addIntLit(0, c.info)

proc refcountOf(c: var LiftingCtx; x: TokenBuf) =
  copyIntoKind c.dest, AddrX, c.info:
    copyIntoKind c.dest, DotX, c.info:
      copyIntoKind c.dest, DerefX, c.info:
        copyTree c.dest, x
      copyIntoSymUse c.dest, pool.syms.getOrIncl(RcField), c.info
      c.dest.addIntLit(0, c.info)

proc emitRefDestructor(c: var LiftingCtx; paramA: TokenBuf; baseType: TypeCursor) =
  c.dest.addParLe IfS, c.info
  c.dest.addParLe ElifU, c.info

  copyTree c.dest, paramA
  copyIntoKinds c.dest, [StmtsS, IfS], c.info:
    # here we know that `x` is not nil:
    copyIntoKind c.dest, ElifU, c.info:
      copyIntoKind c.dest, CallS, c.info:
        copyIntoSymUse c.dest, getCompilerProc(c, "arcDec"), c.info
        refcountOf(c, paramA)

      copyIntoKind c.dest, StmtsS, c.info:
        let oldOp = c.op
        c.op = attachedDestroy
        unravel c, baseType, c.derefInner(paramA), paramA
        c.op = oldOp
        copyIntoKind c.dest, CallS, c.info:
          copyIntoSymUse c.dest, getCompilerProc(c, "deallocFixed"), c.info
          copyTree c.dest, paramA

  c.dest.addParRi()
  c.dest.addParRi()

proc emitIncRef(c: var LiftingCtx; x: TokenBuf) =
  c.dest.addParLe IfS, c.info
  c.dest.copyIntoKind ElifU, c.info:
    copyTree c.dest, x
    copyIntoKind c.dest, StmtsS, c.info:
      copyIntoKind c.dest, CallS, c.info:
        copyIntoSymUse c.dest, getCompilerProc(c, "arcInc"), c.info
        refcountOf(c, x)
  c.dest.addParRi()

proc unravelRef(c: var LiftingCtx; n: Cursor; paramA, paramB: TokenBuf) =
  assert n.typeKind == RefT
  let baseType = n.firstSon
  case c.op
  of attachedDestroy:
    emitRefDestructor c, paramA, baseType
  of attachedTrace:
    # aowlgc: report the edge to the collector. `dest` is the `var ref T`
    # slot, `src` the visitor env; the runtime ignores nil/non-heap pointers.
    if not aowlgcMode:
      discard "ARC has no cycle collector: nothing to trace"
    else:
      copyIntoKind c.dest, CallS, c.info:
        copyIntoSymUse c.dest, getCompilerProc(c, "aowlgcMark"), c.info
        copyTree c.dest, paramB
        copyIntoKind c.dest, CastX, c.info:
          copyIntoKind c.dest, PointerT, c.info: discard
          copyIntoKind c.dest, DerefX, c.info:
            copyTree c.dest, paramA
  of attachedWasMoved:
    copyIntoKind c.dest, AsgnS, c.info:
      copyIntoKind c.dest, DerefX, c.info:
        copyTree c.dest, paramA
      copyIntoKind c.dest, NilX, c.info: discard
  of attachedDup:
    emitIncRef c, paramB
    copyIntoKind c.dest, AsgnS, c.info:
      copyTree c.dest, paramA
      copyTree c.dest, paramB
  of attachedCopy, attachedSink:
    # if src != nil: inc src.rc
    # destroy dest[]
    # dest[] = src
    emitIncRef c, paramB
    let oldOp = c.op
    c.op = attachedDestroy
    let fn = lift(c, n)
    maybeCallHook c, fn, paramA, paramA
    c.op = oldOp
    copyIntoKind c.dest, AsgnS, c.info:
      copyTree c.dest, paramA
      copyTree c.dest, paramB

proc unravel(c: var LiftingCtx; typ: TypeCursor; paramA, paramB: TokenBuf) =
  # `unravel`'s job is to "expand" the object fields in contrast to `lift`.
  if isTrivial(c, typ):
    genTrivialOp c, paramA, paramB
  else:
    let fn = lift(c, typ)
    maybeCallHook c, fn, paramA, paramB

proc depth(s: SymId): int =
  result = 0
  var root = s
  for r in inheritanceChain(s):
    root = r
    inc result

proc setupVTableField(c: var LiftingCtx; param: TokenBuf; cls: SymId) =
  copyIntoKind c.dest, AsgnS, c.info:
    copyIntoKind c.dest, DotX, c.info:
      copyIntoKind c.dest, DerefX, c.info:
        copyTree c.dest, param
      copyIntoSymUse c.dest, pool.syms.getOrIncl(VTableField), c.info
      c.dest.addIntLit(depth(cls), c.info)
    copyIntoKind c.dest, CallX, c.info:
      copyIntoSymUse c.dest, getCompilerProc(c, "getRtti"), c.info
      copyTree c.dest, param

proc unravelDispatch(c: var LiftingCtx; orig: TypeCursor; paramA, paramB: TokenBuf) =
  #if isTrivial(c, typ):
  #  genTrivialOp c, paramA, paramB
  #  return
  let typ = toTypeImpl orig
  case typ.typeKind
  of ObjectT:
    if orig.kind == Symbol and hasRtti(orig.symId):
      if c.op == attachedWasMoved:
        # setup VTable field:
        setupVTableField c, paramA, orig.symId
      elif c.op in {attachedDestroy, attachedTrace}:
        c.routineKind = MethodY
    unravelObj c, typ, paramA, paramB, 0
  of DistinctT:
    # A `distinct T` shares `T`'s representation, so its hook is `T`'s hook.
    # Use `unravel` (not a recursive `unravelDispatch`) so that a base type
    # with a hand-written hook — e.g. `distinct string`, whose resources live
    # in `string`'s custom `=destroy`/`=dup` and not in any reachable field —
    # actually calls that hook. The plain field-recursion produced an empty
    # body for such types and silently moved the buffer.
    unravel(c, typ.firstSon, paramA, paramB)
  of TupleT:
    unravelTuple c, typ, paramA, paramB
  of ArrayT:
    unravelArray c, typ, paramA, paramB
  else:
    discard "nothing to do"
    #let fn = lift(c, typ)
    #maybeCallHook c, fn, paramA, paramB

proc addParamType(c: var LiftingCtx; typ: TypeCursor) =
  var n = typ
  if n.isAtom:
    copyTree c.dest, typ
  else:
    c.dest.takeToken n
    while n.hasMore:
      if isNilAnnotation(n):
        skip n
      else:
        takeTree c.dest, n
    c.dest.addParRi()

proc addParamWithModifier(c: var LiftingCtx; param: SymId; typ: TypeCursor; modifier: TypeKind) =
  copyIntoKind(c.dest, ParamY, c.info):
    addSymDef c.dest, param, c.info
    c.dest.addEmpty2 c.info # export marker, pragmas
    copyIntoKind(c.dest, modifier, c.info):
      addParamType c, typ
    c.dest.addEmpty c.info # value

proc addParam(c: var LiftingCtx; param: SymId; typ: TypeCursor) =
  copyIntoKind(c.dest, ParamY, c.info):
    addSymDef c.dest, param, c.info
    c.dest.addEmpty2 c.info # export marker, pragmas
    addParamType c, typ
    c.dest.addEmpty c.info # value

proc maybeAddResultDecl(c: var LiftingCtx; res: SymId; typ: TypeCursor) =
  if c.op == attachedDup:
    copyIntoKind(c.dest, ResultS, c.info):
      addSymDef c.dest, res, c.info
      c.dest.addEmpty c.info # export marker
      # pragmas
      copyIntoKind c.dest, PragmasS, c.info:
        copyIntoKind c.dest, NoinitP, c.info: discard
      addParamType c, typ
      c.dest.addEmpty c.info # value

proc maybeAddReturn(c: var LiftingCtx; res: SymId) =
  if c.op == attachedDup:
    copyIntoKind(c.dest, RetS, c.info):
      copyIntoSymUse c.dest, res, c.info

proc publishProc(sym: SymId; dest: TokenBuf; procStart: int) =
  var buf = createTokenBuf(100)
  for i in procStart ..< dest.len: buf.add dest[i]
  programs.publish(sym, buf)

proc genProcDecl(c: var LiftingCtx; sym: SymId; typ: TypeCursor) =
  if c.op == attachedCopy:
    let info = siblingHookErrorInfo(c, typ, attachedDup)
    if info != NoLineInfo: c.calledErrorHook = info
  elif c.op == attachedDup:
    let info = siblingHookErrorInfo(c, typ, attachedCopy)
    if info != NoLineInfo: c.calledErrorHook = info

  let paramA = pool.syms.getOrIncl("dest.0")
  var paramTreeA = createTokenBuf(4)
  copyIntoSymUse paramTreeA, paramA, c.info

  var paramB = SymId(0)
  var paramTreeB = createTokenBuf(4)

  case c.op
  of attachedDestroy, attachedWasMoved: discard
  of attachedCopy, attachedSink, attachedTrace, attachedDup:
    paramB = pool.syms.getOrIncl("src.0")
    copyIntoSymUse paramTreeB, paramB, c.info

  let procStart = c.dest.len
  copyIntoKind(c.dest, ProcS, c.info):
    addSymDef c.dest, sym, c.info
    c.dest.addEmpty3 c.info # export marker, pattern, generics

    c.dest.addParLe ParamsU, c.info
    case c.op
    of attachedDestroy:
      addParam c, paramA, typ
      c.dest.addParRi()
      c.dest.addEmpty() # void return type
    of attachedWasMoved:
      addParamWithModifier c, paramA, typ, MutT
      c.dest.addParRi()
      c.dest.addEmpty() # void return type
    of attachedDup:
      addParam c, paramB, typ
      c.dest.addParRi()
      c.addParamType typ
    of attachedCopy, attachedSink:
      addParamWithModifier c, paramA, typ, MutT
      addParam c, paramB, typ
      c.dest.addParRi()
      c.dest.addEmpty() # void return type
    of attachedTrace:
      addParamWithModifier c, paramA, typ, MutT
      copyIntoKind(c.dest, ParamY, c.info):
        addSymDef c.dest, paramB, c.info
        c.dest.addEmpty2 c.info # export marker, pragmas
        copyIntoKind(c.dest, PointerT, c.info): discard
        c.dest.addEmpty c.info # value

      c.dest.addParRi()
      c.dest.addEmpty() # void return type

    copyIntoKind c.dest, PragmasS, c.info:
      copyIntoKind c.dest, NodestroyP, c.info: discard
      let pragmasPos = c.dest.len

    c.dest.addEmpty c.info # exc

    let a = toTypeImpl typ
    let bodyStart = c.dest.len
    copyIntoKind(c.dest, StmtsS, c.info):
      maybeAddResultDecl c, paramA, typ
      let beforeUnravel = c.dest.len
      if a.typeKind == RefT:
        unravelRef(c, a, paramTreeA, paramTreeB)
      else:
        unravelDispatch(c, typ, paramTreeA, paramTreeB)
        if c.dest.len == beforeUnravel:
          var t = typ
          if t.kind in {Symbol, SymbolDef} and hasRtti(t.symId):
            discard "empty hooks are valid for RTTI'ed types"
          else:
            assert false, "empty hook created for " & toString(typ, false)
      maybeAddReturn c, paramA

    # If this hook ended up calling a `.error.` hook, the synthesized routine
    # itself becomes `.error.` (see pragma insertion below) and is therefore
    # unreachable. Drop the body we just built so later passes don't see the
    # inner calls — those calls would otherwise be flagged against user line
    # info even though no reachable code path can execute them.
    if c.calledErrorHook != NoLineInfo:
      c.dest.shrink bodyStart
      copyIntoKind(c.dest, StmtsS, c.info): discard
  # tell vtables.nim we need dynamic binding here:
  if c.routineKind == MethodY:
    c.dest[procStart] = parLeToken(MethodS, c.info)

  if c.calledErrorHook != NoLineInfo:
    c.dest.insert [parLeToken(ErrorP, c.calledErrorHook), parRiToken(c.calledErrorHook)], pragmasPos

  publishProc(sym, c.dest, procStart)

# --- aowlgc: per allocated type, the box tracer and the box finalizer ---------
#
# The heap's type-info entry for an object allocated as `ref T` holds two
# routines that take the *box* (the `ptr {r, d: T}` the ref really is), so the
# runtime never needs to know the payload offset:
#
#   gcTrace_<key>(dest: ref T; src: pointer)  = `=trace`(dest[], src)
#   gcFin_<key>(dest: ref T)                  = `=destroy`(dest[])
#
# The finalizer is simply the payload's lifted `=destroy`; under aowlgc every
# nested `ref` destroy is trivial, so it releases only non-GC resources
# (strings, OS handles, seq buffers it owns) and never frees another object.

proc genGcBoxDecl(c: var LiftingCtx; sym: SymId; typ: TypeCursor; which: int) =
  let paramA = pool.syms.getOrIncl("dest.0")
  var paramTreeA = createTokenBuf(4)
  copyIntoSymUse paramTreeA, paramA, c.info
  let paramB = pool.syms.getOrIncl("src.0")
  var paramTreeB = createTokenBuf(4)
  copyIntoSymUse paramTreeB, paramB, c.info
  let procStart = c.dest.len
  copyIntoKind(c.dest, ProcS, c.info):
    addSymDef c.dest, sym, c.info
    c.dest.addEmpty3 c.info # export marker, pattern, generics
    c.dest.addParLe ParamsU, c.info
    addParam c, paramA, typ
    if which == 1:
      copyIntoKind(c.dest, ParamY, c.info):
        addSymDef c.dest, paramB, c.info
        c.dest.addEmpty2 c.info # export marker, pragmas
        copyIntoKind(c.dest, PointerT, c.info): discard
        c.dest.addEmpty c.info # value
    c.dest.addParRi()
    c.dest.addEmpty() # void return type
    copyIntoKind c.dest, PragmasS, c.info:
      copyIntoKind c.dest, NodestroyP, c.info: discard
    c.dest.addEmpty c.info # exc
    copyIntoKind(c.dest, StmtsS, c.info):
      let a = toTypeImpl typ
      assert a.typeKind == RefT
      c.op = if which == 1: attachedTrace else: attachedDestroy
      unravel c, a.firstSon, c.derefInner(paramTreeA), paramTreeB
  publishProc(sym, c.dest, procStart)

proc getGcBoxHook*(c: var LiftingCtx; which: int; refType: TypeCursor; info: PackedLineInfo): SymId =
  ## aowlgc: the box tracer (`which == 1`) or box finalizer (`which == 2`) for
  ## objects allocated as `refType`. `NoSymId` when the payload has nothing to
  ## trace (a leaf object) or nothing to finalize.
  let op = if which == 1: attachedTrace else: attachedDestroy
  c.op = op
  c.calledErrorHook = NoLineInfo
  c.info = info
  let a = toTypeImpl refType
  if a.typeKind != RefT or isTrivial(c, a.firstSon):
    return NoSymId
  let key = mangle(refType, Frontend, c.bits)
  result = c.gcBoxHooks[which-1].getOrDefault(key)
  if result == SymId(0):
    var name = (if which == 1: "gcTrace_" else: "gcFin_") & key
    var counter = addr c.hookNames.mgetOrPut(name, -1)
    counter[] += 1
    name.add '.'
    name.addInt counter[]
    name.add '.'
    name.add c.thisModuleSuffix
    result = pool.syms.getOrIncl(name)
    c.gcBoxHooks[which-1][key] = result
    # The request outlives the pass buffer `refType` points into: own a copy.
    var buf = createTokenBuf(8)
    buf.addSubtree refType
    c.gcBoxTypes.add ensureMove(buf)
    let typ = cursorAt(c.gcBoxTypes[^1], 0)
    c.requests.add GenHookRequest(sym: result, typ: typ, op: op, gcBox: which)

proc genMissingHooks*(c: var LiftingCtx) =
  # remember that genProcDecl does mutate c.requests so be robust against that:
  while c.requests.len > 0:
    let reqs = move(c.requests)
    for i in 0 ..< reqs.len:
      c.op = reqs[i].op
      c.calledErrorHook = NoLineInfo
      if reqs[i].gcBox != 0:
        c.routineKind = ProcY
        genGcBoxDecl(c, reqs[i].sym, reqs[i].typ, reqs[i].gcBox)
        continue
      # For RTTI types (inheritable objects), hooks need to be methods for vtable dispatch
      let t = reqs[i].typ
      if t.kind in {Symbol, SymbolDef} and hasRtti(t.symId) and reqs[i].op in {attachedDestroy, attachedTrace}:
        c.routineKind = MethodY
      else:
        c.routineKind = ProcY
      genProcDecl(c, reqs[i].sym, reqs[i].typ)

proc genMissingHooks*(c: var LiftingCtx; dest: var TokenBuf) =
  genMissingHooks(c)
  if c.dest.len > 0:
    dest.add c.dest

proc createLiftingCtx*(thisModuleSuffix: string, bits: int; frontendHooks: ptr Table[SymId, HooksPerType] = nil): ref LiftingCtx =
  (ref LiftingCtx)(op: attachedDestroy, info: NoLineInfo, thisModuleSuffix: thisModuleSuffix, bits: bits, routineKind: ProcY, frontendHooks: frontendHooks)

proc getHook*(c: var LiftingCtx; op: AttachedOp; typ: TypeCursor; info: PackedLineInfo): SymId =
  c.op = op
  c.calledErrorHook = NoLineInfo
  c.info = info
  let t = if typ.typeKind == SinkT: typ.firstSon else: typ
  # For RTTI types (inheritable objects), hooks need to be methods for vtable dispatch
  if t.kind in {Symbol, SymbolDef} and hasRtti(t.symId) and op in {attachedDestroy, attachedTrace}:
    c.routineKind = MethodY
  else:
    c.routineKind = ProcY
  result = lift(c, t)

proc getDestructor*(c: var LiftingCtx; typ: TypeCursor; info: PackedLineInfo): SymId =
  getHook(c, attachedDestroy, typ, info)

when isMainModule:
  import std/os
  try:
    setupProgramForTesting getCurrentDir() / "nimcache", "test.nim", ".nif"
  except:
    quit 1
  let res = tryLoadHook(attachedDestroy, pool.syms.getOrIncl(StringName))
  if res != SymId(0):
    echo pool.syms[res]
  else:
    echo "no hook"
