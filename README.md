# aoughwl/nimony

This is the **v0 bootstrap fork** of [nim-lang/nimony](https://github.com/nim-lang/nimony),
the NIF-based reimplementation of the Nim compiler. We use it to compile
**aowlmony**, our from-scratch re-implementation of that pipeline (aowlsem,
aowlhexer, aowlc and friends). Once aowlmony can bootstrap itself, this fork is
no longer needed; until then it is the seed compiler the aowlmony toolchain is
built from.

It is **not** a product fork and it does **not** track upstream continuously.

## What this fork is, and is not

- It is upstream Nimony plus a small set of patches we needed to build and run
  aowlmony on Windows (see [`doc/CHANGES.md`](doc/CHANGES.md) for the patch list
  and [`doc/SYNC-LEDGER.md`](doc/SYNC-LEDGER.md) for what happened to each patch
  at the last sync).
- It is synced **by hand, rarely**. The last sync was **2026-11-06**, onto
  upstream `master` commit `38dadf84`. Before that the fork sat on an upstream
  checkout from July 2026 (`8d22ab81`). Between syncs upstream moves on without
  us; do not assume this tree has upstream's latest fixes, and do not assume a
  patch in here is still needed. Upstream may well have fixed things we patched
  ourselves.
- It is **not** the place for new aowlmony work. aowlsem, aowlhexer and the rest
  live in their own repos. Where this fork lags behind or differs from aowlmony,
  that is recorded in [`doc/aowlmony-status.md`](doc/aowlmony-status.md).

## Branches

- `master`: the public line of the fork.
- `sync/upstream-YYYY-MM-DD`: the result of a manual sync (a merge of upstream
  `master` into the fork's history, never a rebase, so no fork commit is lost).
- `archive/*`: preserved work-in-progress and retired branches pushed so that
  nothing exists only on one machine. Treat them as read-only history, not as
  maintained branches.
- `aowlgc`: an experimental tracing-GC memory mode. It is **not** part of the
  v0 line used in production and was not included in the 2026-11-06 sync; it has
  to be re-merged on top of the synced line before it can be used again.

## Building (Windows)

Nimony builds itself only through classic Nim, so you need a Nim **2.2.2**
toolchain and a MinGW gcc on `PATH` (for example the MSYS2 `ucrt64` one):

```
nim c -r src/hastur/hastur build all
```

This builds the compiler and tools into `bin/` (`nimony`, `nimsem`, `nifler`,
`shoggoth`, `lengc`, `nifmake`, ...). Run the test suite with:

```
bin\hastur.exe all --jobs:auto
```

On Linux and macOS the same two commands apply with a normal Nim 2.2.x.
[`doc/install.md`](doc/install.md) has the upstream installation notes.

### Lowering: `shoggoth` versus an external `hexer`

Upstream's driver now lowers through `shoggoth` (the hexer and the optimizer in
one binary); there is no standalone `hexer` any more. This fork keeps one
extension: if a `hexer` executable is found next to the other tools, the driver
uses it instead of `shoggoth` (this is how aowlhexer is slotted in). Such a
replacement only receives the old hexer command line, without `--os`,
`--native`, `--crt` and `--cycles`. See `doc/aowlmony-status.md`.

## Using the binaries

Do **not** drop binaries from a fresh build into a production aowlmony root
without checking that aowlhexer and the other stages still agree with the
compiler's IR and tag set; the synced compiler changed both. The production root
is seeded from older binaries on purpose.

## Upstream documentation

The rest of this tree is upstream Nimony: the [language manual](doc/language.md),
the [standard library guide](doc/stdlib.md), the
[passive procs](doc/passive_procs.md) design and the
[website](https://nim-lang.github.io/nimony-website/). Those documents describe
upstream behaviour; where this fork differs, the fork documents above win.

See [`AGENTS.md`](AGENTS.md) for the toolchain, the phase pipeline and the test
workflow.
