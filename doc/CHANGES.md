# Our Changes — Issues Fixed & Features Added

The authoritative ledger of what **our** `aoughwl/nimony` tree fixes/adds over
stock upstream `nim-lang/nimony`. This branch (`master`) is the canonical one we
use internally and share: it stays current with upstream and carries our own
fixes and features on top.

**Keep this file current: every time we fix an issue or add a feature, add a row
here** with what, why, the files, and how it's verified.

The compiler features below — the async/coroutine support, macro plugins, the
diagnostics, and the stdlib — live **here** in `aoughwl/nimony`. `aoughwl/nimony-web`
is a downstream *consumer*: a reference async runtime library built on this
compiler's `.passive` coroutines, which also hosts the test suite that exercises
them (see its `docs/CHANGES.md`). This tree's *in-tree* backends are `c` / `llvm` / `native`
(`src/nimony/nifconfig.nim`, `Backend` enum). Our **JS and WebAssembly backends
are separate nimony plugins**, maintained independently in `aoughwl/nimony-web`,
that consume the lowered IR this compiler hands its C backend and emit `.js` /
`.wasm` instead — part of our nimony stack, credited under *Features* below and
detailed in that repo's `docs/CHANGES.md`.

---

## Features Added

### `.passive` / async ergonomics (compiler side)
nimony's own compiler-level async/coroutine support: the machinery that makes
`{.passive.}` CPS coroutines compose into a real async library. This is a
general-purpose capability of `aoughwl/nimony` itself, not tied to any one
consumer; `aoughwl/nimony-web` is one such consumer (a reference runtime) and
supplies the test harness the *Verified* column below cites:

| Feature | What it enables | Where |
|---|---|---|
| Cross-module `.passive` | `await`/`sleepAsync`/coroutine helpers resolve & compose across module boundaries | `hexer/coro_transform.nim`, `hexer/cps.nim` |
| `delay <call>` in generics | Spawn a coroutine from inside a generic proc (needed for generic `race[T]`) | `nimony/sem.nim` (`semDelay`) |
| `suspend()` in generic `.passive` | Generic passive procs that park now instantiate | `nimony/sem.nim` (`semSuspend`) |
| Proc-pragma macros (e.g. `{.async.}`) | A macro can receive & return a `proc` routine, and works when **imported** and on cross-bit targets | `lib/std/private/macros_nif.nim`, `nimony/semcall.nim`, `nimony/macro_plugin.nim` |

### JS / WebAssembly backends (independent — `aoughwl/nimony-web`)
Our two web backends. They are **nimony compiler plugins**, maintained in the
separate `aoughwl/nimony-web` repo (not code in this tree) — linked here because
they are part of our nimony stack. Each reads the lowered pre-C IR nimony hands
its C backend and emits a `.js` or `.wasm` file instead, sharing one flat
`ArrayBuffer` linear-memory layout engine (a pointer is an integer offset).

| Feature | What it enables | Where |
|---|---|---|
| JavaScript backend | compile nimony to `.js` (runs under Node / the browser); ~85% coverage overall, ~95%+ for synchronous Nim; `jsffi` / DOM interop via `aoughwl/js` | `aoughwl/nimony-web` (`src/`) |
| WebAssembly backend | compile nimony to `.wasm` on the same layout engine; shares almost all of its code with the JS backend | `aoughwl/nimony-web` (`src/`) |
| Async runtime on `.passive` | the importable async library (`asyncfut` await, `sleepAsync`, `gather`/`all`, `race`/`any`, `{.async.}` sugar) that consumes this compiler's `.passive` coroutines | `aoughwl/nimony-web` |

### `std/terminal` — fluent ANSI string styling
The "terminal / color" change: chainable, npm-`colors`-style string stylers
alongside the existing `File`-oriented API.

| Feature | What it enables | Where |
|---|---|---|
| Fluent ANSI string stylers | `echo "x".red.bold` — 8 base + bright foreground/background colours (backgrounds named `on<Colour>`, e.g. `onWhite`), styles, plus `stripAnsi`/`visibleLen`; each wrapper nests its own SGR + reset so `"x".red.bold` == `bold(red("x"))` | `lib/std/terminal.nim`; test `tests/nimony/stdlib/tterminal.nim` |

### stdlib additions
New Nimony-ported standard-library modules (over stock upstream).

| Feature | What it enables | Where |
|---|---|---|
| `std/sums` — stable float summation | `sumKbn` (Kahan-Babuška-Neumaier compensated) + `sumPairs` (pairwise) over `openArray[float]`; recovers terms lost when the running total dwarfs the next term (`sumKbn([1.0, 1e100, 1.0, -1e100]) == 2.0`) | `lib/std/sums.nim`; test `tests/nimony/stdlib/tsums.nim` |
| `std/lists` — linked lists | `SinglyLinkedList[T]` + `DoublyLinkedList[T]` with `seq`/`string`-like value semantics (`=dup`/`=copy` deep-copy) and a non-recursive `.nodestroy` `=destroy` that reclaims multi-million-node chains without a stack overflow | `lib/std/lists.nim`; test `tests/nimony/stdlib/tlists.nim` |

