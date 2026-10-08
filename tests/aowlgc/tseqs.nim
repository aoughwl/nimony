# seqs of refs: as locals (only conservatively visible), as fields, nested,
# grown and shrunk while the collector runs; seq of seq of refs; strings.
import std/syncio
when not defined(aowlgc):
  proc GC_fullCollect() = discard

type
  Leaf = ref object
    v: int
    s: string
  Box = ref object
    items: seq[Leaf]
    grid: seq[seq[Leaf]]

proc fill(n: int): seq[Leaf] =
  result = @[]
  for i in 0 ..< n:
    result.add Leaf(v: i, s: "leaf" & $i)

var total = 0
for round in 0 ..< 200:
  var local = fill(100)          # held only by this stack frame
  let b = Box()
  for i in 0 ..< 10:
    b.grid.add fill(10)
  b.items = fill(50)
  discard local.pop
  local.del 0
  local.shrink 50
  for x in local: total += x.v
  for row in b.grid:
    for x in row: total += x.v
  for x in b.items:
    if x.s != "leaf" & $x.v: echo "CORRUPT"
echo total
var keep: seq[Leaf] = @[]
for i in 0 ..< 1000:
  keep.add Leaf(v: i, s: $i)
  discard fill(3)
GC_fullCollect()
var ok = true
for i in 0 ..< keep.len:
  if keep[i].v != i or keep[i].s != $i: ok = false
echo ok
