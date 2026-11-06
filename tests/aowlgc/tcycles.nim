# Cycles (self, 2-cycles, long rings, cycles through seqs) are collected and
# their finalizers run; reachable structures survive.
import std/syncio
when not defined(aowlgc):
  proc GC_fullCollect() = discard

var finalized = 0

type
  NodeObj = object
    next: Node
    kids: seq[Node]
    id: int
  Node = ref NodeObj

proc `=destroy`(x: NodeObj) =
  inc finalized

proc selfCycle() =
  let a = Node(id: 1)
  a.next = a

proc ring(n: int) =
  let first = Node(id: 0)
  var cur = first
  for i in 1 ..< n:
    let nx = Node(id: i)
    cur.next = nx
    cur = nx
  cur.next = first

proc seqCycle() =
  let parent = Node(id: 7)
  for i in 0 ..< 10:
    let k = Node(next: parent, id: i)
    parent.kids.add k

proc build(): Node =
  result = Node(id: 100)
  for i in 0 ..< 50:
    result.kids.add Node(next: result, id: i)

var kept = build()
for i in 0 ..< 1000:
  selfCycle()
  ring(20)
  seqCycle()
GC_fullCollect()
GC_fullCollect()
echo "finalized >= 1000*(1+20+11) - slack: ", finalized >= 31000
var s = 0
for k in kept.kids: s += k.id
echo kept.id, " ", kept.kids.len, " ", s, " ", kept.kids[3].next == kept
