import std/assertions
type Thing = object
  s1: string
  s2: string
var box: seq[Thing]
let c = [Thing(s1: "333"), Thing(s1: "abc", s2: "def")]
for i in 0..high(c):
  box.add c[i]
for i in 0..3:
  box.add Thing(s1: "3x")
box.add Thing(s1: "lastone")
assert box[0].s1 == ""
