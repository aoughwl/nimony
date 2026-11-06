import nifcursors, bitabs
type
  Pass = ref object
    n: Cursor
    tbl: BiTable[int32, string]
proc main() =
  var p = Pass(n: default(Cursor))
  var t: BiTable[int32, string]
  discard t.getOrIncl("x")
main()

# Minimal repro for the nifcursors.nim Cursor-owner-GC-trace fix (commit
# e39f6f54/dbfadac2, branch fix-ref-destroy-aowlgc): a bare `Cursor` field
# directly inside a `ref object`, alongside any BiTable[Id,T] instantiation
# in the same program, fails under -d:aowlgc with:
#   "cannot prove expression is not nil: src" at the Cursor field decl line
#   (and a related "cannot prove that t has been initialized" on the
#   BiTable-using code).
# Reproduces aowli's real build failure (Pass.n*: Cursor in hexer/passes.nim
# + the BiTable usage in bitabs.nim) in isolation.
# A `seq[Cursor]` field (not a bare Cursor field) does NOT trigger this --
# see cursor_trace_seq_ok.nim. Build: nimony c -d:aowlgc -p:src/lib -p:lib
