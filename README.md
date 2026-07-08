# Nimony, but better

An opinionated fork of [Nimony](https://github.com/nim-lang/nimony) — the NIF-based
reimplementation of the Nim compiler — that tracks upstream `master` **daily** and
ships a standard library built to *our* taste instead of waiting on someone else's.

Same compiler core. Fewer opinions imposed on you, more of ours baked in.

## What's different
- **Less bugs and more frontline features** I ship all my Nimony work here exclusively,  I also aggresively push lagging features.
- **Stays current.** We pull from `nim-lang/nimony` master ~daily, so you get all of
  upstream's compiler progress with none of the lag. This is a fork that keeps up, not
  one that drifts.
- **A fuller, opinionated stdlib.** 60+ modules and counting — batteries the official
  tree doesn't ship yet, or ships grudgingly: `terminal` (with fluent, npm-`colors`-style
  string styling), `base64`, `md5`, `sha1`, `bitops`, `complex`, `deques`, `heapqueue`,
  `editdistance`, `sequtils`, `options`, `random`, `wordwrap`, and more. Ergonomics first.


See [`AGENTS.md`](AGENTS.md) for the full toolchain, phase pipeline, and test workflow.

## Relationship to upstream

This mirrors and stays in sync with `nim-lang/nimony`. Compiler fixes are meant to be
portable both ways; the standard-library direction is ours to steer. Pull requests here
are welcome — no BDFL, just taste.
