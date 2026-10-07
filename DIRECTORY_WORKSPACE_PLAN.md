# Directory Workspace: buffers, tabs, and editable directories

Status: phases 0–9 implemented; final integration checks recorded below. Scoped on 2026-10-06.

## Goal

Give Ches an Oil/Dired-style filesystem editing surface, backed by ordinary text
editing, with persistent open file buffers and tabs. Support directory browsing in
either the major editor tile or a minor side tile, and opening files individually,
from a visual selection, or from a non-contiguous marked set.

“Directory Workspace” is the umbrella feature name. Use “directory buffer” in code
and UI; “Oil” describes the interaction inspiration rather than a dependency.

## Agreed interaction model

- `ches .` opens the current directory. File arguments retain their existing meaning.
- `Space o` from a file opens its parent directory and selects that file.
- `Space o` from the directory returns to the previously active file, if one exists.
- `Enter` on a file opens it in the target editor group, reusing its existing tab.
- `Enter` on a directory navigates into it.
- `-` navigates to the parent and selects the directory just left.
- Files remain open when another file is opened; edits, undo, cursor, and scroll survive.
- Directory navigation remembers selection and scroll. Hiding or changing placement
  never discards pending directory edits or marks.
- Directory content is buffer-backed from the first browsing implementation, even
  when initially read-only.
- Directory presentation can occupy the major editor tile or a minor side tile.
  Opening a file from the side tile sends it to its target editor group.
- Directories do not need ordinary tabs alongside file tabs. Major placement changes
  the editor area's presentation while preserving the group's file tabs underneath.
- Visual-range opening and non-contiguous marking are both first-class operations.

Example:

```text
ches . → directory buffer
Enter on main.ml → [main.ml]
Space o → directory buffer, main.ml selected
Enter on config.ml → [main.ml] [config.ml]
```

## Proposed defaults to finalize during implementation

These are recommendations, not additional user-approved keybindings or policies.

- Start with one editor group and persistent file tabs, without preview-tab behavior.
- Normal `Enter` targets the cursor entry; Visual `Enter` targets intersected entry
  rows; a separate “Open marked files” command targets marks. Existing marks never
  silently override ordinary `Enter`.
- Batch open in current listing order, deduplicate targets, and activate the first
  successfully opened target. Continue after individual failures and summarize them.
- Batch opening skips directories with feedback; single-entry `Enter` navigates.
- Clear successfully opened marks; preserve failed or skipped marks.
- Marks are temporary entry-associated state, rendered outside editable text.
  They neither dirty the directory nor participate in text undo.
- Opening entries never implicitly saves filesystem edits. A renamed existing row
  opens its existing backing path until commit; a new row requires saving first.
- Closing the last file shows the remembered directory, or the startup directory.
- Closing a modified buffer and quitting a modified session require explicit handling
  through Ches's command/feedback conventions. Quit checks hidden directory buffers too.
- After successful directory save, refresh the baseline and start a fresh text undo
  history. Filesystem undo is a future feature, not an implication of ordinary `u`.
- Initially retain visited directory buffers for the session. Eviction is future work;
  dirty buffers must never be evicted implicitly.

## Architectural boundaries

### Existing seams

- `app/controller.mli`: explicitly owns one editor, keymap, highlighting runtime, and
  effect execution. Currently exposes document-local save and application exit behavior.
- `screen/ui_state.mli`: holds one controller, a scroll position, tile host, and
  supporting-view state; assembles input routing and diagnostic requests.
- `screen/workspace.mli`: allocates one primary document pane, status, and minor views.
  Existing minor allocation is a bottom band, so a real side tile needs layout work.
- `core/`: modal text editing and undo machinery to reuse for directory text.
- `input/`, `palette/`: bindings and discoverable commands.
- `source/`, `error/`: diagnostic lifecycle, resource identity, and feedback.
- `bin/`, `ui/`: startup path handling and terminal integration.

Implementers must recheck the current checkout, especially ongoing floating-tile
work described in `FLOATING_TILES_PLAN.md`, before changing shared screen modules.

### Target ownership

```text
Session
  buffers: Buffer_id -> File_buffer | Directory_buffer
  resource index: normalized resource -> Buffer_id
  editor group: ordered file tabs + active tab
  directory presentation: buffer + placement + target group + return target
  shared feedback, register/clipboard policy, diagnostic routing

File buffer
  stable ID, current path, text, revision, dirty state, undo, highlight runtime

Directory buffer
  stable ID, directory path, baseline entries, editable text, entry identities
  pending edits, marks, listing/navigation state

View
  buffer reference, viewport, focus/input context
```

- Stable IDs survive path changes; paths are resource attributes, not buffer IDs.
- The session controller coordinates buffers above document-local editing machinery.
- Keep filesystem I/O in the application layer and planning/validation pure where possible.
- Directory content and actions do not depend on major/minor placement.
- Start with one visible directory view. Simultaneous views of one buffer and multiple
  editor groups can be added later without making the initial implementation depend on them.
- Cursor currently belongs to the editor core. Preserve it per buffer initially;
  avoid a full multi-view cursor refactor until independently needed.
- Clear/cancel pending modal prefixes when switching input contexts; preserve paste
  ownership and tile-host focus invariants.
- Shared registers must allow yanking in one file and pasting into another. Avoid
  accidentally introducing one isolated clipboard/register per controller.
- Diagnostic events must resolve resource identity and revision against the owning
  buffer, including inactive buffers, rather than whichever tab is currently active.

## Phased implementation

Each phase should land in a usable state and record a handoff below. Dependencies
are intentional: do not build filesystem mutations before entry identity is settled.

### Phase 0 — Contracts and directory-entry identity spike

Dependencies: none.

Tasks:
- Inspect current editor text/undo APIs, controller effects, tile routing, startup,
  and diagnostic ownership. Record concrete changes needed for session ownership.
- Specify buffer/group IDs, resource normalization, tab deduplication, close/save/quit
  commands, and directory presentation/return-target behavior.
- Define symlink path policy: lexical absolute-path deduplication versus realpath
  deduplication. Never accidentally make editing a symlink rename its target.
- Prototype stable directory entry identity through rename, line deletion, paste,
  duplication, reordering, joining, multiline replacement, and undo/redo.
- Choose protected identity tokens or edit-tracked metadata and document the tradeoff.
  A hidden row-number-to-entry map alone is insufficient once text is edited.
- Specify escaped display/round-trip rules for filenames, including tabs, newlines,
  invalid UTF-8, and names resembling identity syntax. Unsupported names must remain
  visible as non-editable entries rather than being silently misrepresented.
- Resolve mark/open commands and phase-local policy questions before coding dependents.

Acceptance:
- Written contracts and a small meaningful identity test/spike establish that changing
  a name preserves identity and inserting a fresh row creates a new identity.
- Duplicating an identity cannot ambiguously rename two entries: define copy semantics
  or reject it explicitly until copy support lands.
- Invalid identity edits are detected before any filesystem operation.

### Phase 1 — Session and multi-buffer lifetime

Dependencies: phase 0 session contracts.

Tasks:
- Add a session-level owner and resource index around document-local controllers.
- Implement open-or-activate, activate, close, save-current, save-all, and session quit.
- Preserve each buffer's edits, history, cursor, highlighting, and view scroll.
- Move session-wide feedback/clipboard/register/exit decisions to the appropriate owner.
- Define save-all partial-failure reporting; a failed buffer stays dirty.
- Route diagnostic updates/saves/closes to the correct resource; ensure inactive-file
  events cannot acquire the active buffer's revision. Reuse source runtimes where supported.
- Dispose highlight and diagnostic resources on actual close, not merely tab switches.
- Keep single-file startup and existing editing behavior working through the session.

Acceptance:
- Open A, edit A, open/edit B, switch back, and undo A independently.
- Opening A twice returns the same buffer; yanking in A and pasting in B works.
- Switching buffers cancels pending prefixes without leaking input.
- Save-current only saves its target; save-all reports each failure correctly.
- Quit detects dirty inactive buffers; close and application exit are distinct actions.
- Diagnostics and highlighting remain associated with the correct resource.

### Phase 2 — File tabs in the editor group

Dependencies: phase 1.

Tasks:
- Render ordered file tabs, active state, modified indicators, and disambiguated names.
- Add next/previous/close tab commands and palette entries; settle exact bindings.
- Handle narrow terminals and tab overflow deterministically.
- Preserve viewport geometry when tab visibility changes; define one-tab visibility.
- Implement the last-tab fallback without creating a fake file buffer.

Acceptance:
- Multiple opened files are selectable and preserve their state.
- Same-basename files can be distinguished; active tab remains discoverable under overflow.
- Closing tabs chooses a deterministic successor and handles unsaved content explicitly.
- Resize and tiny-terminal behavior preserve valid cursor and content geometry.

### Phase 3 — Buffer-backed directory navigation, major placement

Dependencies: phases 0–2.

Tasks:
- Add typed startup handling for files/directories; make `ches .` work.
- Load baseline directory entries into a buffer-backed, initially read-only surface.
- Render directory path, entry kinds, and an empty-directory state. Define sorting and
  hidden-file display consistently; keep path/header decoration outside editable rows.
- Implement `Space o`, `Enter`, parent navigation, return-to-file, and listing refresh.
- Preserve per-directory selection/scroll and select the originating file or child directory.
- Use a placement-independent directory adapter and explicit target editor group.
- Open files through session open-or-activate, retaining all existing file tabs.
- Report unreadable directories and unsupported files without destroying the current view.

Acceptance:
- The complete `ches .` → A → `Space o` → B workflow works with A and B in tabs.
- Navigating up/down restores the expected entry and viewport.
- `Space o` with no previous file is well-defined and harmless.
- Returning from directory presentation restores the previous file's cursor/scroll.
- Directory state survives presentation changes and failed opens.

### Phase 4 — Visual and marked-set opening

Dependencies: phase 3.

Tasks:
- Enable selection/copy operations in the read-only directory editing surface.
- Make Visual `Enter` resolve selected entry rows to an ordered target set.
- Add toggle-mark, mark/unmark-selection, clear-marks, and open-marked commands.
- Render marks as decorations keyed by entry identity; show a marked count.
- Centralize batch-open resolution so visual and marked opening share deduplication,
  ordering, partial-failure reporting, and target-group behavior.
- Keep marks directory-local initially. Cross-directory collections are deferred.

Acceptance:
- A contiguous visual selection opens multiple persistent file tabs.
- Non-adjacent marks open the intended files in listing order.
- Existing tabs are reused, mixed directories/files follow the documented policy,
  and one unreadable file does not prevent other targets opening.
- Ordinary `Enter` ignores unrelated marks; decoration never becomes filename text.
- Successful versus failed marks follow the documented clearing policy.

### Phase 5 — Minor side-tile placement

Dependencies: phases 3–4; coordinate shared layout files with other tile work.

Tasks:
- Add side placement to workspace allocation using the existing tile host/shell patterns.
- Reuse the directory buffer and adapter from major placement; add placement commands.
- Preserve target editor group and explicit focus-return behavior.
- Keep the side browser present after opening; focus the opened file by default.
- Define size preference, resizing, zen behavior, and behavior when width is insufficient.
- Moving/hiding the view must preserve its buffer and never discard pending state.

Acceptance:
- The same directory supports major and side presentation with matching navigation,
  visual selection, marks, and batch-open behavior.
- Side-tile opens populate editor tabs, not the browser tile.
- Placement changes preserve selection, scroll, marks, and later pending edits.
- Narrow layouts and focus reconciliation leave a reachable editing surface.

### Phase 6 — Editable directory model and pure operation planner

Dependencies: phases 0 and 3–4. Can develop independently of phase 5 after adapter contracts settle.

Tasks:
- Enable ordinary modal text edits and undo using the chosen identity mechanism.
- Parse edited rows against the baseline into an explicit proposed operation plan.
- Support create-file, create-directory, and rename proposals first.
- Detect deletion/copy proposals but reject them clearly until their executor support lands.
- Validate names, duplicate destinations, identity misuse, conflicting paths, and collisions.
- Treat trailing `/` as directory-creation syntax; define existing-entry type changes explicitly.
- Show pending changes/dirty state and expose a readable operation summary.
- Keep planning independent of rendering and filesystem mutation.
- Navigation retains dirty buffers; reload requires explicit discard or refuses when dirty.
- Marks follow existing entries through edits/undo; define cleanup when rows are deleted.

