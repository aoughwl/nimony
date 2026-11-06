# Sync ledger: upstream nim-lang/nimony 38dadf84 into the aoughwl v0 line (2026-11-06)

This is the record of the manual sync done on 2026-11-06. The fork had been
checked out from an old upstream stream; this merge moved it onto upstream
`master` (38dadf84, 559 commits ahead) while keeping every fork commit either
carried over, re-ported onto upstream's new code, or consciously dropped because
upstream already fixed the same thing. Nothing was dropped silently: each
decision has a row below. "NEEDS-VERIFY" rows are things the resolver could not
prove without building; see the "Verification" section for what was later run.

Streams that were combined: the retired v0 line (`fix/windows-close-nif-readers`
2f97bc6f, the line that actually bootstraps aowlmony) and the public fork
`master` (fb953045). The experimental `aowlgc` line is NOT in this merge; it
stays its own branch and must be re-merged on top of this one later.

IMPORTANT: upstream may already have fixed other things the fork patched. The
"redundant" lists below are what the resolvers found by reading; there may be
more. When in doubt, prefer upstream's version and delete the fork patch.

## Fixes applied after the merge commit (build breaks found by compiling)

| file | problem | fix |
|---|---|---|
| src/nimony/semdata.nim | `warnedSources` was `HashSet[PackedLineInfo]`; upstream renamed the type | now `HashSet[NifLineInfo]` |
| src/lengc/jscodegen.nim | referenced the `StoreS` statement tag, which upstream removed | dropped `StoreS` from the two `of` lists |
| src/nimony/sem.nim `patchType` | fork patch kept the user-written type usage's source position across `replace` for idetools; upstream tokens no longer carry inline line info (it is a trailing `LineInfoLit` suffix) so `withLineInfo` is gone | patch NOT ported: **needs re-port** (idetools may now report a type usage at the definition site) |
| src/nimony/deps.nim prewarm (`harvestImport`, `harvestDepImports`) | fork-only parallel pre-nifler pass used `resolveFileWrapper`, `Token.litId`, `nifstreams.open`/`fromStream`, `kind == ParLe` | ported to `resolveFile`, `isIdent`/`strId`, `loadDepsFile`, `isTagLit`/`cursorTagId` |

# Resolver G1: hexer / lengc / shoggoth / lib

## Sync ledger G1 (hexer / lengc / shoggoth / lib / config.nims)

Note: all my files in the working tree are LF (not CRLF); I kept LF. No conflict markers remain in any of them.

