# Our Changes — Issues Fixed & Features Added

The authoritative ledger of what **our** `aoughwl/nimony` tree fixes/adds over
stock upstream `nim-lang/nimony`. This branch (`master`) is the canonical one we
use internally and share: it stays current with upstream and carries our own
fixes and features on top.

**Keep this file current: every time we fix an issue or add a feature, add a row
here** with what, why, the files, and how it's verified. The companion JS/WASM
runtime lives in `aoughwl/nimony-web` (see its `docs/CHANGES.md`).

---

## Features Added

### `.passive` / async ergonomics (compiler side)
The compiler support that makes nimony's `{.passive.}` CPS coroutines usable as
a real async library (the runtime itself ships in `aoughwl/nimony-web`):

| Feature | What it enables | Where |
|---|---|---|
| Cross-module `.passive` | `await`/`sleepAsync`/coroutine helpers resolve & compose across module boundaries | `hexer/coro_transform.nim`, `hexer/cps.nim` |
| `delay <call>` in generics | Spawn a coroutine from inside a generic proc (needed for generic `race[T]`) | `nimony/sem.nim` (`semDelay`) |
| `suspend()` in generic `.passive` | Generic passive procs that park now instantiate | `nimony/sem.nim` (`semSuspend`) |
| Proc-pragma macros (e.g. `{.async.}`) | A macro can receive & return a `proc` routine, and works when **imported** and on cross-bit targets | `lib/std/private/macros_nif.nim`, `nimony/semcall.nim`, `nimony/macro_plugin.nim` |

---

## Issues Fixed

| # | Issue | Root cause | Fix (files) | Verified |
|---|---|---|---|---|
| 1 | `.passive` coroutine helpers didn't resolve across modules (`could not find symbol: …init.<caller>`) | helpers were mangled with the *caller's* module suffix, and the wrapper wasn't published into the defining module's index | `coroSuffix` from the defining module + publish the foreign wrapper | `nimony-web` `tsleep3`, `tgather2` |
| 2 | `delay <call>` inside a generic proc → `[Bug] expected ')'` | `semDelay` wasn't idempotent: a generic body is flattened once, then re-semmed on instantiation | make `semDelay` re-entrant (`sem.nim`) | cps suite |
| 3 | Macro plugins failed to compile for any file outside the repo (`cannot open <mod>.s.deps.nif`) | `nimonyDir()/src/lib` was only added per-dir, so module suffixes disagreed | add it unconditionally in `setupPaths` (`semos.nim`) | macros suite |
| 4 | A `.passive` proc capturing a `.raises` non-void result crashed hexer (`assert n.kind==Symbol`) | coro lifts the result local to `(dot(deref env)fld)` | copy non-Symbol operand verbatim (`constparams.nim`); removes the crash (full raise-across-await still deferred) | cps suite |
| 5 | Proc-pragma macros silently dropped the routine (“expression expected”) | NimNode NIF codec had no `"proc"` case → round-tripped to empty | add `of "proc": nnkProcDef` + map back (`macros_nif.nim`) | macros suite |
| 6 | `suspend()` in a generic `.passive` proc → “Continuation must be discarded” on instantiation | `semSuspend` typed `(suspend)` as `Continuation`, but `suspend` is `void` | type it `void` (`sem.nim`) | cps suite |
| 7 | Generic `race[T]` spawned via `delay raceW(...)` failed to link on **both** native and JS (`loadForeign`: “Symbol not found: raceW.0.coro.<sfx>”) | `semDelay`'s generic-instantiation branch copied the delayed callee verbatim, so a generic callee was never instantiated → its `.coro` frame type was never emitted | reconstruct `(call …)` and re-sem it, then re-flatten to `(delay …)` (`sem.nim`) | `nimony-web` `tgenrace` (native + JS) |
| 8a | An **imported** macro wasn't recognized (“macro '…' not compiled”) | an imported macro's declaration is checked in its *defining* module, so it's absent from the importer's `compiledMacros` | fall back to the on-disk plugin the dependency build produced — `macroPluginExists` (`semcall.nim`, `macro_plugin.nim`) | `nimony-web` `tasyncsugar` |
| 8b | Macro plugin build failed on cross-bit targets (“Pointer size mismatch…”) | a macro plugin is a HOST-native tool but inherited the target compile's `--bits:NN` | strip `--bits:` from the forwarded args — `hostifyPluginArgs` (`macro_plugin.nim`) | `nimony-web` `tasyncsugar` |
| 8c | Macro plugin built but **segfaulted** at run on a cross-bit target | the host plugin reused the target's stdlib artifacts from the shared nifcache | build the plugin in an isolated host-bits nifcache, seeded with `import std/[syncio, macros]` (`macro_plugin.nim`) | `nimony-web` `tasyncsugar` |

---

## Known limits (not yet fixed)

- **Raise-across-await** — the `.raises` error-tuple ABI was never threaded
  through the coroutine lowering (`coro_transform` types the lifted result as
  raw `ptr T`, not `ptr (ErrorCode, T)`). The crash is gone (issue #4), but real
  cross-`await` exception propagation is a deferred *feature*; the `nimony-web`
  library propagates errors via `Future.err`.