Acceptance:
- Editing a name produces rename, adding a row produces create, reordering produces no change.
- Undo restores the proposed text/identity state without touching disk.
- Invalid or unsupported plans execute zero operations and show actionable errors.
- Dirty directory buffers participate in session close/quit checks.
- Existing renamed rows open their backing files; unsaved new rows do not implicitly create files.

### Phase 7 — Filesystem apply and open-buffer reconciliation

Dependencies: phases 1 and 6.

Tasks:
- Execute validated create/rename plans through application effects.
- Recheck affected baseline entries and destinations immediately before mutation;
  document the limits of race detection rather than claiming transaction guarantees.
- Handle rename dependencies and cycles using staged temporary paths with collision checks.
- Initially support within-directory renames and simple child creation; reject cross-device
  or cross-directory move syntax until phase 8 defines it.
- Decide whether save applies directly or presents a confirmation summary, using existing
  command/feedback patterns. Record the chosen behavior here.
- Record completed operations and reconcile actual disk state after partial failure;
  retain unresolved intent explicitly without replaying successful operations on retry.
- Update paths/resource indexes for open files and descendants of renamed directories,
  preserving text, dirty state, undo, tabs, and directory navigation references.
- Refresh highlighting language and diagnostic lifecycle after path changes as needed.
- On success, refresh directory baselines and reset directory text undo history.

Acceptance:
- File/directory creation and renames affect disk only on explicit directory save.
- Rename swaps preserve contents and do not overwrite unrelated destinations.
- Renaming an open dirty file preserves its contents and makes its next save use the new path.
- Renaming a directory updates open descendants and cached directory resources.
- Simulated failure after an earlier success reports actual outcomes and permits a safe retry.
- External changes/collisions are detected without silently overwriting unexpected data.

### Phase 8 — Delete, copy, and cross-directory operations

Dependencies: phase 7.

Tasks:
- Choose and document deletion policy: trash versus permanent removal, including nonempty
  directories, symlinks, unsupported trash environments, and clear command wording.
- Preserve in-memory buffers whose backing files are deleted. Mark them missing and require
  an explicit recreate/save-as action rather than allowing routine save to resurrect them silently.
- Define copied-row semantics and source identity, then add copy planning/execution.
- Define cross-directory moves, destination syntax, dirty-directory coordination, and
  cross-device behavior. Do not disguise copy-plus-delete as atomic rename.
- Specify copies of symlinks and metadata preservation scope.
- Extend partial-failure reconciliation and operation summaries to all supported operations.

Acceptance:
- Deleted open files retain recoverable in-memory text and a clear missing-resource state.
- Copy/move destinations never overwrite unrelated entries implicitly.
- Symlink operations affect the intended link or target according to documented policy.
- Cross-directory operations update all affected cached listings and open-buffer paths.
- Fault-injected failures preserve accurate completed/pending operation reporting.

### Phase 9 — Integration, documentation, and terminal validation

Dependencies: all supported feature phases above.

Tasks:
- Update README capabilities/limitations, CLI help, editor reference, and command palette.
- Document bindings, placement, marks, save semantics, unsupported filenames/operations,
  partial failure behavior, and directory undo boundaries.
- Exercise the complete workflow in the terminal, including startup with no file tabs,
  batch opening, placement changes, dirty buffers, save, and quit.
- Audit runtime cleanup and long-session behavior with many open files/directories.
- Record remaining limitations and follow-up work without expanding this feature's scope.

Acceptance:
- Appropriate headless tests, `dune build`, and `dune runtest` pass with the repository toolchain.
- Terminal smoke coverage verifies focus, rendering, key sequences, tab persistence,
  and filesystem results for representative end-to-end scenarios.
- User documentation matches implemented behavior and all phase handoffs are current.

## Agent execution and handoff protocol

Assign one phase or a clearly bounded phase task per agent. Start each assignment by
reading this plan and the relevant current interfaces; earlier implementation may
have changed the initial architecture observations.

- Phases 1–4 are the main sequential path to the requested navigation workflow.
- Phase 5 (placement) and phase 6 (planner) can run in parallel after phase 4 if
  directory adapter/state contracts are settled and ownership of shared files is explicit.
- Phase 7 depends on the planner, not side placement; phase 8 builds on its executor.
- Avoid concurrent edits to `screen/ui_state`, `screen/workspace`, shared input types,
  or controller interfaces without an agreed integration owner.
- Use meaningful tests for lifetime/routing, identity, planning, and filesystem effects.
  Filesystem tests should use isolated temporary directories and injected failures;
  never exercise mutation tests against the repository's own files.
- Run checks appropriate to the phase; record commands and results. Do not claim a phase
  complete if a required behavior is only stubbed or a check could not run.

Append a handoff for every implemented phase:

```text
Phase / date / status:
Implemented behavior:
Changed modules and new public contracts:
Policy decisions settled:
Checks run and results:
Known gaps or blockers:
Next-phase integration notes:
```

## Deferred beyond this plan

- Multiple editor groups/split editors and simultaneous views of one buffer.
- Preview tabs, session persistence across process restarts, and buffer eviction.
- Persistent named tags, cross-directory mark collections, recursive batch opening.
- Filesystem-level undo, background directory watching, remote filesystems.
- Editable permission/owner/time columns and general-purpose file-manager features.

## Implementation handoffs

### Phase 0 / 2026-10-07 / implemented

#### Implemented behavior and public spike contracts

- Added pure `core/directory_identity.ml` / `.mli` and eight headless tests in
  `test/test_directory_identity.ml`. No startup, controller, input, rendering, or
  filesystem behavior changes. This is an identity/codec spike, **not** phase 6's
  operation planner. `create` validates a baseline; `text` serializes it into ordinary
  `Text_buffer`; `parse` validates a whole edited snapshot and returns entry-associated
  rows; `missing_ids` exposes deletion proposals without executing anything.
- Existing entries carry positive directory-local IDs, independent of name, order,
  and kind decorations. Baseline IDs are allocated monotonically by the eventual
  directory-buffer owner, never reused during that buffer's lifetime, and remain
  stable across refresh/save for surviving entries. Refresh after external changes
  must not infer identity solely from a matching row number or inode (hard links
  exist); retain unchanged backing names, reconcile known committed operations,
  and give genuinely new/external replacement entries new IDs.
- Chosen mechanism: explicit identity tokens, protected **by validation**, rather
  than edit-tracked invisible metadata. Existing row syntax is
  `@ches[ID]<TAB>ENCODED_NAME`, with `/` after directory names only. Tokens are ordinary
  visible text in this spike and travel with yank/paste, multiline replacement, and
  the editor's existing undo snapshots. Rendering may style them as a muted prefix
  later, but must not hide a row-number map and claim it is identity. Headers, kind
  icons, mark indicators and paths remain outside editable text.
- Renaming a name retains its ID; moving whole rows retains IDs; deleting a row
  removes that ID from the proposal, not from the baseline. A tokenless row is
  `Fresh`, a creation proposal with **no backing identity**. Separate fresh rows
  are separate proposals; stable entry IDs are assigned on successful creation,
  not from provisional row positions. Opening fresh rows requires save first.
- Copying a complete existing row duplicates its ID and is explicitly rejected
  until phase 8. Cutting then pasting once is a move. Joining two token rows,
  splitting a token, malformed/noncanonical/unknown IDs, malformed escapes, and
  existing-kind changes fail whole-snapshot validation. Undo/redo can restore either
  valid or invalid text; invalid text never authorizes filesystem IO.
- This mechanism is not tamper-proof: removing a **whole** token looks like deleting
  the original entry plus creating a new one, and exchanging valid unique tokens
  asserts different name-to-ID associations. Do not infer an intended rename from
  these edits. Phase 6 must reject every missing-ID/deletion proposal until phase 8;
  phase 8 must show destructive intent explicitly under its deletion policy. The
  adapter should discourage partial token edits, but command interception is not
  required to make the snapshot validator safe. Never execute only the valid subset
  of an invalid snapshot. Destination collisions and unsupported operations still
  require phase 6 validation; parser success alone is not an executable plan.

#### Filename display and round-trip contract

- Unix child names are raw byte strings, not assumed UTF-8. The canonical editable
  representation is printable ASCII; encode every byte below 32 or at least 127,
  backslash, `@`, and first/last spaces as uppercase `\xHH`. Internal spaces remain
  literal; do not trim any row. Thus TAB = `\x09`, LF = `\x0A`, CR = `\x0D`, invalid
  UTF-8 byte FF = `\xFF`, backslash = `\x5C`, and `@` = `\x40`. Unicode names are
  currently byte-escaped too: less pretty, but deterministic, terminal-safe, and
  lossless without a UTF-8 exception path. Names resembling identity syntax are
  escaped names, never tokens. No shell-style quoting or escape interpretation.
- Decode only canonical uppercase hex escapes. Reject empty names, `.`, `..`, NUL,
  and slash even when escaped. A single unescaped final `/` means fresh directory
  creation; existing entries must keep their original kind. In particular a symlink
  to a directory is still a symlink row, **without** `/`; display target-kind hints
  outside text. Empty rows (including final LF) are ignored; a literal-space-only
  name must use canonical edge escapes. Preserve original baseline bytes for IO.
- The codec supports all legal Unix child-name bytes, tested individually and in
  combination. Unsupported filesystem kinds (FIFO/socket/device or a later platform
  limitation) remain visible as `Unsupported` rows and are non-editable: alteration
  or omission rejects validation. They may be selected/copied, but opening or filesystem
  operations report unsupported. Never silently omit an unrepresentable entry; use
  an explicitly read-only escaped display if another platform cannot round-trip it.

#### Session contracts for phase 1 (specified, not implemented here)

- Introduce separate abstract `Buffer_id` and `Group_id` types with comparison/hash
  support and monotonic session-local integer allocation. IDs are not paths, tab
  positions, `View_id`, entry IDs, or LSP versions. Start with exactly one editor
  group. The session resource index maps a normalized absolute path to one typed
  file/directory buffer; kind conflicts require explicit refresh/reconciliation.
  Close releases the index entry; reopen gets a new buffer ID. IDs survive renames.
- Resource normalization is **lexical absolute-path** normalization: resolve relative
  inputs against an explicit startup working directory, collapse repeated `/`, `.`,
  and `..` (clamped at root), strip final `/` except root. Case-sensitive byte equality
  on this Unix checkout; no `realpath`, case folding, inode or hard-link deduplication.
  Normalized paths must also be the paths used for IO, not just index keys. This
  intentionally gives lexical `link/..` semantics, not the OS's symlink traversal
  semantics; document this limitation and do not silently mix both interpretations.
  Startup directories may themselves be symlink paths and keep that lexical identity.
- Opening the same normalized file activates its existing buffer/tab, including dirty
  content; a failed new open creates no tab and leaves the current presentation intact.
  Tabs are ordered by first successful open, no preview replacement or MRU reordering.
  Two symlink aliases or hard links may deliberately open as distinct buffers; their
  shared target is not deduplicated and save conflict detection is not promised.
- Symlink **directory-entry mutations** always use the stored lexical parent/child
  path and `lstat` identity, never a resolved target path. Renaming a symlink renames
  the link, not the target. Opening/saving a file through a symlink follows the target
  as current `File_io` does. Single-entry navigation may follow a directory symlink,
  retaining its lexical path; cycles do not trigger recursive traversal. Refresh and
  phase 7 must distinguish a replaced link from the original baseline link.
- Semantic commands: `Open_or_activate`, `Activate_buffer`, `Close_current`,
  `Force_close_current` (explicit discard), `Save_current`, `Save_all`, `Quit_session`,
  `Force_quit_session`. Exact new keys deferred to their UI phases; existing `Space w`
  stays save-current and `Space q` / `Space Q` become session quit / explicit discard
  quit. Close is not quit. Dirty close/quit refuses with actionable feedback naming
  dirty buffers, including hidden directories; force commands require explicit user
  invocation, not a repeated-key or implicit discard heuristic. No confirmation dialog
  machinery is required for phase 1. Save-all visits dirty buffers in buffer-ID order,
  continues after failures, reports each result and a summary; failures stay dirty.
