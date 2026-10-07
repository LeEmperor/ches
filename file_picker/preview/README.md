# Bounded file preview (phases 11–13)

`ches_file_preview` is a read-only data/lifecycle library. It does not
render, modify screen state, open/activate documents, initialize highlighting or
language servers, or change file-picker acceptance. Production frontend wiring
and responsive presentation are now installed by `ui/editor_view.ml` and
`screen/file_picker_tile.ml`. `ches_file_preview_model` in `pure/` exposes the
same Model through the service's compatibility alias without adding Async to
the screen library.

Historical phase-11 scope was data/lifecycle only, with no presentation. Phase 12
installed the production pane; phase 13 reviewed it and added real-terminal checks.

## Data contract

- `Model.state`: Loading, Ready, Truncated, Empty, Missing, Unreadable, or
  Unsupported (Binary, Encoding, Special_file).
- Payloads have source (Disk or Buffer with revision), valid UTF-8 prefix text,
  at most 100 LF-delimited rows, and raw prefix byte count. Retained text and rows
  are each at most 64 KiB; neither includes the rest of the document. Rows exclude
  LF, with no extra row after a trailing LF.
- Truncation records byte cap, line cap and UTF-8 boundary removal separately.
  Cap hits are conservatively truncated even at exact EOF: no extra read is used
  to prove EOF. An incomplete legal scalar at the byte cap is dropped; invalid
  interior UTF-8 or incomplete UTF-8 at actual EOF is Unsupported Encoding.
- NUL-containing prefixes are Unsupported Binary. This is a prefix detector, not
  whole-file binary classification. CRLF is retained, not normalized. Control
  characters may remain: **render through safe shared display-cell utilities,
  never write payload text directly to the terminal**.
- `Model.collect` bounds every read by BOTH remaining bytes and LF budget. Even
  newline-only input cannot read line 101; arbitrarily long lines cannot allocate
  arbitrarily large reads. Scratch space is 100 bytes. No buffered whole-file or
  unbounded line reader is used.
- `Model.of_buffer` uses line offsets and a boundary-safe bounded `Text_buffer.slice`,
  not whole-text conversion or copying an entire long line.

## Phase-12 integration guide

1. Add `ches_file_preview` to the appropriate Async host/frontend library, not
   `ches_app` or the pure screen library. Reuse **one Provider per frontend**, not
   one per opening/render. Construct it with a late current-session lookup:

   ```ocaml
   let preview = Ches_file_preview.Provider.create
     ~buffer:(fun ~path ->
       Ches_file_preview.Buffer_snapshot.lookup
         (Ches_screen.Ui_state.session !current_ui) ~path) ()
   ```

   The adapter uses retained file controllers (including dirty/missing buffers),
   without activation or provider initialization. None falls back to disk.

2. After picker activation, selection navigation, query/result installation and
   discovery changes, derive the current pure picker model using
   `Ui_state.file_picker -> File_picker_tile.session -> Interaction.model`.
   Pass that to `Provider.follow preview (Some model)`. Pass None if the picker is
   closed, absent, UI exited, or frontend inactive. `follow` resolves the actual
   selected candidate and discovery session. It is idempotent for unchanged
   identity; empty results clear the preview. Retain its returned request option
   as the UI's expected installation token. A direct `Provider.select` is also
   available if the host already has the selected candidate.

3. Render the immediate `Provider.snapshot` (Loading after identity changes).
   Run a **single frontend-owned Async notification pump**: capture a
   `Provider.changed` deferred BEFORE reading the latest snapshot/injecting its
   delivery, then await that captured deferred and repeat.
   Notifications coalesce; there is no accumulating result/event queue. Read
   current state between turns; never capture the initial picker/session.
   Selection changes must also update expected identity synchronously, not wait
   for the pump. Capturing the waiter before injection ensures a notification
   during a yielding injection is not lost. A clear/absent snapshot ends the pump;
   restart on activation/selection. Teardown must explicitly clear the provider.

4. Add a preview delivery input/state to the phase-12 screen model. At installation,
   use `Model.accept ~expected delivery`: it compares discovery session/root,
   selected identity AND generation. A path-only guard is insufficient for A-B-A
   or close/reopen. On close/deactivation clear the screen payload and expected
   token as well as calling `Provider.clear`; queued screen events must then be
   rejected. Provider guards alone cannot reject an event already queued by UI.

