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

## Consumers / motivation (why the daemon exists)

The cold full-build speedup is marginal, so it is **not** the justification. The
justification is a set of index-API consumers that need a **persistent,
whole-program, interned symbol graph** — something a one-shot single-module
`nimsem m` process structurally cannot provide. Today the `nimony-lsp` side
implements these with source-scan + single-module NIF heuristics ("good"); the
daemon upgrades them to "exact" by resolving overloads across module boundaries
against the warm cross-module graph:

1. **Go-to-definition with exact overload resolution** (`defs`) — pick the exact
   winning overload at a call site whose candidates are imported from other
   modules. A single-module process only sees its own decls + opaque stubs and
   must guess; the daemon holds every imported interface in one `pool` and
   resolves precisely.
2. **Call hierarchy** (`callHierarchy`) — incoming/outgoing call sites across
   modules. Callers/callees live in other modules and the exact callee depends
   on cross-module overload resolution, so a source scan can only approximate.
3. **Go-to-type-definition** (`typeDefinition`) — resolve the type of the symbol
   at a position to its (usually cross-module) declaration site.

These three are the concrete drivers of the reserved query verbs below. Each MUST
use the warm whole-program graph; none is exact without it.

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
**Exact resolved definition** at a position. Request adds `"file"`, `"line"`,
`"col"`. The reply's `"symbols"` object holds the ONE symbol the expression at
that position resolves to — the **correct overload**, its definition site, and
its type.

Overload resolution **MUST** be performed against the warm **whole-program**
symbol graph (`prog` + interned `pool`), not a single-module guess. This is the
capability a one-shot single-module `nimsem m` process structurally cannot
provide: at a call site whose candidates are declared in (and imported from)
other modules, only the daemon — holding every imported interface interned in
one `pool` — can pick the exact winning overload. A single-module process sees
only its own module's decls plus opaque interface stubs and must fall back to
heuristics. Where resolution is genuinely ambiguous the reply lists every live
candidate (multiple keys) rather than guessing; `"resolved": true|false` marks
whether a unique winner was found.

Request:
```jsonc
{ "v":0, "id":9, "verb":"defs", "file":"src/app.nim", "line":42, "col":11 }
```
Reply keyed by symbol id, each entry carrying `kind`, `type`, definition
`locations`, and a `role:"def"` location for the definition site (see the shared
shape below). For `defs` the winning symbol's `def` location is the go-to-
definition target.

### `typeDefinition` — reserved (schema fixed, handler `unimplemented in v0 prototype`)
**Go-to-type-definition.** Request adds `"file"`, `"line"`, `"col"`. Resolves the
**type** of the symbol/expression at that position, then returns that type's
definition site — **cross-module**: the type is very often declared in a
different module than the reference, so this too requires the persistent
whole-program graph to name the exact declaring symbol. Reply is the standard
`"symbols"` object; the single key is the resolved **type** symbol id, with its
`def` location as the jump target.

### `callHierarchy` — reserved (schema fixed, handler `unimplemented in v0 prototype`)
**Incoming/outgoing call sites across modules** for a routine. Request identifies
the anchor by symbol id OR by position, and a direction:
```jsonc
{ "v":0, "id":10, "verb":"callHierarchy",
  "symbol":"foo.1.app",              // OR "file"/"line"/"col"
  "direction":"incoming" }            // "incoming" | "outgoing"
```
- `incoming`: every routine that calls the anchor (callers), across all cached
  modules.
- `outgoing`: every routine the anchor calls (callees).

Reply `"symbols"` is keyed by the **caller/callee symbol id**; each entry's
`locations` are the concrete call-site positions (`role:"call"`) that link it to
the anchor. Because callers/callees routinely live in other modules and the exact
callee depends on cross-module overload resolution, this is another consumer that
the warm daemon uniquely serves exactly (vs. a source-scan approximation).

### `symbols` — reserved (schema fixed, handler `unimplemented in v0 prototype`)
Name / substring symbol query. Request adds `"query":"substr"`. Reply returns the
same symbol-keyed `"symbols"` object (workspace-symbol style).

## Query response shape (reserved: `defs` / `typeDefinition` / `callHierarchy` / `symbols`)
Keyed by **symbol id** (the fully-qualified NIF symbol string, e.g. `foo.1.mod`).
The `type` field is itself a symbol id (or a rendered type string when the type
is structural/anonymous). `role` is one of `def` | `use` | `call`:

```jsonc
{
  "v": 0, "id": 9, "verb": "defs", "ok": true,
  "resolved": true,                     // false => ambiguous, all candidates listed
  "symbols": {
    "foo.1.mod": {
      "kind": "proc",
      "type": "proc.2.mod",             // symbol id of the (resolved) type
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
effort; this daemon does not alter it. If the query verbs
(`defs` / `typeDefinition` / `callHierarchy` / `symbols`) later emit
idetools-style records they will keep that format byte-for-byte or the divergence
will be announced.