- Closing an active tab chooses the next tab at its old index, else the preceding last
  tab. Closing an inactive tab leaves activation unchanged. Closing the final file
  falls back to the remembered directory, else startup directory (the initial file's
  parent for file startup); phase 1 may represent this as a no-file session pending
  phase 3, never fabricate an empty file. Non-active buffers retain text, undo, cursor,
  mode, highlights, and scroll; finish Insert transactions/exit Visual on an explicit
  context switch before hiding, then reset both outgoing and incoming pending keymaps.
- Session owns one unnamed register, clipboard queue and feedback store. Before each
  document dispatch install the session register; after a yank/delete collect its new
  value, without falsely publishing clipboard changes merely due to tab activation.
  Effect dispatch stays synchronous and buffer-addressed; highlight runtimes remain
  document-local and are released on actual close/session shutdown, never switching.

#### Presentation, navigation, and marks contracts

- Presentation state carries directory `Buffer_id`, `Major | Side`, target `Group_id`,
  and optional return file `Buffer_id`. Major replaces the visible editor surface,
  preserving file tabs and group activation underneath; directories do not become file
  tabs. Side reuses the same directory adapter/state, not a new buffer. Initially one
  directory view; moving/hiding it preserves text, cursor, scroll, marks and baseline.
- File `Space o` shows its parent and selects its baseline backing entry, recording
  that file as return target. Directory `Space o` returns to the recorded live file;
  if closed, fall back to the group's live active file; with neither, remain in the
  directory and give harmless feedback. Successful major file-open activates the file
  surface; side file-open keeps the directory visible and focuses the target editor.
  Parent navigation selects the child just left. Remember selection by entry ID and
  scroll per visited buffer; missing selections choose the old index's next neighbor,
  else last row. Retain visited directories for the session. Dirty refresh refuses
  unless an explicit discard/reload command is invoked.
- Sort all entries, including dotfiles, by raw byte name (case-sensitive, no directory
  grouping); synthetic parent/header/empty hints are decorations, not editable entries.
  Listing order means current text row order once editing is enabled. Normal Enter
  acts only on the cursor row; single directory Enter navigates. Visual Enter opens
  all intersected entry rows, including blockwise intersections, in listing order;
  headers/empty rows are ignored. Marks never override either Enter behavior.
- Named commands (palette-first, new bindings deferred): `Toggle_entry_mark`,
  `Mark_selection`, `Unmark_selection`, `Clear_directory_marks`, `Open_marked_files`.
  Marks are directory-local existing-entry IDs, external to text/history/dirty state;
  fresh proposals cannot be marked for opening. A deleted text row leaves its mark
  dormant so undo restores visibility; successful commit prunes actually removed IDs.
  Existing renamed rows open their **baseline backing path**, not pending destination.
- Both batch paths deduplicate normalized resources in current listing order, skip
  directories/unsupported kinds with feedback, continue after individual failures,
  activate the first successful file, and summarize failures/skips. Open-marked clears
  only successfully opened IDs (including existing-tab activation); skipped/failed
  marks remain. Ordinary/visual opens do not change marks. No opening implicitly saves.

#### Concrete current-code seams and changes required

- `core/editor.mli`: immutable text snapshots, byte-boundary cursor, increasing revision,
  dirty comparison to saved text, Insert transactions and text/cursor undo already
  suffice for token identity. `Text_buffer` accepts only UTF-8 without NUL/CR, hence the
  byte codec. Cursor is per editor; do not introduce multi-view cursors. Editor path
  has no reassociation API: add a narrow path update before phase 7, preserving history
  and saved text. Directory save must not dispatch `Effect.Write_file` for listing text;
  phase 6/7 use application planning/apply and a fresh saved-text/history baseline.
- `app/controller.ml` currently owns feedback, pending clipboard/save, keymap, highlight
  runtime and synchronous `perform`; `Effect.Exit` closes its highlight runtime. Phase
  1 must separate session exit from document close, collect save events per buffer
  rather than one newest event, and centralize feedback/registers. Do not dispatch
  document-local Quit as if it checked dirty siblings. `Controller.cancel_pending`
  already wraps `Keymap.reset`; `Editor.set_unnamed_register` is the register seam.
- `screen/ui_state.ml` owns a single controller, `scroll`, `sent_revision`, held source
  lists and host. Replace active-controller ownership with session access, persist
  scroll per buffer, sent revisions per resource, held lists per owning buffer/source,
  and clear animation trails on context switches. `take_source_requests` emits only
  active text today; `receive` stamps **every** event with the active revision/text and
  delays all lists during active Insert. Resolve each normalized event resource first:
  stamp/hold with its owning buffer's revision/text/mode even while inactive; unknown
  resources retain workspace findings but must not acquire an unrelated revision.
  Close/reopen and rename need source lifecycle/generation handling for late events.
- `error/source_request.mli` lacks document-close; `source/lsp_client.ml` stores one
  `document`/`opened`/revision-text queue and uses realpath-based canonicalization.
  Therefore it is **not** currently a multi-document reusable runtime. Phase 1 must
  add addressed close and per-resource runtime state (or explicit separate runtimes
  per buffer until reuse exists), handle URI alias mapping without merging lexical
  buffers, and never reinterpret a late version against a different document. The
  frontend's single `?source`/`Source.stop` wiring in `ui/editor_view.ml` and source
  startup in `bin/ches.ml` must become session lifecycle wiring as well.
- `tile/host.mli` already owns focus, capture prefix and paste start owner by `View_id`.
  The document view ID stays constant across file tabs, so paste ownership must also
  capture the starting **buffer ID/context generation**: tab change/close during paste
  must drop it, not deliver to the newly active file. Clear controller and host prefixes
  on switches; do not erase paste ownership to make a stale paste look unowned. Current
  captured tile routing rejects editor actions and text input consumes leader keys;
  a side directory adapter needs explicit modal document routing, not the read-only
  details adapter or palette text-input policy reused unexamined.
- `screen/workspace.ml` allocates one document, status, and bottom-band minors; use
  the major document allocation for directory presentation without losing tab state.
  Real side placement waits for phase 5. `Ui_state.view_layout`/`view_available` have
  explicit floating-layer parameters from floating phase 1; preserve that seam.
  `FLOATING_TILES_PLAN.md` currently has only phase 1 implemented; no shared screen
  modules were changed here. `bin/ches.ml` has one required PATH and calls
  `Controller.open_file`; `File_io.read` rejects directories. Typed file/directory
  startup belongs to phase 3, not this spike. No additional CLI syntax chosen.

#### Checks, gaps, and next-phase handoff

- `opam exec --switch=5.2.0+ox -- dune build`: passed.
- `opam exec --switch=5.2.0+ox -- dune runtest test`: passed, including the eight new
  tests. Coverage includes name rename, fresh insertion/paste, deletion, whole-row
  movement, yank/paste duplication, joining, token splitting, multiline replacement,
  undo/redo, baseline validation, unsupported kinds, and exhaustive legal byte names.
- `opam exec --switch=5.2.0+ox -- dune runtest screen/test`: passed.
- `git diff --check`: passed. Git was used only for read-only status/diff/archive;
  no mutative Git operations, metadata changes, remote actions, or subagents.
- `opam exec --switch=5.2.0+ox -- dune runtest`: fails in
  `ui/test/test_editor_view.ml` on old snapshots expecting hidden tiles while current
  defaults show status/problems/history. No expectations were promoted. This failure
  is also recorded in the floating phase-1 handoff and was reproduced by running
  the same UI suite in an isolated, unchanged `git archive HEAD` extraction at
  `/tmp/opencode/directory-phase0-baseline-10zq87vb` (exit 1, same snapshot diff).
  Log: `ui-baseline-check.log` in that directory. No source-suite failure occurred
  in this run.
- No filesystem executor, directory adapter, tokens styled/protected at input time,
  new commands/bindings, resource-normalization implementation, or session owner was
  added: those belong to the explicitly pending phases. No terminal smoke needed for
  this pure, non-UI phase. The full-suite snapshot failure is a repository check gap,
  not an identity-spike blocker.
- Phase 1 should implement the specified owner/lifetime contracts and tests, recheck
  current source interfaces, and keep the phase-0 codec isolated from application IO.
  Phase 3 can use baseline serialization read-only; phase 6 can consume validated rows
  but must add collision/type/operation validation before any filesystem plan. Phase 7
  must reconcile backing paths and saved baselines without conflating text undo with
  filesystem undo. Do not start those phases in this assignment.

### Phase 1 / 2026-10-07 / implemented

#### Implemented behavior

- Added `Ches_app.Session`: session-local abstract `Buffer_id`/`Group_id`, an actual
  lexical-resource index, ordered persistent file controllers, one editor group,
  open-or-activate, addressed activation/close, explicit force-close, save-current,
  save-all and guarded/forced session quit. Failed opens preserve the presentation;
  repeated opens retain dirty text rather than reading disk again. Close removes the
  resource index entry; reopen allocates a new ID. Closing an active buffer chooses
  the next at its former index, else the preceding last buffer. Inactive close does
  not switch activation or cancel the active document's pending input.
- Controllers retain independent text, history, cursor and highlighting. Switching
  finishes Insert transactions/exits Visual, cancels incoming/outgoing keymaps and
  host capture prefixes, and restores per-buffer UI scroll. Highlight providers are
  released only on actual close or session shutdown, not activation.
- Session feedback, unnamed register, newest pending clipboard publication and FIFO
  successful-save events are shared. Installing an equal register is a no-op; merely
  switching does not publish clipboard changes. Existing minor-view copies use this
  same register/clipboard route. Quit checks every open buffer, including inactive
  dirty files, and names dirty buffers with actionable force-quit guidance.
- Save-current targets only its file. Save-all visits dirty buffers in ID order,
  continues after each failure, returns addressed outcomes, retains each failure as
  file-operation feedback and publishes a saved/failed summary. Failed text stays
  dirty. Application save requests work independently of modal command availability,
  preserving Visual selection/mode and committing an Insert transaction as needed.
- The UI exposes open/activate/close-current/close-addressed/save-all/quit APIs for the
  upcoming adapters. Existing `Space w`, `Space q`, `Space Q` now use session policy.
  A paste retains its host start owner, but any document switch invalidates its
  buffer context, even a switch away and back before paste-end. Closed scroll and
  diagnostic-anchor state is pruned. Closing the final file leaves a **no-file**
  session, renders a no-file message with no cursor, and still accepts session quit;
  it does not fabricate an empty file or quit implicitly.

#### Changed modules and public contracts

- New `app/session.ml` / `.mli`, `app/buffer_id`, `app/group_id`, and `core/resource`
  (re-exported as `Ches_app.Resource`). Resource normalization is the phase-0 lexical
  absolute policy, used for actual file IO too. Symlink aliases remain distinct.
- `core/editor`: narrow `with_path` and effect-only `request_save` APIs, preserving
  text/history/cursor; filesystem IO remains in the controller. `app/controller`:
  feed-without-execution, shared-feedback/register installation, normalization path
  update and original display-path access. `input/keymap`: configuration accessor so
  newly opened files inherit the initial controller's configured keymap.
- `screen/ui_state`: session ownership/synchronization, lifecycle APIs, per-buffer
  scroll, addressed source requests and events, context-safe paste. Its legacy
  `controller` accessor is a presentation snapshot: check `has_document` before
  treating it as live, especially after last close. `screen/frame` handles no-file
  presentation; `screen/status` retains original filename spelling for display.
- `screen/problems` finding keys now include resource identity; `problems_tile`
  diagnostic text anchors are keyed by source **and** resource, not source alone.
  `error/error.forget_resource` releases closed-document diagnostic collections and
  revision guards without erasing operation-feedback history.
