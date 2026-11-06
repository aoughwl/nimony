# Closure environments are traced refs: refs captured by a live closure
# survive collections; environments of dead closures are collected (their
# captured objects get finalized).
# (nimony limitation, also under ARC: closures stored in object fields or
# seqs are not lowered correctly, so this test keeps closures in locals.)
import std/syncio
when not defined(aowlgc):
  proc GC_fullCollect() = discard

var fins = 0
type
  WidgetObj = object
    name: string
  Widget = ref WidgetObj

proc `=destroy`(w: WidgetObj) =
  inc fins

proc churn() =
  for i in 0 ..< 1000:
    discard Widget(name: "junk")

proc makeCounter(start: int): (proc (): int {.closure.}) =
  var box = Widget(name: "counter")
  var n = start
  result = proc (): int {.closure.} =
    inc n
    n + box.name.len

proc callMany(f: proc (): int {.closure.}; times: int): int =
  result = 0
  for i in 0 ..< times:
    churn()
    result += f()

proc dropClosure(i: int): int =
  let w = Widget(name: "dropped")
  let f = proc (): int {.closure.} = w.name.len + i
  result = f()

let c = makeCounter(100)
var s = 0
for i in 0 ..< 20000:
  s += dropClosure(i) - i
GC_fullCollect()
s += callMany(c, 10)
echo s
echo "dead closure envs collected: ", fins >= 19000
