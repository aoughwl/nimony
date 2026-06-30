# Regression for nim-lang/nimony#1056. An object constructor is rewritten into
# field-declaration order, so the field values are evaluated in that order
# regardless of how they are written. Rather than silently preserve source order
# (inconsistent with how named call arguments are already reordered), writing the
# fields — or named call arguments — out of evaluation order is flagged with a
# warning (see the accompanying .msgs). The values are still correct; only the
# evaluation order is fixed to declaration/parameter order.

import std / [assertions]

type Foo = object
  a, b, c: int

proc f(a, b, c: int): int = a * 100 + b * 10 + c

proc main =
  # out-of-order object constructor -> warning
  let x = Foo(c: 3, a: 1, b: 2)
  assert x.a == 1 and x.b == 2 and x.c == 3
  # in-order object constructor -> no warning
  let y = Foo(a: 1, b: 2, c: 3)
  assert y.a == 1 and y.c == 3
  # out-of-order named call arguments -> warning
  let z = f(c = 3, a = 1, b = 2)
  assert z == 123
  # in-order / positional -> no warning
  assert f(a = 1, b = 2, c = 3) == 123
  assert f(1, 2, 3) == 123

main()
