# File picker (phases 1–6, 10–13)

`Interaction` is a single-owner, scheduler-independent mutable session. The screen
adapter is `Ches_screen.File_picker_tile`, now registered with the shared floating
host through explicit `Ui_state.open_file_picker`. `Ches_file_picker_host.Runtime`
connects Async discovery and yielded ranking; `Editor_view.app ?file_picker`
optionally overrides the production consumer for tests. By default `Space f f`
and **Find project files** use the session's existing-file open/activation path
after capture release and UI installation. Dirty buffers are never reread.

Production activation is installed between inputs, including batched input, so
following query keys cannot reach the document. `scripts/picker_smoke.py` checks
real file/content opening with isolated terminal fixtures; build/full suites and
terminal checks pass, including native Tab/Shift-Tab and bounded selected previews.
See the current phase-13 handoff in `FILE_PICKER_PLAN.md`.
Human visual/ranking/performance acceptance remains separate and unperformed.

## Host contract

1. Retain the explicit project root. Start the existing discovery provider and
   create a tile with that run's snapshot and the invoking host's token.
2. Poll bounded discovery deliveries and call `install`. Other roots/runs and
   closed sessions are rejected. The provider still owns ordering, deduplication,
   candidate limits and process cleanup. A refresh uses a new session/run.
3. Forward query events/paste to `update`. Keys follow the command palette's
   conventions. Tab/Shift-Tab and Ctrl-n/p navigate results; Escape/Ctrl-c remain
   host-owned; cancellation calls `cancel`.
4. Schedule `work ~budget:128` **outside input/render callbacks**, yielding between
   turns and polling for new input/delivery. Do not synchronously drain work in the
   live host. Also do not restrict work to one turn per terminal redraw: a broad
   50k query needs 782 turns. Runtime `next` polls one batch and yields before work;
   the frontend chains dedicated snapshot/work actions, independently of frames.
5. Render into shared shell content. Reserve at least three content rows for
   query, discovery status, and one result; root is in the title and counts/status
   are in the footer. This differs from the command palette's two-row content
   minimum. Narrow/tiny rendering is bounded but can clip important metadata.
6. `accept ~release ~consume` first marks the session closed and drops work/cache,
   then invokes `release`, then delivers exactly one raw-path intent. A validated
   idle session may first export a data-only snapshot to its runtime. `release`
    must cancel discovery and release input/paste capture/restore focus. Production
    consumption queues a dedicated UI input using `Session.open_or_activate
    ~must_exist:true`; missing new files cannot become empty documents. Errors
    appear in feedback/history, with restored focus and the current buffer intact.
    Cancellation releases once with no intent. Exceptions are not retried.

The file-only float prefers 80×40 on narrow terminals and 175×40 at terminal widths
of 104 cells or more, centered and clamped with a one-cell margin where possible;
it requires a 14×5 terminal (three content rows). Other pickers retain their sizes.
Control footers follow the global hotkey-hints preference (hidden by default).
Use `Space v ?` before opening a picker, or **Toggle tile hotkey hints** in the
command palette. Counts, discovery status, errors and notices remain visible.
At 96 content cells or more, results are on the left and a read-only plain-text
preview is on the right. The preview never takes focus or opens a tab. It follows
selection and shows the first 64 KiB/100 lines, current dirty retained text when
available, otherwise a debounced asynchronous disk prefix. Loading, empty, missing,
unsupported, unreadable and truncated states are visible. Only visible rows are
rendered, with line numbers and safe control/TAB/UTF-8 display-cell clipping.
See [`preview/README.md`](preview/README.md) for lifecycle/data contracts.
It does not reallocate the underlying workspace and works in zen. Fitting resizes
retain query/selection; undersized resize closes and restores prior available
focus. Interrupted paste is invalidated on close, collected to its end, then
dropped even if the view reopens. Opening during paste is refused. Escape cancels;
Tab/Shift-Tab navigate; Ctrl-c follows the shared host's existing return-guidance notice.

For explicit assembly, call `Runtime.open_picker runtime ui ~root ~width ~height`,
then install that returned UI. Headless callers await `Runtime.next`, apply its
inputs and install the result before repeating, or use one `Runtime.pump` with a
current-state accessor. Restart after query changes; never run concurrent pumps.
The optional frontend assembly carries this initial UI, runtime and consumer.
`Ui_state.take_file_requests` must be taken/consumed only after installing the UI:
capture/discovery are already released and each intent is taken once. Cancel the
runtime on teardown and await `finished` for descriptor closure/child reaping.

