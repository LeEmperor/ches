# File picker foundations and floating integration (phases 1–5)

`Interaction` is a single-owner, scheduler-independent mutable session. The screen
adapter is `Ches_screen.File_picker_tile`, now registered with the shared floating
host through explicit `Ui_state.open_file_picker`. `Ches_file_picker_host.Runtime`
connects Async discovery and yielded ranking; `Editor_view.app ?file_picker`
assembles the frontend with a required injected consumer. There is still no
`Space f f` binding, command entry, default/no-op opener or real buffer activation.

## Host contract

1. Retain the explicit project root. Start the existing discovery provider and
   create a tile with that run's snapshot and the invoking host's token.
2. Poll bounded discovery deliveries and call `install`. Other roots/runs and
   closed sessions are rejected. The provider still owns ordering, deduplication,
   candidate limits and process cleanup. A refresh uses a new session/run.
3. Forward query events/paste to `update`. Keys follow the command palette's
   conventions. Escape/Tab/Ctrl-c remain host-owned; cancellation calls `cancel`.
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
   then invokes `release`, then delivers exactly one raw-path intent. `release`
   must cancel discovery and release input/paste capture/restore focus. Use a test
   consumer until the real multi-buffer open/activate-existing-path API lands.
    Cancellation releases once with no intent. Exceptions are not retried.

The shared float prefers 80×14 and requires a 14×5 terminal (three content rows).
It does not reallocate the underlying workspace and works in zen. Fitting resizes
retain query/selection; undersized resize closes and restores prior available
focus. Interrupted paste is invalidated on close, collected to its end, then
dropped even if the view reopens. Opening during paste is refused. Escape/Tab
cancel; Ctrl-c follows the shared host's existing return-guidance notice.

For explicit assembly, call `Runtime.open_picker runtime ui ~root ~width ~height`,
then install that returned UI. Headless callers await `Runtime.next`, apply its
inputs and install the result before repeating, or use one `Runtime.pump` with a
current-state accessor. Restart after query changes; never run concurrent pumps.
The optional frontend assembly carries this initial UI, runtime and consumer.
`Ui_state.take_file_requests` must be taken/consumed only after installing the UI:
capture/discovery are already released and each intent is taken once. Cancel the
runtime on teardown and await `finished` for descriptor closure/child reaping.

## Work and selection policy

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
none. The existing shared tile selection helper scrolls to the selected identity.

This is count-bounded work, not hard realtime. Publication performs O(results)
list reversal/selection validation; navigation, viewport fitting and counts also
scan lists. Individual long queries/4 KiB paths and natural GC can exceed a time
budget. The prepared cache is additional to provider string limits (phase-3
measurement: about 78 MiB at 50k typical paths); cache maps, old/current results
and the in-flight ranking/output structures add overhead. Cache maps share
prepared entries, rather than decoding a second full snapshot. Closing clears
session-held candidates/results/cache. See `bench/README.md` for measured costs
and limitations. No end-to-end scheduling/latency claim is made.