### New diagnostics & runtime checks
Semantic-analysis and codegen improvements migrated from our PRs.

| Feature | What it enables | Where |
|---|---|---|
| nil-tracking through and/or guards | not-nil facts now survive short-circuit guard-then-use forms (`if a == nil or b == nil: return`; guard in an `and` chain). Snapshots live facts at each `jmp` (`leaveToLabel`) and restores the meet of a label's predecessors at `(lab)` in the Final IR | `src/nimony/contracts_fir.nim`; test `tests/nimony/notnil/tandor.nim` |
| `RangeCheck` runtime mode | out-of-range `range[a..b](x)` conversions abort at runtime instead of silently truncating; new `--rangechecks:on\|off`, off under `-d:danger`. Mirrors the array bound check, rewritten in `desugar` before `xelim` so the check inlines like `nimIcheckAB` | `lib/std/system/panics.nim` (`nimIRcheck`/`raiseRangeError3`), `src/hexer/desugar.nim` (`trRangeConv`), `src/nimony/nimony.nim`, `contracts_fir.nim`, `semmain.nim`; test `tests/nimony/rtchecks/trangeconv.nim` |
| Object-constructor eval-order warning (#1056) | warns when object-constructor fields / named call args are written out of declaration order (they are re-emitted, hence evaluated, in declaration order regardless of written order); objects with a base type are skipped | `src/nimony/sem.nim`, `sembasics.nim`, `semcall.nim`, `semdata.nim`, `sigmatch.nim`; test `tests/nimony/object/tobjconstr_evalorder.nim` |
| DWARF variant part for variant objects (#2068) | a debugger shows only the active branch of a case object instead of all branches overlaid. New `(variant (ranges …))` pragma carries the discriminant→branch mapping in the `.c.nif`; the LLVM backend lowers it to `DW_TAG_variant_part`/`DW_TAG_variant` | `src/hexer/lengcgen.nim`, `src/lengc/llvmdebug.nim` (+ `codegen`/`gentypes`/`llvmcodegen`), `src/models/{tags,leng_tags}.nim`, `doc/tags.md`; verified with clang/llvm 18 + readelf |

### Build / tooling
| Feature | What it enables | Where |
|---|---|---|
| Parallel dependency discovery (`preNifle`) | cold module-dep discovery runs `nifler` over the whole import closure in parallel (`osproc.execProcesses`) before the serial DFS, which then hits the staleness short-circuit and does only cheap in-memory work; self-heals via the DFS's own `execNifler` if a module is missed | `src/nimony/deps.nim` (`preNifle`, `niflerCommandFor` factored out of `execNifler`); verified on `tests/nimony/stdlib/tall.nim` (~80-module closure) |

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
| 9 | `--def`/`--usages` rejected an **absolute** query path (`symbol not found`) | idetools interned the raw query filename to a `FileId`, but NIF line-info stores paths as `relativePath(fullPath, getCurrentDir(), '/')` (nifler `--portablePaths`); an absolute path produced a different `FileId`, so the file,line,col lookup missed | normalize an absolute query path to that relative form before interning; output format unchanged (`idetools.nim`) | `tests/nimony/track/ttype_usage.nim` |
| 10 | Type-usage records duplicated, real source position dropped | for a typed local **with** an initializer, `patchType` replaced the user-written type node with the inferred type cursor, whose head token carries the type's *definition-site* line info, clobbering the real usage position | `patchType` preserves the original declared-type head line info (`sem.nim`) | `tests/nimony/track/ttype_usage.nim` |
| 11 | `concept X of Y` (inheriting concepts) failed to parse | nifler used the stale host-Nim `parseTypeClass`; the CI devel-parser overlay wasn't applied to a local build | `ensureNiflerParserOverlay` generates a private `.nim_overlay/` with the fix and points nifler's `nim.cfg` at it; `build nimony` now rebuilds nifler so the overlay lands (`hastur.nim`, `src/nifler/nim.cfg`) | `build nimony` (self-host) |
| 12 | Type-mismatch error printed a literal `[position]` placeholder | the message was built as `"Type mismatch at [position]"` but `[position]` was never substituted — pure noise in one of the most common diagnostics (position is already shown per-candidate as `[N]` and in the `Error:` line) | drop it, lowercase to `type mismatch` for consistency with sibling messages (`semcall.nim`); regenerated `.msgs` goldens | `errmsgs`/`generics`/`calls`/`overload` `.msgs` goldens |
| 13 | `RangeDefect` rendering a string literal > 32 KB (e.g. a generated data table) | `RenderTok.length` was `int16`; `int16(s.len)` overflowed | widen `RenderTok.length` `int16` -> `int32` (field is write-only within the renderer, so safe) (`renderer.nim`) | — |

---

## Known limits (not yet fixed)

- **Raise-across-await** — the `.raises` error-tuple ABI was never threaded
  through the coroutine lowering (`coro_transform` types the lifted result as
  raw `ptr T`, not `ptr (ErrorCode, T)`). The crash is gone (issue #4), but real
  cross-`await` exception propagation is a deferred *feature*; the `nimony-web`
  library propagates errors via `Future.err`.
