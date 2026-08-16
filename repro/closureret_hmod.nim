## A module that exports a closure TYPE and a proc returning it.
type Handler* = proc(x: int): int {.closure.}

proc makeHandler*(base: int): Handler =
  proc(x: int): int {.closure.} =
    base + x

proc use*(h: Handler): int =
  h(1)
