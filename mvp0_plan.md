# Ches MVP0 implementation plan

## Purpose and relationship to the architecture brief

This plan records the decisions made while discussing
[`ches_editor_prototype_brief.md`](ches_editor_prototype_brief.md) and turns them
into bounded implementation phases.

The companion [layout and visual design](rendering_design.md) records centered
placement, keyboard layout adjustments, and the visual direction. Its MVP0 subset
is assigned to phase 6; future panel/theme ideas are explicitly deferred.

The original brief remains the source of the long-term direction. This plan
narrows that direction to MVP0 and resolves initial implementation choices.
Where they differ on MVP0 scope or behavior, follow this plan. Changes to an
agreed contract should be documented here before dependent work proceeds.

The goal is a little editor that works, with enough deliberate architecture to
avoid expensive rework. Prefer a short route to usable software; spend extra
effort on boundaries, correctness, and testability rather than future features.

## Instructions for implementation agents

- **Do not change Git state.** The directory is a Git repository; the owner
  writes their own commit messages and manages commits, branches, and remotes.
  Read-only commands (`git status`, `git diff`, `git log`) are fine. Do not
  commit, push, stage, stash, reset, check out, switch branches, rebase, tag,
  or otherwise modify the repository or any remote unless explicitly asked.
- Implement only the phase assigned, plus prerequisites demonstrably necessary
  for that phase. Do not silently expand into later phases.
- Read this plan, the relevant sections of the original brief, and any applicable
  `AGENTS.md` instructions before editing. Inspect existing work before replacing
  anything.
- Keep core editing behavior independent of Bonsai and terminal APIs.
- Verify actual dependency APIs and compiler compatibility rather than guessing
  Bonsai_term interfaces from examples or memory.
- Run the phase's checks. Report blockers and incomplete checks honestly.
- Finish with a concise handoff: files/modules changed, commands run and their
  results, any deviations, and the next phase's prerequisites.

## Project root and layout

Use **this directory (`ches/`) as the Dune project root**. Put `dune-project`
beside this plan and the original brief; do not create a second nested `ches/`.

An initial layout is:

```text
ches/
  dune-project
  ches.opam                    # package metadata; generated if appropriate
  README.md
  ches_editor_prototype_brief.md
  mvp0_plan.md
  core/                        # ches_core: pure editing library
    text_buffer.ml / .mli
    command.ml / .mli
    editor.ml / .mli
  input/                       # terminal-independent key sequence interpreter
    keymap.ml / .mli
  app/                         # I/O execution and application coordination
  ui/                          # Bonsai_term adapter and components
  bin/
    ches.ml
  test/
```

Each implemented directory gets the appropriate Dune stanzas. Additional modules
are fine when they simplify real code. Do not create empty modules for every
future concept in the original brief. Use `Text_buffer`, avoiding confusion with
OCaml's existing `Buffer` module.

