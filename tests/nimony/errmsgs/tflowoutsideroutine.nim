# `return` and `yield` outside a routine used to CRASH nimsem: the error was
# reported, then `c.routine.returnType` was read anyway — an empty cursor
# outside a routine — tripping the nifcursors `load` assertion.
var x = 1
if x == 1:
  return
yield 1
