# Picker performance: native optimization and final handoff

**Status (2026-10-14):** slices **6b–6f are implemented**. See the
[6f final handoff](#slice-6f-final-handoff--2026-10-14) for current architecture,
reopen policy, validation and limits. Final integration build/full Dune suite,
full terminal smoke, directory terminal checks and picker PTY smoke **pass**;
see [final integration verification](#final-integration-verification--2026-10-14).
The earlier blockwise-save and LSP-Undo timing failures are resolved. The
research below is the historical **6a baseline**; appended handoffs record later
changes and measurements.

2026-10-13. Research/measurement only; production behavior unchanged. Sole agent,
no git mutations, software installation, cloned repositories or large filesystem
fixtures. Existing dirty-tree work preserved.

## Decision

**Optimize the native file picker first. Keep Ches in charge of query editing,
selection, floating layout, preview, capture and acceptance.** Start with blank-query
fast paths, indexed results, compiled queries and generation-scoped reuse; then fix
streaming discovery and add bounded reopen reuse. Do not introduce a per-key fzf
process or a terminal handoff. Reconsider an optional external backend only after
these changes are measured and if the remaining gain justifies a second policy and
process protocol.

This does not establish that native is already fast enough. At 50K, settled-query
completion is roughly 80–100 ms, and cold preparation is roughly a quarter second.
Yielding protects input handling but does not make results arrive in 2 ms.

## Bounded measurements

Local fzf: `/usr/bin/fzf`, **0.44.1 (debian)**. OCaml: `5.2.0+ox`. Dune default
development profile. Synthetic fixture exactly follows the existing interaction
probe: five directories, five basenames, numbered packages/components, deterministic
input order. 10K/50K paths; serialized NUL payloads 436,000/2,180,000 bytes. No paths
were created on disk. Native candidate creation alone: 11.296/56.902 ms.

One observation per synthetic scenario, no warm-up or statistical claims. All
durations use monotonic wall clocks. Native `drain` executes bounded work turns
back-to-back: **no Async yield, frontend scheduling, frame rendering or terminal IO
inside these totals**. They are aggregate service-time observations, not live
input-to-screen latency. The native work API yields after 128 records, not after a
hard time deadline. GC and publication may exceed a desired turn budget.

### Native lifecycle

| Phase | 10K total ms | 50K total ms | 50K turns | 50K matches |
| --- | ---: | ---: | ---: | ---: |
| Cold complete snapshot, blank query | 44.633 | 256.929 | 782 | 50,000 |
| Edit `m` | 12.900 | 88.428 | 782 | 50,000 |
| Extend to `mo` | 17.634 | 97.537 | 782 | 50,000 |
| Extend to `model` | 15.827 | 83.708 | 470 | 10,000 |
| Backspace to `mode` | 17.172 | 95.085 | 548 | 20,000 |
| Backspace to `mod` | 16.149 | 88.025 | 548 | 20,000 |
| Return to `model` | 15.585 | 83.362 | 470 | 10,000 |
| Clear query | 8.437 | 44.885 | 782 | 50,000 |
| Close/reopen same complete snapshot | 41.362 | 226.128 | 782 | 50,000 |

50K cold live-heap delta after full GC: **82.436 MiB**, versus 16.487 MiB at 10K.
This is retained **interaction state**, including preparation caches and results,
above already-created candidates; not peak RSS or just decoded arrays. Every
candidate was prepared even for the empty query. Warm edits did not prepare more
candidates, but they still ranked the whole collection; repeated queries have no
result-cache shortcut. Reopening prepared all candidates again.

50K cold maximum work turn: 4.897 ms. Query maxima: 0.787–2.270 ms; clear: 0.926 ms.
Final publication turns: 0.024–0.647 ms across those queries. Those final turns do
**not** include the preceding output traversal, which has its own turns. Publication
also reverses the accumulated list and preserves selection synchronously.

Tile-only render at 160×36 (no disk preview data): 50K blank 1.338 ms; after blank
Next 0.804 ms. Next update plus fit: 0.716 ms. Query-update-plus-fit observations:
0.060–3.162 ms; post-query tile renders: 0.547–1.972 ms. Selection was near the head;
deep-selection/worst-position list scans were not benchmarked. These are distinct
from full frame or terminal rendering.

### Discovery/install simulation

The probe reproduces `Provider.poll`'s map insertion + `Map.data` per 128-candidate
batch, then `Interaction.install` and one work turn per snapshot. It is deliberately
**not a filesystem discovery benchmark**: batches are immediately available, no rg
process, Async scheduler or UI work is present.

| Count | Batches | Map insertion + cumulative-list rebuild ms | Restarted first turns ms | Final drain ms |
| --- | ---: | ---: | ---: | ---: |
| 10K | 79 | 5.738 | 3.208 | 38.464 |
| 50K | 391 | 66.100 | 17.007 | 290.637 |

Only **256** candidates had been prepared before the final drain at either size.
Restarting on every cumulative snapshot repeatedly visits the sorted head rather
than progressing through newly discovered entries. The 50K final drain had one
36.942 ms maximum turn; retain this outlier, do not claim every turn is below 2 ms.
The simulation sums to about 374 ms at 50K, but cannot be substituted for cold-open
latency. Real discovery backpressure, batch timing and coalesced redraws differ.

### Actual host, small real project

`host_probe` uses actual rg discovery, `Runtime.pump`, `Ui_state.apply_all`, and
`Frame.render`, at 160×40 on this checkout (445 discovered files). It eagerly renders
every injected event batch, including ranking-only turns. This includes scheduling
and frame construction, excludes Bonsai view/terminal transport and asynchronous
disk previews, and is not the production redraw cadence.

Final verified observation:

| Phase | Total ms | Injected batches | Sum of frame construction ms |
| --- | ---: | ---: | ---: |
| Cold open through final published results/frame | 30.019 | 18 | 19.624 |
| Edit `m` (392 matches) | 11.977 | 8 | 8.058 |
| Extend `mo` (46 matches) | 8.522 | 5 | 4.928 |
| Backspace `m` | 12.047 | 8 | 7.952 |

Movement apply + frame: 1.213 ms. Max apply-and-frame batch across final phases:
1.924 ms. Cleanup printed `finished=true`. Two earlier development observations
were 27.688/30.566 ms for cold open; they prompted checking cleanup and are not
pooled into a latency distribution. Real Async reopen was not measured; same-snapshot
reopen above establishes redundant native work only. No new PTY latency claim.

### CLI fzf filter, including subprocess/pipe IO

Each query uses a **fresh process**. Environment clears `FZF_DEFAULT_OPTS` and
`FZF_DEFAULT_COMMAND`, limits Go execution with `GOMAXPROCS=2` to avoid server
stress. Args: `fzf --read0 --print0 --extended -i --tiebreak=index --filter=QUERY`.
Timer includes process spawn, input delivery, matching/sorting, all output draining
and process exit. Output splitting into Python byte strings is separately timed.
Pre-serialized input is reused; serialization is 5.570/28.176 ms for 10K/50K,
including Python fixture generation. No candidate-ID mapping or highlighting cost
is included. No shell is used, timeout is 10 seconds per child, queries sequential.

| Query progression | 10K child ms | 50K child ms | 50K split ms | 50K matches |
| --- | ---: | ---: | ---: | ---: |
| blank | 13.642 | 61.546 | 3.059 | 50,000 |
| `m` | 19.698 | 78.720 | 3.792 | 50,000 |
| `mo` | 19.265 | 81.406 | 2.816 | 50,000 |
| `model` | 8.364 | 28.942 | 1.261 | 10,000 |
| `mode` | 11.564 | 43.014 | 1.264 | 20,000 |
| `mod` | 11.996 | 42.597 | 0.912 | 20,000 |
| `model` again | 8.611 | 28.308 | 0.474 | 10,000 |
| blank again | 12.968 | 56.861 | 1.820 | 50,000 |
| `src mod` | 7.621 | 28.606 | 0.464 | 4,000 |
| `zzzzzz` | 5.632 | 13.035 | 0.301 | 0 |

A first invocation failed immediately because this version does not recognize
`--ignore-case`; the probe was corrected to `-i` before the measured run. The
extra native-query token/no-match cases were not freshly benchmarked in this slice.

**Policy is not equivalent.** Native uses ASCII folding, whitespace token AND,
best-field scoring with basename weight 150/path 100, exact-field bonus, stable
discovery-order ties and command-vs-loose policy. fzf searches one full-path field,
has its own bonuses/normalization/case/tie behavior and extended operators. Counts
agree on the shared ASCII query progression; that is not proof of identical order,
positions or behavior on arbitrary queries/paths. A `path` scheme or `--nth` is not
the existing weighted two-field policy. Full-result CLI output also transfers
2.18 MB on every broad query. Selective-query gains are real observations but
insufficient to justify replacing the native lifecycle.

## Source audit

- `palette/fuzzy.ml`: three native-word integer arrays per prepared field
  (folded scalars, byte offsets, bonuses); transient decoded tuples; full score and
  predecessor matrices for matching fields; positions constructed for every match.
  `Search.prepare` duplicates basename and path decoding. `Interaction.work` calls
  `Search.rank` separately for each candidate, so query token decoding is also
  repeated per candidate. There is already a subsequence rejection precheck.
- `file_picker/interaction.ml`: persistent string maps for preparation lookup and
  per-job cache rebuilding; persistent rank map per matched result; two-stage scan
  and output traversal; every changed query rescans all candidates. Changed list
  identity schedules a fresh job. Metadata-only completion preserves list identity
  and **does not** restart ranking. Cancel/accept discards all session caches.
- `file_picker/discovery/provider.ml`: backpressured 128-record batches, bounded
  provider, kill/reap semantics already present. Each poll rebuilds a sorted
  cumulative list using `Map.data`; each open resets the map and restarts rg.
- `file_picker/model.ml`, `screen/file_picker_tile.ml`, `tile/navigation.ml`:
  results/selection are lists/IDs. Movement, selection validation, count, fit,
  ID-list creation, preview lookup and deep viewport drops are O(results).
  Tile fits on update and render; host also fits at final publication.
- `file_picker/host/runtime.ml`: while busy, one bounded action per Async yield;
  idle discovery polls wait 2 ms. Frontend chains turns rather than one per frame.
  Budgeted service time must be distinguished from elapsed time including yields.
- `screen/frame.ml`, `ui/editor_view.ml`: existing cache reuse is specifically for
  animation-only turns. Non-animation updates invalidate, including mutable picker
  work. Reusing the same mutable picker pointer is **not** a valid cache key.
  Redraw avoidance needs an explicit visible revision, separate from work progress.
- `line_picker/lines.ml`: repeats the map/DP/output/list-selection pattern,
  prepares blank queries, discards preparation on close. Snapshot identity/revision
  invalidation must remain intact. Share matcher optimizations, then indexed view
  work; do not share filesystem freshness assumptions with in-memory lines.
- `content_picker/model.ml`, `provider/provider.ml`, `host/runtime.ml`,
  `screen/content_picker_tile.ml`: on-disk literal rg search, 150 ms debounce,
  generation/query cancellation, cumulative `List.rev` snapshots and list-based
  selection/rendering. fzf would change its semantics. Reuse only result-view
  improvements if needed; keep this implementation slice focused on files/fuzzy.
- Native command palette is a small synchronous catalog; retain command-quality
  filtering and preserve its ranking. File scale does not justify adding a child
  process to every palette edit.

## What fzf-lua actually does; persistent fzf option

Targeted upstream source read on 2026-10-13 (fzf-lua `main`, moving reference):

- [core.lua](https://github.com/ibhagwan/fzf-lua/blob/main/lua/fzf-lua/core.lua):
  `fzf_exec` wraps a command and launches fzf. `fzf_live` uses `--disabled` and
  `change:reload`/transform, delegating live search to the producer. Resume stores
  command/options/query; `win.unhide` can retain a hidden process. Resume metadata
  alone is not a persistent ranked-candidate cache.
- [fzf.lua](https://github.com/ibhagwan/fzf-lua/blob/main/lua/fzf-lua/fzf.lua):
  `raw_fzf` starts a PTY terminal job (`termopen`, or jobstart for tmux), normally
  supplies `FZF_DEFAULT_COMMAND`, redirects accepted output to a temp file, reads
  it on exit, and returns selected records. Neovim owns the outer window/preview;
  fzf owns terminal query input and result-list interaction. This is not a per-query
  `--filter` wrapper and not a drop-in service for Ches's existing float.

There **is** evidence for caching within a retained interactive fzf process:
[0.44.1 cache.go](https://github.com/junegunn/fzf/blob/0.44.1/src/cache.go) stores
eligible full-chunk query results and searches cached prefixes/suffixes;
[matcher.go](https://github.com/junegunn/fzf/blob/0.44.1/src/matcher.go) has a merger
cache, invalidates on count/revision changes, cancels scans and reuses worker slabs.
Neither cache survives a fresh `--filter` process. Persistent interactive performance
and memory were **not measured** here.

Version 0.44.1 also has an HTTP `--listen` interface:
[server.go](https://github.com/junegunn/fzf/blob/0.44.1/src/server.go) supports POST
actions and GET limit/offset;
[terminal.go](https://github.com/junegunn/fzf/blob/0.44.1/src/terminal.go) status
contains query/count/position/current/matches/selection (index and text), not match
byte positions or scores. This still belongs to a live terminal process. A hidden
PTY plus HTTP control could retain matching state, but Ches would need a substantial
adapter, not merely a subprocess invocation:

1. Keep Ches query editing, list selection and preview ownership; drain hidden PTY
   output and handle terminal lifecycle/resize without exposing fzf's screen.
2. Serialize bounded candidate generations once; use opaque stable IDs mapped back
   to raw paths, never escaped display strings as identities. NUL input/output for
   `--filter` handles newlines; HTTP JSON is not a byte-preserving arbitrary-path
   transport without an explicit encoding/ID layer. Tabs/newlines/invalid UTF-8 and
   backslashes cannot be parsed as casual delimiters.
3. Correlate query **and completed rank generation** before installing data; query
   echo alone is not completion. Page requests and selection changes must refer to
   the same candidate/rank generation. Cancel/coalesce requests, reject stale
   replies, kill/reap on close/failure, cap buffers and disable inherited fzf opts.
4. Obtain visible-row match positions separately. Re-running native alignment for
   fzf-ranked rows may highlight a different alignment and does not reproduce fzf's
   scoring. Exact native weighted ranking cannot be recovered by reranking only a
   CLI top subset: omitted candidates might win under native weighting.
5. Define syntax/Unicode/ranking as an explicit backend policy and test acceptance,
   stable IDs, ordering, selection preservation, missing fzf, startup and crashes.

Per-query filter is simpler but repeatedly parses/transfers the corpus and loses
interactive caches. Persistent CLI adds protocol/PTY/version complexity and two
owners of navigation state. Neither currently has a demonstrated safe net win for
Ches's UX. Do not substitute terminal handoff under a performance label.

## Recommended architecture and sequential implementation slices

**6b — Native result index and blank-query fast path (small/medium).**
Generation-owned candidate/result arrays or chunked vectors, O(1) count/index,
stable-ID-to-index lookup built at publication, direct viewport slices and selected
candidate lookup. Preserve all results/counts, ordering, clamping and stable-ID
selection. Blank queries reference discovery order with zero scores/no positions;
skip fuzzy preparation, ranking-map construction and second output pass. Empty
results publish immediately. Cancellation/replacement remains generation guarded.
Do not hide this behind top-K truncation, which changes navigation/count behavior.

**6c — Compile query once, memory/DP fast paths (medium, split if needed).**
Add compiled tokens API without changing public `rank` policy. Candidate-local
ranking consumes the compiled query. Represent ASCII paths compactly (identity
byte offsets implicit, compact bonuses), share basename/path storage via ranges;
retain UTF-8 fallback and escaped-display mapping. Introduce score-only rolling DP
and a single-character fast path with exact-policy equivalence; compute alignment
only for visible/selected rows with revision-keyed caching. Preserve per-token best
field, weights, exact bonus and stable ties. Use reusable per-job scratch storage
with bounded dimensions rather than allocating two matrices per matching field.
Measure each part; avoid an all-at-once fuzzy algorithm rewrite.

**6d — Bounded query reuse (small/medium after indexed results).**
Keep a small byte-accounted LRU (suggested 2–4 query results, not unbounded strings
or histories) tied to candidate generation and matcher policy. Backspace/repeat
uses an exact cached query; compiled tokens that strictly extend existing loose
subsequence constraints can rank the prior **complete match set**, never just
visible/top results. General edits or incomplete previous jobs scan the corpus.
New discoveries must also be tested against the current query. Do not apply this
narrowing rule blindly to Command policy's quality threshold.

**6e — Discovery deltas/progress and visible revisions (medium).**
Expose new-candidate batches/generation/status instead of rebuilding a cumulative
list at every provider poll. Maintain bounded deduplicated entries in the index;
rank additions once without restarting already processed entries. Use bytewise path
tie/order keys, not arrival IDs, so completed behavior remains deterministic.
Publish immutable result generations on a bounded cadence, with separate visible
revision for query/selection/status/results/preview changes. Background work that
does not change visible state should not force full picker frame reconstruction.
Keep all stale-run/root/query guards, backpressure and Enter-pending behavior.
Avoid a large synchronous final sort/copy; measure final merge/publication and GC.

**6f — Runtime-owned bounded reopen index (medium).**
Cache one frontend project-root index across picker close, distinct from the
capture-local session/query/preview. Reuse candidate identity/compact preparation
and exact query results; release capture, pending ranking and previews as today.
Refresh via rg on each open, reusing unchanged entries and removing absent ones at
refresh completion. A single root-directory mtime is insufficient for recursive
changes/ignore rules. Conservative initial policy: cached display explicitly marked
refreshing, acceptance disabled until current refresh validates membership; no new
watcher dependency or TTL freshness promise. Clear/evict on root/policy changes,
frontend exit and a measured memory ceiling. Start with compact/lazy preparation;
retaining today's 82 MiB indefinitely is not a good reopen optimization.

**6g — Bounded end-to-end acceptance and backend decision (small).**
Use the same cold/query/extend/backspace/repeat/movement/reopen sequence on a
representative owner project, plus targeted Unicode/control-path and cancellation
tests. Record first visible feedback separately from stable final results, full
host apply/render costs and memory. Add a small PTY observation only where needed,
including preview changes and coalesced redraws; do not launch a broad benchmark
suite. Re-evaluate external integration only if native still misses an agreed
budget; persistent fzf would require a separate scoped protocol feasibility slice.

For each implementation slice: meaningful deterministic equivalence/work-bound,
generation-invalidation and lifecycle tests; relevant palette/file/screen/host
checks; explicit bounded probe; all Dune commands sequential with `-j 10` under
the required switch. No timing assertions on this unstable server. Sharing matcher
changes with lines is natural; broaden content/command UI only when justified by
the resulting indexed-view API, not as a separate feature redesign.

## Commands, artifacts and remaining input

Exact shell commands run from repository root (all Dune invocations sequential):

```sh
git status --short
command -v fzf; command -v python3; opam exec --switch=5.2.0+ox -- ocamlc -version
fzf --version
ls scripts /tmp/opencode
opam exec --switch=5.2.0+ox -- dune exec -j 10 ./scripts/picker_comparison_probe/probe.exe
python3 scripts/picker_comparison_probe/fzf_filter.py
# Above failed for unsupported --ignore-case; corrected to -i, then:
python3 scripts/picker_comparison_probe/fzf_filter.py
opam exec --switch=5.2.0+ox -- dune exec -j 10 ./scripts/picker_comparison_probe/host_probe.exe -- /home/wayne/devel/ches
/usr/bin/time -f 'exit=%x elapsed=%e' opam exec --switch=5.2.0+ox -- dune exec -j 10 ./scripts/picker_comparison_probe/host_probe.exe -- /home/wayne/devel/ches
opam exec --switch=5.2.0+ox -- dune build -j 10 scripts/picker_comparison_probe/probe.exe scripts/picker_comparison_probe/host_probe.exe
# Final host invocation after adding explicit cleanup completion:
opam exec --switch=5.2.0+ox -- dune exec -j 10 ./scripts/picker_comparison_probe/host_probe.exe -- /home/wayne/devel/ches
git diff --check
git diff --stat; git status --short
```

Only the small real-root host observation was repeated to verify probe completion;
the synthetic lifecycle and successful CLI comparison each ran once. Probe build
and final host cleanup passed; `git diff --check` passed. Production tests were not rerun for this research-only
addition. Results are in tool output and compact tables here; no external result
files or fixtures created. Dune created ordinary `_build` artifacts. Targeted raw
GitHub webfetches used the sources linked above; initial `v0.44.1` cache/server URLs
returned 404 and were corrected to the actual `0.44.1` tag.

Created files: this report and
`scripts/picker_comparison_probe/{dune,probe.ml,host_probe.ml,fzf_filter.py}`.
Updated only the feature handoff in `PERFORMANCE_TEST_PLAN.md` in addition to these
new files. No production file-picker or matcher edits in this slice.

No user decision blocks **6b**. Useful input before acceptance: representative
project size, desired settled-query/reopen budget, and basename-vs-directory ranking
examples. Recommended default is to preserve the current ranking and use refresh-
validated reopen reuse. If accepting cached results before discovery refresh or
using fzf's different syntax/ranking is wanted, that needs an explicit UX decision.
No predicted speedup is presented as measured; next invocation should implement 6b
and measure it before moving to 6c.

## Slice 6b implementation handoff — 2026-10-13

### Implemented architecture

- `Model.Result_index` stores **all** results in fixed 128-slot chunks, indexed by
  a small integer map, plus a stable raw-ID-to-position map. Producer-owned builders
  append one record at a time under the existing work budget; `finish` transfers
  ownership in constant time and rejects later mutation. No whole-corpus array
  allocation, final reversal or result-list traversal on publication.
- Counts and selected index are O(1); movement updates the index in O(1). ID lookup
  is O(log results), direct access O(log chunks), and viewport reads O(rows × log
  chunks). Selection survives reordered results by raw candidate ID and falls back
  to the first result if absent. Unchanged ranked records retain their scores and
  safe display positions exactly as produced by `Search.rank`.
- File tile fitting, footer counts, result rows, preview filename, preview-provider
  follow and acceptance use indexed access. Discovery count is cached at snapshot
  installation. `Model.results` remains available as a lazy compatibility list,
  materialized once per result generation; it is absent from live file-picker
  render/navigation/preview paths.
- Empty/whitespace-only queries append zero-score, no-position records in **input
  candidate order**, without `Search.prepare`, DP scoring, ranking-map insertion or
  the second ranked-output pass. Blank indices are reused on query clear/whitespace
  changes for the same candidate-list identity. Changed candidate snapshots discard
  that cache; status-only snapshots retain it. Empty snapshots publish in one work
  turn without indexed/prepared records.
- Queries/snapshots still replace pending jobs, old results remain visible while
  busy, and Enter/movement stay disabled until publication. Cancellation drops
  builders, results, blank indices and preparation caches. Reopen starts a new
  session, with zero prepared candidates; it does not retain a project index.

No matcher policy, fuzzy algorithm, query-result LRU, discovery delta protocol,
visible-frame revision or runtime reopen cache was implemented. These remain later
slices. Shared line/content/palette navigation was not changed.

### Work-invariant coverage

Relevant existing tests passed, with expectations updated so blank opening proves
zero preparation and the first fuzzy query still proves preparation/cache reuse.
Additional deterministic checks cover:

1. At most one index append per budget-one work turn, including abandoned blank
   builds and nonblank output; zero fuzzy preparations for blank/whitespace queries.
2. Equivalence to existing `Search.rank` blank records/order, including Unicode and
   escaped paths; exact cached blank reuse does not append records again.
3. Selected index/ID after reordering, additions, removals, query changes, status-only
   updates and reopen; pending acceptance, stale run/root delivery and close guards.
4. Chunk boundaries 127/128 and 255/256; a finished builder cannot mutate published
   data; compatibility enumeration is cached and preserves all results.
5. Navigating to result 2,048 uses one indexed fit read per move. Rendering a deep
   eight-result viewport uses at most ten indexed reads (rows + selection/preview),
   with no compatibility enumeration; counts and last-result acceptance are correct.
6. Preview-provider follow at a deep selected index reads exactly one result, never
   forces the result list, and keeps same-identity preview requests idempotent.

These are work/correctness assertions, not server-dependent timing gates. A chunk
allocation initializes at most 128 slots; a record budget is still not a hard wall
clock bound, especially with GC or long fuzzy queries.

### Final bounded comparison

Same synthetic sequence and measurement boundaries as 6a. The probe's result-count
report now uses the O(1) accessor, so logging does not force the compatibility list
between measured scenarios. One observation per final scenario, no statistical
speedup/p99 claim. Candidate creation remained separate: 13.195/61.452 ms at
10K/50K. Synthetic totals exclude Async/frames/terminal IO.

| Phase | 6a 10K ms | 6b 10K ms | 6a 50K ms | 6b 50K ms |
| --- | ---: | ---: | ---: | ---: |
| Cold blank complete snapshot | 44.633 | 2.946 | 256.929 | 16.615 |
| First `m` | 12.900 | 59.042 | 88.428 | 313.776 |
| Warm extension `mo` | 17.634 | 23.623 | 97.537 | 134.063 |
| `model` | 15.827 | 16.368 | 83.708 | 87.450 |
| Backspace `mode` | 17.172 | 18.021 | 95.085 | 98.667 |
| Backspace `mod` | 16.149 | 17.489 | 88.025 | 93.988 |
| Repeat `model` | 15.585 | 18.068 | 83.362 | 87.056 |
| Clear query | 8.437 | 0.001 | 44.885 | 0.001 |
| Reopen same complete snapshot | 41.362 | 3.039 | 226.128 | 18.686 |

**Important tradeoff:** 6a already prepared all paths during blank opening; 6b
defers preparation to the first nonblank query. First `m` is therefore not a warm
comparison. Cold blank + first `m` combined: 57.533 → 61.988 ms at 10K and
345.357 → 330.391 ms at 50K. The improvement is earlier blank results and lower idle
memory, not elimination of fuzzy preparation. First `m` still reaches 50K prepared
entries and had a 5.057 ms maximum work turn.

**Broad warm ranking regressed in this observation:** `mo` 97.537 → 134.063 ms at
50K. Building the stable ID-to-position map during ranked output adds O(matches ×
log matches) work that previously accumulated a simple list. The narrower queries
also show smaller overhead. This is explicitly carried forward to 6c; do not claim
all picker queries are faster. No additional stress repetitions were used to infer
the size of a reliable regression distribution.

Other final observations:

- Blank retained interaction delta after GC: **0.883/4.410 MiB** at 10K/50K,
  versus 16.487/82.436 MiB in 6a. Already-created candidate strings are excluded.
  This is not prepared-query memory or peak RSS; nonblank caches remain substantial.
- Blank publication: 79/391 work turns versus 158/782; 50K max turn 1.295 ms.
  Clearing an unchanged snapshot needs **one turn and no index rebuild**. The
  0.001 ms measurement is near clock resolution, not a latency guarantee.
- 50K blank tile render 1.338 → **0.190 ms**; blank Next update+fit
  0.716 → **0.001 ms**. Postquery tile renders mostly 0.181–0.192 ms, with observed
  0.586/0.690/0.776 ms outliers for first `m`, `mo`, and clear. The deterministic
  deep-viewport test establishes the work bound independently of these timings.
- Stream simulation still incurs cumulative discovery rebuilding/restarts:
  50K map/snapshot 69.322 ms, restarted first turns 17.975 ms, final blank drain
  19.236 ms (390 turns, maximum 0.959 ms), with **zero prepared candidates**.
  This is not real filesystem discovery latency; fixing discovery is still 6e.
- An initial two-persistent-map result-index variant was measured once, then replaced
  within 6b because its broad-query overhead was worse (50K warm `mo` 158.074 ms).
  The final fixed-chunk variant above was measured once after that change.

Actual Async host + eager frame observation on this checkout now has **446 files**
(393 `m` matches, 47 `mo` matches); the 6a checkout had 445 files:

| Phase | 6a total ms | 6b total ms | 6b batches | 6b frame-sum ms |
| --- | ---: | ---: | ---: | ---: |
| Cold open | 30.019 | 34.139 | 13 | 17.538 |
| First `m` | 11.977 | 12.949 | 8 | 8.811 |
| Extend `mo` | 8.522 | 7.975 | 5 | 4.534 |
| Backspace `m` | 12.047 | 14.144 | 8 | 9.147 |

Movement apply+frame 1.476 ms; max apply+frame batch 1.714 ms; cleanup explicitly
confirmed `finished=true`. No overall live-open speedup is established: this small
workload is dominated by discovery polling/full-frame work, and earlier completion
of blank work can return the host to its existing 2 ms idle polling cadence. The
probe eagerly renders each batch, unlike production coalescing, and excludes
terminal output/Bonsai view construction and disk previews.

The first host observation in 6b logged only its initial phases before exit because
it used Async's buffered `printf`. The probe now uses synchronous
`Stdlib.Printf.printf` with explicit flushing for reporting (outside timed work).
One repeat verified all phases and cleanup; no production scheduler change was
needed. This also explains why 6a's development host logs could omit trailing
messages. Do not interpret missing log suffixes as measured picker failures.

### Commands, checks and files

All Dune invocations below were sequential, under the required switch and `-j 10`:

```sh
git status --short
opam exec --switch=5.2.0+ox -- dune runtest -j 10 file_picker/test screen/test file_picker/host/test file_picker/preview/test palette/test ui/picker_test
opam exec --switch=5.2.0+ox -- dune exec -j 10 ./scripts/picker_comparison_probe/probe.exe
opam exec --switch=5.2.0+ox -- dune runtest -j 10 file_picker/test screen/test file_picker/host/test file_picker/preview/test file_picker/discovery/test palette/test ui/picker_test
opam exec --switch=5.2.0+ox -- dune build -j 10 bin/ches.exe scripts/picker_comparison_probe/probe.exe scripts/picker_comparison_probe/host_probe.exe file_picker/bench/interaction_latency.exe
opam exec --switch=5.2.0+ox -- dune exec -j 10 ./scripts/picker_comparison_probe/host_probe.exe -- /home/wayne/devel/ches
git diff -- file_picker/model.ml file_picker/model.mli file_picker/interaction.ml file_picker/interaction.mli screen/file_picker_tile.ml file_picker/preview/provider.ml file_picker/test/test_model.ml file_picker/test/test_interaction.ml screen/test/test_file_picker_tile.ml ui/picker_test/test_frontend.ml file_picker/bench/interaction_latency.ml
git diff --check
git status --short
```

Invocation history: first test command ran twice (initial mistaken lazy-list test
expectation corrected, then passed). Expanded test command ran three times (missing
test-record type annotation corrected, then passed; final run also covered new
preview-read invariant). Synthetic probe ran twice for the two index designs; host
probe twice for buffered-output correction. Build command ran twice, final passed.
No external fzf comparison was rerun. No huge on-disk synthetic fixture, install,
subagent, staging/commit or other mutative git operation. Existing prior edits
were retained.

Modified production files:
`file_picker/{model,interaction}.{ml,mli}`, `file_picker/preview/provider.ml`,
`screen/file_picker_tile.ml`.

Tests/probes/docs:
`file_picker/test/{test_model,test_interaction}.ml`,
`file_picker/preview/test/test_preview.ml`,
`screen/test/{test_file_picker_tile,test_file_picker_host}.ml`,
`ui/picker_test/test_frontend.ml`,
`file_picker/bench/{interaction_latency.ml,README.md}`, `file_picker/README.md`,
`scripts/picker_comparison_probe/{probe,host_probe}.ml`, `docs/pickers.md`, this
recommendation report, and `PERFORMANCE_TEST_PLAN.md`. No new source files created
in 6b; ordinary Dune build/test artifacts are under `_build` (existing tests use
their usual small temporary fixtures and clean them).

### Next slice observations

Proceed to **6c**, starting with query compilation once per job and compact/shared
prepared fields. Measure cold blank → first nonblank as a combined workload as well
as warm edits: eager blank preparation no longer masks first-query cost. Separately
attribute ranked-output index construction/ID map work; retain deterministic full
result accessibility, immutable ownership, stable selection and yielded publication
when reducing that overhead. Do not restore corpus-sized work in the key/render
callbacks to improve aggregate scoring numbers. Query-result LRU/narrowing,
discovery deltas, visible-frame revisions and reopen caching remain separate slices.
No new user decision is required for the existing 6c policy-preserving scope.

## Slice 6c implementation handoff — 2026-10-13

### Implemented

- Added `Fuzzy.Fast`, keeping the original `Fuzzy.rank`/`rank_prepared` DP untouched
  as an independent oracle and as the existing palette/line path. File jobs compile
  query tokens once, reuse score scratch, and consume scalar scores directly instead
  of constructing a one-candidate `Search.rank` collection, field comparison tuples,
  alignments and escaped positions for every candidate.
- Compact immutable preparation: one shared path text, two suffix views. ASCII
  folded characters and bonuses occupy two byte strings, with implicit offsets;
  Unicode uses shared scalar/byte-offset arrays plus bonus bytes. No copied decoded
  basename. Prepared candidates are accessed by snapshot ordinal slots during warm
  scoring; the path map is updated only for newly prepared candidates and pruned
  during snapshot identity construction, not rebuilt on every query.
- General scoring uses rolling score rows and a reusable linear parent vector,
  without score/trace matrices. Single-scalar and whole-field matches use exact
  fast paths. Early subsequence rejection is retained. Quality filtering, integer
  weight rounding (including negative loose scores), first-field ties, earliest
  endpoints, consecutive/gap parent ties and stable candidate-order ties agree with
  the oracle. Existing case behavior is **unconditional ASCII folding**, not a new
  smart-case mode; non-ASCII scalars remain case-sensitive.
- Ranked rows retain only immutable candidate/score metadata. Public `result_at`,
  `selected_result`, viewport slices and `results` still return **complete exact
  positions**; there is no placeholder-position API change. Selection/acceptance/
  preview metadata accesses do not align. Only full result reads invoke alignment.
  A private query-index FIFO memoizes at most **128 aligned rows**; this is a record
  bound, not a byte/RSS budget. Explicit full enumeration intentionally reconstructs
  and retains all requested records via the existing lazy compatibility list.
- Alignment captures immutable compiled tokens and a frozen preparation map, never
  the mutable session, ordinal slots or reused scoring scratch. Eviction/replacement
  cannot change old query results. Traceback uses at most 262,144 integer cells
  (**2 MiB** on this 64-bit switch), plus linear rolling storage. Larger non-exact
  alignments recompute prefix rows to preserve exact parent ties at greater CPU cost.
- A yielded snapshot-owned ID-to-ordinal index is shared across queries. Ranked
  output writes ordinal-to-position chunks, with **zero per-query string-ID map
  inserts**. No whole-corpus allocation/sort/copy at final publication; all results
  remain accessible. Query edits retain partial snapshot identity work; real changed
  snapshots still replace jobs/indices as before. This is local identity reuse,
  not the 6e discovery-delta protocol or the 6f runtime reopen cache.

### Correctness/work/space evidence

- New `palette/test/test_fast_fuzzy.ml`: 160 deterministic randomized inputs and
  explicit edge fixtures, checked against the legacy matcher under both Command
  and Loose_subsequence policies. Queries cover blank, mixed ASCII case, Unicode
  case distinctions, malformed bytes, exact fields, multiple tokens and scattered
  negative-score matches. Every matched score and position list is compared. A
  forced zero-cell traceback budget checks the recomputation algorithm on small
  inputs without a large pathological fixture.
- File oracle tests compare complete ordered records against legacy **two separately
  prepared weighted fields**, including basename offsets and display escaping:
  48 randomized 12-candidate datasets × 11 supported queries. Existing ranking,
  ties, raw/display paths and Unicode highlighting tests also pass.
- Work invariants: one compile per scheduled job, no additional compilations while
  draining; score calls visit the full corpus (no narrowing/result cache); scoring
  triggers zero alignments/traceback allocations; scratch capacity is O(path scalar
  length), ASCII character/bonus payload is exactly twice path length.
- Old-model tests read evicted rows after another query, changed snapshot and close,
  and compare them to the original oracle. Metadata movement/acceptance align zero
  rows; a seven-row slice aligns seven once; visiting over 128 rows keeps memoization
  at 128; shared-identity queries perform no string-ID inserts. Existing deep viewport,
  selection/snapshot/coalescing/cancellation/frontend tests pass.
- The comparison probe independently checked **68 candidates × 11 queries**, with
  `scores_order_positions=equal`, before timing its bounded lifecycle.

### One bounded synthetic observation

Same 10K/50K paths and lifecycle as 6a/6b; no on-disk synthetic files. Candidate
creation remains outside timed work (12.096/61.545 ms). Monotonic back-to-back
work-turn totals exclude Async scheduling, rendering and terminal IO. There was
**one** 10K/50K lifecycle run in 6c, no repeated large benchmark or fzf run.

| Phase | 6b 10K ms | 6c 10K ms | 6a 50K ms | 6b 50K ms | 6c 50K ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| Blank complete snapshot | 2.946 | 3.174 | 256.929 | 16.615 | 21.694 |
| First `m` after blank | 59.042 | 18.407 | 88.428* | 313.776 | 102.810 |
| Warm `mo` | 23.623 | 7.649 | 97.537 | 134.063 | 43.335 |
| Extend `model` | 16.368 | 4.452 | 83.708 | 87.450 | 23.178 |
| Backspace `mode` | 18.021 | 6.826 | 95.085 | 98.667 | 34.061 |
| Backspace `mod` | 17.489 | 5.024 | 88.025 | 93.988 | 29.795 |
| Repeat `model` | 18.068 | 4.174 | 83.362 | 87.056 | 25.584 |
| Clear | 0.001 | 0.001 | 44.885 | 0.001 | 0.002 |
| Reopen same snapshot, blank | 3.039 | 4.147 | 226.128 | 18.686 | 26.367 |

\* 6a prepared all candidates during blank opening, so its first `m` was already
warm. Combined blank + first `m` at 50K: **345.357 → 330.391 → 124.504 ms** for
6a/6b/6c. At 10K, 6b 61.988 → 6c 21.581 ms. This is reduced total work, not simply
deferring preparation. Warm `mo` is also below the 6a baseline in this observation,
fixing the 6b broad-query regression without truncating results or changing policy.

50K stage attribution (GC included):

| Query | Score/preparation stage ms | Ranked-output/index stage ms |
| --- | ---: | ---: |
| First `m` | 98.097 | 4.681 |
| `mo` | 40.040 | 3.266 |
| `model` | 22.848 | 0.313 |
| `mode` | 31.821 | 2.219 |
| `mod` | 28.622 | 1.153 |
| Repeat `model` | 23.721 | 1.846 |

Every new fuzzy query published with **zero alignments**, then rendering at 160×36
aligned 34 visible rows and cached 34. Final publication turns were 0.004–0.014 ms;
record-turn counts remain 782 broad / 470 `model` / 548 `mode`/`mod`. Largest observed
50K first-query work turn: 2.658 ms; warm maxima 1.326–2.143 ms. These are individual
observations, not hard bounds or quantile claims.

Memory after full GC, above already-created candidates:

- 6c blank retained state: **1.199/5.982 MiB** (10K/50K), versus 6b 0.883/4.410.
  Shared identity, ordinal-result mappings, preparation slots and raw-row wrappers
  add modest blank-state overhead. Blank time/reopen time also rose versus 6b.
- 6c after first `m` and its viewport render: **5.030/25.112 MiB**. Both sizes have
  all candidates prepared. 6a's full-prepared blank state was 16.487/82.436 MiB;
  those are different result phases, not a standalone preparation-only comparison.
- Compact character/bonus payload: **852,000/4,260,000 bytes**. This excludes record,
  map, array header, result-index, candidate strings and alignment-list overhead.
  No peak RSS claim and no extrapolation to arbitrary 4 KiB Unicode paths.

Tile render observations at 50K: blank 0.180 ms; `model`/backspaces/repeat 0.275–0.313
ms; first `m` 2.446 ms and `mo` 2.189 ms (retain these outliers, including natural GC).
Lazy alignment moved some work into rendering, but only for requested rows, with
exact API meaning and bounded memoization. There is no guarantee that every frame
or long-query alignment completes under 2 ms.

Discovery simulation remains a later-slice cost: 50K cumulative map/list rebuilding
75.036 ms, restarted identity first turns 16.999 ms, final blank drain 23.337 ms.
No fuzzy preparation during that blank simulation. This is not real discovery
latency and does not justify claiming a 6e improvement.

### Small actual host observation

One real-root Async host + eager frame run, now **447 files**, 394 `m` matches and
47 `mo` matches. Same exclusions/coalescing caveats as previous handoffs:

| Phase | 6c total ms | Batches | Frame-sum ms |
| --- | ---: | ---: | ---: |
| Cold open | 34.848 | 13 | 17.974 |
| First `m` | 11.770 | 8 | 7.799 |
| Extend `mo` | 8.222 | 5 | 4.718 |
| Backspace `m` | 12.698 | 8 | 8.795 |

Movement apply+frame: 1.289 ms. Cleanup printed `finished=true`. Max cold injected
batch 2.399 ms; fuzzy-query batch maxima 1.047–1.473 ms. This validates actual
host/frame operation with lazy alignment, not a statistically established live
speedup or terminal input-to-screen latency.

### Exact commands/checks/artifacts

From repository root, all Dune invocations sequential:

```sh
git status --short
opam exec --switch=5.2.0+ox -- dune build -j 10 file_picker/test palette/test line_picker/test screen/test ui/picker_test scripts/picker_comparison_probe/probe.exe
opam exec --switch=5.2.0+ox -- dune runtest -j 10 palette/test line_picker/test file_picker/test screen/test file_picker/host/test file_picker/preview/test ui/picker_test
opam exec --switch=5.2.0+ox -- dune exec -j 10 ./scripts/picker_comparison_probe/probe.exe
opam exec --switch=5.2.0+ox -- dune build -j 10 bin/ches.exe scripts/picker_comparison_probe/probe.exe scripts/picker_comparison_probe/host_probe.exe file_picker/bench/interaction_latency.exe file_picker/bench/query_latency.exe line_picker/bench/latency.exe
opam exec --switch=5.2.0+ox -- dune runtest -j 10 palette/test line_picker/test file_picker/test file_picker/discovery/test screen/test file_picker/host/test file_picker/preview/test ui/picker_test
opam exec --switch=5.2.0+ox -- dune exec -j 10 ./scripts/picker_comparison_probe/host_probe.exe -- /home/wayne/devel/ches
git diff --check
git status --short
```

Initial directory build ran twice: missing record-type annotations corrected, then
passed. The first test command ran three times: pending-output test setup now has
visible blank results; expectations were corrected, then all passed. No independent
oracle mismatch. Expanded discovery-inclusive tests and executable build passed.
After final public blank-search fast-path/doc hardening, those expanded test/build
commands were run once more; no synthetic/host benchmarks repeated. Diff whitespace
check passed. Probe sources/config were inspected; no nested Dune commands are
invoked. No installs, subagents, mutative git operations or work outside pickers.

Created: `palette/test/test_fast_fuzzy.ml`.
Modified: `palette/fuzzy.{ml,mli}`, `file_picker/{search,model,interaction}.{ml,mli}`,
`file_picker/preview/provider.ml`, `screen/file_picker_tile.ml`,
`file_picker/test/{test_search,test_interaction}.ml`,
`scripts/picker_comparison_probe/probe.ml`, `file_picker/README.md`,
`file_picker/bench/README.md`, `docs/pickers.md`, this recommendation report and
`PERFORMANCE_TEST_PLAN.md`. Earlier edits preserved. Ordinary build/test artifacts
remain under `_build`; synthetic paths were never created on disk.

### Remaining limits / next invocation

Proceed to **6d bounded query-result reuse/narrowing**, as a separate slice.
There is still a full candidate scoring scan and ranked map per uncached query;
first-query preparation and map/GC costs remain meaningful. Repeated `model` here
rescored all 50K candidates; a cache/narrowing shortcut was deliberately not used.

Retain exact full-result positions on explicit reads, byte-account any future
query-result cache, and account for old immutable indices holding preparation maps.
The current alignment cache is count-bounded only; worst-case long/control paths
can make individual cached position lists large. Bounded traceback's large-matrix
fallback has increased worst-case CPU, and visible alignment is synchronous; no
hard long-query UI-turn bound is established. A future cancellable alignment
scheduler would be a separate design, not an unnoticed change to result meaning.
Discovery cumulative snapshots/restarts and runtime reopen reuse remain 6e/6f.
No new user decision blocks the previously recommended policy-preserving 6d scope.

## Slice 6d implementation handoff — 2026-10-13

### Completed-query reuse and safe narrowing

- Added a per-session completed-query LRU, default **4 entries / 96 MiB conservative
  ownership charge**. Library callers can use `create_with_cache_limits`; entry caps
  are restricted to 0–16 and zero entries/bytes disable query reuse and narrowing.
  The active picker still ranks correctly when a result is too expensive to admit.
- Admission occurs only after every source candidate was scored and the complete
  ranked-output index was published. No partial job/output, visible top subset or
  abandoned query is cached. Completeness is relative to the immutable known
  candidate set (including a capped/partial discovery snapshot); newly discovered
  candidates create a new generation and invalidate those results.
- Exact raw-query hits skip compilation/scoring/output reconstruction. Identical
  compiled **folded token arrays** also reuse exact results under the existing
  ASCII-case/whitespace semantics; non-ASCII case is not folded, and token order is
  not canonicalized by the cache. The public raw query is always updated. Equivalent aliases do not
  create extra cache entries or retain an unbounded alias history.
- Hits publish in **one explicit work turn**, preserving the CURRENT selected ID
  and ordinary first-result/empty fallback. Query edits always make the session busy
  first; pending Enter/movement are ignored, including when a hit is waiting to
  publish. A previously cached visit does not restore its old selection.
- Uncached queries can rescore the smallest complete cached **proper subset** when
  every prior folded token is a scalar prefix of its corresponding next token and
  added tokens only add AND constraints. This is a proof for loose subsequences,
  not Command quality filtering. Token splits/merges/reordering, non-prefix edits,
  removed constraints and Unicode case changes fall back unless an independently
  compatible complete ancestor exists. No narrowing for a replacement that
  interrupted pending work. Whole-corpus parents are skipped to avoid needless
  metadata traversal when there is no candidate-count reduction.
- Survivors are accessed as metadata (no alignment), **rescored**, and ranked with
  their original snapshot ordinals. Cached rank/score values are not reused on an
  extension. An exact-basename extension test deliberately changes rank order and
  verifies stable ties, so this cannot degrade into filtering old ranked output.
- Every changed candidate-list identity drops the LRU immediately, even if the new
  path bytes are equal. Entries are also checked against the immutable ID-index
  identity and session generation. Status-only deliveries keep it. Close drops all
  entries; reopen creates an empty cache. Compact preparation reuse rebinds current
  candidate objects, avoiding old-candidate retention through frozen aligners.

### Byte accounting and ownership boundary

All accounting is incrementally accumulated or uses index/map counts, so lookup,
admission and eviction do not enumerate the corpus. The charge deliberately
overestimates sharing and future alignment growth:

- Shared current corpus/identity/preparation/blank index is charged **once** while
  any LRU entry exists. Candidate records count `192 + lengths(root, absolute,
  relative, display)` bytes, including even shared strings separately; each input
  adds 24 bytes for a list cell, 128 for identity nodes and 24 for preparation slot/
  map overhead. Fixed headers add slack.
- Each retained preparation charges compact payload plus **512 bytes** for records,
  field views, variants and headers, plus **128 bytes** for its path-map node.
  All current preparation is counted, not just the matching candidates, because
  published aligners capture the full frozen preparation map.
- Every private result index charges **96 bytes per result**, full 128-slot array
  capacity and map nodes for result/ordinal chunks, eager position lists, an 8 KiB
  header/table/queue allowance and its full **256 KiB** future alignment reservation.
  Compiled scalar arrays, representative keys and cache-entry/closure/list overhead
  are additionally charged. Shared immutable identity/candidate/preparation data
  is not multiplied per entry.
- Alignment memoization now has both **128-row** and **256 KiB charged-payload**
  bounds. A row charges `128 + 32 × position_count` bytes. FIFO eviction satisfies
  both caps. An individual oversized row is returned with its complete exact
  positions but is not memoized. Reserving the maximum up front prevents later
  rendering from exceeding the LRU charge without admission-time rescans.

This is a cache-ownership budget, **not a process/picker RSS bound**. Active and
in-flight ranking state and caller-retained models/full compatibility enumerations
are outside the LRU; the accounting includes their shared corpus conservatively
when the LRU owns references to it. No LRU admission means a zero LRU charge, not
zero live picker memory. A changed set clears old cached indices immediately;
ordinary old visible results survive only as required until replacement publication.

### Tests and deterministic work assertions

Created `file_picker/test/test_query_cache.ml` with cached/narrowed versus cache-
disabled cold full ranking and the independent legacy oracle across append,
backspace/repeat, case, Unicode/malformed paths, whitespace/token transitions and
mid-query replacements. Coverage additionally checks:

- Zero scoring/indexing and one-turn publication on hits; current selection and
  fallback rather than cached-visit selection; pending acceptance/navigation guards.
- Exactly the complete parent's match count examined on narrowing; original
  ordinals/changed score ordering; no partial score/output admission; interrupted
  replacement examines the full corpus.
- Same-byte new candidate lists and real additions/replacements clear entries/
  charges, status-only updates retain them, stale runs are rejected, close/reopen
  cannot resurrect an old cache.
- Byte eviction with an entry cap that would otherwise allow more, entry-cap
  eviction, over-budget empty results (which still own preparation), reserved
  alignment growth, and a weak-reference GC check that old candidate objects are
  released after same-path replacement/rebinding.
- Model tests force byte eviction before the row-count cap using tiny aligners and
  verify oversized rows remain exact and uncached. Palette helper tests check the
  folded-token prefix proof against loose oracle membership. Palette/line ranking
  implementations remain unchanged.

Instrumentation exposes cumulative scoring/examined counts, per-job examined
count, committed hits, scheduled narrowed jobs, representative queries, entry
count, conservative cache charge and capacity evictions. Existing work-budget,
full-result access, alignment ownership, host/frontend/cancellation tests passed.

### One bounded 10K/50K lifecycle observation

Same synthetic candidates and timing boundaries as 6c; one run per size, no
repeated large benchmark. The probe's small independent oracle again reported
**68 candidates × 11 queries: scores/order/positions equal**. Additional lifecycle
phases exercise warmed backspace, token narrowing and whitespace-equivalent reuse.

| Original phase | 6c 10K ms | 6d 10K ms | 6c 50K ms | 6d 50K ms | 6d 50K examined |
| --- | ---: | ---: | ---: | ---: | ---: |
| Blank publication | 3.174 | 3.725 | 21.694 | 28.516 | 0 |
| First `m` | 18.407 | 22.955 | 102.810 | 108.435 | 50,000 |
| Warm `mo` | 7.649 | 7.557 | 43.335 | 48.315 | 50,000 |
| First `model` | 4.452 | 4.220 | 23.178 | 24.232 | 50,000 |
| First backspace `mode` | 6.826 | 7.016 | 34.061 | 36.931 | 50,000 |
| First backspace `mod` | 5.024 | 4.950 | 29.795 | 31.042 | 50,000 |
| Repeat `model` | 4.174 | 0.001 | 25.584 | 0.002 | **0** |

`m`/`mo` match the whole synthetic corpus; their parent sets are deliberately not
used for narrowing. First backspaces here have no exact cached entry yet, and the
remaining compatible ancestor is also whole-corpus. These misses modestly increased
in this observation (ownership accounting, retained indices and natural GC);
do not claim all queries improved. Combined 50K blank + first `m` was 136.951 ms
versus 6c 124.504, still far below 6b 330.391 ms. Candidate creation was separately
12.085/61.369 ms, excluded from these work totals.

| Added warm/reduction phase | 10K work ms | 50K work ms | 50K examined | 50K work turns |
| --- | ---: | ---: | ---: | ---: |
| Cached backspace `mode` | 0.001 | 0.002 | 0 | 1 |
| Cached backspace `mod` | ~0.000 | 0.001 | 0 | 1 |
| Cached repeat `model` | ~0.000 | ~0.000 | 0 | 1 |
| Extend to `model m` | 3.294 | 20.636 | **10,000** | 158 |
| Extend to `model ml` | 3.962 | 27.351 | **10,000** | 158 |
| Ctrl-w to `model ` (same tokens) | 0.001 | 0.002 | 0 | 1 |
| Clear | ~0.000 | 0.002 | 0 | 1 |

Near-zero values are at clock resolution, not latency guarantees. Narrowed phases
rescore the complete 10K survivor set rather than scan 50K; no full-cold timing for
these extra-token queries was collected, so no corresponding speedup ratio is
claimed. Narrowed score/output stages: 20.207/0.423 ms (`model m`) and
25.859/0.636 ms (`model ml`). New narrowed indices published with zero alignments;
rendering aligned 34 rows. Hits retained their already-aligned rows with no new
alignment in this viewport.

Budget/memory observations:

- Peak 50K conservative LRU charge **84,225,912 bytes** (below 96 MiB), four entries.
  After the complete sequence: **75,827,206 bytes**, four entries and three capacity
  evictions. At 10K final charge was 16,265,478 bytes.
- Blank live-heap deltas remained 1.199/5.982 MiB. First-query deltas were
  **5.108/25.495 MiB**, versus 6c 5.030/25.112; rows now retain original ordinals.
- After clear with four cached indices: **5.378/26.738 MiB** above pre-created
  candidates. This is not peak RSS and not directly equal to the conservative
  charge, which also counts candidate storage excluded from the probe's delta and
  reserves future growth. Compact payload remains 852,000/4,260,000 bytes.
- Visible aligned-row charges were **5,440–11,968 bytes**, 34 rows, comfortably
  under 256 KiB. Tests, rather than ordinary short paths, establish byte eviction.
- Most 50K hit renders were 0.162–0.178 ms; first repeat `model` render had a
  **2.374 ms** outlier. First `m` render was 3.069 ms. Retain these natural-GC/frame
  observations; reuse removes corpus work, not all rendering latency.
- Reopen remains uncached: 50K blank 30.026 ms, no prepared entries/cache hits.
  Discovery simulation still rebuilds cumulative lists/restarts work (75.240 ms
  rebuilding, 18.971 ms restarted turns, 28.523 ms final blank drain). No 6e/6f
  improvement is claimed.

One actual small-project host + eager-frame observation (448 files, 395 `m` and
47 `mo` matches): cold 34.774 ms, first `m` 11.760 ms, `mo` 8.878 ms, cached backspace
`m` **4.045 ms / one injected batch**, versus 6c 12.698 ms / eight batches.
Movement apply+frame 0.998 ms; cleanup confirmed `finished=true`. The cached
backspace's injected frame cost was 0.945 ms. These observations include Async/
headless frame construction but exclude terminal transport, Bonsai drawing, disk
preview and production redraw coalescing. They establish neither p99 nor
keypress-to-screen/photon latency.

### Commands, files and checks

Exact commands from repository root; Dune invocations all sequential:

```sh
git status --short
opam exec --switch=5.2.0+ox -- dune build -j 10 file_picker/test palette/test screen/test scripts/picker_comparison_probe/probe.exe
opam exec --switch=5.2.0+ox -- dune runtest -j 10 palette/test line_picker/test file_picker/test screen/test file_picker/host/test file_picker/preview/test ui/picker_test
opam exec --switch=5.2.0+ox -- dune runtest -j 10 palette/test line_picker/test file_picker/test file_picker/discovery/test screen/test file_picker/host/test file_picker/preview/test ui/picker_test
opam exec --switch=5.2.0+ox -- dune exec -j 10 ./scripts/picker_comparison_probe/probe.exe
opam exec --switch=5.2.0+ox -- dune build -j 10 bin/ches.exe scripts/picker_comparison_probe/probe.exe scripts/picker_comparison_probe/host_probe.exe file_picker/bench/interaction_latency.exe file_picker/bench/query_latency.exe line_picker/bench/latency.exe
opam exec --switch=5.2.0+ox -- dune exec -j 10 ./scripts/picker_comparison_probe/host_probe.exe -- /home/wayne/devel/ches
git diff --check
git status --short
```

Initial directory build ran twice: fold accumulator type annotation corrected,
then passed. The first test command ran twice as coverage/semantic-alias support
was added; discovery-inclusive checks passed, then were repeated once after final
documentation/style edits. Executable build passed and was repeated once for final
verification. **Synthetic and host probes each ran once**. All tests passed; no
oracle mismatches or expected-output promotions. Probe sources/config inspected:
no nested Dune subprocesses. Diff check passed. No agents, installs or mutative git
operations; earlier work preserved.

Created `file_picker/test/test_query_cache.ml`.
Modified `palette/fuzzy.{ml,mli}` (Fast query helpers only),
`palette/test/test_fast_fuzzy.ml`, `file_picker/{interaction,model,search}.{ml,mli}`,
`file_picker/test/test_model.ml`, `scripts/picker_comparison_probe/probe.ml`,
`file_picker/README.md`, `file_picker/bench/README.md`, `docs/pickers.md`, this report
and `PERFORMANCE_TEST_PLAN.md`. No synthetic files on disk; ordinary test/build
artifacts are under `_build` and existing tests use their usual small temp fixtures.

### Next extension points and limits

Next is **6e discovery deltas/progress and visible revisions**. Treat this LRU's
generation/identity checks as the invalidation boundary: new candidates cannot be
silently excluded from old cached matches. Either invalidate or deliberately test
and merge additions into every retained query while preserving completeness,
stable ordinals and byte charges. Status-only updates should still keep results.
Any future dynamic ranking/ignore policy needs a matching cache-policy identity.

**6f runtime reopen reuse** remains separate; this slice intentionally clears the
cache on close and does not promise filesystem freshness across reopen. Retaining
the index later requires refresh/acceptance and memory ownership to be designed
together, not simply keeping this LRU alive indefinitely.

Evicted/over-budget queries can still require full scoring; conservative token
prefix proof deliberately declines some mathematically safe edits. Long synchronous
alignment/traceback recomputation and natural GC remain unbounded in elapsed time.
The byte charge is conservative ownership accounting on this 64-bit toolchain,
not an RSS measurement or global allocator limit. No new user decision is required
to proceed with the existing 6e scope.

## Slice 6e implementation handoff — 2026-10-13

### Discovery ownership and streaming progress

- Production `Provider.poll_update/current` deliver bounded additions and persistent
  bytewise candidate-set roots, with predecessor stamp/count, request and revision.
  Roots share immutable trees and retain no predecessor snapshot chains. No production
  `Map.data`/cumulative list reconstruction per 128-record batch. Explicit legacy
  `poll/snapshot`, `Model.discovery` and set enumeration lazily materialize one list
  per set; production host/UI/preview metadata accesses do not force those adapters.
- Stream intake keeps stable arrival ordinals/preparation slots and an appendable
  identity builder. An unchanged query continues its cursor as records arrive,
  preparing/scoring each once. Query edits replace scoring, not intake/preparation.
  Matching keys use descending score then **raw relative-path bytes**, giving the
  deterministic provider ordering even when arrivals are reverse/traversal order.
  Legacy supplied-list sessions retain their original input-order tie semantics.
- Persistent ranked trees publish completed known partial sets directly, without
  an O(results) output-copy stage. Selection is preserved by raw ID; count/lookup/
  viewport operations remain indexed. Blank results reference the sorted candidate
  set instead of allocating a zero-score record for every candidate. Append-only
  hidden score slots never overwrite prior ordinals; frozen rank/identity roots
  prevent later tail writes from changing old published models.
- Additions immediately invalidate the generation-scoped complete-query LRU, while
  preserving current work. An already-started narrow job finishes its complete old
  survivor set and examines every new tail candidate; a pending completed-cache
  reuse extends its complete tree. No added candidate is omitted. Partial complete
  known sets may accept once caught up; while busy old visible results cannot accept.
  Complete/truncated/failed/cancelled status, caps/excludes, preview, capture and
  stale request/root/revision isolation retain their existing rules.
- The host polls ready delivery before its idle wait, yields between work actions,
  and still sleeps 2 ms when neither delivery nor work is ready. It neither spins
  while rg is idle nor forces every queued batch through a 2 ms delay. Provider
  process backpressure/kill/reaping and frontend effect pumping remain intact.

### Explicit visual invalidation

`Interaction` has a unique lifetime ID and monotonic visible revision. Query,
selection, discovery count/status, busy/results publication and close advance it;
preparation/scoring-only work does not. The file tile versions preview changes using
value equality of immutable preview payloads, not mutable picker pointer equality.

`Frame.Cache.apply_inputs` is now the shared frontend/probe/test transition boundary:
only already-sized animation/file-work-only batches with unchanged explicit visual
stamps may retain workspace rows and base image. All other inputs invalidate,
including discovery/status snapshots, previews, key/paste/notice/focus changes,
source events, empty synchronization and dimensions. `get` independently checks
dimensions and the content stamp, including preview changes after synchronization.
`Editor_view` still executes its full activation, preview, request/source/session
and next-turn effect path for file work; only the pre-existing animation shortcut
skips effects. No physical equality inference is used for mutable visible content.

### Deterministic checks

- New file streaming tests: reverse arrivals, partial publication, each candidate
  prepared/scored exactly once for an unchanged query, bounded work, continued
  unfinished scoring, query edits midstream, status-only completion/truncation,
  partial failure, stale/duplicate revisions and reopen isolation.
- Final complete ranking/positions equal the independent legacy oracle over the
  sorted candidate set. Cached/narrowed jobs include additions; a pending reuse
  scores only its new tail; old published results stay unchanged.
- Provider delta tests show at most one new record for batch-size-one delivery and
  no cumulative list materialization; existing scope/ignore, caps, cancel, timeout,
  failed launch/output and reaping tests also run through the underlying delta poll.
- New UI test counts workspace/Notty base builds and compares images with uncached
  rendering. Seven nonpublishing identity turns and seven score turns cause no
  additional base builds; publication, query, preview, snapshot/status, resize and
  notice changes draw. `after_step` executes on each suppressed work turn. Existing
  production Bonsai frontend/animation/source/session/capture tests passed.

### Bounded observations

One invocation of the 10K/50K probe, retaining its static 6d comparison and adding
the actual persistent-set/delta streaming protocol for **two sessions** (blank and
fixed `model`). No filesystem synthetic fixture, stress repeats, CLI fzf run or
statistical/terminal latency claims. Small oracle check: 68 candidates × 11 queries,
scores/order/positions equal.

| Streaming service work | 10K | 50K |
| --- | ---: | ---: |
| Incoming batches | 79 | 391 |
| Persistent candidate-set append ms | 1.844 | 20.904 |
| Both sessions' install/work ms | 25.202 | 124.997 |
| Fuzzy preparations before final status | 10,000 | 50,000 |
| Fuzzy scoring calls | 10,000 | 50,000 |
| Blank fuzzy preparations | 0 | 0 |
| Extra final drain turns | **0** | **0** |
| Cumulative list materialized | false | false |

6d's blank-only simulation rebuilt cumulative maps/lists for 75.240 ms at 50K and
needed another 28.523 ms / 390 final blank work turns. The new 20.904 ms set stage
has no cumulative lists; the 124.997 ms work total includes **both blank and fuzzy
sessions**, so it is not an apples-to-apples blank-only total-time speedup ratio.
The important deterministic improvement is complete progress before final status,
rather than starvation/restarts. The 6a fuzzy simulation prepared only 256 before
its final drain; this run prepared/scored all 50K exactly once.

Static-list observations remain consistent with 6d: 50K first `m` 103.293 ms,
warm `mo` 45.440, `model` 23.986; cache hits one turn ~0.000–0.002 ms, zero examined;
extra-token narrowing examines 10K. Static retained-state measurements are unchanged
(first query 25.495 MiB, final four-entry LRU 26.738 MiB above pre-created candidates).
These static sessions exercise compatibility ordering/storage, not the production
stream tree representation. Persistent tree index/map/score-slot charges are also
included by the existing conservative cache estimator; cache limits remain 4/96 MiB
and alignment remains 128 rows/256 KiB. Do not infer streamed peak RSS from static
measurements.

Actual small-root host probe now uses `Frame.Cache.apply_inputs/get` and reports
injected batches and **new base builds during those batches** (initial input/open
render is outside the base-build count). 450 files, 397 `m` and 47 `mo` matches:

| Phase | 6d eager-frame total ms | 6e cached-frame total ms | Batches | Base builds | Frame-sum ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| Cold open | 34.774 | 25.349 | 7 | 6 | 8.872 |
| First `m` | 11.760 | 4.956 | 4 | **1** | 1.244 |
| `mo` | 8.878 | 4.707 | 4 | **1** | 1.168 |
| Backspace cached `m` | 4.045 | 4.833 | 1 | 1 | 1.076 |

Movement apply+frame 1.554 ms; cleanup printed `finished=true`. This diagnoses fewer
work/redraw turns and verifies the host path, not a universal live speedup: dataset
size changed by two test files, redraw policy differs deliberately, and scheduling/
GC/load are uncontrolled. Disk preview, Bonsai image construction and terminal
transport/painting remain outside this headless probe; Notty correctness/build
suppression is separately covered by the UI test. Cached backspace did not improve
in this small observation.

### Commands and files

All Dune calls sequential under the required switch and job limit:

```sh
git status --short
opam exec --switch=5.2.0+ox -- dune build -j 10 file_picker/test file_picker/discovery/test file_picker/host/test screen/test ui/test ui/picker_test scripts/picker_comparison_probe/probe.exe
opam exec --switch=5.2.0+ox -- dune runtest -j 10 file_picker/test file_picker/discovery/test file_picker/host/test file_picker/preview/test screen/test ui/test ui/picker_test palette/test line_picker/test
opam exec --switch=5.2.0+ox -- dune build -j 10 bin/ches.exe scripts/picker_comparison_probe/probe.exe scripts/picker_comparison_probe/host_probe.exe file_picker/bench/interaction_latency.exe
opam exec --switch=5.2.0+ox -- dune exec -j 10 ./scripts/picker_comparison_probe/probe.exe
opam exec --switch=5.2.0+ox -- dune exec -j 10 ./scripts/picker_comparison_probe/host_probe.exe -- /home/wayne/devel/ches
git diff --check
git status --short
```

Initial build ran twice (stream record annotation corrected, then passed). Targeted
tests ran once before new invariants, once after them, and once for final verification;
all passed. Executable build passed and ran again for final verification. Both probes
ran exactly once. Probe sources/config inspected; no nested Dune invocations. No
full repository/stress benchmark, installs, subagents or mutative git operations.

Created `file_picker/test/test_streaming.ml`, `ui/test/test_file_picker_cache.ml`.
Modified `file_picker/{model,interaction}.{ml,mli}`,
`file_picker/discovery/{provider.ml,provider.mli,test/test_discovery.ml}`,
`file_picker/host/runtime.ml`, `file_picker/preview/provider.ml`,
`file_picker/preview/pure/model.{ml,mli}` (immutable equality),
`screen/{file_picker_tile,ui_state,frame}.{ml,mli}`, `ui/editor_view.ml`,
`scripts/picker_comparison_probe/{probe,host_probe}.ml`, `file_picker/README.md`,
`docs/pickers.md`, this report and `PERFORMANCE_TEST_PLAN.md`. Prior edits preserved;
ordinary build/test artifacts under `_build`, no new on-disk large fixtures.

### Next slice / limits

**6f runtime-owned reopen index** remains next. It must preserve immutable ownership,
query-policy/generation checks, byte accounting and refresh-validated acceptance;
this slice intentionally discards all session indices/query history on close.

Production callers must use delta/current and metadata getters; explicit cumulative
compatibility enumeration still costs O(N) and repeated enumeration of every
generation can recreate the historical cost. Streaming partial publications use
persistent sorted rank trees instead of final arrays; changed-set LRU entries are
invalidated safely, not incrementally maintained across generations. Stable arrival
ordinals never determine final bytewise ties. Pure-work redraw suppression is scoped
to file work only; other source/line/content transitions remain conservative. Long
DP/alignment and natural GC are still not hard time-bounded; no peak-RSS/p99/terminal
latency guarantee is established. No new user decision blocks the existing 6f plan.

## Slice 6f final handoff — 2026-10-14

**Implemented:** a bounded, runtime-owned native file-picker reopen cache. The
native backend remains the recommendation after slices 6a–6f. It now avoids
rebuilding unchanged discovery/index/preparation/query state on quick reopen,
while fresh asynchronous discovery is still mandatory before accepting a cached
result. This completes the planned implementation slices; human ranking/visual
acceptance and comparative terminal-latency/RSS quantiles remain unperformed.

### Final architecture and freshness

- The provider owns one asynchronous rg run, bounded additions and persistent
  bytewise candidate sets. During refresh it can reuse the saved candidate objects
  by exact path, then releases the temporary reuse reference on completion/error/
  cancellation. No live process or descriptor belongs to a cached snapshot.
- Interaction owns yielded index/preparation/scoring work, lazy exact alignment
  (128 rows / 256 KiB), and the four-entry / 96 MiB conservative complete-query LRU.
  Progress-preserving intake, immutable ranking roots, token-prefix narrowing and
  the independent original matcher oracle remain in place. Nonpublishing file work
  retains the cached workspace/Notty base while normal effect pumping continues.
- On close, only an idle successful untruncated streamed session exports data:
  candidate/arrival roots, identity and blank index, compact preparation/map/slots
  and bounded completed-query entries. Mutable preparation slots are copied at
  capture and copy-on-write on restore. Query aligners capture immutable query and
  preparation data, not sessions. The weak-reference test verifies retired session
  collection while its cache entry remains live. Capture copies O(N/128) chunks on
  close; this is not a zero-work close or a peak-memory bound.
- Runtime admission is independently capped at **two roots / 128 MiB conservative
  reachable-ownership charge / 30 seconds since validation**, with a configurable
  maximum of four roots. Keys use normalized lexical roots plus an explicit policy
  version (`native-v1` by default). TTL uses a monotonic clock. Lookup updates LRU
  order without renewing age; runtime cancellation clears retention. Snapshot bytes
  include corpus/map/slot overhead and full future query-alignment reservations.
  Active/in-flight structures and externally retained models are outside this cap.
- Reopen preserves the original **blank query / first selection** UX. Cached rows
  are immediately visible with `Loading / refreshing cached files...` and explicit
  disabled Enter. A new rg run starts every time. Query edits can use retained
  complete entries, but cannot bypass refresh validation. Previews restart with a
  new session identity; no cached disk/dirty preview bytes are retained here.
- Successful unchanged sets commit without reindexing, preparing or rescoring.
  Changed sets rebuild in bounded turns, reuse unchanged compact preparation and
  prune deleted/ignored paths and old query entries. `.ignore` changes are detected
  by traversal; explicit discovery configuration changes can use
  `Runtime.open_picker_with_policy`. Failed/truncated refreshes publish only their
  fresh known subset, remain visibly nonaccepting, and evict the saved entry.
  Cancelling a refresh can keep the previously validated entry until its original
  TTL, never cancellation state. Close/reopen retries a failed refresh.
- Acceptance still routes through `Session.open_or_activate ~must_exist:true`;
  missing new files fail visibly and retained dirty buffers are not reread. A
  successful traversal is not an atomic filesystem snapshot. Stale run/root/work
  identities cannot install into the replacement picker.

### Bounded measurements

One synthetic 10K/50K lifecycle invocation and one actual small-root host invocation
were run for this slice. No repeated/stress measurement. The synthetic tool output
was truncated and its later 50K/reopen timings were not retained, so no exact new
large-corpus reopen timing is claimed. Retained 10K observations: blank 3.351 ms /
1.199 MiB; first `m` 18.976 ms, `mo` 7.924 ms, `model` 4.749 ms; independent oracle
equality over 68 candidates × 11 queries. The new probe emits snapshot capture,
restore, charge, blocking state and unchanged-commit work counters.

Actual host, 451 files, one local observation:

| Phase | Time ms | Visible rows / work | Injected batches | Base builds |
| --- | ---: | --- | ---: | ---: |
| Cold immediate open | 0.026 | 0 rows | — | — |
| Cold completion | 25.351 | 451 rows | 7 | 6 |
| First `m` | 4.824 | 451 prepared / 398 matches | 4 | 1 |
| `mo` | 4.702 | 47 matches | 4 | 1 |
| Cached backspace `m` | 5.490 | reused query | 1 | 1 |
| Cached immediate reopen | **0.012** | **451 rows; 0 indexed / 0 prepared** | — | — |
| Reopen refresh completion | 21.177 | 0 prepared | 6 | 5 |

Cache hit count was 1, refreshing was true at immediate reopen, conservative
entry charge was **1,298,646 bytes**, and cleanup printed `finished=true`. Immediate
row visibility is not readiness to accept: refresh still took about 21 ms. Headless
host timings exclude disk preview, Bonsai image construction, terminal transport and
painting; uncontrolled scheduling/GC/load and the small changing repository prevent
universal speedup or p99 claims. The cached-backspace observation did not improve.

For context, the existing 6a external comparison used `/usr/bin/fzf` **0.44.1
(debian)**, `GOMAXPROCS=2`, separate `--filter` processes with NUL input/output. Its
50K `m` / `mo` / `model` observations were **78.720 / 81.406 / 28.942 ms**. Earlier
6e native 50K static-list observations were **103.293 / 45.440 / 23.986 ms**.
These are historical local headless observations, with differing ranking policy
and no native highlight/ID mapping in the fzf CLI path. They do not establish a
terminal-equivalent winner or a first-query speedup. Native wins here on retained
integration/ownership and implemented incremental/reuse behavior, not an all-query
timing claim. No fzf terminal handoff or per-keystroke subprocess backend was added.

### Validation, commands and remaining issue

All Dune invocations were sequential with the required switch and job limit.
The final continuation reran build/full tests after the probe source changes:

```sh
opam exec --switch=5.2.0+ox -- dune build -j 10
opam exec --switch=5.2.0+ox -- dune runtest -j 10
opam exec --switch=5.2.0+ox -- dune runtest -j 10 file_picker/host/test file_picker/test file_picker/discovery/test screen/test ui/picker_test
opam exec --switch=5.2.0+ox -- dune exec -j 10 ./scripts/picker_comparison_probe/host_probe.exe -- /home/wayne/devel/ches
opam exec --switch=5.2.0+ox -- dune exec -j 10 ./scripts/picker_comparison_probe/probe.exe
python3 scripts/picker_smoke.py
TMPDIR=/tmp/opencode bash scripts/smoke.sh
git diff --check
git status --short
```

Build/full Dune tests and focused suites passed. New `host/test/test_reopen.ml`
covers immediate rows, same-set zero rebuild/retyped query reuse, additions/deletions,
ignore/policy/TTL invalidation, root/byte admission, failed/truncated/cancelled
refresh, stale work and weak lifetime release. Initial development errors were
fixed without expectation promotion. A production readiness timeout exposed the
initial refresh label's omission of `Loading`; the explicit
`Loading / refreshing...` label fixed readiness and targeted tests passed.

The picker PTY smoke **passed**: bindings/catalog, query/navigation/accept/cancel,
dirty revisits, missing/stale opens, Unicode locations, undo compatibility, zen,
tiny/resize, preview/control safety, interrupted paste/reopen, startup scope and tty
restoration. Fixtures/captures: `/tmp/opencode/picker-terminal-5kxg6ln1`.

The broader full smoke ran once and **failed one check**: saved `blockop.txt` bytes
in **blockwise delete, yank, and paste** differed from the expected bytes. Its screen
checks and all other smoke checks passed, including palette/line/source/LSP and tty
cleanup. This does not provide a green full-terminal gate and has not been diagnosed
as timing-related or pre-existing. No unrelated block/text-storage fix was attempted.
Retained screens: `/tmp/opencode/ches-smoke-screens.IDj6iG`; full captured output:
`/home/wayne/.local/share/opencode/tool-output/tool_1382e24f0001Kwada6pvzzZsqc`.
The script removes its work fixture on exit. Both smoke scripts were inspected for
nested Dune calls before execution; neither launches Dune.

Implementation files: `file_picker/{interaction,model}.{ml,mli}`,
`file_picker/discovery/provider.{ml,mli}`, `file_picker/host/{runtime.ml,runtime.mli,dune}`,
new `file_picker/host/test/test_reopen.ml`, `screen/file_picker_tile.ml`, and
`scripts/picker_comparison_probe/{probe,host_probe}.ml`. Documentation: this report,
`file_picker/README.md`, `docs/pickers.md`, `PERFORMANCE_TEST_PLAN.md`. Extensive
pre-existing edits/untracked files were preserved. No installs, subagents, commits
or mutative git operations. At this historical handoff, the blockwise smoke issue
was explicitly outstanding; its diagnosis and closure are recorded below. Long-path/query DP, GC, cold first
preparation, bounded-but-costly capture and refresh traversal remain real costs;
cache limits are not hard realtime, total RSS, or terminal latency guarantees.

### Integration smoke blocker closure — 2026-10-14

The `blockop.txt` blocker is **resolved: a missing test synchronization barrier**.
The exact keys are `3l<C-v>2jlld`, `u`, `<C-r>`, `0P`, then `Space w`.
Headless replay through the real keymap/editor verifies the original trailing LF,
delete bytes `abcgh\nab\nabcgh\n`, undo restoration, redo, cursor offset zero after
paste, and the save effect's exact 24 bytes `defabcgh\n   ab\ndefabcgh\n`.
Successful write outcome handling also marks that saved revision clean.

In the historical failed output, the initial `cmp -s` failed, but the subsequent
diagnostic `cmp` printed no difference. The intervening failure screen already
showed `Wrote .../blockop.txt (24...)`. `tmux send-keys` acknowledges queued input,
not completion of the editor command. The scenario compared bytes immediately
after queuing Save. `app/controller.ml` performs `File_io.write` before reporting
`Write_file_finished`; `core/editor.ml` emits `Wrote` only on its successful outcome.
Thus the correct completion barrier is the path-specific `Wrote` status, not the
preceding `1:1` cursor status. The removed fixture prevents recovering the exact
transient bytes seen by the first comparison; the evidence does not establish
whether it observed the old file or an in-progress write.

Changes in this slice:
- `scripts/smoke.sh`: wait for `Wrote $work/blockop.txt` before the existing exact
  comparison, and repeat the same comparison after clean exit. Expected bytes and
  screen semantics are preserved; no sleep was added.
- `test/test_keymap.ml`: durable headless exact-sequence regression checks each
  editing stage, padded short row, save payload and successful save outcome.
- The full run exposed another immediate assertion after queued Undo in the OCaml
  LSP scenario. Its negative notice check failed, while the failure capture already
  showed restored text/cursor and a cleared notice. That assertion now waits for
  the cursor row `let b = ERROR` before checking absence of the stop notice.
  A `--lsp-only` mode reuses that same scenario for low-load focused verification.

Verification (sequential; smoke script inspected in full and has no nested Dune):
- `opam exec --switch=5.2.0+ox -- dune runtest -j 10 test screen/test`: **PASS**, including
  the new keymap regression and existing core/app/input/screen suites.
- `opam exec --switch=5.2.0+ox -- dune build -j 10 bin/ches.exe source/test/fake_lsp/fake_lsp.exe`:
  **PASS**.
- `bash -n scripts/smoke.sh`: **PASS**.
- `TMPDIR=/tmp/opencode bash scripts/smoke.sh`: ran once after the block fix. Block
  screen/save/post-exit bytes **PASS**, as did all other checks except the newly
  diagnosed immediate LSP Undo negative assertion. Full output:
  `/home/wayne/.local/share/opencode/tool-output/tool_138334f7d001SPXOee40TlNXC5`;
  screens `/tmp/opencode/ches-smoke-screens.V8IULe`.
- First focused LSP verification caught an erroneous additional bottom-row status
  barrier: the problems tile occupies the bottom row. Removed that additional
  barrier and retained the cursor-row completion check; its failed-run screens
  are `/tmp/opencode/ches-smoke-screens.3gtRbn`.
- `TMPDIR=/tmp/opencode bash scripts/smoke.sh --lsp-only`: final **PASS**, including
  Undo notice clearing, restart, retained history, server cleanup and tty restoration;
  screens `/tmp/opencode/ches-smoke-screens.J4qWgl`.

Both observed integration failures are diagnosed and fixed. The full smoke was
not repeated after the focused LSP correction to avoid redundant server load;
there is no claim of a single all-green full run in this slice. Existing changes
were preserved; no production editing/storage redesign, subagents or mutative git
commands were used. Undo/text-storage work can proceed with this blocker closed.

### Final integration verification — 2026-10-14

After the final text/history changes and focused cross-feature review, one full
`TMPDIR=/tmp/opencode bash scripts/smoke.sh` run **passed all checks** (exit 0),
including blockwise saved bytes before/after exit and LSP Undo/restart/process
cleanup. Screens: `/tmp/opencode/ches-smoke-screens.yaj6JY`; full output:
`/home/wayne/.local/share/opencode/tool-output/tool_13849d53a001CTzZiDprhYNL3m`.
`python3 scripts/picker_smoke.py` also **passed**; fixtures/captures:
`/tmp/opencode/picker-terminal-9lji89tq`. Final build/full Dune suite and three
directory PTY scenarios passed sequentially; exact commands and review scope are
in `../PERFORMANCE_TEST_PLAN.md`, final integration handoff. Review fixed bounded
cleanup of an LSP process surviving stdout EOF, with a real-child regression.
This supersedes the outstanding full-terminal verification status above while
preserving all failed-run evidence. Human visual/ranking acceptance, comparative
terminal latency/RSS quantiles and the documented bounded-work limitations remain
separate, unperformed checks.
