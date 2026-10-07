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
   then invokes `release`, then delivers exactly one raw-path intent. `release`
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
