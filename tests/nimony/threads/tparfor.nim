## Test: the `||` parallel-for iterator (std/parfor) lowered by its for-loop
## plugin. Each iteration writes a disjoint output index `x[i]`, so the result
## is data-race free by construction and must match the sequential map.
import std / [parfor, syncio]

const N = 1000

var x: array[N, int]
var input: array[N, int]

proc check(lo, hi: int): bool =
  result = true
  for i in lo ..< hi:
    if x[i] != input[i] * 2 + 1:
      result = false

proc main =
  for i in 0 ..< N:
    input[i] = i
    x[i] = 0

  # Full-range parallel map. `||` is inclusive (Nim's standard rule), so the
  # last index is `N-1`.
  for i in 0 || (N-1):
    x[i] = input[i] * 2 + 1
  let okFull = check(0, N)

  # Sub-range parallel map (non-zero start) exercises the chunk arithmetic and
  # pins down inclusivity: `100 || 900` must write `x[900]` but not `x[901]`.
  for i in 0 ..< N:
    x[i] = 0
  for i in 100 || 900:
    x[i] = input[i] * 2 + 1
  let okSub = check(100, 901) and x[99] == 0 and x[901] == 0

  # Inner loop that reduces into a per-iteration LOCAL, writing the output
  # `x[i]` only *outside* the inner loop, must be accepted by the checker.
  for i in 0 ..< N:
    x[i] = 0
  for i in 0 || (N-1):
    var s = 0
    for k in 0 ..< 2:
      s = s + input[i]
    x[i] = s + 1
  var okReduce = true
  for i in 0 ..< N:
    if x[i] != input[i] * 2 + 1:
      okReduce = false

  # Strided map: `||` with an explicit `step` visits `a, a+step, …, ≤ b`, so
  # `0 || (N-1)` with step 2 writes only the even indices.
  for i in 0 ..< N:
    x[i] = 0
  for i in `||`(0, N-1, 2):
    x[i] = input[i] * 2 + 1
  var okStep = true
  for i in 0 ..< N:
    let want = if i mod 2 == 0: input[i] * 2 + 1 else: 0
    if x[i] != want:
      okStep = false

  # Explicit grain: `chunkSize = 250` runs chunks of 250 iterations each
  # (ceil(N/250) = 4 runners). Grain is a scheduling knob, not a semantic one,
  # so the result must still match the sequential map.
  for i in 0 ..< N:
    x[i] = 0
  for i in `||`(0, N-1, chunkSize = 250):
    x[i] = input[i] * 2 + 1
  let okChunks = check(0, N)

  if okFull and okSub and okReduce and okStep and okChunks:
    echo "parfor ok"
  else:
    echo "parfor FAIL"

# Windows used to be stubbed out here: std/rawthreads did not COMPILE on Windows
# (CreateThread arguments 3 and 6 -- DWORD is `unsigned long`, nimony's `uint32`
# is `unsigned int`, and GCC 14 makes that an error, not a warning). The stub
# echoed this file's expected output, so the lane was green while nothing ran.
# With rawthreads spelling the DWORD-typed arguments `culong`, the real thing
# runs here and produces that output for the right reason.
main()