See the original brief's [Recommended Architecture](ches_editor_prototype_brief.md#recommended-architecture),
[Suggested Project Layout](ches_editor_prototype_brief.md#suggested-project-layout),
and [Bonsai Usage Guidance](ches_editor_prototype_brief.md#bonsai-usage-guidance).

## MVP0 scope

Deliver one terminal editor, editing one document at a time:

- `ches PATH`: open a valid UTF-8, LF text file, or start an empty document for a
  nonexistent path.
- Display text, a visible cursor, and a status line with mode, filename, dirty
  indicator, line, column, and application feedback.
- Resize handling and vertical/horizontal scrolling that keep the cursor visible.
- Normal and Insert modes; `h/j/k/l`, `i`, Escape, text insertion, Enter,
  Backspace, and forward deletion.
- Save and quit through Normal-mode Space-leader bindings.
- Undo and redo with explicit transaction boundaries.
- A compilable Dune project, meaningful tests, and build/run documentation.

Deferred: ropes/piece trees, `:` command prompt, `w/b/0/$`, `a`, `dd/dw`, counts,
operators, search, highlighting, LSP, multiple documents or panes, plugins,
configuration language, and everything else listed as out of scope in the brief.
These are extensions, not hidden requirements for finishing MVP0.

## Agreed architectural contracts

### Text storage and positions

Start with an **immutable string behind an abstract `Text_buffer.t`**. Copying on
edit and scanning for line information are acceptable initially. Do not expose
the representation or make UI and motion code convert the entire buffer to a
string on every operation.

Provide operations for insertion, deletion, slices, byte length, line count,
line start/end lookup, position-to-line lookup, and previous/next code-point
boundaries. Whole-text access is appropriate at loading/saving boundaries.

- Internal offsets are zero-based byte offsets at valid UTF-8 boundaries.
- Line APIs explicitly document whether their indices are zero-based; use that
  convention consistently. Status line coordinates are one-based.
- Character movement/deletion respects Unicode code points. Full grapheme-cluster
  editing is deferred and documented as a limitation.
- Display columns are distinct from byte offsets and code-point counts. The UI
  handles tabs and terminal character widths; use the rendering stack's width
  facilities where possible.
- Use a fixed tab stop of 8 display cells initially. Define this once rather than
  scattering constants through rendering.
- Accept valid UTF-8 and LF line endings. Reject invalid UTF-8, CRLF/bare CR, and
  NUL-containing input with a clear error for MVP0; do not silently normalize it.
  Apply the same text validity rules to inserted/pasted input.
- Preserve text exactly on save, including whether it has a final newline.
- An empty buffer has one empty logical line. A trailing LF creates an empty
  final logical line. Line-end offsets exclude the newline byte.

The rejection policy and fixed tab stop above make the agreed LF/UTF-8 scope
concrete; they can be relaxed in a later milestone.

This follows the brief's [Text Storage](ches_editor_prototype_brief.md#text-storage)
section, which discusses gap buffers, ropes, piece tables, and piece trees while
explicitly allowing a simpler initial representation behind a replaceable API.

### Cursor and editing semantics

- Insert mode uses insertion points, including after the final character.
- Normal mode sits on a code point on nonempty lines. Empty lines have a valid
  cursor at their line start, including the empty final line after a trailing LF.
- `h/l` stop at line boundaries.
- `j/k` retain a preferred logical code-point column across shorter lines. The UI
  separately maps this to a display column. Horizontal movement and edits reset
  that preference to the resulting cursor column.
- `i` enters Insert at the current position.
- Escape returns to Normal and moves left one code point if possible without
  crossing a newline; then normalize the cursor for Normal mode.
- Enter inserts LF. Backspace removes the preceding code point and may join
  lines. Insert-mode Delete removes the following code point and may join lines.
- Normal-mode `x` deletes the code point under the cursor but not a newline;
  on an empty line it is a no-op.
- All transitions preserve valid cursor boundaries. Attempts to move beyond a
  boundary are no-ops rather than exceptions.

### State ownership

The core editor state is the logical state at an instant, not just the mode:

```text
document: buffer, optional path, monotonic revision, last saved snapshot
cursor and preferred logical column
mode: Normal | Insert
undo/redo history and active transaction
user-visible outcome/message data, where needed
```

Keep pending key sequences in the keymap, viewport dimensions/scrolling in the
UI, and I/O execution/resources in the application. A frontend must be able to
drive the core without a terminal.

UI state also owns preferred text width, centered/full-width mode, and horizontal
placement offset. Layout actions never enter document undo history or modify
core cursor/revision/dirty state. See [rendering design](rendering_design.md).

### Commands, dispatch, and effects

“Dispatch” means applying an editor command. Use state-first argument order:

```ocaml
val dispatch : State.t -> Command.t -> State.t * Effect.t list
```

The exact module packaging may differ, but keep this functional boundary.
Initial commands cover movement, entering/leaving Insert, inserting text,
Backspace, forward deletion, undo/redo, save, normal quit, and forced quit.
Commands describe editor actions rather than physical keys.

Represent I/O requests explicitly. The application executes effects and reports
their outcomes through a separate core result-handling entry point. Define the
concrete effect/result types before implementing save behavior. A write request
identifies the path and exact buffer snapshot being saved; success marks that
snapshot saved, not whatever happens to be current when the response arrives.

Saving can be synchronous in MVP0. Do not introduce an async framework solely to
prepare for future LSP work. Keep the effect boundary so asynchronous execution
can be introduced later.

See [Editing Model](ches_editor_prototype_brief.md#editing-model) and
[Important Engineering Invariants](ches_editor_prototype_brief.md#important-engineering-invariants).

### Undo, revisions, and dirty state

Distinguish an individual edit from an undo transaction. Store before/after
buffer snapshots and cursor information behind the history implementation.

- Contiguous Insert-mode edits form one transaction.
- Escape, an explicit movement command, or save closes the active transaction.
  Backspace/Delete remain part of the current typing transaction.
- Each Normal-mode editing command is its own transaction.
- Movement and mode changes alone produce no undo entry. Empty/net-no-change
  transactions should not create useful-looking undo steps.
- A text-changing edit after undo clears redo; entering Insert alone does not.
- Undo/redo restores text and cursor, retaining file association and saved-state
  bookkeeping. MVP0 binds undo/redo only in Normal mode.
- Document revision increases on every actual text change, including undo/redo;
  it is not restored from a historical snapshot.
- Dirty means current text differs from the last successfully saved text.
  Comparing strings is acceptable initially. Undoing back to saved content clears
  dirty; revision equality alone cannot determine this.
- A nonexistent file starts clean and empty; saving still creates it even if no
  text was entered. Failed writes never mark content saved.

This leaves room to change grouping policy without replacing storage or commands.
See [Undo / Redo](ches_editor_prototype_brief.md#undo--redo).

### Input bindings and feedback

| Mode | Keys | Action |
| --- | --- | --- |
| Normal | `h/j/k/l` | Move |
| Normal | `i` | Enter Insert |
| Normal | `x` | Delete character under cursor |
| Normal | `u` | Undo |
| Normal | `Ctrl-r` | Redo |
| Normal | `Space w` | Save |
| Normal | `Space q` | Quit if clean; otherwise show refusal/message |
| Normal | `Space Q` | Quit and discard unsaved changes |
| Normal | Escape | Cancel pending sequence |
| Both | `Ctrl-c` | No command; cancels pending sequence and hints `Space q` (phase 6) |
| Insert | Text / Space | Insert literal text |
| Insert | Enter / Backspace / Delete | Edit text |
| Insert | Tab | Insert a 2-column soft tab (default) or a literal TAB; configurable |
| Insert | Escape | Return to Normal |
| Insert | `j k` | Return to Normal (default; configurable or disabled) |

Tab and `j k` were added during phase 4 at the owner's request. They are
keymap settings (`Keymap.Config`) chosen by the frontend, not a configuration
file; a configuration language remains deferred. With `Spaces n` (soft
tabs), Tab inserts spaces to the next multiple of `n` columns and Insert-mode
Backspace deletes spaces back to the previous multiple, as in Vim's
`softtabstop`; the core provides these as `Insert_soft_tab` and
`Delete_soft_tab_backward` commands. Their columns are code-point columns, so
a TAB earlier on the line counts as one column. `j` is inserted when typed, and an immediately
following `k` deletes it and returns to Normal, so no timeout is needed and
typed text is never hidden; the cost is that `jk` cannot be typed literally
(paste it instead). Space is the leader only in Normal mode.

Use a small terminal-independent key type and stateful sequence interpreter.
Unknown leader continuations cancel the sequence without editing text. A pending
leader has no timeout initially; show it in the status area. Terminal event
normalization belongs in the UI adapter. Paste should become literal inserted
text in Insert mode, not a sequence of Normal-mode commands.

A future `:` prompt can map `:w`, `:q`, `:wq`, and `:q!` to the same commands.
Do not implement that prompt in MVP0.

Phase 6 adds the Normal-mode `Space v` layout prefix: `c` toggles centered/full
width, `h/l` nudge left/right by 2 cells, `H/L` by 10, `-/+` adjust preferred text
width (`=` is an unshifted alias for `+`), and `r` resets layout. Full
semantics and defaults are in
[rendering_design.md](rendering_design.md#normal-mode-layout-commands).
These are view commands routed separately from core editor commands. This is a
bounded phase-6 extension to phase 4, not a requirement to redo that phase.
Phase 6 also makes Ctrl-C a hint-only key (see the table above); in raw mode it
is no longer a signal, and the phase 1 skeleton's Ctrl-C exit goes away.

## Phase execution and context budget

There are **seven phases**, each intended as a fresh implementation session.
No phase count guarantees fitting a particular model's context window; dependency
investigation and failures are unpredictable. The boundaries below limit scope
and provide useful stopping points without requiring dozens of tiny phases.

For each phase, give the agent this plan, the phase number, and the previous
handoff. Ask it to read only relevant source and brief sections rather than dump
the whole repository or dependency source into context. If an unexpected blocker
threatens the session budget, stop with a precise handoff instead of starting an
unrelated workaround or relying on compaction.

Suggested assignment:

> Implement phase N of `mvp0_plan.md`. Respect its scope and architecture
> contracts. Do not commit, push, or otherwise change Git state. Run its acceptance checks
> and provide a concise handoff with any unresolved issues.

For phase 6, name the checkpoint ("Implement phase 6A …"), and give a 6B
session the 6A handoff.

### Phase 1 — Dune project and real terminal skeleton

**Goal:** validate the toolchain and Bonsai_term before building on assumptions.

Read the brief's TUI Choice and Bonsai Usage Guidance sections.

Work:
- Inspect available OCaml/OxCaml, opam, Dune, and dependency versions.
- Select and record a compatible toolchain. Prefer ordinary OCaml unless the
  chosen Bonsai_term stack requires OxCaml; avoid speculative compiler features.
- Establish the root Dune project, package metadata, executable, and initial
  independent core library boundary.
- Launch an actual Bonsai_term screen with placeholder text/status, handle resize,
  and exit cleanly with a temporary documented key.
- Write README build/run instructions using the actual setup that succeeded.

Acceptance:
- `dune build` succeeds in the documented environment.
- The terminal demo launches, resizes, and exits while restoring terminal state.
- The core library target builds without a Bonsai_term library dependency.

Stop after the skeleton. If Bonsai_term cannot be installed or compiled, report
the exact incompatibility; do not silently switch to Notty/Nottui.

### Phase 2 — Text buffer and position contracts

**Goal:** implement the replaceable text representation and boundary operations.

Work:
- Add the abstract string-backed `Text_buffer` interface and implementation.
- Implement UTF-8 validation/boundaries, edits, slices, and line access.
- Specify invalid argument behavior in the interface; reject invalid offsets
  explicitly rather than corrupting text.
- Add focused core tests, using expect tests where convenient.

Acceptance:
- Tests cover empty text, trailing/no trailing LF, consecutive empty lines,
  multibyte text, first/last positions, insertion/deletion across newlines, and
  rejected input.
- Verify byte/line conversions and preservation of untouched text.
- Core tests run without importing the UI.
- `dune build` and the relevant `dune runtest` targets pass.

Stop before mode handling, keyboard interpretation, and terminal rendering.

### Phase 3 — Editor transitions, transactions, and effects contract

**Goal:** make the editor usable entirely through core commands and tests.

Work:
- Define public state accessors, commands, effects, and I/O result types.
- Implement Normal/Insert cursor rules, movement, insertion, deletion, and cursor
  normalization.
- Implement snapshot history, transaction boundaries, revisions, and dirty state.
- Implement save/quit request decisions and result handling without performing
  filesystem I/O. Test them with simulated results.

Acceptance:
- Test short-line vertical movement, empty/final lines, mode transitions,
  newline joining, and multibyte deletion.
- Test grouped typing, movement splitting transactions, standalone deletion,
  undo/redo, redo invalidation, and no-op commands.
- Test undoing back to saved content, failed save, and save completion for an
  older snapshot while newer text remains dirty.
- Test clean quit, dirty quit refusal, and forced quit effects.
- Core builds/tests pass without UI dependencies.

Stop before keymaps or real file writes. Keep tests behavioral rather than
snapshotting every internal record field.

### Phase 4 — Modal input and leader sequences

**Goal:** turn normalized key events into the already-tested commands.

Work:
- Implement the terminal-independent key type and keymap state machine.
- Implement all bindings above, including pending leader feedback/cancellation.
- Define the adapter contract for text input and paste.
- Feed key sequences through the keymap and core together in headless tests.

Acceptance:
- Test `Space w/q/Q`, Escape cancellation, unknown continuations, and repeated
  sequences with no leaked pending state.
- Test literal Space in Insert, mode changes, `u`, and `Ctrl-r`.
- Test Insert-mode paste as literal text and safe ignoring of paste in Normal.
- A key-sequence test can insert text, leave Insert, undo/redo, and request save.
- Relevant build/tests pass.

Stop before terminal event integration and file execution.

### Phase 5 — File lifecycle and application controller

**Goal:** connect core effects to real loading, saving, and exit decisions.

Work:
- Parse the single required path argument; give clear usage errors.
- Load existing valid files or construct a clean empty document for a missing
  path. Treat other read failures as errors, not empty documents.
- Execute write effects and route outcomes back to the core.
- Preserve exact text bytes. Use a straightforward synchronous save with checked
  errors and reliable resource cleanup; document its limitations. Crash-safe
  replacement, symlink policy changes, and external modification detection are
  later work.
- Expose controller outcomes so the UI can show errors and perform clean exits.

Acceptance:
- Temporary-directory integration tests cover load/edit/save/reload, creating a
  missing file, final-newline preservation, and validation/read/write failures.
- Failed writes retain dirty state and produce useful feedback.
- Tests cover dirty quit refusal and forced quit without overwriting the file.
- Relevant build/tests pass.

Stop before full editor rendering. Keep filesystem access out of `ches_core`.

### Phase 6 — Working Bonsai_term editor

**Goal:** join the tested pieces into an interactively usable editor.

Read [rendering_design.md](rendering_design.md) for the MVP0 visual/layout
contracts and reference examples. Its
[settled phase 6 decisions](rendering_design.md#settled-phase-6-decisions) fix
the UI state model, feedback precedence, cell mapping, cursor placement,
scrolling, and layout limits; follow them rather than re-deciding. Preserve
completed phases 1–5, including the owner's Tab and `jk` choices. The
anticipated interface changes are exactly: keymap output tagged as editor
versus view actions, `Controller.handle_input` also returning view actions,
the Ctrl-C hint, and the `Space v` bindings. Update callers/tests accordingly.

Use two checkpoints within this phase to keep the context budget bounded. They
are intended as separate implementation sessions with a short handoff; they do
not add new top-level phases. 6A reaches a usable editor first, following the
"short route to usable software" rule; 6B adds layout controls and the visual
pass on top of real content. 6A's geometry already takes the width/offset
preferences (fixed at their defaults), so 6B adds controls without reworking it.

#### 6A — Working editor

Work:
- Write a Bonsai-free screen model in `ui/` (or a small Bonsai-free library if
  that keeps tests simpler): geometry for tile, text, gutter, border, and status
  rectangles, including centered placement at the default width 100 / offset 0
  and responsive dropping of border/gutter on small screens; the cell mapping;
  the cursor cell; and the scroll fit function. Cover it with headless expect
  tests: tabs, wide and zero-width characters, escape forms, edge clipping,
  scrolling, and tiny/zero dimensions.
- Write the pure UI model and transition (controller, layout preferences,
  scroll, paste buffer, message slot) and test it headlessly with key sequences.
- Replace the placeholder screen: one `Bonsai.state_machine`, terminal event
  adaptation into normalized keys and bracketed paste, rendering of text,
  gutter, a plain border, status line, pending keys, and feedback, the
  mode-dependent cursor, and resize handling.
- Add the Ctrl-C hint. Remove the skeleton's temporary exit keys.
- Define theme roles in one module with provisional colors, so 6B tunes values
  rather than plumbing.
- Write the terminal smoke script (below) covering the 6A checks.

6A is done when the editor can open, edit, scroll, save, quit, and reopen
files; the acceptance items on control characters, lost keystrokes, terminal
restoration, tall/wide/empty files, and tiny dimensions pass; and `dune build`,
`dune runtest`, and the smoke script pass. The handoff lists any acceptance
items that remain open.

#### 6B — Layout controls and visual pass

Work:
- Add the view-command type, tag keymap output, extend
  `Controller.handle_input`, and update callers/tests.
- Add the `Space v` bindings, layout feedback, and preference limits. Keep
  requested preferences across resize.
- Finish the visual design: cohesive dark palette, fine border with the filename
  in the top border when space permits, muted gutter, and subtle current-line
  emphasis.
- Before adding the top-border filename, split the status line in
  `screen/frame.ml` into three parts, so status information can later appear
  in any tile, not only the bottom row:
  1. **Fields as data:** a function from UI state to a list of fields (mode,
     filename, dirty, pending keys, position, message), each with its spans,
     priority, and how it may be cut.
  2. **Layout functions:** fields plus a size in, spans out. The existing
     priority-ordered single-row fitting becomes one layout; the top-border
     filename is a second, using the same filename field.
  3. **Placement:** `Geometry` decides which rectangle gets which layout and
     fields.

  The bottom status line must look and behave exactly as in 6A; its existing
  expect tests should pass unchanged. This is a refactor that makes the top
  border use shared fields, not a status-panel or tile framework. Field
  configuration stays in code (no configuration language), and additional
  status tiles remain later work.
- Review screens at 80×24 and 160×48 and at tiny sizes, with representative
  Normal, Insert, dirty, pending-prefix, and error states, in a real terminal
  where available.
- Extend the smoke script to cover layout commands.

6B is done when every acceptance item below passes or is reported as not
checkable in this environment.

#### Terminal smoke script

Add `scripts/smoke.sh`. It drives the built `ches` binary inside tmux, so the
agent can run the interactive checks and phase 7 can repeat them. It is run
explicitly, not by `dune runtest`, since it needs tmux and a built binary.

- Use a private tmux server (`tmux -L ches-smoke`) and kill it on exit, so it
  never touches the owner's sessions. Work on fixture copies in a temporary
  directory, removed on exit.
- Start a session with a plain shell and an explicit size, e.g.
  `new-session -d -x 80 -y 24`, with `window-size manual`. Launch `ches` from
  that shell, so the terminal state after exit can be checked.
- Send input with `send-keys` (`-l` for literal text; named keys such as
  `Escape`, `Enter`, `BSpace`, `Space`, `C-r`, `C-c`). Send pastes with
  `load-buffer` plus `paste-buffer -p`, which brackets the paste when the
  application has enabled bracketed paste.
- Wait by polling `capture-pane -p` until expected text appears or a timeout
  passes; avoid fixed sleeps as the only synchronization.
- Assert on the screen text (`capture-pane -p`), the cursor position and
  visibility (`display -p '#{cursor_x} #{cursor_y} #{cursor_flag}'`), the
  alternate screen (`#{alternate_on}`), and file contents after save, compared
  byte for byte with `cmp`.
- Resize with `resize-window -x W -y H`, including tiny sizes such as 1×1 and
  10×3, then back to 160×48.
- Cover open/edit/save/reopen, undo/redo, dirty-quit refusal and forced quit,
  a save error (e.g. a read-only directory), scrolling in tall and wide files,
  tabs/Unicode/control characters, a fast burst of keys, Insert-mode paste,
  Ctrl-C, and (6B) each `Space v` command with its clamping/restore behavior.
- Save `capture-pane -e -p` output (which keeps colors) for the 80×24 and
  160×48 review screens to a directory the script prints, for the owner to
  look at. Exit nonzero on any failed assertion and name it.

The script cannot verify cursor shape (tmux 3.4 does not report it), how the
palette looks, or flicker. Check those in a real terminal, or record them as
unchecked in the handoff.

#### Acceptance for the whole phase

- Open a file, move, edit, undo/redo, save, quit, and reopen it.
- Exercise files taller/wider than the screen, empty files, tabs, Unicode, and
  terminal resizing, including very small dimensions.
- Open a file containing ESC sequences, other C0/C1 controls, and bidi
  overrides: each shows its escape form, nothing reaches the terminal raw, and
  the gutter/border stay aligned.
- Type quickly and paste while the screen is busy: no keystroke is lost.
- After quitting a session that used Insert mode, and after an error exit, the
  shell's cursor shape and visibility are restored.
- Confirm Space-leader feedback, dirty quit refusal, and save-error visibility.
- Verify nudge/width/reset/toggle controls, clamped placement on small terminals,
  restoration on larger terminals, and cursor visibility after every adjustment.
- Verify view actions leave document text, cursor, history, revision, and dirty
  state unchanged, and preserve existing keymap behavior.
- Review representative screens at laptop-sized (80×24) and monitor-sized
  (160×48) dimensions. Inspect actual terminal colors/cursor behavior where
  available; textual snapshots alone do not verify the aesthetic result.
- Add focused viewport/rendering tests and Bonsai_term expect tests where the
  installed framework supports them.
- `dune build`, `dune runtest`, and `scripts/smoke.sh` pass.

Use the smoke script for every item it can check; check the rest by hand or
report them as unchecked.

Stop when the specified editor works; do not add convenience commands from the
deferred list.

### Phase 7 — Acceptance pass and user-facing documentation

**Goal:** finish MVP0 as a reproducible, documented working item.

Work:
- Run a bounded end-to-end acceptance pass through the complete binding table.
  Start from `scripts/smoke.sh` and extend it for any binding or behavior it
  does not yet cover.
- Fix integration defects within MVP0 scope.
- Complete README: setup/build/run, bindings, architecture, storage tradeoff,
  supported text, undo policy, known limitations, and next milestones.
- Document layout controls, default width/offset, resize behavior, and the fact
  that layout preferences are session-local in MVP0.
- Record the exact tested toolchain and any manual checks that could not run.
- Document how to run `scripts/smoke.sh`, what it needs (tmux), and what it
  cannot check.
- Review dependency boundaries and ensure no terminal-specific semantics leaked
  into core editing modules.

Acceptance:
- A user following the README can build and run `ches PATH`.
- `dune build` and `dune runtest` pass in the documented environment.
- `scripts/smoke.sh` passes and, with any hand checks, demonstrates
  edit/save/reopen, undo/redo, scrolling, resize, error feedback, and both quit
  behaviors.
- No commits or pushes have been made by implementation agents.

MVP0 is complete here. Further features require a new milestone rather than
stretching this phase indefinitely.

**Done (2026-10-01).** `dune build`, `dune runtest`, and `scripts/smoke.sh`
pass, and the owner accepted the editor after trying it in a real terminal.
MVP0 is complete.

## Likely next milestones, not MVP0 requirements

1. Word/line motions, `a`, and composable operators such as `dd/dw`.
2. A small `:` prompt using existing commands and effects.
3. Improved Unicode/grapheme and line-ending support.
4. Profile real editing latency and memory; replace string storage with a rope
   or piece-based tree if justified. Snapshot history currently retains whole
   strings, so large-file editing/history is an explicit limitation.
5. Search, then language tooling after the core is stable.

Retain the original brief's architectural direction, but avoid treating its
long-term performance targets or future workspace/plugin sections as MVP0 gates.
