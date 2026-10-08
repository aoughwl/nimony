proc `=trace`(t: var Thing; env: pointer) {.inline.} =
  discard env
type
  Thing = object
    v: int
  Pass = ref object
    n: Thing
proc main() =
  var p = Pass(n: Thing(v: 1))
  discard p.n.v
main()

# GENERALIZED finding (fix-ref-destroy-aowlgc branch, follow-up to
# e39f6f54/7d0c2457): this is NOT specific to Cursor or to BiTable (both
# red herrings in the original cursor_trace_field_nilcheck.nim repro --
# confirmed BiTable alone only triggers an UNRELATED, separate
# "cannot prove that t has been initialized" error with no Cursor involved).
#
# The REAL, minimal trigger: ANY type with a hand-written `=trace` hook,
# used as a bare (non-seq, non-ref) field directly inside a `ref object`,
# fails under -d:aowlgc with "cannot prove expression is not nil: src".
# A `seq[Thing]`/`seq[Cursor]` field of the same type does NOT trigger it
# (see cursor_trace_seq_ok.nim) -- only a bare field does.
#
# Root cause located but NOT fixed: the lifter-generated =trace wrapper for
# Pass calls the hooked field type.s =trace, passing its own `src: pointer`
# (the generic trace-env argument) through. nimony.s contracts.nim:297
# (wantNotNil, reached via checkNilMatch) rejects this because the CALLEE
# side.s parameter type is apparently marked `not nil` (NotnilU) while the
# generated wrapper.s own `src` parameter is plain `pointer` -- a mismatch
# between what the lifter declares for its generated proc and what the
# call target expects. This is a nil-tracking/contracts-system interaction
# with LIFTER-GENERATED code, not a narrow single-site bug; fixing it needs
# either relaxing the not-nil requirement on the hooked trace dispatch path
# or having the lifter annotate/prove its generated src parameter -- both
# touch shared compiler machinery (contracts.nim and/or hexer/lifter.nim.s
# proc-generation for ANY custom-hooked field), not a bounded, isolated fix.
# Deferred for a dedicated compiler-internals pass.
