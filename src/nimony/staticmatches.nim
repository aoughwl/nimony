#       Nimony
# (c) Copyright 2024 Andreas Rumpf
#
# See the file "license.txt", included in this
# distribution, for details about the copyright.

## Helpers for value (`static`) generic parameters that are independent of the
## `Match` object: recognising a canonical compile-time value, reading the type
## of such a value and deciding whether it satisfies a declared element type
## (including an `openArray` element type bound to an array value). `sigmatch`
## builds the actual value binding on top of these, and `semtypes` reuses the
## recogniser when accepting a `static` generic argument.

when defined(nimony):
  {.feature: "untyped".}

include ".." / lib / nifprelude
include ".." / lib / compat2

import nimony_model, decls, programs, builtintypes, typeprops
import ".." / lib / symparser
import ".." / models / tags

proc sameStaticSymbol(a, b: SymId): bool =
  if a == b:
    return true
  let sa = pool.syms[a]
  let sb = pool.syms[b]
  result = isInstantiation(sa) and isInstantiation(sb) and
    removeModule(sa) == removeModule(sb)

proc isStaticValue*(n: Cursor): bool =
  ## A canonical compile-time value as bound to a `staticTypevar`.
  case n.kind
  of IntLit, UIntLit, FloatLit, CharLit, StringLit:
    result = true
  of Symbol:
    let res = tryLoadSym(n.symId)
    result = res.status == LacksNothing and
      res.decl.symKind in {ConstY, EfldY, StaticTypevarY}
  of ParLe:
    case n.exprKind
    of FalseX, TrueX:
      result = true
    of SufX:
      var elem = n
      inc elem
      result = isStaticValue(elem)
    of AconstrX, SetconstrX, TupconstrX, OconstrX:
      var elem = n
      inc elem
      skip elem # type
      result = true
      while elem.hasMore:
        if elem.substructureKind in {KvU, RangeU}:
          inc elem
          skip elem # key or range start
          if not isStaticValue(elem):
            result = false
            break
          skip elem
          if elem.kind == ParRi:
            break
          inc elem
        else:
          if not isStaticValue(elem):
            result = false
            break
          skip elem
    else:
      result = false
  else:
    result = false

proc staticValueType*(a: Cursor): Cursor =
  result = default(Cursor)
  case a.kind
  of Symbol:
    let res = tryLoadSym(a.symId)
    if res.status == LacksNothing and isLocal(res.decl.symKind):
      result = asLocal(res.decl).typ
  of ParLe:
    case a.exprKind
    of AconstrX, SetconstrX, TupconstrX, OconstrX:
      var typ = a
      inc typ
      result = typ
    else:
      discard
  else:
    discard

proc staticOpenArrayElemType(t: Cursor): Cursor =
  result = default(Cursor)
  var t = t
  var depth = 0
  while t.kind == Symbol and depth < 20:
    let res = tryLoadSym(t.symId)
    if res.status != LacksNothing or res.decl.symKind != TypeY:
      return default(Cursor)
    let decl = asTypeDecl(res.decl)
    if decl.typevars.typeKind == InvokeT:
      t = decl.typevars
      break
    elif decl.body.kind == Symbol:
      t = decl.body
    else:
      return default(Cursor)
    inc depth
  if t.typeKind == InvokeT:
    inc t
    if t.kind == Symbol and pool.syms[t.symId] == OpenArrayHeadName:
      inc t
      result = t
  elif t.typeKind == VarargsT:
    inc t
    if t.kind != ParRi:
      result = t

proc staticValueTypeMatches*(elemType, valueType: Cursor): bool =
  if cursorIsNil(valueType):
    return false
  if sameTrees(elemType, valueType):
    return true
  if elemType.kind == Symbol and valueType.kind == Symbol:
    return sameStaticSymbol(elemType.symId, valueType.symId)
  if elemType.typeKind == VarargsT and valueType.typeKind == ArrayT:
    var elem = elemType
    inc elem
    if elem.kind == ParRi:
      return true
    var arrElem = valueType
    inc arrElem
    return sameTrees(elem, arrElem)
  let openArrayElem = staticOpenArrayElemType(elemType)
  if not cursorIsNil(openArrayElem) and valueType.typeKind == ArrayT:
    var arrElem = valueType
    inc arrElem
    return sameTrees(openArrayElem, arrElem)
  false
