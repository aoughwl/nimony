# Case objects are traced by discriminator; arrays and tuples of refs;
# inheritance with ref fields at every level and dynamic dispatch.
import std/syncio
when not defined(aowlgc):
  proc GC_fullCollect() = discard

type
  Kind = enum kLeaf, kPair, kList
  Expr = ref object
    case kind: Kind
    of kLeaf: val: int
    of kPair: l, r: Expr
    of kList: items: seq[Expr]

  Base = ref object of RootObj
    up: Base
    tag: string
  Mid = ref object of Base
    pair: (Base, int)
  Leaf3 = ref object of Mid
    arr: array[3, Base]

method sum(e: Base): int {.base.} = 1
method sum(e: Mid): int = 10 + (if e.pair[0] != nil: e.pair[0].sum else: 0)
method sum(e: Leaf3): int =
  result = 100
  for i in 0 .. 1:
    let b = e.arr[i]
    if b != nil: result += b.sum

proc mk(depth: int): Expr =
  if depth == 0: return Expr(kind: kLeaf, val: 1)
  if depth mod 2 == 0:
    result = Expr(kind: kPair, l: mk(depth-1), r: mk(depth-1))
  else:
    result = Expr(kind: kList, items: @[mk(depth-1), mk(depth-1), mk(depth-1)])

proc eval(e: Expr): int =
  case e.kind
  of kLeaf: e.val
  of kPair: eval(e.l) + eval(e.r)
  of kList:
    var s = 0
    for x in e.items: s += eval(x)
    s

proc mkTree(): Base =
  let l = Leaf3(tag: "leaf")
  l.arr[0] = Base(tag: "b0", up: l)
  l.arr[1] = Mid(tag: "m1", pair: (Base(tag: "inner"), 5), up: l)
  l.arr[2] = l   # self edge through an array
  l.pair = (Base(tag: "p"), 1)
  result = l

let e = mk(8)
var keep = mkTree()
for i in 0 ..< 3000:
  discard mk(5)
  discard mkTree()
GC_fullCollect()
echo eval(e)
echo keep.sum
echo keep.up == nil, " ", keep.tag
