# Finalizers: the payload =destroy runs once per dead object, frees non-GC
# resources (strings), and destroying a VALUE that holds refs never frees the
# referenced objects.
import std/syncio
when not defined(aowlgc):
  proc GC_fullCollect() = discard

var fins = 0

type
  ResObj = object
    name: string
    buf: seq[int]
  Res = ref ResObj

  Holder = object       # a value type containing refs
    a, b: Res
    label: string

proc `=destroy`(x: ResObj) =
  inc fins
  `=destroy`(x.name)    # explicit: a user =destroy replaces the lifted one
  `=destroy`(x.buf)

proc makeHolder(r: Res): Holder =
  Holder(a: r, b: Res(name: "tmp"), label: "h")

proc useAndDrop(r: Res) =
  var h = makeHolder(r)
  h.label.add "!"
  # h is destroyed here: its label is freed, its refs are not

let shared = Res(name: "shared", buf: @[1, 2, 3])
for i in 0 ..< 10000:
  useAndDrop(shared)
GC_fullCollect()
echo shared.name, " ", shared.buf.len, " ", shared.buf[2]
echo "tmp finalized: ", fins >= 9000
let before = fins
GC_fullCollect()
echo "no double finalization: ", fins == before