## Work and selection policy

Production discovery uses `Discovery.Update`: bounded additions plus an immutable
bytewise ordered candidate-set tree, predecessor stamp/count and monotonic revision.
The provider does not build cumulative lists per batch. `Provider.poll`/`snapshot`
and `Model.discovery` remain explicit lazy compatibility list adapters; production
metadata, rendering, preview and host paths use non-materializing accessors.

Stream arrivals keep the current query cursor/ranking and preparation progress.
Stable intake ordinals drive preparation/selection identity, while persistent rank
keys use score then raw relative path for deterministic final ordering. Completed
known partial sets publish directly from persistent trees without a full output
copy. New additions invalidate the complete-query LRU, then are individually scored;
an in-progress narrow/reuse job keeps its already-done old-set work and adds the
new tail. Pending old results remain visible but cannot accept; after catching up,
the labelled partial set may accept as before. Failure/truncation retains its known
ranked subset on cold opens. Cached refresh failures/truncation instead remain
nonaccepting; see the reopen policy below.

An explicit picker visible revision covers query, selection, count/status, busy,
results and lifetime; the tile separately versions preview content. File-only work
with unchanged stamps retains cached workspace rows and Notty base. It still runs
normal activation/preview/source/session effect pumping. Every discovery delivery,
preview/input/notice/focus/layout/resize turn invalidates conservatively. The render
cache also checks dimensions and stamps independently; mutable pointer equality is
not used to infer unchanged content.

Input and snapshot installation only schedule/replace jobs; there is no full
preparation or ranking in them. One explicit work turn processes a bounded number
of candidates or ranked output records. Prepared fields are reused by exact raw
path across queries and incremental batches, including abandoned jobs. A new job
supersedes any partially emitted output. Ordered score/input-index map inserts
preserve `Search.rank`'s full ranking and stable ties without a final whole-list
sort. Completed jobs atomically publish results and drop obsolete cache entries.
Status-only snapshots sharing the candidate list do not rerank. Keep only the
latest snapshot, not a snapshot/history list.

Old results remain visible while filtering, labelled `Filtering... (Enter waits)`;
navigation and acceptance have no effects until publication. There is no queued
Enter that might unexpectedly open a later result. On publication, selection
survives by candidate identity; when absent it falls back to the first result or
none. The file tile fits its viewport to the model's retained selected index.

Results use a producer-owned builder with fixed 128-slot chunks and a shared
snapshot ID-to-ordinal map. Each ranked output writes ordinal-to-result positions
in chunks instead of rebuilding a balanced string map per query. Snapshot identity
and preparation slots are built once in yielded turns, including blank queries;
query changes retain partial identity work. Publication transfers ownership and validates
selection by logarithmic lookup without a final corpus copy. Counts, selected index
and movement are constant time; direct result/selection/viewport reads are
logarithmic and rendering reads only visible rows. `Model.results` remains a lazy,
once-per-generation compatibility enumeration, outside the live render/preview path.
Discovery counts are computed on snapshot installation, not on every frame.

Each fuzzy job compiles/decodes its query once and reuses score-only rolling DP
scratch. A candidate's basename/path share compact prepared text: ASCII folded
characters and bonuses use byte strings, while Unicode scalar/offset arrays are
shared across views. Single-character and whole-field matches skip DP. The original
fuzzy ranker remains available and is the independent randomized-test oracle.

Ranked rows contain immutable candidate/score metadata; alignment and escaped byte
positions are computed only by full result/viewport access. `Model.results` still
returns fully populated results if explicitly enumerated. Query-scoped memoization
holds at most 128 aligned rows and 256 KiB of conservatively charged position-list/
record payload. Oversized rows are returned exactly without being cached; metadata
selection, movement, preview following and acceptance do not align. Published
aligners capture immutable compiled queries/preparation maps, not reused job scratch
or mutable session/ordinal slots, so retained old models remain correct.

Empty/whitespace queries build an ordered zero-score/no-position index without
fuzzy preparation or a ranking/output pass. The index is reused when clearing the
query on the same snapshot; changed candidate lists invalidate it. Work still
honors the record budget, and pending results cannot be accepted or navigated.
Preparation is deferred until the first nonblank query, not eliminated for fuzzy
queries. Validated runtime snapshots can retain this index across close/reopen.

