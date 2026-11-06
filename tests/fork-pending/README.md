# Tests waiting for a feature that is not in this tree

`tandor.nim` / `tandor.output` come from the fork's "nil-tracking through and/or
short-circuit guards" work on Final IR (commits 6086199e / fcdaee59, branch
`master` of this fork before the 2026-11-06 sync). That feature was written against
the older `Tracker` API in `src/nimony/contracts_fir.nim`; the v0 / aowlgc lines carry
a newer journaled-tracker design (`gotoLabel(c.tr, c.flow, ...)`) that the old code
cannot sit on. During the sync the newer design won and the feature was set aside.
Upstream may already implement it - check before re-porting. The test is kept here
(not under tests/nimony) so the main suite does not run a test that is expected to fail.
