
import std/[rawthreads, syncio]

const
  numThreads = 8
var
  results: array[numThreads, string]

proc worker(p: pointer) =
  let idx = cast[ptr int](p)[]
  results[idx] = "worker " & $idx

proc main =
  var thr {.noinit.}: array[numThreads, RawThread]
  var indexes = default array[numThreads, int]
  try:
    for i in 0..<numThreads:
      indexes[i] = i
      create thr[i], worker, addr(indexes[i])
  except:
    echo "error creating thread"
    return
  echo "other"
  for i in 0..<numThreads:
    thr[i].join()
  for i in 0..<numThreads:
    var ok = false
    for j in 0..<numThreads:
      if results[j] == "worker " & $i:
        ok = true
        break
    if not ok:
      echo "thread ", i, " not found"
      return
  echo "all threads found"

# Windows used to be stubbed out here, because std/rawthreads did not COMPILE on
# Windows (CreateThread arguments 3 and 6: DWORD is `unsigned long`, nimony's
# `uint32` is `unsigned int`, and GCC 14 makes that an error rather than a
# warning). The stub printed the expected output, so the lane was green while
# nothing ran. With rawthreads using `culong` for the DWORD-typed arguments the
# real thing runs here, so run it.
main()
