import nifcursors
type
  Holder = ref object
    bodies: seq[Cursor]
proc main() =
  var h = Holder(bodies: @[])
  discard h.bodies.len
main()
# This builds CLEANLY under -d:aowlgc with the Cursor =trace fix (the
# actual target scenario: Interp.procBodies: seq[Cursor]) -- confirming the
# core fix is sound; the failure in cursor_trace_field_nilcheck.nim is a
# SEPARATE, narrower lifter/nil-tracking issue specific to a bare field.
