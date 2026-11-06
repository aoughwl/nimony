# Closure iterators (heap frames owned by the iterator value) and .passive
# coroutine frames (pinned, conservatively scanned) holding refs across
# yields / calls while the collector runs.
import std/syncio
when not defined(aowlgc):
  proc GC_fullCollect() = discard

type Item = ref object
  v: int
  s: string

iterator items3(n: int): Item {.closure.} =
  var held = Item(v: 0, s: "held")
  var i = 0
  while i < n:
    let it = Item(v: i, s: $i)
    held.v += i
    yield it
    inc i
  yield held

proc churn(n: int) =
  for i in 0 ..< n:
    discard Item(v: -1, s: "junk")

proc main() =
  var acc = 0
  for round in 0 ..< 200:
    for it in items3(50):
      churn(3)
      if it.s == "held": acc += it.v
      elif it.s != $it.v: echo "CORRUPT"
  echo acc

main()

proc leaf(x: Item): int {.passive.} =
  churn(100)
  result = x.v + x.s.len

proc mid(n: int): int {.passive.} =
  let a = Item(v: n, s: "mid")
  let b = leaf(Item(v: 1, s: "x"))
  churn(100)
  result = a.v + a.s.len + b

proc driver() =
  var t = 0
  for i in 0 ..< 300:
    t += mid(i)
  echo t

driver()
