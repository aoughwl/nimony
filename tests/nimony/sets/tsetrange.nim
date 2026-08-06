import std/assertions

# Regression for: an INLINE range as a set's element type — `set['a'..'z']`,
# which Nim defines as `set[range['a'..'z']]` — was semmed as a value
# expression rather than a range type. It was therefore not an ordinal type,
# the program was rejected with "set element type must be ordinal", and because
# the error node was appended AFTER the already-closed `(set …)` tree the
# rejection surfaced as a `[Bug]` traceback ("expected ')', but got: (err …)")
# instead of a diagnostic. `array['a'..'z', T]` always accepted the same form.
#
# Also covers a char literal as a range value: `range['a'..'z'] = 'b'` was
# rejected with "cannot prove value is in range 97..122" because the
# range-proof pass modelled `IntLit`/`UIntLit` literals but not `CharLit`.

type
  Lower = set['a'..'z']
  Digit = set[0..9]

var lower: Lower = {}
var digits: Digit = {}

lower.incl 'q'
digits.incl 3

assert 'q' in lower
assert 'Z' notin lower
assert 3 in digits
assert 7 notin digits

# the named form must keep working and mean the same thing
type
  LowerRange = range['a'..'z']
  LowerNamed = set[LowerRange]

var named: LowerNamed = {}
named.incl 'q'
assert 'q' in named
assert 'Z' notin named

# a char literal is an ordinal the range check can model
var c: LowerRange = 'b'
assert c == 'b'
