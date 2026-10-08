# Tables of refs, refs only reachable from deep recursion (conservative stack
# scan), large objects (> 32 KiB, span pages), generic ref types, and ref
# objects holding strings that are rebuilt while collections run.
import std/syncio
import std/tables
when not defined(aowlgc):
  proc GC_fullCollect() = discard

type
  Entry = ref object
    key: string
    hits: int
  Big = ref object
    data: array[10000, int]       # 80 KB payload: a large-object span
    next: nil Big
  GNode[T] = ref object
    val: T
    kids: seq[GNode[T]]

proc churn(n: int) =
  for i in 0 ..< n:
    discard Entry(key: "junk", hits: i)

proc deep(n: int; e: Entry): int =
  # `e` lives only in registers / stack slots of this recursion
  if n == 0:
    churn(2000)
    GC_fullCollect()
    return e.hits + e.key.len
  let local = Entry(key: "d" & $n, hits: n)
  result = deep(n - 1, e) + local.hits - n

var t = initTable[string, Entry]()
for i in 0 ..< 2000:
  let k = "k" & $i
  t[k] = Entry(key: "k" & $i, hits: i)  # not `key: k`: nimony moves k into the ctor first
  churn(5)
GC_fullCollect()
var s = 0
for i in 0 ..< 2000:
  let e = t.getOrDefault("k" & $i, Entry(key: "missing"))
  if e.key != "k" & $i: echo "CORRUPT"
  s += e.hits
echo s

echo deep(300, Entry(key: "bottom", hits: 7))

var bigs: seq[Big] = @[]
for i in 0 ..< 200:
  let b = Big()
  if bigs.len > 0: b.next = bigs[bigs.len-1]   # edges between large objects
  b.data[0] = i
  b.data[9999] = i * 2
  if i mod 10 == 0: bigs.add b   # keep every tenth, drop the rest
GC_fullCollect()
var bs = 0
for b in bigs:
  bs += b.data[0] + b.data[9999]
echo bs

proc tree(d: int): GNode[string] =
  result = GNode[string](val: "n" & $d)
  if d > 0:
    for i in 0 ..< 3:
      result.kids.add tree(d - 1)

proc count(n: GNode[string]): int =
  result = 1
  for k in n.kids: result += count(k)

let tr = tree(6)
for i in 0 ..< 20: discard tree(4)
GC_fullCollect()
echo count(tr), " ", tr.kids[2].kids[1].val