- `Source_request.Document_opened {resource; generation}` and
  `Document_closed {resource}` delimit actual lifetimes. `Source_event.Owned`
  carries runtime ownership/generation; the UI rejects events from closed/reopened
  owners. Changed-text requests cover every open buffer, not only the active one;
  successful saves are not collapsed to the newest buffer's event.
- New `source/workspace` multiplexes existing single-document runtimes. LSP URI paths
  use lexical normalization (no realpath alias merging); LSP saves and closes are
  resource-addressed, and close clears its document/revision-text state. Synthetic
  close invalidates pending timers. Event-queue coalescing respects owner lifetime.
  `bin/ches` creates the source manager; `ui/editor_view` disposes session highlights
  and all diagnostic drivers on exit/deactivation, including shutdown without keys.

#### Policy decisions and scope

- Both existing drivers remain single-document, so phase 1 deliberately uses one
  runtime per resource rather than claiming multi-document process reuse. Managed
  source names have a `#buffer-ID` suffix, isolating diagnostics/revision guards and
  stopped state between runtimes. Existing restart/kill commands address all managed
  runtimes. The source manager belongs to one session, not multiple replacement sessions.
- Diagnostics resolve their owning buffer's revision/text/mode even while inactive.
  Insert-held lists release when that owner leaves Insert, including on activation
  of another buffer. Unknown workspace resources remain visible and use arrival
  revision `-1` (the current diagnostics API has an integer basis), never the active
  file's revision. Actual close clears the closed resource's diagnostic guards.
- No tab strip, new navigation/close bindings, directory startup/browser, directory
  buffer, filesystem planner/executor, or later-phase commands were implemented.
  Final-file close remembers `Session.startup_directory` for phase 3's fallback.
  The no-file UI retains a closed presentation snapshot for legacy geometry queries,
  but that snapshot is not indexed/live and its highlight runtime is disposed.

#### Checks and next-phase integration

- `opam exec --switch=5.2.0+ox -- dune build`: passed.
- `opam exec --switch=5.2.0+ox -- dune runtest test screen/test source/test`: passed.
  Seven new headless tests in `test/test_session.ml`,
  `screen/test/test_session_ui.ml`, and `source/test/test_workspace.ml` cover independent
  edits/undo/highlight identities, deduplication, symlink aliases and normalized IO,
  shared registers, mode/prefix/scroll preservation, failed-open safety, save-current,
  save-all with two individually retained failures and a successful save after a
  failure, hidden dirty quit, both close-successor cases, no-file quit, inactive and
  unknown diagnostic revisions, held-list release, late close/reopen events, round-trip
  paste invalidation, addressed source saves and runtime cleanup. Earlier tests pass;
  only intentional named-quit feedback and initial source-open expectations changed.
- PTY smoke of `_build/default/bin/ches.exe --no-lsp TEMP/a.txt`: passed startup,
  Insert editing, dirty `Space q` refusal without implicit save, `Space w` disk write,
  and clean `Space q` exit (status 0), using an isolated `/tmp/opencode` fixture.
- `opam exec --switch=5.2.0+ox -- dune runtest`: still fails only on the documented
  `ui/test/test_editor_view.ml` old hidden-tile layout snapshots. The same HEAD failure
  is established in the phase-0 handoff; those UI expectations were not promoted.
  Final full-suite log: `/tmp/opencode/directory-phase1-runtest.log` (exit 1).
- `git diff --check`: passed. Only read-only Git inspection was used. No Git metadata,
  staging/history/config/branch/worktree operations, remote mutations, or subagents.
- Phase 2 should render the session's ordered file buffers and use the UI lifecycle
  facade, not replace controllers. Phase 3 must add typed directory ownership and
  presentation/fallback without bypassing shared lifetime, source routing or paste
  invalidation; presentation switches must invalidate input context even if the
  underlying active file ID remains unchanged. Phase 7 still needs explicit resource
  reindex/reassociation and refreshed display labels on rename; `with_path` here is
  a normalization seam, not a complete rename operation. Per-resource language-server
  processes are a known scalability limitation, not a phase-1 correctness blocker.

### Phase 2 / 2026-10-07 / implemented

#### Implemented behavior and policy decisions

- File tabs render in first-successful-open order above the document allocation.
  Brackets and the title style identify the active tab; `*` identifies modified
  buffers. Labels use the shortest distinguishing lexical path suffix (e.g.
  `one/same.txt`, `two/same.txt`), with the phase-0 byte-name codec keeping controls,
  invalid UTF-8 and non-ASCII names terminal-safe. Visible ordinals identify tabs
  even when long labels are clipped. No preview replacement or MRU reordering.
- Exact Normal-mode defaults: `Space b n` next, `Space b p` previous, `Space b c`
  close, `Space b C` force-close/discard. Navigation wraps in open order. Four
  matching palette entries derive shortcuts from the configured bindings and run
  once through the existing UI/session lifecycle. Dirty close refuses with the
  file path and explicit save/force-close guidance; ordinary close is not quit.
- **One-tab visibility:** hide the strip for zero or one file, and in zen. Show
  it for multiple files when the document allocation has positive width and at
  least three rows. Very short terminals give their rows to content/status instead.
  The workspace's document/status/minor rectangles are unchanged; the strip takes
  one row inside the document allocation. All document geometry, fitted scroll,
  rendering and cursor queries use the same reduced allocation. Appearing/hiding
  the strip fits the viewport without modifying document cursor/text/history;
  scroll is retained where valid and adjusted only as necessary to keep the cursor
  visible. Stale animation coordinates are cleared on context/visibility changes.
- Overflow is a deterministic contiguous window containing the active tab. Grow
  toward preceding neighbors first, then following neighbors when they fit; `<`
  and `>` advertise hidden neighbors. Individual labels cap at 40 cells including
  chrome; `~` denotes clipping. The active ordinal and dirty suffix survive where
  width permits; at extremely small widths retain a styled active marker rather
  than overflowing. Every rendered row has exactly the requested cell width.
- Closing active tabs uses phase 1's next-at-old-index, else preceding-last policy.
  Inactive close preserves active input/prefix state while reconciling strip
  visibility. Last-file close leaves zero indexed/live buffers, no cursor and a
  terminal-safe no-file message showing `Session.startup_directory` as the directory
  fallback target. It neither creates an empty file nor exits. Tab commands are
  harmless with no files; quit remains available. Opening another file reuses the
  ordinary lifecycle. A no-file palette open is explicitly refused, not left as an
  invisible input capture. Actual directory presentation remains phase 3 work.

#### Changed modules and public contracts

- New `screen/file_tabs.ml` / `.mli`: `tabs` projects the session's live ordered file
  controllers into disambiguated descriptors; `render` handles terminal-safe strip
  content, clipping and overflow. No new file-buffer ownership or filesystem IO.
- `input/view_command` adds `Next_tab`, `Previous_tab`, `Close_tab`, `Force_close_tab`;
  `input/bindings` and `palette/catalog` expose the defaults and discoverable actions.
- `screen/ui_state` exposes `tab_rect`; `geometry` now delegates to `geometry_in`,
  sharing the strip reservation with explicit allocations, scroll and frame drawing.
  Moved common lifecycle reconciliation into `adopt_session_state` and
  `close_buffer_state` so keyed/palette commands and the phase-1 public facade share
  scroll retention, source cleanup, pending-prefix cancellation and paste invalidation.
  Buffer changes cannot animate a cursor trail between unrelated documents.
- `app/session` improves dirty-close instructions and resets the no-file keymap when
  entering/leaving a file context, preventing a no-file leader prefix from surviving
  open/last-close and unexpectedly executing in the next no-file context.
- `screen/frame` composes the strip outside document text, and clips the no-file
  directory-target message as safe ASCII. Only palette catalog/count expectations
  were updated in `palette/test` and `screen/test/test_palette_tile.ml`; existing
  single-file geometry and UI snapshots were not broadly promoted.

#### Checks run and results

- `opam exec --switch=5.2.0+ox -- dune build`: passed.
- `opam exec --switch=5.2.0+ox -- dune runtest test screen/test palette/test source/test`:
  passed. Five new headless tests in `screen/test/test_file_tabs.ml` cover binding and
  palette selection, both wrap directions, deduplication/open order, independent
  dirty text/undo/cursor/scroll, same-basename labels, dirty refusal/explicit discard,
  both close successor cases, inactive-close prefix retention, no-file prefix reset,
  last-file fallback/reopen, deterministic overflow/dirty markers, exact span widths,
  zen/strip visibility, offset allocations and exhaustive small terminal geometry.
  Earlier session, diagnostic, paste and highlight lifetime tests also pass.
- PTY smoke of `_build/default/bin/ches.exe --no-lsp TEMP/file.txt`: passed Insert
  editing, dirty `Space b c` refusal, `Space b C` returning to no-file with a directory
  target, explicit SIGWINCH resize to 8x2 and restoration to 80x16, then clean no-file
  `Space q` exit (0). The discarded edit never reached disk. Capture:
  `/tmp/opencode/directory-phase2-pty.log`. Multi-file input/rendering is exercised
  headlessly through the public open facade; the CLI still accepts one startup file
  and the directory-driven opening workflow deliberately waits for phase 3. No human
  visual acceptance is claimed.
- Final `opam exec --switch=5.2.0+ox -- dune runtest`: exit 1, only the previously
  documented `ui/test/test_editor_view.ml` default-visible-tile snapshot mismatch.
  Log: `/tmp/opencode/directory-phase2-runtest.log`. Those expectations remain unchanged.
  An initial attempted `input/test` target was invalid (input tests live in `test`),
  and a parallel build/test attempt hit Dune's lock; the valid checks above were
  rerun serially and passed.
- `git diff --check`: passed. Git inspection was read-only; no Git metadata,
  staging/history/config/branch/worktree operations, remote changes or subagents.

#### Known gaps and next-phase integration

- No directory owner/listing/navigation/startup handling, filesystem planner, side
  placement, mark commands or later-phase documentation was implemented. The full UI
  snapshot failure is an existing repository check gap, not a tab acceptance blocker.
- Phase 3 should replace no-file fallback with remembered-directory, else startup-
  directory presentation, keeping zero file tabs rather than fabricating a file.
  Extend session fallback ownership when remembered directories exist. Directories
  must not join `File_tabs.tabs`; retain the group's ordered file controllers under
  major directory presentation. Keep `tab_rect`/geometry consistent with that new
  presentation policy and preserve the shared lifecycle facade for file opens.
- Directory/file presentation changes must still invalidate paste/input context even
  if the underlying active file ID is unchanged. Preserve the explicit floating-layout
  seam in `view_layout`/`view_available` from `FLOATING_TILES_PLAN.md`; no floating work
   or workspace allocation changes were made in phase 2.

### Phase 3 / 2026-10-07 / implemented

#### Implemented behavior

- `ches .` and other directory PATHs start a read-only, buffer-backed major directory
  presentation with zero file tabs. `Startup` classifies normalized paths and checks
  readability; `Controller.Kind` carries explicit file/directory startup identity
  rather than guessing from arbitrary text-controller paths. Missing file arguments
  retain the existing new-file behavior. The startup directory controller is adopted
  into a directory owner, never indexed or retained as a file tab.
- Normal `Space o` opens a file's parent with that backing entry selected; from a
  directory it returns to the recorded live file, else the group's active file, else
  stays put with feedback. `Enter` opens/activates the cursor file in persistent tabs,
  or enters a directory (including directory symlinks). `-` goes to the lexical parent
  and selects the child just left. `Space r` explicitly refreshes a directory; these
  directory-only actions are harmless from a file. Directory opens use the session's
  ordinary file lifetime and deduplication route, not controller replacement.
- Directory rows are the phase-0 `Directory_identity.text` in a real editor controller,
  retaining baseline entry IDs and escaped raw-byte backing names. All entries,
  including hidden ones, sort by raw byte name without directory grouping. The path
  header, read-only label, kind gutter (`f`, `d`, `@`, `!`) and empty-state hint are
  decorations outside row text. The status reports DIRECTORY. On tiny allocations
  the header/margins give space to content using the existing geometry rules.
