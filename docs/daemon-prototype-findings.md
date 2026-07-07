# Compile-daemon prototype — Track 2 findings

**Goal:** de-risk a future Nimony "compile daemon" by (A) measuring the ceiling
of redundant work in the process-per-module model, and (B) proving the
structural win with a zero-IPC, near-zero-risk batch-in-one-process experiment.

**Toolchain:** Nim 2.3.1, debug build (no `-d:release`). nimsem/hexer built with
`-d:vfsProfile -d:idxProfile`. Machine: WSL2.

**Target:** `tests/nimony/stdlib/tall.nim` — imports 41 std modules; a
representative multi-module frontend workload. Full build spawns
**55 nimsem + 109 hexer = 164 processes**.

---

## Instrumentation added

* **`-d:idxProfile`** (`src/nimony/programs.nim`): times and counts the single
  integration seam `proc load*(suffix)` — the memoized per-process parse+intern
  of a module's `.s.idx.nif` into the process-local interner `pool`. Each
  process dumps one `[idx] <label> <suffix> cold=… warm=… ms=…` line per module
  at exit (plus a `TOTAL`). `cold` = a real parse+intern (cache miss); `warm` =
  a memoized hit within the same process. Wired into `nimsem` and `hexer` next
  to `dumpVfsProfile`.
* **`-d:vfsProfile` fix** (`src/lib/vfs.nim`): the pre-existing profiling hook
  referenced `getMonoTime`/`inNanoseconds` without importing `std/monotimes` /
  `std/times`, so it never actually compiled. Added the imports. (Latent bug,
  now usable.)
* **`tests/daemon-proto/batch_experiment.sh`**: the N-vs-1 driver for Part B.

Aggregate across processes with `awk`/`grep` over stderr (the driver spawns many
short-lived processes, one profile block each).

---

## PART A — the ceiling

Full `nimony c tests/nimony/stdlib/tall.nim` (cold nimcache), profiles
aggregated across all 164 processes:

| metric | value |
|---|---|
| `system.s.idx.nif` **re-parsed + re-interned** | **107 times** (once per process that imports system) |
| aggregate CPU spent re-parsing/interning **system's** index | **≈ 505 ms** |
| aggregate CPU in **all** index parse+intern (`load`, all modules) | **≈ 642 ms** |
| total build wall time | ≈ 6.6 s |

**Interpretation / honesty:** `system` is auto-imported by ~every module
(`deps.nim:643`), so its index is interned once per nimsem **and** once per
hexer process — 107 times here. The ~505 ms is **aggregate CPU summed across
processes**, not wall time: nifmake runs these processes in parallel
(`execProcesses(n = gMaxJobs)`), so the *wall* ceiling is `505 ms / effective
parallelism`, i.e. materially less. And the 6.6 s wall is dominated by process
spawning + the C backend, not interning. So the redundant-intern ceiling is
**real and structural but modest in wall terms for a cold debug build** — on the
order of a few hundred ms of CPU that parallelism already partly hides.

This is the number the daemon could save, and no more.

---

## PART B — proving the win (N separate procs vs 1 batched proc)

`nimsem m` accepts multiple input files; internally `semcheck` routes >1 file to
**`semcheckCycleGroup`** (`semmain.nim:568`), which processes all modules through
each phase against a **shared `prog`/`pool`**. Consequence: `system`'s index is
`load()`-ed once and every subsequent module hits the warm memo. This mechanism
**already exists** (the driver uses it today for genuine cyclic module groups via
`Node.cyclicFiles`).

Experiment: 20 independent std modules from the `tall` graph that all import
system, already-built nimcache. Run as **20 separate `nimsem m <file>`** (today's
model) vs **one `nimsem m <f1..f20>`**.

| | wall (s) | system idx cold-loads | total index parse+intern |
|---|---|---|---|
| **A: 20 separate invocations** | 0.82–0.88 | **20** | **91.6 ms** (52 cold loads) |
| **B: 1 batched invocation** | 0.61–0.65 | **1** | **8.6 ms** (12 cold loads) |

* **system interned 20× → 1×** (batched: `cold=1`, then `warm=499` reuse hits).
* index parse+intern CPU **91.6 ms → 8.6 ms (~10.6×)**; system-specific
  **74.8 ms → 3.8 ms**.
