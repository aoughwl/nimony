# Nimony, but better

An opinionated fork of [Nimony](https://github.com/nim-lang/nimony) — the NIF-based
reimplementation of the Nim compiler — that tracks upstream `master` **daily** and
ships a standard library built to *our* taste instead of waiting on someone else's.

Same compiler core. Fewer opinions imposed on you, more of ours baked in.

## What's different

- **Stays current.** We pull from `nim-lang/nimony` master ~daily, so you get all of
  upstream's compiler progress with none of the lag. This is a fork that keeps up, not
  one that drifts.
- **A fuller, opinionated stdlib.** 60+ modules and counting — batteries the official
  tree doesn't ship yet, or ships grudgingly: `terminal` (with fluent, npm-`colors`-style
  string styling), `base64`, `md5`, `sha1`, `bitops`, `complex`, `deques`, `heapqueue`,
  `editdistance`, `sequtils`, `options`, `random`, `wordwrap`, and more. Ergonomics first.
- **Carries real PR work.** I'm an active Nim / Nimony contributor. Work I'd rather not
  route through upstream's review queue lands here first — usable today, not parked
  behind a process.

## Why a fork?

Because sometimes you just want to ship. Upstream has its process and its gatekeeper;
this tree has neither. Nothing here is secret and nothing here is hostile — the license
matches upstream and the compiler bugfixes flow back when it makes sense. If the Nim team
wants any of this, they know where to find it. The *stdlib taste*, though, stays here.

## Fluent terminal colors

```nim
import std/terminal

echo "this is red and bold".red.bold
echo "warning".yellow
echo "selected".black.onWhite
```

Chainable string stylers alongside the classic `File`-oriented API, plus `stripAnsi` /
`visibleLen` for recovering and measuring plain text.

## Building

```sh
nim c -r src/hastur build nimony     # build the Nimony toolchain
bin/nimony c yourfile.nim            # compile
```

See [`AGENTS.md`](AGENTS.md) for the full toolchain, phase pipeline, and test workflow.

## Relationship to upstream

This mirrors and stays in sync with `nim-lang/nimony`. Compiler fixes are meant to be
portable both ways; the standard-library direction is ours to steer. Pull requests here
are welcome — no BDFL, just taste.