5. Use `~refresh:true` on `follow`/`select` only for a known retained-buffer revision
   change requiring a fresh snapshot. Do not refresh every render: that would
   restart debounce. Lookup occurs after debounce and after an older active read
   completes, so pending work sees current unsaved text rather than opening-time
    text. The production frontend refreshes on retained buffer identity/revision changes.

6. Attach `Provider.clear` to actual picker release, replacement, shutdown and
   frontend deactivation, including error paths. It drops retained payload/pending
   work immediately, aborts debounce/timeout timers, sets the cancellation token
   and wakes an idle notification waiter. UI close must NOT wait for physical IO.
   `finished` joins the read active at call time; clear first for teardown tests or
   background cleanup.

## IO and lifecycle bounds

The production frontend follows selection after every transition (also between
batched inputs), immediately installs the expected token/loading snapshot, and
runs one waiter-before-snapshot/injection pump. Its buffer lookup reads the CURRENT
UI session; retained buffer identity/revision changes trigger refresh without
refreshing unchanged renders. Resize clears and re-follows with a fresh generation;
closure, replacement, deactivation and exit clear provider and screen payloads.
The screen additionally validates current discovery session/selection at delivery.
The file-only floating pane splits at 96 content cells (104 terminal cells opens
the wider layout), using shared `Cell_map`/`Span` safe display-cell mapping and
visible rows only. It never captures keyboard focus or changes acceptance.

Defaults: 60 ms selection debounce and 2 s disk-read timeout (test-configurable).
At most one physical read, one latest pending identity, one debounce timer and one
current payload exist per service. Replacement cancels old work cooperatively and
overwrites pending identity instead of chaining a deferred job per selection.
Workers return data only; they never mutate the UI. Old results cannot install
even when a test reader ignores cancellation and returns late.

Disk `stat`, `open`, `fstat`, reads and close execute in `Async.In_thread.run`.
Known non-regular targets are rejected before opening. `O_NONBLOCK` prevents a
regular-to-FIFO race from blocking open, and descriptor `fstat` rejects a raced
special target before reading. Symlinks may resolve to regular files; links to
special files/directories are unsupported, dangling links missing, loops/errors
unreadable. This is not a symlink-containment/security boundary.

**Limitation:** an already-blocked regular-filesystem syscall (e.g. unavailable
network filesystem) cannot safely be forcibly cancelled in an OCaml worker thread.
Timeout replaces visible Loading with Unreadable and sets cancellation, but the
single physical slot remains occupied until it returns. Latest replacements wait
without spawning additional workers; `finished` can consequently be delayed.
Debounce/timeout do not constitute a measured latency guarantee. No UI-thread disk
IO, unbounded read-ahead or special-file streaming is performed.

## Checks

`test/test_preview.ml` exercises strict read budgets, giant lines/newline-only
files, cap UTF-8 boundaries and invalid encodings, cancellation between reads,
bounded buffer copies, 1000 rapid replacements with a controlled stalled read,
session/generation rejection, close cleanup, debounce and late buffer lookup,
timeout serialization, actual picker-model follow/refresh/empty-selection seams,
idle teardown notification and exception states. Real `/tmp/opencode` fixtures
exercise regular files, missing/empty/binary files, FIFO/symlink policies and a
retained dirty buffer whose disk file disappears, checking unchanged tab identity,
buffer count and highlight parse count.

`screen/test/test_file_preview.ml`, `screen/test/test_file_picker_host.ml` and
`ui/picker_test/test_preview_frontend.ml` additionally exercise presentation,
generation/session guards, rapid selections, dirty snapshots without activation,
resize/hide/tiny closure and close/reopen. Frontend deactivation rejects queued
preview deliveries in `ui/picker_test/test_frontend.ml`. `scripts/picker_smoke.py`
checks native Tab/Shift-Tab selected acceptance, dirty/missing/large/empty/binary
prefixes, safe controls, narrow/wide resize, A-B-A, close/reopen and interrupted
paste in an isolated tmux terminal. The phase-13 handoff records exact outcomes
and captures. No human visual acceptance or measured latency/p99/RSS claim is made.
