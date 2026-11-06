# Roots: globals, threadvars, GC_ref-pinned refs stored in raw memory.
import std/syncio
when not defined(aowlgc):
  proc GC_fullCollect() = discard

type R = ref object
  v: int
  s: string

var g1 = R(v: 1, s: "global")
var gs: seq[R] = @[R(v: 2, s: "gseq")]
var tv {.threadvar.}: R

proc churn() =
  for i in 0 ..< 50000:
    discard R(v: i, s: "x" & $i)

tv = R(v: 3, s: "threadvar")
let raw = cast[ptr R](alloc0(sizeof(R)))
block:
  let hidden = R(v: 4, s: "hidden")
  GC_ref(hidden)
  raw[] = hidden
churn()
GC_fullCollect()
echo g1.s, " ", gs[0].s, " ", tv.s, " ", raw[].s
GC_unref(raw[])
raw[] = nil
GC_fullCollect()
echo g1.v + gs[0].v + tv.v
