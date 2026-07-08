# Nimsem daemon protocol (`nimsem serve`)

**Envelope version: `v0`** — SOURCE OF TRUTH for the LSP client. Additive changes
keep `v: 0`; a breaking change bumps the number. Clients MUST send `v` and SHOULD
reject replies whose `v` they do not understand.

`nimsem serve` is a persistent semcheck worker. It keeps one interner (`pool`),
one loaded-interface cache (`prog.mods`) and the derived style indexes warm
across many requests, so shared interfaces (notably `std/system`) are parsed and
interned once for the whole session instead of once per module. This is the
foundation for interactive / incremental (LSP) use; the cold full-build payoff is
marginal (system re-intern is CPU-cheap and wall-hidden behind parallel fan-out).

## Framing

- Transport: the worker's **stdin/stdout**. Launch with `nimsem serve`.
- Framing: **JSONL** — exactly one JSON object per line, request and reply.
  `\n`-terminated, no embedded newlines (compact-encode). Blank lines ignored.
- Synchronous and single-threaded: one reply per request, in order.
- **stderr** carries human diagnostics and the `[nimsem serve] ready v0` banner;
  never parse stderr for protocol data.

## Request envelope

```jsonc
{
  "v": 0,                // protocol version (required)
  "id": 7,               // client request id, echoed back (any JSON scalar; optional)
  "verb": "semcheck",    // see verbs below (required)
  "args": ["--isMain", "nimcache/foo.p.nif"],   // semcheck/recheck: argv AFTER `nimsem m`
  "overlays": [          // optional dirty buffers installed before the verb runs
    { "path": "nimcache/foo.p.nif", "content": "(.nif27)\n(stmts …)" }
  ]
}
```

## Reply envelope

```jsonc
{
  "v": 0,
  "id": 7,               // echoed from the request
  "verb": "semcheck",
  "ok": true,
  "outputs": ["nimcache/foo.s.nif", "nimcache/foo.s.idx.nif"],
  "diagnostics": [],     // reserved; today hard errors go to stderr
  "error": "…"           // present only when ok:false
}
```

## Verbs

### `semcheck` — implemented
Semantic-check one module (optionally a cyclic group). `args` is exactly the
argv you would pass after `nimsem m` (`--isMain` / `--isSystem` / flags, then the
primary `.p.nif`, then any cyclic-group `.p.nif` members). Writes `.s.nif` /
`.s.idx.nif` / `.s.deps.nif` to disk exactly as the one-shot path (output is
**byte-identical** to `nimsem m`) and returns the written files in `outputs`.

Before each `semcheck` the worker runs invalidation: `prog.mem` is reset and any
cached module that is stale (its `.s.nif` mtime changed) or was a compilation
input (`.p.nif`) rather than an interface is evicted. Correctness beats speed:
when in doubt, evict. Drive modules in dependency order (deps before importers).

### Dirty-buffer / overlay submission — implemented seam
An `overlays` array on any request, or the `setOverlay` verb, registers
in-memory content that overrides the on-disk file for **all subsequent** parses,
until `clearOverlay`. This is the editor "unsaved buffer" seam. Today the overlay
key is the **NIF path** the daemon reads (the `.p.nif`); wiring an editor's
*source* buffer through `nifler` into a `.p.nif` overlay is the remaining step
and does not require an envelope change.

- `setOverlay` — `{ "verb":"setOverlay", "path":"…", "content":"…" }` → `{ok:true}`
- `clearOverlay` — `{ "verb":"clearOverlay", "path":"…" }` clears one, or omit
  `path` to clear all → `{ok:true}`

### `shutdown` (aliases `quit`, `bye`) — implemented
Reply `{ok:true, verb:"shutdown"}` then the worker exits. EOF on stdin also stops it.

### `recheck` — reserved (currently aliased to `semcheck`)
Incremental re-check of ONE module against the warm cached graph. Same request
shape as `semcheck`; will diverge to a cache-diff fast path.

### `defs` — reserved (schema fixed, handler `unimplemented in v0 prototype`)
Position query. Request adds `"file"`, `"line"`, `"col"`. Reply returns a
`"symbols"` object keyed by symbol id (see below) with definition + use locations
and kinds. MUST reuse `idetools`' existing text record shape for the per-location
payload where practical; any divergence is called out to the LSP author.

### `symbols` — reserved (schema fixed, handler `unimplemented in v0 prototype`)
Name / substring symbol query. Request adds `"query":"substr"`. Reply returns the
same symbol-keyed `"symbols"` object.

## Query response shape (reserved, for `defs` / `symbols`)
Keyed by **symbol id** (the fully-qualified NIF symbol string, e.g. `foo.1.mod`):

```jsonc
{
  "v": 0, "id": 9, "verb": "defs", "ok": true,
  "symbols": {
    "foo.1.mod": {
      "kind": "proc",
      "locations": [ { "file":"…","line":12,"col":6,"role":"def" },
                     { "file":"…","line":40,"col":10,"role":"use" } ]
    }
  }
}
```

Interactive latency target: <~100 ms per query on a warm session.

## Errors
Malformed JSON → `{ "v":0, "ok":false, "error":"bad JSON: …" }` (no `id`/`verb`).
Verb-level failures (bad args, unknown/unimplemented verb) → `ok:false` with
`error`. A **hard sem error** still `quit`s the worker in this prototype (the
client observes stdin EOF); making `semcheck` failures recoverable per-request is
tracked as remaining work.

## Compatibility note
The standalone `idetools` text output format is unchanged and owned by a separate
effort; this daemon does not alter it. If `defs`/`symbols` later emit
idetools-style records they will keep that format byte-for-byte or the divergence
will be announced.