| file | hunk | decision | reason / evidence | follow-up |
|---|---|---|---|---|
| src/config.nims | Uninit/ProveInit lines | KEPT-OURS | upstream commented the two `--warningAsError` lines out; fork's `when not defined(windows)` block (5d7d476f) already auto-merged below, so upstream's commented lines dropped | NEEDS-VERIFY: non-Windows build may hit Uninit/ProveInit warnings-as-errors in new upstream code (Windows unaffected) |
| src/lib/tooldirs.nim | findDriver vs parserTool | MERGED-BOTH | independent additions: fork `findDriver` (15c7003c, aowlmony then nimony fallback), upstream `parserTool`. findTool never raises (returns bare name.exe when absent) so deps.nim's speculative `findTool("shoggoth")` is compatible | none |
| src/lib/nifstreams.nim | big hunk (Literals/pool/token ctors) | TOOK-THEIRS + PORTED | upstream rewrote nifstreams into a compat shim over nifpools/nifcore. fc489f5e `initializeNifStreams` re-ported as a proc at end of float section: re-creates `pool = newPool()` and re-seeds `globalTags` from models/tags TagData | NEEDS-VERIFY: nifstreams.nim still compiles (mid-file `import ".." / models / tags as masterTags`, uses newTagPool/registerTag/newPool). Nothing in this tree calls it; the external embed host does. If it fails to compile, move the proc into nifpools.nim (not mine) |
| src/lib/nifcursors.nim | MODIFY/DELETE | DROPPED (file deleted from working tree) | upstream deleted it (be087be3 "Massive refactoring: Nimony uses nifcore (#2184)"); content now nifcore/nifpools. Fork changes: e622a927 hasMore guard, 3831c66b consumeParRi guard, 5d7d476f 1_000_000 -> 100_000_000 cap, 7c66dcde close reader: cap -> upstream nifpools/nifcore has no 1_000_000 cap anywhere (grep'd src/lib); close-reader -> nifcoreparse.nim already carries `defer: rd.close(r)` (auto-merged, not mine); hasMore/consumeParRi guards are cursor-model specific, nifcore Cursor has `rem`-based hasMore | NEEDS-VERIFY: error path rendering of unresolvable call (tests with errmsgs) no longer asserts; and a very large single compilation unit (>1M tokens) |
| src/hastur.nim | MODIFY/DELETE | DROPPED (file deleted) | upstream replaced by src/hastur/. Fork changes: 7f05fb0b concept-of parser overlay -> superseded by nifler/config.nims patchFile + nimparser/upstream.commit + `syncNimParser` (src/hastur/deps.nim); de337c4c default jobs = all cores -> src/hastur/hastur.nim:259 `parallelJobs = countProcessors()` and walk.nim serialDirs replaces `hastur.serial`; 4e65d2ad nimcache_static keyed on cc cmd -> src/nimony/deps.nim ~1047-1070 digest. | NEEDS-VERIFY: src/nifler/nim.cfg still has the fork's `--path: $config/../../.nim_overlay` line (not mine, harmless when dir absent; could be removed). tests/nimony/{threads,plugins}/hastur.serial fork marker files are now unused |
| src/hexer/constparams.nim | trCall region | TOOK-THEIRS | upstream removed the whole `.raises` tuple lowering (produceSuccessTuple/trRaise/trFailed, nextRaiseIsSpecial). Fork's 7760ab5f part 3 (trFailed non-Symbol operand) therefore moot: file now byte-identical to upstream | NEEDS-VERIFY: tests/nimony/cps with `.raises` + await |
| src/hexer/coro_transform.nim | coroTypeForProc/Wrapper/stateToProcName | TOOK-THEIRS | upstream 1f8e608b "name passive-proc coro helpers for the defining module (#2344)" + b2ba55ed (coroHelperName, publishWrapperSignature) supersede fork 0e144ece. Also removed fork-only auto-merged `coroSuffix` and `publishForeignPassiveWrapper` (dead): file == upstream | tests/nimony/cps/tcrossmodulepassive (exists in both; AA in tests, another agent) |
| src/hexer/cps.nim | 2 hunks (call site wrapper) | TOOK-THEIRS | same as above (publishWrapperSignature replaces publishForeignPassiveWrapper); file == upstream | same |
| src/hexer/desugar.nim | CallX/ConvX dispatch | MERGED-BOTH / PORTED | upstream dropped string-concat chain from CallX (taken); fork RangeCheck runtime (357570ab) is not in upstream (no nimIRcheck anywhere upstream) so KEPT: `of ConvX, HconvX` case + `trRangeConv`, ported to the new cursor idiom (`n.childCursor`, `n.into`, `pool.symId`, `addParLe`). ConvX/HconvX removed from upstream's trSons list | NEEDS-VERIFY: tests/nimony/rtchecks/trangeconv; compile of trRangeConv (childCursor/skip on bounded cursor, `dest.addParLe(convKind, info)`); lib/std/system/panics.nim must still define nimIRcheck (not mine) |
| src/hexer/lambdalifting.nim | hunk 1 (itertype else branch / containsClosureProcType) | TOOK-THEIRS | upstream #2251 (issue #2244) lifts type bodies via treType and republishes; supersedes fork 75da5035. Fork helpers containsClosureProcType/treTypeBody removed (they were unreferenced) | tests with closure-typed object fields |
| src/hexer/lambdalifting.nim | hunk 2 (captured param, Araq XXX) | PORTED | fork 8878ac65 var/out-capture error kept: added `let capturedParamType = n` + `if typeKind in {MutT, OutT}: error ...` before the env-assign, upstream's new env-owner comment preserved. Upstream still has the bare XXX | NEEDS-VERIFY: `error(msg, cursor)` resolves in hexer (decls.error exists, used by defaultvalues.nim) |
| src/hexer/lambdalifting.nim | hunk 3 (TypeS) | TOOK-THEIRS | upstream code is a superset (isLiftedClosureTuple + republish) | |
| src/hexer/mover.nim | singlePath body | TOOK-THEIRS | upstream rewrote the analysis over final IR positions (scanAt/afterNode set `otherUsage = at(base,pos)` = the real use site); fork 6fe69882 (diagnostic position fix on the old pc-based walk) is moot | NEEDS-VERIFY: move-analysis diagnostic positions in tests/nimony/*.msgs |
| src/hexer/lengcgen.nim | 4 hunks | TOOK-THEIRS (whole file == upstream) | upstream implemented discriminated unions natively (`trBranchRanges`/`trBranchBody`, union branches carry `(ranges)`; `isUnionBranch` in lengc/gentypes). Fork e0fd7c17 `(variant ...)` pragma (variantPragma param, trRanges) superseded. Auto-merged trField/trCase fork bits removed with it | src/lengc/{codegen,llvmcodegen,gentypes}.nim still contain fork `of VariantP:` arms (auto-merged, other agent/not mine) and models have `variant` pragma tag: now dead; remove or keep consistent with regenerated tags |
| src/lengc/llvmdebug.nim | 2 hunks | TOOK-THEIRS (whole file == upstream) | fork e2cbc253 DWARF variant part superseded by upstream's `selectorType`/`addUnionMember(.., selectorType)` | NEEDS-VERIFY: variant-object debug info |
| src/lengc/lengc.nim | action dispatch x2 | MERGED-BOTH | upstream `getOrQuit(actionTable, ...)` style; kept fork JS backend hooks (4ba64cd3): `import jscodegen`, `js` command, `atJS` cases using getOrQuit; `atJS` exists in noptions.nim (auto-merged) | NEEDS-VERIFY: jscodegen.nim (untouched, fork-only) compiles against current nifmodules/mangler/nifcdecl APIs; `lengc js` smoke |
| src/lengc/shoggoth/constant_folding.nim | import | PORTED | upstream `import nifpools` (bare, needs `--path ../lib`); fork removed `--path` from lengc/hexer nim.cfg (5d7d476f) => spelled `import "../../lib" / nifpools` | |
| src/lengc/shoggoth/optfuzz.nim | import | PORTED | same | |
| src/lengc/shoggoth/nifrender.nim | import | PORTED | `import "../../lib" / [nifpools, nifbuilder]` | |
| src/lengc/shoggoth/intermodinliner.nim | import | TOOK-THEIRS | upstream no longer imports nifstreams/cursors (nifprelude include suffices) | |
| src/lengc/shoggoth/imi_bridge.nim | import | TOOK-THEIRS | same | |

## Fork commits that now look redundant
- 0e144ece (cross-module .passive) -> upstream 1f8e608b / b2ba55ed (coroHelperName, publishWrapperSignature); upstream has the same test name tcrossmodulepassive.
- 7760ab5f part 3 (trFailed) -> upstream removed tuple raises lowering.
- 75da5035 (closure proc type in object field) -> upstream #2251/#2244 in lambdalifting TypeS.
- 6fe69882 (mover diagnostic position) -> upstream mover rewrite.
- e0fd7c17 / e2cbc253 (variant pragma + DWARF variant part, #2068) -> upstream native discriminated unions (trBranchRanges, isUnionBranch, selectorType).
- 7f05fb0b, de337c4c, 4e65d2ad (hastur overlay / jobs / nimcache_static key) -> src/hastur/*, nifler config.nims patchFile, deps.nim digest.
- nifcursors patches e622a927, 3831c66b, 7c66dcde, cap part of 5d7d476f: file removed upstream, no 1M cap in nifcore.

## Fork patches re-ported
- trRangeConv + ConvX/HconvX case in desugar.nim (357570ab), new cursor idiom.
- var/out capture error in lambdalifting.nim (8878ac65).
- JS backend hooks in lengc.nim (4ba64cd3) using getOrQuit.
- initializeNifStreams in nifstreams.nim (fc489f5e) over nifpools.
- shoggoth "../../lib" / nifpools spelling (5d7d476f). config.nims `when not defined(windows)` Uninit/ProveInit kept.
- findDriver (15c7003c) kept in tooldirs.nim.

## IMPORTANT for the coordinator (not my files)
- src/hexer/nim.cfg and src/lengc/nim.cfg lost `--path: "../lib"` (fork 5d7d476f merged cleanly). All hexer/lengc sources now spell lib imports relatively (checked with grep, plus my shoggoth fixes), BUT anything they import from src/nimony/* that uses bare lib imports (e.g. `import nifpools`) needs the path; if build fails on "cannot open file: nifpools" restore `--path: "../lib"` in those two cfgs (and then the "../../lib" spelling in the 3 shoggoth files risks the bootstrap-compiler double-module problem: use bare names there instead).
- src/nifler/nim.cfg has fork's .nim_overlay line (obsolete).

## External hexer hook (aowlhexer)
A standalone `hexer.exe` can NOT be produced from this tree. Upstream src/hexer/hexer.nim is a library module only (`import lengcgen, dce2; export expand, deadCodeElimination, computeLiveSet, dceEmit`); its CLI moved into `src/lengc/shoggoth/shoggoth.nim` (commands `c`, `d`, `dl`, `de`, plus `opt`/`pat`). `hastur build` has no `hexer` target (only `shoggoth`, builders.nim buildShoggoth; boot.nim BootSelfTools = nimsem, shoggoth, lengc, nimony). deps.nim calls `findTool("shoggoth")` and `defineHexerCmds(b, shoggoth, ...)` invokes `<tool> c --bits ... ` i.e. the shoggoth CLI. So an aowlhexer substitute must be installed as/under the name `shoggoth` or speak the shoggoth CLI (c/d/dl/de, and `opt` only when the optimizer is on). If an external-`hexer`-if-present override is wanted, deps.nim can use `fileExists(findTool("hexer"))` (findTool never raises). tooldirs.nim needed no change for that.


# Resolver G2: src/nimony (front end)

## Sync ledger G2 (src/nimony: contracts_fir, deps, expreval, idetools, macro_plugin, renderer, sem, sembasics, semmagics, semmain, semos, semtypes, sigmatch)

All 53 conflict hunks resolved; no markers left in these files (grep verified). Nothing compiled (hard constraint).
Line endings: all LF, untouched.

## Hunk table

| file | hunk | decision | reason / evidence | follow-up |
|---|---|---|---|---|
| contracts_fir | buildErr head + `userSymName` | TOOK-THEIRS | upstream `buildErr(c: FirContext, rawInfo)` + `asNimCode(sym)` replaces our 9f15ac4d `userSymName` ("result", not "result.0"). `userSymName` now unused and dropped | NEEDS-VERIFY: init error for `result` prints `result` (tests/nimony errmsgs for "cannot prove that result has been initialized") |
| contracts_fir | checkInRange value fold / CharLit | TOOK-THEIRS | upstream folds `foldOrdinal(c.bits, value)` (expreval `getConstOrdinalValue` handles CharLit) before the symbol path; supersedes our 9225cbe9 char-range case | NEEDS-VERIFY: `var c: range['a'..'z'] = 'b'` |
| contracts_fir | traverseExpr head (journaled-tracker / NjvlContext) | TOOK-THEIRS | upstream FirContext/TagLit structure; our `c.tr` journaled design is already what upstream has | - |
| contracts_fir | result/out-param init message | TOOK-THEIRS | `asNimCode(...)` | as row 1 |
| contracts_fir | (non-conflict) RangeCheck runtime mode | PORTED | fork 357570ab/85295612: added `FirContext.rangeChecks`, `checkRangeAssign(..., runtimeChecked=false)` passing `reportUnprovable = not runtimeChecked` to `checkInRange` (upstream already has the `reportUnprovable` switch; out-of-range literal still always an error), explicit ConvX/HconvX site passes `runtimeChecked = c.rangeChecks`; `analyzeFinalIr`/`analyzeContractsFinalIr` got trailing `rangeChecks = false` | NEEDS-VERIFY: tests/nimony/rtchecks/trangeconv (needs hexer/desugar RangeCheck part, other agent) and errmsgs/trangecheck |
| deps | imports | MERGED-BOTH | upstream list + `osproc` (needed by `execProcesses` in our `preNifle`) | - |
| deps | nifler invocation | MERGED-BOTH | upstream `execArgs c.nifler args` (no shell) kept; fork's parallel `preNifle` pre-pass (fd6636ee) kept by turning `niflerCommandFor` into `niflerArgsFor` returning an argv; `execNifler` = `execArgs`; `preNifle` renders argv with `semos.renderCmd` (now exported) for `execProcesses` | NEEDS-VERIFY: cold build of tests/nimony (discovery pre-pass + `execProcesses` on Windows quoting) |
| deps | sharedObjFile / ccIdentity | TOOK-THEIRS | upstream keys shared `.compile` objects on abs source path + customArgs + full cc argv (`ccKey`, `uhashBase36`); same intent as our 4e65d2ad (key on cc command). Our FNV `ccIdentity` dropped | the "no debug mimalloc" half of 4e65d2ad lives in lib/std + hastur (not mine) |
| deps | cc cmd flag collection | MERGED-BOTH | upstream `ccArgs` (targetDriverFlags, -fwrapv, ...) used; `-I rootPath(c)` deliberately NOT added to `ccArgs` (fork fix fb953045); the per-node `args` slot with `-I rootPath` for project TUs (auto-merged, verified at the `cc` do-node) is kept | NEEDS-VERIFY: build from cwd and parent dir yields one `static_*.o` |
| deps | -fPIC / opt level / passC | MERGED-BOTH | theirs names (`ccArgs`), ours dropped `-I` | - |
| deps | 3x `sharedObjFile(cfile, ...)` | TOOK-THEIRS | `ccKey` | - |
| deps | (non-conflict) external hexer hook | PORTED | see section below | see below |
| expreval | evalBitSetImpl | TOOK-THEIRS + fork `int()` casts | upstream passes `bits`; re-applied our `result[int(i shr 3)]` index casts (32-bit/--bits:32 self host; newSeq `int(s)` was already auto-merged) | - |
| idetools | usages requestedInfo | MERGED-BOTH | upstream `NifLineInfo(file: pool.filenames.getOrIncl(..))`; fork b4506b6d absolute-path normalisation (`relativePath(.., getCurrentDir(), '/')`) kept in front (nifler still `--portablePaths`) | NEEDS-VERIFY: tests/nimony/track absolute query path |
| macro_plugin | imports | TOOK-THEIRS | `dirs, paths`, `compat2` | - |
| macro_plugin | tooldirs / shellArgs import | MERGED-BOTH | `from tooldirs import findDriver` (aowlmony driver, 15c7003c) + `from semos import shellArgs` | - |
| macro_plugin | `hostifyPluginArgs` | TOOK-THEIRS (SUPERSEDED) | upstream threads `hostCommandLineArgs` (outer cmd line minus target triple; nimony.nim builds it) which fixes the same `--bits:32` leak our 24dc83bf stripped | NEEDS-VERIFY: JS/--bits:32 harness with macros (tests/nimony/macros, cps); check nimony.nim's hostCommandLineArgs drops `--bits` |
| macro_plugin | pluginBaseName / pluginCache / setup / cmd (4 hunks) | TOOK-THEIRS | upstream `macroFileStem`, `macro_setup.nim`, `shellArgs(hostCommandLineArgs)`; call site `nimonyExe = findDriver()` (non-conflict, ours) kept | - |
| semos | selfExec, plugin cmd, runProgram, prepareEval | TOOK-THEIRS + `findDriver()` | upstream `shellArgs(...)` and `buildWriteNifModule` under vfs lock; every `findTool("nimony")` in semos replaced by `findDriver()` (15c7003c). `.aowl` fallback in `resolveFile` (0a45053c) verified intact (auto-merged) | NEEDS-VERIFY: aowlmony root without `nimony.exe` runs a CTFE/plugin sub-compile |
| semos | (non-conflict) | edit | `renderCmd` exported (`renderCmd*`) for deps.preNifle | - |
| semtypes | SetT head | MERGED-BOTH | upstream `takeInto` structure + our `isRangeExpr -> semRangeTypeFromExpr` (1dc52142: `set['a'..'z']`) | NEEDS-VERIFY: tests with `set['a'..'z']` |
| semtypes | ordinal / too-large error | TOOK-THEIRS (SUPERSEDED) | upstream `buildErrAt dest, setStart, errMsg` replaces the whole `(set ..)` tree: same bug as our `dest.shrink setStart` fix | NEEDS-VERIFY: "set element type must be ordinal" no longer a `[Bug]` traceback |
| semtypes | too-large error | TOOK-THEIRS | as above | - |
| semmagics | hasError / semCompiles | MERGED-BOTH | upstream restructure (`globalTags.registerTag`, `into`) + our `hasError(dest, start)` scanning only from `beforeExpr` (2f97bc6f). Upstream is STILL broken (scans from 0) so the fork fix is required | NEEDS-VERIFY: a `compiles()` after an earlier module error |
| semmain | 2x contract pass | TOOK-THEIRS + PORT | upstream `derefsOf` + `lowerAndProve`; our `analyzeContractsFinalIr(...rangeChecks=)` calls dropped, `lowerAndProve` now passes `rangeChecks = RangeCheck in parseFlags(c.g.config.checkFlags)` to `analyzeFinalIr` | as contracts_fir RangeCheck row |
| sembasics | warn / combineErr | MERGED-BOTH | kept our `warn` (#1056 warning, retyped `NifLineInfo`); upstream `combineErr` (non-conflict, already NifLineInfo) + `buildErrAt` taken; our old PackedLineInfo `combineErr` dropped | **semdata.nim:253 `warnedSources*: HashSet[PackedLineInfo]` must become `HashSet[NifLineInfo]` (not my file)** |
| sigmatch | Match fields | MERGED-BOTH | kept `namedArgsReordered`/`namedArgsReorderInfo` (retyped NifLineInfo) + upstream `resolvedChoice`, `missingConstraints` | (a7515346 `&` message verified: no `concat` left) |
| sem | findObjFieldAux return | MERGED-BOTH | upstream `takeLocal`/`field.name.symId` + fork `pos: fieldPos` / `inc fieldPos` (needed by #1056 warning; `ObjField.pos` is in semdata) | - |
| sem | semReturn | MERGED-BOTH | upstream `takeInto`/IteratorY + our NoSym guards (3574a13a): upstream still asserts when `c.routine.kind == NoSym` | NEEDS-VERIFY: `return` at module level gives an error, no crash |
| sem | semYield | MERGED-BOTH | upstream + our NoSym -> autoType guard | same |
| sem | semDelay (3 hunks) | TOOK-THEIRS (SUPERSEDED) | upstream re-sems the flattened `(delay fn args)` as a call (same fix as 7d46bcf8/24dc83bf) and adds escape checks | NEEDS-VERIFY: generic `race[T]` / delay-spawn in tests/nimony/cps |
| sem | semSuspend | TOOK-THEIRS (SUPERSEDED) | upstream types `suspend` void on re-sem (d1ba638a/7aa054af) | NEEDS-VERIFY: generic .passive proc |
| sem | buildObjConstrField default | TOOK-THEIRS (SUPERSEDED) | upstream emits `field.val` and handles generic bindings with `instantiateExprIntoBuf` (our 3f406b4d deliberately skipped bindings) | NEEDS-VERIFY: `labelCounter: int = 1` and generic default |
| sem | forward decls, fieldsPresentInInitExpr, caseHasSetField, of/else/best-branch bodies, emitNestedCase (6 hunks) | TOOK-THEIRS (SUPERSEDED) | upstream's `buildObjConstrFields` recursion + `nextField(keepCase=true)` handles nested case-in-case (efd5adc6 fix); our `emitNestedCase`/`caseHasSetField` removed entirely | NEEDS-VERIFY: nested case-in-case object construction test |
| sem | after semObjDefault: `flatFieldDeclOrder` vs `asksForNil`.. | MERGED-BOTH | kept both; `flatFieldDeclOrder` rebounded with `sub(f)` (upstream's `nextField` wants a bounded cursor) and `isDotToken/isSymbol` | - |
| sem | semObjConstr field loop | MERGED-BOTH | upstream always stores field sym (`addSymUse`), plus our `givenOrder.add field.sym` | - |
| sem | semObjConstr tail | MERGED-BOTH | our #1056 warning (e883ea94; `isGenericObj` no longer exists upstream so the guard was dropped; `warn` dedups by position) + upstream `nilableAllocResult` | NEEDS-VERIFY: tests/nimony for #1056 warning (flat objects only) |

## External hexer hook (aowlhexer)

- `deps.nim`: new `externalHexer()` = `findTool("hexer")` (same lookup as every other tool: cwd, then `binDir()`); returns the path only if `os.fileExists`, else `""` (findTool never raises, it returns the bare `hexer.exe` name when missing). Both `defineHexerCmds` call sites (generateFinalBuildFile ~1499, second generator ~2467) use it, falling back to `shoggoth` exactly as upstream when absent. The `optimize` command keeps using `shoggoth`.
- RISK: a stale `hexer.exe` left in a dev `bin/` of a checkout will now silently win over shoggoth. Delete it or keep it only in the aowlmony root.
- CLI compat (compared `src/lengc/shoggoth/shoggoth.nim` options with `sync/fm:src/hexer/hexer.nim`): the old hexer knows `c d dl de`, `--bits --cpu --outdir --isMain --app --flags`. Shoggoth additionally takes `--os:`, `--native`, `--crt`, `--cycles` (and its own `opt/pat`). The old hexer prints help and fails on unknown options, so with the external hexer `defineHexerCmds(legacyHexer = true)` omits those four, i.e. emits precisely the command line the v0 line used to emit. Consequence: no `--os:` (Windows `main` shape), `--native`, `--crt`, `--cycles` for aowlhexer. NEEDS-VERIFY: that aowlhexer's output (.x.nif / .c.nif formats) is still consumed correctly by upstream's lengc, and whether aowlhexer wants those flags (then drop `legacyHexer`).

## Fork commits that now look redundant

- 24dc83bf/7d46bcf8 (delay-spawn generic re-sem) and 7aa054af/d1ba638a (suspend void): upstream sem.nim has independent equivalents (delay re-sem as call; "suspend is declared void" comment).
- 3f406b4d (field default): upstream buildObjConstrField emits `field.val`, handles generics.
- efd5adc6 (nested case-in-case): upstream `buildObjConstrFields` recursion.
- 1dc52142 second half (error node must replace `(set ..)` tree): upstream `buildErrAt`.
- 9f15ac4d (`result.0` message): upstream `asNimCode`.
- 9225cbe9 (char range): upstream `foldOrdinal` path.
- 24dc83bf hostifyPluginArgs: upstream `hostCommandLineArgs`.
- 4e65d2ad (deps cache key): upstream `ccKey` + `uhashBase36` (the mimalloc-debug half is outside my files).
- 3831c66b (renderer must not assert): upstream removed `skipParRi` in favour of `into`; whether `into` is as tolerant on a malformed tree is unproven (NEEDS-VERIFY: error message for an unresolved expression, tests/nimony errmsgs).
- bf9dfbb9 (RenderTok length int32): kept (auto-merged), upstream did not change it.
- 6086199e/fcdaee59/9d8edc8f (nil tracking through and/or): upstream contracts_fir works on the lowered Final IR where `and/or` are already control flow; no `AndX/OrX` nil-refinement code exists upstream. Treated as SUPERSEDED by structure, NEEDS-VERIFY: `if p != nil and p.x > 0` style nil-guard tests.
- 91adf00a (implications.nim) is not in my files.

## Fork patches re-ported

- RangeCheck runtime mode (contracts_fir + semmain), see above.
- `.aowl` import fallback in semos.resolveFile: survived the auto-merge unchanged.
- `findDriver()` for all self sub-compiles in semos + macro_plugin (nimsem.nim not mine).
- `compiles()` only inspects own errors (semmagics).
- `return`/`yield` outside a routine guards (sem).
- `set['a'..'z']` range-expression element (semtypes).
- #1056 out-of-order constructor warning (sembasics `warn`, sigmatch fields, sem `flatFieldDeclOrder` + `ObjField.pos`).
- deps: preNifle parallel pre-pass (on top of upstream's execArgs), project include path per node, external hexer hook.
- idetools absolute path normalisation, expreval int() index casts.

## Needs action outside my files

- `src/nimony/semdata.nim:253`: `warnedSources*: HashSet[PackedLineInfo]` -> `HashSet[NifLineInfo]` (NifLineInfo has `hash`/`==`).
- `src/nimony/nimony.nim`: verify `hostCommandLineArgs` strips `--bits` for the JS harness.
- `hastur`/`lib/std` mimalloc half of 4e65d2ad.


# Resolver G3: std lib, tests, docs, generated tags

## Sync ledger G3 (worktree wt-union, merge of upstream/master 2026-11-06)

| file | hunk | decision | reason / evidence | follow-up / NEEDS-VERIFY |
|---|---|---|---|---|
| lib/std/rawthreads.nim | CreateThread decl (1 hunk) | MERGED-BOTH | Upstream switched ALL Windows imports from `header: "<Windows.h>"` to `dynlib: "kernel32"` (no C prototype from header => the GCC 14 `unsigned long` vs `unsigned int` clash of fork fix dd503f39 should no longer arise). But the fork's auto-merged parts (WinThreadProc returns `culong`, `threadProcWrapper`, call site passing `culong(0)`/`var culong`) are outside the hunk and stayed, so the hunk takes upstream's `dynlib: "kernel32"` with fork's `culong` param types (culong is 32-bit on Windows = DWORD, correct either way). Taking upstream's `uint32` would have mismatched the call site. | NEEDS-VERIFY: build + run tests/nimony/threads/threads1 and tparfor on Windows (gcc 14). Could later fully drop fork culong bits if upstream's uint32 form proves fine (low priority). |
| tests/nimony/threads/threads1.nim, tparfor.nim | tail (Windows stub) | MERGED-BOTH | Kept fork un-stubbing (`main()` unconditionally, comment) + upstream's trailing `{.feature: "assumeSync".}` line. Upstream still stubs Windows. | NEEDS-VERIFY with rawthreads above; if threads fail on Windows, re-stub. |
| lib/std/terminal.nim | fluent section vs cursor wrappers | MERGED-BOTH | Not the same feature: upstream (b0b37a5a) added cursor/erase/size/truecolor + stdout wrappers; fork (60110d01) added string-returning styling funcs (red, bold, onWhite, stripAnsi, visibleLen ...). Disjoint, so both kept: upstream wrappers first, fork fluent block after. Checked name clashes: std/colors `red/green/blue(Color)` are non-exported; `stylePrefix` exists upstream. | NEEDS-VERIFY: compile tterminal and tterminal_fork (overload ambiguity of `red` etc. if a module imports both std/colors and std/terminal). |
| tests/nimony/stdlib/tterminal.nim | ADD/ADD | TOOK-THEIRS | Upstream test covers upstream API (cursor, truecolor, size); fork test covers the fluent API only; no overlap. | - |
| tests/nimony/stdlib/tterminal_fork.nim (new) | - | KEPT-OURS (renamed) | Fork's fluent-API assertions; passes only if fluent block kept (it is). No .output (prints nothing); fork's original had none. | NEEDS-VERIFY: run it. |
| tests/nimony/cps/deps/mcrosspassive.nim, tcrossmodulepassive.nim, .output | ADD/ADD | TOOK-THEIRS | SUPERSEDED: upstream versions are strict supersets (same pingpong/addUp/driver cases + methods + iterators). Fork output is the first 7 lines of upstream's. Fork commit adding cross-module passive is redundant IF upstream's hexer logic is what is kept (hexer owned by others). | Coordinator: the hexer/coro_transform merge must provide cross-module passive; run tcrossmodulepassive. |
| tests/nimony/calls/tcall_module_arg.msgs, errmsgs/tdistinctinfos.msgs, errmsgs/tifconderr.msgs | whole file | TOOK-THEIRS + wording patch | Took upstream (line numbers/candidate lists follow upstream's lib), then changed first line `Error: Type mismatch at [position]` to `Error: type mismatch` because the merged src/nimony/semcall.nim (line ~1441, auto-merged, not conflicted) has fork's 7df447ef form `errorMsg = "type mismatch\n"` and upstream did not touch that line. | NEEDS-VERIFY: run the 3 tests. Declared-in line numbers could differ if fork changed lib files. |
| .gitignore | 1 hunk | MERGED-BOTH | Union, no duplicates (upstream: _hastur_joined.nim, nimparser entries, system/upstream/; fork: .nim_overlay/, .claude/, _*.log). | - |
| README.md | 2 hunks | TOOK-THEIRS | README: TOOK-THEIRS, coordinator rewrites. | coordinator |
| doc/tags.md | 1 hunk | MERGED-BOTH | Upstream rows kept, fork's only added row `(variant (ranges ...)*)` LengPragma appended after upstream's last row of that table (so upstream ids unchanged). Fork diff vs base 8d22ab81 contains only that row (checked). | - |
| src/models/tags.nim, leng_tags.nim | both | REGENERATED | Ran tools/gen_tags.nim with Nim 2.2.2 (output binary/cache in scratchpad). Diff vs upstream/master version: tags.nim only +VariantTagId (id 376, after OptionkeyTagId 375) and ("variant",376); leng_tags.nim only +VariantP and VariantTagId in raw set. Other src/models/*_tags.nim unchanged by the generator. No markers remain. | - |

## Fork commits that now look redundant
- dd503f39 (rawthreads culong): partially. Upstream moved to `dynlib: "kernel32"` which avoids the C-header prototype clash; fork's culong retained for consistency, may be droppable.
- Cross-module `.passive` procs (fork test tcrossmodulepassive): upstream has the feature with a wider test (methods, iterators). Source-side redundancy is for the hexer owners to judge.

## API/compat breaks the user must know about
- None lost in std/terminal: fork's fluent functions (black red green yellow blue magenta cyan white gray grey bright*, on*, bold dim italic underline inverse hidden strikethrough, stripAnsi, visibleLen) are all kept alongside upstream's API. Upstream does not have them (fork-only extension).
- Fork-only `type mismatch` wording (no `[position]`): 8 other .msgs files that upstream added/changed still say `Type mismatch at [position]` and will fail with the fork's semcall.nim: tests/nimony/concepts/tandconstraintconceptcrash.msgs, concepts/tdollar_char_loophole.msgs, errmsgs/tdistinctnoeq.msgs, tgenericbasemismatch.msgs, tstaticparamnotconst.msgs, tsubscripterroperand.msgs, ttype_mismatch_closure_proc.msgs, stdlib/tsmartcli_variadic_mixed.msgs. Not my files; coordinator should either sed them or drop 7df447ef (upstream compat).