- Visited directory buffers survive for the session. Selection/cursor and viewport
  survive hiding, parent/child revisits and failed opens. Refresh preserves surviving
  entry IDs/selection; missing selection chooses the old index's next neighbor, else
  the last row. Explicit originating-file/child selection takes precedence over a
  directory's remembered cursor. Refresh errors preserve the existing baseline/view.
- Unsupported kinds (including FIFO), broken links, invalid file text and unreadable
  directories produce feedback without creating a tab or replacing the current view.
  Read-only dispatch rejects edits, Insert/Visual entry, paste, undo, save and ordinary
  file reload; movement and search remain available. No filesystem mutation commands,
  visual-range opening, marks or side placement were enabled.
- Last-file close now shows the remembered directory, else the file-startup parent,
  instead of the phase-1/2 no-file placeholder. A fallback read failure retains a
  zero-file session with feedback and the existing no-file rendering; quitting stays
  available. File tabs remain underneath major directory presentation. File cursor,
  scroll, dirty text and undo are preserved on return and existing-tab activation.
- UI lifecycle adoption uses the visible **context ID**, independently of the active
  file tab. Both keyed/palette and public directory switches reconcile scroll, host
  prefixes, animation and paste ownership, including a file→directory→same-file
  round trip. Source requests still enumerate only file buffers. Save-all while
  browsing saves dirty files and restores the directory presentation.

#### Changed modules and new public contracts

- New `app/directory_buffer.ml` / `.mli`: placement-independent baseline loader,
  selected-entry/name-selection adapter and read-only command policy. Directory state
  includes stable session buffer ID, lexical path, baseline identity text/entries,
  controller, monotonic next-entry ID and lstat fingerprints. No screen/tile types or
  filesystem mutation depend on its placement.
- New `app/startup.ml` / `.mli`, `Controller.Kind` and optional `Controller.create
  ~kind`: explicit file/directory classification before frontend startup. `bin/ches`
  uses it and mentions the phase-3 navigation keys in CLI help.
- `app/session`: retained directory ownership, `show_directory`, `directory_buffer`,
  `context_id`, `has_buffer` and typed `find_resource_buffer`. Existing `buffers`,
  `active_id`, `find` and `find_resource` remain **file** APIs for tabs/diagnostics;
  `active_controller` is now the visible file **or directory**. The presentation
  descriptor explicitly carries buffer, `Major`, target `Group_id` and return file;
  `Side` is only a future contract vocabulary, not implemented placement.
- `screen/ui_state`: public `show_directory ?select`, directory header allocation,
  directory-aware geometry and context-based viewport/paste reconciliation.
  `screen/frame` and `screen/status` render directory decorations; no workspace or
  floating layout allocation changes. `input/view_command` / `bindings` add the four
  navigation actions/defaults. Session dispatch owns their IO and read-only policy.
- Five new headless tests in `screen/test/test_directory_navigation.ml`. Only
  intentional Enter/last-file-fallback expectations changed in existing keymap,
  file-tab and session-UI tests; unrelated UI snapshots remain untouched.

#### Policy decisions settled

- Cached revisits do not implicitly reread disk; `Space r` is the explicit refresh.
  Unchanged names/kinds with matching lstat device/inode retain IDs. Replaced resources
  with different fingerprints and new names get monotonically fresh IDs. This is not
  a watcher or a race-proof identity guarantee (rapid inode reuse can be indistinguishable);
  later filesystem apply must still recheck its own baseline immediately before IO.
- Symlink-directory navigation keeps the lexical alias, and separate aliases retain
  separate buffers. Kind decorations still identify the link as a symlink; its row
  has no directory suffix. Files open through their stored lexical backing paths.
- File/directory resource-kind conflicts are explicitly refused rather than permitting
  two differently typed owners at the same normalized path. Directories never appear
  in `File_tabs.tabs`. The one existing editor group is the explicit open target.
- Directory text is read-only in this phase, including selection/copy commands reserved
  for phase 4. Refresh replaces its clean text baseline, not filesystem contents.

#### Checks run and results

- `opam exec --switch=5.2.0+ox -- dune build`: passed.
- `opam exec --switch=5.2.0+ox -- dune runtest test screen/test palette/test source/test`:
  passed. New tests cover the complete directory→A→directory→B workflow, independent
  edits/undo and cursor/scroll, cached parent/child selection and viewport, read-only
  editing/save/paste rejection, no-return behavior, refresh identity including a
  same-name external replacement, failed navigation/refresh under actual unreadable
  permissions, invalid text/broken symlink/FIFO refusal, save-all while browsing,
  directory exclusion from tabs/source requests, normalized resource reuse, symlink
  alias policy, and exhaustive 0–29 by 0–13 terminal geometry/cell widths.
- `python3 /tmp/opencode/directory-phase3-smoke.py`: passed against the built executable,
  with PATH `.` in an isolated fixture. PTY coverage: directory startup, opening/editing
  A and B in retained tabs, parent/child and return-to-file, dirty quit refusal, saving
  B only, dirty-close refusal, force-close of the last file into a real directory,
  harmless no-return toggle, SIGWINCH resize to 8x2/back, clean quit (0), and disk
  verification that discarded A was untouched. Capture:
  `/tmp/opencode/directory-phase3-pty.log`; last fixture:
  `/tmp/opencode/directory-phase3-pty-lyms4490`. No human visual acceptance is claimed.
- Final `opam exec --switch=5.2.0+ox -- dune runtest`: exit 1, only the previously
  documented `ui/test/test_editor_view.ml` default-visible-tile snapshot mismatch.
  Log: `/tmp/opencode/directory-phase3-runtest.log`. No baseline expectations promoted.
- `git diff --check`: passed. Git was used only for read-only diff inspection; no Git
  metadata/staging/history/config/branch/worktree changes, remote mutations or subagents.

#### Known gaps and next-phase integration notes

- Phase 3 is complete; phases 4–9 remain pending. No filesystem edit planner/executor,
  visual or marked batch opening, side layout, directory eviction or background watcher
  was implemented. The existing full-suite UI snapshots remain a repository check gap.
- Phase 4 should extend the directory adapter's allowed command set for read-only
  selection/yank and intercept Visual Enter before ordinary cursor-entry navigation.
  Add entry-ID marks outside text; normal Enter must continue ignoring marks.
- Phase 5 should store/change actual placement and reuse these same retained buffers,
  target-group descriptor and context-safe UI adoption, not create a second controller
  for side placement. `directory_rect` and major kind gutter are presentation-only.
- Phase 6 must add dirty-directory session quit/save-all handling before enabling text
  mutation, preserve dirty baselines on navigation, refuse dirty refresh, and integrate
  marks/entry reconciliation. Today's read-only filter must never simply be removed
  while allowing directory `Command.Save` to reach ordinary `Effect.Write_file`.
- Session construction consumes the validated startup directory classification and
  loads its baseline synchronously. Like other startup IO, filesystem changes between
  readability validation and baseline loading can still race; no atomic snapshot or
  watching guarantee is claimed. Per-file source runtime scalability and later rename
   resource-reindexing limitations from phase 1 remain unchanged.

### Phase 4 / 2026-10-07 / implemented

#### Implemented behavior and policy decisions

- Read-only directories now permit Characterwise, Linewise and Blockwise selection,
  selection cancellation and all yank variants. They still reject text mutation,
  paste, undo, reload and save. Yanks use the session's shared register/clipboard.
- Visual `Enter` opens all intersected entry rows in listing order, including reverse
  and block selections. Normal `Enter` remains cursor-only and ignores marks; single
  directory navigation remains unchanged. Neither ordinary nor Visual opens clears marks.
- Directory-local existing-entry IDs carry noncontiguous marks outside text, dirty
  state and undo. The kind gutter adds `*` and the header reports the marked count.
  Cached navigation/hiding preserves marks; refresh retains surviving IDs and prunes
  IDs genuinely absent from the new clean baseline. Decorations are never yanked.
- Exact Normal/Visual bindings: `Space m m` toggle cursor mark, `Space m s` mark
  selection (cursor outside Visual), `Space m u` unmark selection, `Space m c` clear
  this directory's marks, `Space m o` open marked files. Five discoverable palette
  commands expose the same actions and configured shortcuts. The existing palette
  remains Normal-only; Visual selection commands use their bindings/public dispatch.
- One shared session batch resolver handles Visual and marked targets. It deduplicates
  normalized lexical backing resources in current listing order, opens via the ordinary
  persistent-tab lifecycle, continues after failures, skips directories (including
  directory symlinks) and unsupported kinds, and activates the first successful file.
  Each failure/skip is retained in feedback history, followed by an opened/failed/skipped
  summary. With no successful target, the directory presentation remains intact.
  Open-marked clears only successful IDs, including reused tabs; failed/skipped marks
  remain. Empty batches report zero outcomes without switching. Opening never saves.

#### Changed modules and contracts

- `app/directory_buffer`: `marks : Int.Set.t`, listing-ordered `selection_entries` and
  `marked_entries`, `mark_selection`, `toggle_mark`, refresh mark reconciliation and
  expanded read-only allowlist. This remains placement-independent; no filesystem
  planner/executor or side placement was added.
- `app/session`: centralized batch resolution and directory mark action interception.
  `input/view_command`, `input/bindings`, `palette/catalog`, `screen/ui_state` and
  `screen/frame`: commands, routing, shortcuts and external decorations. Existing
  palette order is retained; only intentional new catalog/count expectations changed.
- Five additional headless tests in `screen/test/test_directory_navigation.ml` cover
  Visual kinds/shared yank, noncontiguous order/tab reuse/normal-Enter isolation,
  failure summaries and real unreadable permissions, successful/failed/skipped marks,
  mark/unmark/clear, cached directory-local lifetime/refresh, palette execution/shortcut
  discovery and tiny-frame widths. Prior phases' tests remain intact.

#### Checks run and results

- `opam exec --switch=5.2.0+ox -- dune build`: passed.
- `opam exec --switch=5.2.0+ox -- dune runtest test screen/test palette/test source/test`:
  passed, including all new tests. Initial runs exposed intentional catalog/count and
  header expectations; the final header retains the old read-only prefix and existing
  catalog ordering. Only the five new catalog entries/counts required updates.
- `python3 /tmp/opencode/directory-phase4-smoke.py`: passed. PTY coverage: directory
  startup, Visual multi-open, first-success activation verified by edit/save on disk,
  noncontiguous marks, existing-tab reuse, bad-text failure/directory skip feedback,
  failed/skipped mark retention, clear, SIGWINCH 8x2/back and clean quit (0). Other
  fixture files stayed unchanged. Capture `/tmp/opencode/directory-phase4-pty.log`;
  final fixture `/tmp/opencode/directory-phase4-pty-9bg27e0n`. The first smoke assertion
  expected an unclipped summary in a narrow history tile; corrected assertions verify
  visible individual failure/skip feedback. No human visual acceptance is claimed.
- Full `opam exec --switch=5.2.0+ox -- dune runtest`: exit 1, the documented baseline
  `ui/test/test_editor_view.ml` visible-tile snapshot mismatch only. Log:
  `/tmp/opencode/directory-phase4-runtest.log`; no baseline UI snapshots promoted.
- `git diff --check`: passed. Git use was read-only; no Git metadata/staging/history,
  branches/config/worktrees, remote mutations/publications or subagents.

#### Known gaps and next-phase integration

- Phase 4 complete; phases 5–9 remain pending. Full-suite baseline UI mismatch remains
  a repository check gap. Cross-directory collections and recursive opens are deferred.
- Phase 5 must reuse retained directory marks/controller and the shared session resolver
  with its explicit target-group presentation contract. The current sole group remains
  the target; actual Side placement/focus behavior is not implemented here.
- Phase 6 must replace baseline-row selection resolution with validated current identity
  rows before enabling edits, retain dormant marks for deleted text rows until commit,
  resolve renamed entries to baseline backing paths, and reject marking/opening fresh
  rows until save. Do not remove save/mutation guards without dirty-directory/session
  policy and the operation planner. Refresh currently reconciles a clean read-only baseline.

### Phase 5 / 2026-10-07 / implemented

#### Implemented behavior and policy decisions

