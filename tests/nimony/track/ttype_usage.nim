type
  Thing = object
    a: int

proc use1(x: Thing) = discard
#            ^usages

var g: Thing
let h: Thing = g
use1(g)
discard h.a
