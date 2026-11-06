## Consumer in a DIFFERENT module. The extern declaration emitted for
## makeHandler gets a bare nimcall return type instead of the closure tuple.
import std/syncio
import closureret_hmod

let h: Handler = makeHandler(41)
echo use(h)