- The same retained directory buffer/controller, entry IDs, marks and session batch
  resolver now support major and left minor-side placement. A side open sends files
  through the ordinary persistent-tab lifecycle, leaves the browser present, and
  focuses the opened file (first successful file for batches). Failed/skipped opens
  retain the browser/input context and marks according to phase 4's policy. Directory
  Enter/parent/refresh/search/yank/Visual/mark keys use the same modal adapter, not the
  supporting-details or palette input interpreter.
- Exact Normal/Visual bindings: `Space d m` major, `Space d s` side/show, `Space d h`
  hide, `Space d f` focus browser/editor, `Space d +` grow four columns, `Space d -`
  shrink four columns. Six matching palette entries preserve the existing catalog's
  ordering. `Space o` still selects a file's parent entry or returns to the recorded
  live file (else active group file). Side `Tab` explicitly returns focus to the
  editor; Escape remains the ordinary modal selection/search/prefix cancellation.
  Palette/supporting-view cancellation restores the directory target's focus when
  it was opened from the side browser. Modal prefixes and stale paste context are
  canceled across focus/placement changes.
- Moving/hiding/focus-return preserves directory text/controller, selection, cursor,
  marks and per-buffer scroll (fitted only as needed for the new viewport). File
  opening intentionally finishes a Visual batch as before. File cursors, edits,
  undo and scroll remain independent underneath either placement. Placement never
  refreshes a cached baseline or discards text; phase 6 can retain pending edits using
  the same owner. Target `Group_id` and return-file descriptor survive placement.
- Preferred side outer width is **32**, adjusted in four-column steps and retained
  in the range **16–500**. Allocation clamps the effective width while leaving at
  least 16 editor columns and a one-cell backdrop gap. It requires **33 columns and
  four rows**. The side shell spans the terminal height; status and existing bottom
  minors occupy the remaining right-hand allocation. Shared `Tile_shell` geometry
  drives its content, drawing, availability and cursor; no floating implementation
  was added and the explicit floating-layout seam is unchanged.
- Zen or insufficient terminal space suppresses (does not hide/discard) a requested
  side browser. If it owned input and a file exists, focus returns to the file and
  prefixes/paste context are canceled. Growing/leaving zen restores the requested
  placement/width without stealing file focus. With no file tabs, including after
  last-file close, the directory remains a reachable major fallback while preserving
  the Side request for the next successful file open. Hide/focus-return with no file
  cannot strand the user on an empty editor; hide reports no return file.

#### Changed modules and public contracts

- `app/session`: actual placement and directory-input ownership; `directory_buffer`
  now also returns an **unfocused presented side browser**, while `input_directory`
  identifies the modal directory input owner. `context_id`, `active_controller`,
  `replace_active`, read-only dispatch and save-all respect that distinction. New
  `set_directory_placement`, `focus_directory`, `hide_directory` preserve retained
  ownership; `surface` is a rendering-only snapshot, never a session to adopt/dispatch.
  Existing group IDs, directory adapter and batch resolver remain the sole owners.
- `screen/workspace`: optional `allocate ~side:(View_id, preferred_outer_width)`
  splits the full-height left shell before allocating existing status/bottom panes.
  Without that request, existing allocation is unchanged.
- `screen/ui_state`: directory host spec/ID, size preference, side availability,
  modal routing, scroll/prefix/paste reconciliation, focus-return, rendering surface
  snapshots and shared side cursor queries. `screen/frame` renders both retained
  surfaces and places the directory shell into its disjoint backdrop allocation;
  backdrop slicing deliberately introduces no text clipping markers. Major directory
  headers remain unchanged; the narrower side header shows marked count and path.
  `screen/status` uses the input owner, so editor focus does not say DIRECTORY merely
  because a side browser is present.
- `input/view_command`, `input/bindings`, `palette/catalog`: placement/focus/size
  commands and defaults. Only six catalog entries and resulting palette counts were
  added to existing expected output; unrelated baseline UI snapshots remain untouched.
- Nine new headless tests in `screen/test/test_directory_side.ml`; reusable isolated
  PTY check in `scripts/directory_side_smoke.py` (run after building).

#### Checks run and results

- `opam exec --switch=5.2.0+ox -- dune build`: passed.
- `opam exec --switch=5.2.0+ox -- dune runtest test screen/test palette/test source/test`:
  passed. New tests cover exhaustive side allocation containment/nonoverlap/minima
  with nonzero origins, width restoration, frame cell widths/cursor bounds across
  tiny resizes, unchanged backdrop gaps, same buffer/group identity, editor focus on
  single and all three Visual batch kinds, marked partial failures/clearing, cached
  parent navigation/return target, selection/marks/exact same-size scroll retention
  on hide/show, file-local scroll/edits/undo, shared yank/paste refusal, interrupted
  editor paste across a side focus round trip, palette focus restoration/commands,
  zen and tiny suppression, and no-file/last-close fallback.
- `python3 scripts/directory_side_smoke.py`: passed with an isolated PATH `.` fixture.
  PTY coverage: side request before files exist, single/Visual/marked opens, first
  activation verified by edit/save on disk, major/side/hide restoration, failed-file
  and directory-skip feedback/mark retention, width changes, zen/tiny editor input,
  parent navigation, palette hide, explicit Tab focus return and clean quit (0).
  Other files remain unchanged. Capture: `/tmp/opencode/directory-phase5-pty.log`;
  final successful fixture: `/tmp/opencode/directory-phase5-pty-6j7x0mt6`.
  An initial feedback assertion was clipped by the narrow history tile; the smoke
  now hides status/problems before checking full failure text. No human visual
  acceptance is claimed.
- Full `opam exec --switch=5.2.0+ox -- dune runtest`: exit 1, only the documented
  `ui/test/test_editor_view.ml` baseline visible-tile snapshot mismatch. Log:
  `/tmp/opencode/directory-phase5-runtest.log`; no baseline snapshots promoted.
- `git diff --check`: passed. Git inspection was read-only. No Git metadata/index,
  history/config/branch/worktree changes, remote mutations/publications or subagents.

#### Known gaps and next-phase integration notes

- Phase 5 is complete; phases 6–9 remain pending. The full-suite baseline mismatch
  remains a repository check gap, not a side-placement blocker. Directory text is
  still read-only; no filesystem planner/executor or later-phase behavior was added.
- Phase 6 must use `input_directory` for input/save guards and `directory_buffer`
  for presented-browser decorations, including when the editor owns input. Retained
  directory buffers survive hide/move; add dirty-directory quit/save-all and refresh
  policy before enabling mutation. Do not send listing text to `Write_file`, or
  adopt the rendering-only `Session.surface` / `Ui_state.surface` snapshots.
- The sole editor group remains the explicit target. Simultaneous directory views,
  multiple groups, mouse dragging, floating browser placement and background watching
  remain outside this phase. Existing source-runtime scalability and rename-reindex
   limitations from earlier phases are unchanged.

### Phase 6 / 2026-10-07 / implemented

#### Implemented behavior and public contracts

- Directory controllers now accept ordinary modal editing, paste, undo and redo.
  Visible identity tokens travel with the existing text history; validation protects
  identities, not an invisible row-number map. Existing-kind changes, malformed or
  duplicated identities and unsupported-entry alteration remain whole-snapshot errors.
- New pure `core/directory_plan.ml` / `.mli`: `plan` returns `Create_file`,
  `Create_directory`, and identity-addressed `Rename {id; source; destination}`
  proposals; `summary` provides escaped, readable operation descriptions. It performs
  no IO. Child-name/escape/type validation uses `Directory_identity`; missing IDs
  reject deletion, repeated IDs reject copy, duplicate final names reject collisions.
  Slash/cross-directory paths are invalid, a fresh final `/` creates a directory,
  and existing entries cannot change kind. Rename swaps/cycles and creation into a
  name renamed away are valid proposals for the later dependency-aware executor.
- `app/directory_buffer` exposes validated current rows, row selection, backing-entry
  resolution, dirty state and planning. Cursor, Visual and marked targets now resolve
  current logical row positions/order (including blank lines), not baseline indices.
  Renamed rows open their baseline backing paths. Fresh rows cannot be marked/opened;
  Visual batches continue opening existing rows and report fresh rows requiring save.
  Invalid identity snapshots refuse row-associated actions rather than guessing.
- Marks remain baseline-ID state outside text/history. Omitted rows retain dormant
  marks and undo restores their visibility; current rows drive mark/open ordering and
  gutter decorations. Clean refresh still prunes actually missing baseline IDs.
- Dirty cached directories survive navigation, major/side/hide changes and editor
  focus. Dirty refresh refuses with undo guidance; ordinary directory Reload refuses
  instead of reading listing text as a file. Insert transactions finish when focus
  changes; cached same-directory navigation retains the finished controller/history.
- `app/session` checks all retained dirty directories (including hidden/inactive ones)
  on quit and addressed close. Explicit force-close discards that owner and reconciles
  presentation/fallback. Save-all visits dirty files and directories in buffer-ID order,
  continues saving files, and reports directory proposals as failures, retaining edits.
  File tabs' close commands retain their existing file-tab semantics.
- Directory Save validates and displays the full operation summary, then explicitly
  refuses application because no executor exists yet. It never clears dirty state,
  emits a successful-save event, or writes listing text. Session intercepts Save/Reload;
  `app/controller` also filters those actions for Directory kind as defence in depth,
  including direct calls outside Session. No filesystem executor/mutation was added.
- `screen/frame` shows dirty/pending-count or invalid-plan headers on major and side
  surfaces, even with editor focus, and resolves gutters from current identities.
  Empty-directory decoration no longer covers inserted text. `screen/status` shows
  directory Insert/Visual modes and existing dirty indicators. No new keys or palette
  entries: `Space w` is the phase-local validation/summary action.

#### Checks run and results

- `opam exec --switch=5.2.0+ox -- dune build`: passed.
- `opam exec --switch=5.2.0+ox -- dune runtest test screen/test palette/test source/test`:
  passed. Seven new tests in `test/test_directory_plan.ml` and
  `screen/test/test_directory_editing.ml` cover creates, symlink renames, swaps,
  reorder/blank rows, collisions, deletion/copy/type/token/path rejection, modal
  undo/redo, dormant marks, dirty refresh/close/quit, hidden/save-all ordering/results,
  current-order Visual opens with fresh rows, backing paths, placement/navigation
  retention, unfocused side dirty decoration, and controller-level no-write defence.
  Only obsolete read-only directory expectations in earlier headless tests changed.
- `python3 scripts/directory_editing_smoke.py`: passed against the built executable
  in an isolated fixture. It verifies modal rename/create summaries, undo, save/refresh
  refusal, backing-file editing/saving, hidden dirty quit refusal, fresh-row refusal,
  clean quit (0), and unchanged filesystem names/no listing writes. Capture:
  `/tmp/opencode/directory-phase6-pty.log`; fixture:
  `/tmp/opencode/directory-phase6-pty-az2x24qw`. No human visual acceptance is claimed.
- Full `opam exec --switch=5.2.0+ox -- dune runtest`: exit 1, the documented
  `ui/test/test_editor_view.ml` baseline visible-tile snapshot mismatch only. Log:
  `/tmp/opencode/directory-phase6-runtest.log`; no baseline snapshots promoted.
- `git diff --check`: passed. Git was used read-only only. No metadata/index,
  staging/history/config/branch/worktree operations, remote mutations or subagents.
  All pre-existing working-tree changes were preserved.

#### Known gaps and phase-7 integration notes

- Phase 6 complete; phases 7–9 remain pending. Save intentionally cannot apply even
  a valid/no-op directory proposal or mark its text saved. Undo to the clean text or
  explicit force-close/force-quit are available; dirty refresh never discards intent.
- The pure planner validates collisions against the supplied baseline/final names,
  not external filesystem changes, path length limits or race conditions. Phase 7
  must recheck lstat fingerprints/destinations immediately before mutation, handle
  dependencies/cycles without overwriting occupants, reconcile partial failures and
  refresh baselines/history only after successful application. Never route directory
  Save through `Effect.Write_file`. Deletion/copy/cross-directory moves remain rejected.
- Retain dormant marks until commit reconciliation; use `backing_entry` for pending
  opens and current `Row.line` for rendering/navigation. Resource/path reassociation
  for open files/descendants remains phase 7; no index changes were implemented here.