* **wall speedup ≈ 1.3–1.45×** on 20 modules, stable over repeats. Batched
  output is byte-valid (`reportErrors == 0`, `.s.nif` regenerated).

**Honesty:** the wall win (1.3–1.45×) is *larger* than the pure intern saving
(~83 ms) because batching also eliminates 19 process startups and keeps all
caches warm. BUT the "A" arm here runs the 20 processes **serially**; the real
build runs them **in parallel**, so against a parallel baseline the wall win from
serial batching is smaller — batching trades parallel fan-out for warm-pool
reuse. The rock-solid, parallelism-independent result is the **structural** one:
`20 → 1` interns and `91.6 → 8.6 ms` of intern CPU.

### Driver-side batching (Part B.2 — described, not landed)

`generateSemInstructions` (`deps.nim:1419`) emits one `(do nimsem … m <file>)`
per graph Node. To batch dependency-independent modules: group Nodes at the same
DAG **depth** with no mutual dependency into a single `(do nimsem … m fA fB …)`
node, reusing the `semcheckCycleGroup` path (already correct for shared-pool
multi-module runs). **Tension:** nifmake dispatches each depth's commands via
`execProcesses(n = gMaxJobs)` in parallel; collapsing K modules into one call
drops that depth's fan-out from K to 1. The sweet spot is bundles of
≈ `nodes_at_depth / cores`: keep every core busy while each process amortizes
system-interning across its bundle. This is a self-contained driver change with
no IPC and no new binary — strictly less risky than a daemon.

---

## Recommendation

**Do NOT build the full `nimsem serve` persistent daemon next. Build in-process
batching first.**

1. **The mechanism for 80%+ of the win already ships** (`semcheckCycleGroup`).
   The remaining work is a driver-side grouping heuristic in `deps.nim` — no
   IPC, no daemon lifecycle, no cache-coherency protocol. Low risk, reuses
   tested code.
2. **The cold-build ceiling is modest.** ~505 ms aggregate CPU for system, most
   of it already hidden by nifmake parallelism, against a 6.6 s wall dominated
   by the C backend. A daemon's incremental payoff *over batching* on cold
   builds is small and it costs real complexity (IPC, the SHA1
   `(checksum …)` coherency key already exists in `.s.idx.nif` but must be wired
   into a request/validate loop, worker lifecycle, crash recovery).
3. **The daemon's real (unmeasured) value is warm/incremental rebuilds** —
   keeping one process's `pool` hot across successive edit→compile cycles, where
   the same `system` + unchanged imports would otherwise be re-interned on every
   keystroke-driven rebuild. That is the case that would justify Phase 1, and it
   is *not* what this cold-build experiment measured. If the daemon is pursued,
   measure the incremental-rebuild scenario first.

**Expected payoff, ranked:**
* In-process depth-batching: captures the intern redundancy (10× less intern
  CPU) with a bounded parallelism trade-off; ~1.3× on serial-equivalent
  frontend work. **Ship this.**
* Full daemon on cold builds: marginal over batching. **Defer.**
* Full daemon on warm/incremental rebuilds: potentially large, **unquantified
  here** — measure before committing.

---

## Reproduce

```
# instrumented build
nim c --warningAsError:ProveInit:off --warningAsError:Uninit:off \
      -d:vfsProfile -d:idxProfile src/nimony/nimsem.nim
nim c --warningAsError:ProveInit:off --warningAsError:Uninit:off \
      -d:vfsProfile -d:idxProfile src/hexer/hexer.nim

# Part A: full build, aggregate
bin/nimony c --nimcache:/tmp/nc tests/nimony/stdlib/tall.nim 2>/tmp/err.log
grep '^\[idx\]' /tmp/err.log | grep -v TOTAL | grep <system-suffix> | \
  awk '{for(i=1;i<=NF;i++){if($i~/^cold=/){split($i,a,"=");c+=a[2]};if($i~/^ms=/){split($i,b,"=");m+=b[2]}}}END{print c,m}'

# Part B: N-vs-1 (needs a pre-built nimcache + a module list of *.p.nif)
tests/daemon-proto/batch_experiment.sh 20 /tmp/nc tests/nimony/stdlib mods.txt
```
The system module's suffix (e.g. `sysvq0asl`) is the hashed `moduleSuffix` of
`lib/std/system.nim`; find it via `grep -l system.nim /tmp/nc/*.p.nif`.
