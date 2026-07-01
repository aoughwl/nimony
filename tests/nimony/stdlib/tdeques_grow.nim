## Exercises the ring buffer's uninitialized-storage lifecycle with a
## destructor element type (`string`): repeated grows migrate live elements
## into fresh `newSeqUninit` buffers and destroy the old (partly moved-from)
## one, and the whole deque is destroyed at scope end. A garbage-slot destroy
## would crash or leak here. Dropping `HasDefault` must keep all this correct.

import std/[syncio, deques]

var d = initDeque[string](2)          # small cap forces several grows
for i in 0 ..< 10:
  d.addLast("v" & $i)
echo d.len                            # 10
echo d[0]                             # v0
echo d[9]                             # v9

echo d.popFirst()                     # v0  (slot becomes moved-from)
echo d.popLast()                      # v9
echo d.len                            # 8

d.addFirst("front")                   # reuse a moved-from / zeroed slot
d.addLast("back")
echo d[0]                             # front
echo d.peekLast()                     # back
echo d.len                            # 10

var total = 0
for s in d.items:
  total += s.len
echo total                            # 8*("v#"=2) + front(5) + back(4) = 25
