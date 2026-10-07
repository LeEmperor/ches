# Directory Workspace: buffers, tabs, and editable directories

Status: planned; no implementation phases completed. Scoped on 2026-10-06.

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

None yet.
