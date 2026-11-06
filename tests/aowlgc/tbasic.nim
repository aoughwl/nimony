import std/syncio
when not defined(aowlgc):
  proc GC_fullCollect() = discard

type
  Node = ref object
    next: Node
    val: int
    name: string

proc makeCycle(i: int) =
  let a = Node(val: i, name: "a" & $i)
  let b = Node(val: i+1, name: "b")
  a.next = b
  b.next = a

var keep = Node(val: 42, name: "kept")
for i in 0 ..< 100000:
  makeCycle(i)
GC_fullCollect()
echo keep.val, " ", keep.name
echo "collections>0: ", GC_collections() > 0
echo "live<1000: ", GC_liveObjects() < 1000