### Phase 7 / 2026-10-07 / implemented

#### Implemented behavior and public contracts

- Explicit directory Save (`Space w`) now applies the entire validated create/rename
  proposal directly, using the existing feedback/history conventions rather than a
  confirmation dialog. Save-all applies retained dirty directories and files in ID
  order, continues on failure, and fetches each live owner again after earlier renames.
  Listing text never goes through file-write effects. Delete/copy/type changes and
  cross-directory/move syntax remain rejected by the pure phase-6 planner.
- New `app/directory_apply.ml` / `.mli` executor performs whole-plan preflight, then
  rechecks the directory device/inode and each rename source's lstat device/inode,
  kind, size, mtime and ctime immediately before its mutation. Destination checks
  include dangling symlinks. Normal refresh retains entry IDs by device/inode/kind,
  not mutable file size/times; recheck fingerprints are refreshed separately.
- Every rename source is first staged to a collision-checked immediate-child
  `.ches-stage-PID-counter` name, then placed at its final destination. This handles
  dependencies, swaps and longer cycles, including creation into a vacated source
  name. Staging skips disk occupants, desired row names, and open/cached resource
  paths. New files use `O_CREAT|O_EXCL`; new directories use `mkdir`. Creation modes
  are 0666/0777 subject to umask; existing contents and rename metadata are retained.
- `app/directory_fs_stubs.c` uses Linux `renameat2(RENAME_NOREPLACE)` for **both**
  staging and final placement. There is deliberately no unsafe check-then-rename
  fallback. Occupants appearing after the absence check cannot be overwritten.
  Unsupported kernels/filesystems return a visible failure, not ordinary rename.
- The executor result records completed mutation operations (including staging),
  aggregate original-to-actual backing paths, reconciled directory state and error.
  Each successful syscall updates the journal/backing identity before fallible
  post-operation work. A partial failure assigns IDs to completed creations,
  rebases the baseline to actual tracked backing names, and retains canonical text
  describing only unresolved intent. Ordinary Save retries from that baseline:
  successful creations/final renames are not replayed. Session feedback records
  completed mutations, actual backing paths, remaining operations and the failure.
- Partial progress is **not rolled back**. An incomplete cycle can leave owned staging
  names on disk; existing rows/open files then resolve to those actual paths. Retry
  rechecks staged identities and final destinations. A collision or external source
  replacement blocks retry rather than overwriting/adopting unrelated data. Force
  close/quit explicitly discards remaining in-memory intent, not disk changes.
- `app/session` reassociates paths simultaneously, not sequentially through swap
  destinations: file buffers, open descendants, cached directories, startup fallback,
  resource indexes and queued successful-save paths follow actual outcomes. Buffer IDs,
  tabs/order, text, dirty state, file undo, cursor, registers and viewport ownership
  survive. Destination conflicts with an open missing-file buffer are rejected before
  mutation. Cached dirty directories keep their pending text and history at new paths.
- `Controller.reassociate` refreshes display labels and highlighting language while
  preserving the editor/highlight document identity. File diagnostic generations are
  now distinct from stable buffer IDs and increment on path reassociation. UI requests
  close old resources, open new generations and resend current text even when its
  revision did not change. Retired diagnostics, held lists and problem anchors are
  cleared; late owned events cannot attach to a swapped or subsequently reused path.
- Known session file saves update matching tracked fingerprints without accepting a
  different device/inode/kind. This permits ID-ordered save-all to save a file before
  applying its pending directory rename. Directory applies similarly update a cached
  parent's fingerprint for the known changed child directory.
- `Editor.rebase_text` / `Controller.rebase_text` establish the saved actual snapshot
  and reset directory text undo at the filesystem boundary. Success rereads the listing,
  preserves surviving entry IDs/marks/selection and clears dirty state. Partial progress
  also resets old undo so it cannot resurrect pre-apply identity associations; remaining
  intent is still dirty and retryable. A post-apply listing-read failure reports that
  the applied baseline was retained and recommends explicit refresh rather than hiding
  the error. No filesystem undo is implied.

#### Checks run and results

- `opam exec --switch=5.2.0+ox -- dune build`: passed.
- `opam exec --switch=5.2.0+ox -- dune runtest test screen/test palette/test source/test`:
  passed. Thirteen new isolated-filesystem tests in `test/test_directory_apply.ml`
  cover exclusive creation, directory creation, cycles, symlink/link-target behavior,
  external replacements/content changes/parent replacements, dangling destinations,
  invalid plans, every swap/create failure boundary, actual staged backing paths,
  retry without replay, source/destination races, staging reservation/collision checks,
  dirty file/descendant preservation, file and directory swaps, dirty cached reindexing,
  next-save paths, language changes, file undo, save-all ordering and queued saves.
  The primitive-level test introduces an occupant after the absence check and verifies
  that the rename syscall itself rejects it without changing either file/link.
- Added a diagnostic lifetime regression to `screen/test/test_directory_editing.ml`:
  clears old findings, sends close/open/current-text at unchanged revision, rejects
  old generations, and rejects late events after returning to the original path.
  Prior phase-6 save-refusal expectations were updated to real apply; planner/editing,
  backing-path-before-save, unsupported-operation and dirty-lifetime coverage remains.
- `python3 scripts/directory_apply_smoke.py`: passed with isolated PATH `.` fixtures.
  PTY checks explicit rename/file/directory creation saves, disk unchanged before Save,
  dirty-file next-save reassociation, dirty descendant saves after parent rename,
  directory undo boundary, invalid-plan zero mutation, no leftover staging paths, and
  clean quit (0). Capture: `/tmp/opencode/directory-phase7-pty.log`; successful fixture:
  `/tmp/opencode/directory-phase7-pty-ebr7xccd`. An initial summary-text assertion was
  clipped by the history tile; the final smoke verifies the visible rename summary
  and actual filesystem outcomes. No human visual acceptance is claimed.
- Full `opam exec --switch=5.2.0+ox -- dune runtest`: exit 1, only the documented
  `ui/test/test_editor_view.ml` default-visible-tile snapshot mismatch. Log:
  `/tmp/opencode/directory-phase7-runtest.log`. No baseline snapshots promoted.
- `git diff --check`: passed. This agent used only read-only Git status/log/diff;
  no metadata/index/history/config/branch/worktree/staging operations, remote
  mutations/publications or subagents. A checkpoint appeared during implementation
  in read-only inspection; this agent did not create it or alter that state.

#### Limits and next-phase integration

- Phase 7 complete; phases 8–9 remain pending. The full-suite baseline UI mismatch is
  still a repository check gap. Historical phase-6 PTY save-refusal assertions are
  superseded by `scripts/directory_apply_smoke.py`; no phase-8 operations were added.
- This is not a transaction, lock, watcher or crash-persistent journal. Rechecks cannot
  atomically bind path lookup/source identity to the mutation; concurrent parent/source
  replacement after the last check and indistinguishable inode/stat reuse remain race
  limits. Destination no-overwrite is syscall-enforced, unlike source race detection.
  Process termination can leave staging entries; reopening shows them as ordinary
  escaped entries, while the prior remaining intent is not persisted across sessions.
- The no-overwrite primitive currently targets this Linux checkout. There is no
  portable fallback, cross-device copy/delete emulation, filesystem rollback or
  filesystem undo. Renaming a symlink operates on the link, not its resolved target;
  resource reassociation remains the agreed lexical-path policy, not realpath alias
  discovery. Diagnostic runtimes remain per-resource as in phase 1.
- Phase 8 can extend the executor/journal and reconciliation contracts for its explicitly
   chosen delete/copy/cross-directory policy. It must not bypass no-overwrite checks or
   represent cross-device copy-plus-delete as atomic rename. Phase 9 should document
   these save/retry/staging and directory text-undo boundaries and the Linux limitation.

### Phase 8 / 2026-10-07 / implemented

#### Implemented behavior and policy decisions

- **Deletion is permanent, not trash.** Omitting an existing identity row requests
  unlink of a regular file/symlink or rmdir of an **empty** directory on explicit
  directory Save (`Space w`). Summaries say **Permanently delete**, with “empty only”
  for directories. Nonempty directories refuse the entire preflight, including other
  proposed operations; there is no recursive delete, trash fallback, implicit save,
  confirmation dialog, or filesystem undo. Unsupported entry kinds remain read-only.
  Unlinking a directory symlink removes the link, never traverses/removes its target.
- Deleted open file buffers retain their text, dirty state, undo, cursor and stable
  IDs. Controllers carry an explicit missing flag; status shows `[missing]`, tabs
  include `[missing]`, save/save-all refuse resurrection, and close/quit require
  explicit discard even for clean missing buffers. Direct controller save also detects
  external ENOENT for a previously backed file. Initially new/unbacked file buffers
  retain their ordinary create-on-save behavior. This is not background watching:
  external deletions are detected at save; known directory deletions mark immediately.
- Normal `Space b r`, or palette **Recreate missing path**, exclusively recreates the
  missing file from retained buffer text. An externally reappeared occupant (including
  a dangling symlink) is never overwritten. Missing parent directories are not created.
  Clean cached parent listings refresh after recreation. `Session.save_as` provides
  an addressed, exclusive application API for recovery to a different path, reindexes
  the same buffer and refreshes its clean destination listing. There is no interactive
  path-prompt/save-as palette command in this phase; recreate is the user-facing action.
- **Copied-row semantics are deliberate:** yank/paste of an unchanged `@ches[ID]`
  still rejects duplicate identities. Change the copied token to `@copy[ID]`, keep
  its TAB separator/kind suffix, and give it a distinct destination. The ID refers
  to that directory baseline's original backing entry, not edited source text or
  another directory's ID. Multiple explicit copies from one source are allowed.
  Copy rows have no open/markable backing identity until committed. Retaining the
  original `@ches[ID]` keeps the source; omitting it proposes copy **and permanent
  delete**. Copies always read disk, not unsaved text in an open file tab.
- Existing/copy destinations accept relative (`../other/name`, `sub/name`) or absolute
  (`/absolute/name`) lexical paths; slash separates individually byte-encoded components.
  `.`/`..` are permitted as intermediate components, never the final name. Existing
  directories/copies of directories keep final `/`; symlinks do not acquire `/` even
  if their targets are directories. Bare/fresh rows still create immediate children
  only. Normalize against the source directory using the existing lexical resource
  policy. Parents must already exist. No path prompt, glob, shell expansion or realpath
  resource deduplication is introduced.
- Move destinations use the same no-overwrite Linux rename primitive and staging
  journal as phase 7. **Cross-device moves are explicitly unsupported**: device
  mismatch rejects preflight; a later EXDEV remains a visible syscall failure. There
  is no copy/delete fallback and no atomicity claim for the multi-operation apply.
  Destinations whose parent belongs to another dirty cached listing (including dirty
  ancestors) are refused until its edits are saved/undone. Dirty source descendants
  follow a directory move with their intent intact. Destinations overlapping moved or
  deleted parents require separate saves. Directory destinations inside their source,
  including symlink-parent aliases verified by ancestor inode checks, are rejected.
- Copies support regular files, symlinks and recursive directory trees; special kinds
  anywhere in a tree reject preflight. Symlinks copy their **link bytes**, never their
  targets, including dangling links. Relative targets are not rewritten, so they may
  resolve differently in the destination. File/directory rwx bits are preserved;
  set-ID/sticky bits, ownership, timestamps, ACLs, xattrs, sparseness and hard-link
  relationships are not preserved. New ownership is the copying process's; hard-linked
  files become separate byte copies. No filesystem snapshot consistency is promised.
- Copies are built in an owned `.ches-copy-*` temporary tree **at the destination**,
  then published by no-overwrite rename. They may cross devices because they do not
  move the source. A copy IO/publication failure cleans only its owned private tree;
  previously published copies remain journaled and are not replayed. Destination
  occupants appearing during the copy cannot be replaced. Crash termination can leave
  private trees, as it can leave rename staging paths; there is no persistent recovery
  journal. Copy publication precedes source staging/deletion so copy-plus-delete uses
  the original backing identity. Delete/create follow completed rename placement.

