# aoughwl/nimony

An opinionated fork of [Nimony](https://github.com/nim-lang/nimony) — the NIF-based
reimplementation of the Nim compiler — that tracks upstream `master` **daily** and
ships our own compiler fixes, `.passive`/async features, and a fuller, opinionated
standard library on top. Same compiler core; more of our taste baked in.

**📖 Docs + the running record of Issues Fixed & Features Added →
[aoughwl.github.io/nimony](https://aoughwl.github.io/nimony)**

- Tracks `nim-lang/nimony` master ~daily — upstream progress, none of the lag.
- Our compiler fixes + `.passive` / `{.async.}` ergonomics (see the ledger).
- 60+ stdlib modules: `terminal`, `base64`, `md5`, `sha1`, `bitops`, `complex`,
  `deques`, `heapqueue`, `sequtils`, `options`, `random`, and more.

See [`AGENTS.md`](AGENTS.md) for the full toolchain, phase pipeline, and test workflow.
The compiler-side ledger also lives in [`doc/CHANGES.md`](doc/CHANGES.md).