Completed nonblank queries are retained in a generation-scoped LRU: **four entries,
96 MiB conservative reachable-ownership budget** by default. The shared current
corpus (candidate records/strings/list, ID map, preparation data/maps/slots and blank
index) is charged once. Each entry charges result arrays/maps/rows, compiled tokens,
keys/closure overhead and its full future 256 KiB alignment reservation. Admission,
reuse and eviction do not walk the corpus. Counts/memory charges and hits/examined
candidates are available on `Interaction`; `create_with_cache_limits` supports
headless budget tests (entry cap 0–16, zero disables reuse/narrowing).

An exact cached query publishes in one work turn with no scoring/output rebuild,
retaining the CURRENT selected ID rather than the previous visit's selection.
Identical folded token arrays also reuse results for ASCII case/whitespace aliases;
the public raw query remains current. Busy queries still cannot accept or navigate.
For uncached queries, a complete cached matching set may supply survivors when every
old folded token is a scalar prefix of its corresponding new token and additional
tokens only add AND constraints. Survivors are rescored using original snapshot
ordinals; cached scores/rank order are not reused. The smallest compatible proper
subset is chosen. Whole-corpus parents add no benefit and are skipped. Interrupted
queries, partial output, incompatible edits and changed candidate sets never narrow.

Any changed candidate-list identity immediately drops the query LRU, even when the
path bytes happen to be equal; status-only delivery keeps it. Reused compact fields
are rebound to current candidate objects. No old corpus/index history is retained
through the LRU. Evicted or over-budget queries may need full ranking again; active
and in-flight results, externally retained models and explicit full-result lists
are separate from the LRU budget. This is not a global picker/peak-RSS limit.

This is count-bounded work, not hard realtime. Individual long queries/4 KiB paths,
ID map construction and natural GC can exceed a time budget. Visible-row alignment
uses at most 262,144 traceback cells (2 MiB on this 64-bit switch), plus rolling
rows. Larger alignments recompute prefix rows to preserve exact ties with bounded
memory, at increased worst-case CPU cost; explicit full-result enumeration aligns
all requested rows. The prepared cache remains additional to provider string
limits; cache maps, old/current results and in-flight structures add overhead. The
6c synthetic 50K observation retained 25.112 MiB after its first query, with a
4.26 MB compact character/bonus payload; this is not peak RSS or a worst-case bound.
Cache maps share
prepared entries, rather than decoding a second full snapshot. Closing clears
session-held candidates/results/cache. See `bench/README.md` for measured costs
and limitations, and `../docs/picker_performance_recommendation.md` for slices 6b–6f's
bounded lifecycle comparison, including first-query and broad-query costs. No
terminal input-to-screen latency guarantee is made.

## Runtime-owned reopen cache (6f)

One frontend runtime retains at most **two roots / 128 MiB conservative ownership
charge**, with a **30-second monotonic TTL since successful validation**. This is
separate from the four-entry query LRU. Keys use normalized lexical roots and an
explicit discovery-policy version (`native-v1` by default); use
`Runtime.open_picker_with_policy` when changing discovery configuration. Lookup
touches LRU order but does not extend validation age. Runtime cancellation clears
the cache; configurable root caps are limited to 0–4, with zero disabling retention.

Only idle, successful, untruncated streamed sessions export snapshots on close.
They retain candidate sets, identity/blank indices, compact preparation and bounded
completed-query entries. They contain no UI/session, preview, process, pipe,
cancellation callback or pending job. Preparation slots are copied on capture and
copy-on-write after restore; immutable map/tree roots are shared. Capture therefore
has an O(N/128) chunk-copy cost on close; a hit avoids a corpus rebuild on open.
Conservative byte charges include shared corpus ownership, slot/map overhead and
query alignment reservations, not process-wide peak RSS or externally retained models.

Reopen resets to the **blank query and first selection**. Cached blank rows appear
immediately, labelled `Loading / refreshing cached files...`; every opening starts
a fresh asynchronous rg traversal. **Enter is disabled until successful untruncated
refresh and publication**, even when a cached query is retyped. Unchanged sets
reuse their identity/preparation/results; retyped completed queries can hit the LRU.
Changed sets rebuild in bounded work turns, reusing unchanged preparations and
pruning deleted/ignored paths and obsolete query indices. Normal ignore-rule changes
are detected by traversal, independent of TTL or explicit policy versions.

Failed/truncated refreshes publish the fresh known subset, visibly remain
nonaccepting, and evict the saved runtime entry; close/reopen retries. Cancelling a
refresh may retain the previous validated entry only until its original TTL.
Acceptance still uses the existing session gate (`must_exist:true` for new files);
refresh is not an atomic filesystem snapshot, and retained dirty buffers are never
reloaded. Preview starts afresh under the new session identity.