#### Changed modules and reconciliation contracts

- `core/directory_identity`: explicit `Row.Copy`, destination-component decoder and
  kind/identity validation. `core/directory_plan`: `Delete {id; source; kind}` and
  `Copy {id; source; destination; kind}` alongside existing create/rename operations;
  readable destructive/copy summaries. Parsing/planning remain filesystem-free.
- `app/directory_apply`: result adds `deleted` backing paths and `affected` parent
  listings. Normalized destination uniqueness, destination-parent inode rechecks,
  empty-directory policy, recursive copy validation and no-overwrite publication are
  whole-plan checks. Mutation and copy-publication fault hooks support isolated tests.
  Successful cross-directory rows leave the source baseline/intent; successful local
  copies get fresh IDs; successful deletes leave no retry proposal. Actual outcomes
  and unresolved intent remain separately reported after all supported partial failures.
  Actual removed marks are pruned; affected tracked child-directory fingerprints are
  refreshed without accepting inode replacements.
- `app/session`: actual cross-directory moves reuse simultaneous path reassociation,
  including resource indexes/diagnostic generation/queued-save paths. Clean affected
  destination caches reload after progress, including partial progress; deleted clean
  directory caches are released and presentation references fall back to the source.
  Dirty destination caches block before IO rather than being silently reloaded. Failed
  affected-cache refresh is reported with explicit refresh guidance. Missing file
  resources stay indexed to their retained buffers. `Controller` guards save in depth
  and exposes missing/recreate/exclusive-save-as contracts. Failed exclusive save-as
  writes can leave a partial newly created file; they never replace an existing file.
- `input/view_command`, `input/bindings`, `palette/catalog`, `screen/ui_state`,
  `screen/status`, `screen/file_tabs`: explicit recovery command/routing and persistent
  missing display. Only intentional new command/count expectations and superseded
  deletion/path-rejection tests changed; unrelated UI snapshots were not promoted.

#### Checks run and results

- `opam exec --switch=5.2.0+ox -- dune build`: passed.
- `opam exec --switch=5.2.0+ox -- dune runtest test screen/test palette/test source/test`:
  passed. Twelve new isolated-filesystem phase-8 tests in `test/test_directory_apply.ml`
  plus one pure planner test cover clean/dirty missing buffers, save-all/close/quit
  refusal, exclusive recreate/save-as, external deletion/direct-controller defence,
  nonempty refusal, unlink/link-target safety, recursive copy/rwx/dangling links,
  every copy/move/delete/create mutation boundary and retry, publication faults and
  races/cleanup, dirty descendant cache/path retention, clean destination refresh,
  dirty destination coordination, normalized collisions, parent replacement races,
  symlink-ancestor self-copy/move rejection, partial-delete missing state and cross-device
  rejection/copy. The cross-device test conditionally uses an isolated `/dev/shm`
  fixture when a distinct writable device exists; all other fixtures use `/tmp/opencode`.
  Log: `/tmp/opencode/directory-phase8-targeted.log`.
- `python3 scripts/directory_operations_smoke.py`: passed. PTY checks dirty backing
  source versus copied disk bytes, no mutation before Save, permanent delete, routine
  missing save refusal and `[missing]`, palette recreation, cross-directory move,
  dirty file next-save reassociation, unchanged copy, no leftover private staging,
  and clean quit (0). Final fixture `/tmp/opencode/directory-phase8-pty-nvrn3ybg`;
  capture `/tmp/opencode/directory-phase8-pty.log`. Initial smoke assertions were
  corrected for clipped feedback and the intentionally retained file cursor; no
  human visual acceptance is claimed. Phase-7 smoke's cross-path rejection assertion
  is superseded by this phase's supported destination syntax.
- Full `opam exec --switch=5.2.0+ox -- dune runtest`: exit 1, the known
  `ui/test/test_editor_view.ml` visible-tile snapshot mismatch only. Log:
  `/tmp/opencode/directory-phase8-runtest.log`. No baseline snapshots promoted.
- `git diff --check`: passed. Git use was read-only inspection only. No Git metadata,
  index, history, config, branch/worktree changes, remote mutations/publications or
  subagents. Prior working-tree changes were retained.

#### Limits and phase-9 handoff

- Phase 8 is complete under the policies above; phase 9 remains pending. Nonempty
  directory deletion and cross-device moves are intentionally unsupported, not stubs.
  Interactive save-as path prompting is not provided; explicit recreate is available.
- Phase-7 source/parent lookup race limits still apply: there are no locks, rollback,
  transactions, watchers or crash-persistent intents. Recursive copy descendants can
  change during traversal; root rechecks do not prove a consistent tree snapshot.
  Directory ancestor checks do not remove races after validation. No-overwrite
  publication is syscall-enforced; source identity is best-effort rechecked.
- Phase 9 should document permanent/empty-only deletion prominently, `@copy[ID]`
  versus duplicated identities, destination syntax/dirty-cache ordering, rwx-only
  copy metadata, relative link semantics, missing/recreate behavior, cross-device
  limits and partial-progress/undo boundaries in end-user docs. It should update the
  old phase-7 smoke's invalid cross-path case, perform full workflow integration and
  terminal validation, and retain the known baseline snapshot gap unless addressed
   in a separate authorized task. No phase-9 README/CLI/reference sweep was done here.

### Phase 9 / 2026-10-07 / implemented

#### Integrated fixes and documentation

- Reviewed the full plan and all current handoffs, then the integrated session,
  directory identity/planner/executor, controller, side input and diagnostic runtime
  ownership. Unsupported cross-device moves, nonempty deletion and interactive
  save-as are explicit policies, not unfinished executor stubs. Previous phase
  implementation and working-tree changes were preserved.
- Fixed partial-apply serialization of cross-directory destinations: byte-escape
  each component independently so leading/trailing component spaces remain canonical
  and retryable. A regression stages a move, injects failure, then safely retries
  into escaped space-edged parent and child names.
- Fixed copy publication to recheck destination-parent identity **after** the copy
  and publication hook, immediately before no-overwrite publication. Private-root
  cleanup checks its owned device/inode before recursive removal; an unrelated
  replacement tree is left untouched. Regression coverage externally relocates the
  parent and inserts a replacement private-root path, verifying zero publication
  and no deletion of the unrelated data. As documented, the externally relocated
  owned tree can remain behind; path-based cleanup cannot safely discover it.
- Fixed side-browser Tab routing after editing became enabled: Insert Tab now
  performs ordinary soft-tab editing rather than unexpectedly returning focus.
  Normal/Visual Tab retains the explicit editor-focus return. A durable headless
  regression verifies mode, text/undo and both focus paths.
- Updated `README.md`, `docs/editor_reference.md`, CLI `-help`, and the palette
  integration notes. Added `docs/directory_workspace.md` covering exact bindings,
  placement/focus, tabs/marks, visible validation-protected IDs, real TAB separators,
  byte/path encoding, explicit `@copy[ID]` versus duplicated identities, disk-versus-
  dirty-buffer copy content, permanent empty-only deletion, missing/recreate/save-as,
  destination coordination, symlink/rwx policies, cross-device limits, partial retry,
  staging/crash races and text-versus-filesystem undo. Palette Save is now accurately
  named **Save buffer** with directory/apply/delete search keywords; catalog ID and
  command order stay stable. Save-all is documented as an API, not a nonexistent key.

#### Baseline snapshot and durable terminal coverage resolution

- The unchanged-HEAD frontend snapshot failures recorded in phases 0–8 were stale
  **fixture assumptions**, not directory regressions: these scenarios expected
  document-only geometry while the documented production defaults show Status,
  Problems and History. `ui/test/test_editor_view.ml` now explicitly hides those
  companions and clears fixture-only feedback before its original editing/resize/
  layout scenarios. Their existing expected frames remain unchanged. A separate
  snapshot verifies the actual default-visible workspace. No production default
  was changed, failing suite excluded, or broad snapshot promotion performed.
- Added `scripts/directory_workspace_smoke.py`, a durable runner for the four
  directory PTY scenarios. Updated the historical phase-6 smoke to current apply/
  undo behavior, and phase-7's obsolete cross-path-invalid assertion to a genuinely
  malformed identity. Extended side smoke with persistent tab switching, independent
  edit/undo and last-file-close fallback. All fixtures are isolated under
  `/tmp/opencode`; these tests never exercise mutations against repository files.
- Updated `scripts/smoke.sh` assertions for lexical absolute resource paths,
  generation-suffixed diagnostic names, supported directory startup, and **Save
  buffer**. Long diagnostics get sufficient width for source/path/location/message
  assertions; narrow layout failures still assert displayed error attention, with
  resource-specific checks in the problems pane and disk/dirty/recovery checks.
  Startup-error restoration now uses invalid file contents rather than a valid
  directory. No obsolete directory-startup failure strands subsequent scenarios.
- Added long-session lifecycle regressions: 48 files and visited directories retain
  distinct IDs and live highlight providers until actual close; closed providers are
  released and repeated dispose is safe. 96 diagnostic driver lifetimes release
  exactly once across addressed close, reopen and repeated session shutdown.
  Narrow `For_testing` provider-liveness accessors support actual cleanup assertions,
  not merely rendered-state assertions. This is functional lifetime coverage, not
  an RSS/performance guarantee.

#### Checks and remaining limits

- `opam exec --switch=5.2.0+ox -- dune build`: passed.
- `opam exec --switch=5.2.0+ox -- dune runtest --force`: passed across the full suite,
  including frontend snapshots, new regressions and all earlier phase tests. Log:
  `/tmp/opencode/directory-phase9-runtest-final.log`.
- `python3 scripts/directory_workspace_smoke.py`: passed all four current PTY
  scenarios; repeated successful run log:
  `/tmp/opencode/directory-phase9-workspace-final.log`. Verified directory startup
  without tabs, single/Visual/marked opens and partial-open feedback, major/side/hide,
  zen/tiny focus, tab retention/undo/last-close fallback, hidden dirty quit/refresh
  guards, backing-path opens, explicit create/rename/copy/permanent-delete/recreate/
  cross-directory saves, dirty descendant next-save paths, text-undo boundaries,
  invalid-plan zero mutation, no ordinary leftover private/staging paths and clean
  exit status 0. No human visual sign-off is claimed.
- CLI `_build/default/bin/ches.exe -help`: passed; output reflects editable directory
  policy and destructive save behavior. `git diff --check`: passed.
- `TMPDIR=/tmp/opencode scripts/smoke.sh`: passed all checks (exit 0), including
  editing, save/reload/dirty recovery, startup default tiles, tiny resizes, palette,
  synthetic and fake LSP diagnostics/crash/restart, no surviving language server,
  SIGTERM/SIGHUP/error exits and terminal modes/cursor restoration. Final log:
  `/tmp/opencode/directory-phase9-terminal-pass.log`; review captures:
  `/tmp/opencode/ches-smoke-screens.psOLHY`. Initial runs identified stale relative-
  path/source-name/startup assertions and clipping, not hidden feature failures;
  they were investigated and corrected as described above. `bash -n scripts/smoke.sh`
  also passed. Final post-Tab-fix directory PTY run passed:
  `/tmp/opencode/directory-phase9-workspace-last.log`.
- Residual limitations are intentional and documented: one editor group/browser,
  session-local state, retained directories/no eviction, whole-text unbounded undo,
  one diagnostic runtime/process per file, Linux-specific no-overwrite mutation,
  no cross-device move/nonempty deletion/trash/filesystem undo/rollback/watcher or
  crash-persistent intent; best-effort source/parent race detection and non-snapshot
  recursive copies; rwx-only copy metadata; no interactive open/save-as prompt;
  in-place ordinary file writes can truncate on failure and do not detect external
  content conflicts. Colors/cursor shape/flicker still need human terminal review.
- Only local source edits, build/tests, isolated fixture operations and read-only
  Git inspection were performed. No Git metadata/index/staging/history/config/
  branch/worktree operations, remote mutations/publications or subagents were used.
  Historical earlier-phase pending statements/snapshot gaps describe their original
  handoffs and are superseded by this final integration handoff.
