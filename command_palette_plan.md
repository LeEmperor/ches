# Ches command palette implementation plan

Status: proposed. This document does not implement the feature.

Coordination update (2026-10-05): reviewed the working files in `../tiles/`,
especially `../tiles/workspace_tiles_design.md` and its planned phases 7A–7C.
Backend work can proceed now. Shared dispatch and runtime integration follow the
tiling integration checkpoints below; they are no longer the first assignment.

## Goal

Provide an Emacs `M-x` / fzf-style command palette: press `Space c c` in
Normal mode, type a partial command name or related keywords, select a result,
and execute it. Discoverability should not depend on knowing the shortcut.

Keep command metadata, matching, and interaction independent of window geometry
and Bonsai. The workspace/tiling worktree supplies the generic presentation host.

## Current architecture

- `core/command.ml` and `.mli`: typed editing commands, independent of bindings.
- `input/view_command.ml` and `.mli`: view commands, including line-number toggles,
  layout adjustments, scrolling, and smear-cursor toggle.
- `input/bindings.ml` and `.mli`: validated Normal-mode bindings. Some targets
  represent incomplete interactions such as operators or search prompts.
- `input/keymap.ml` and `.mli`: modal input processing; `Keymap.Action.t` separates
  editor actions from view actions.
- `app/controller.ml` and `.mli`: editor dispatch, synchronous effects, highlighting,
  clipboard requests, and exit handling. The main public dispatch route currently
  starts with `handle_input`; `move` is a specialized exception.
- `screen/ui_state.ml` and `.mli`: terminal-independent UI transitions, view-command
  application, scrolling, paste collection, feedback, and animation state.
- `ui/editor_view.ml`: Bonsai frontend and rendering integration.
- The local `workspace_tiles_design.md` predates the current tiling work. For
  coordination, consult `../tiles/workspace_tiles_design.md` and the actual working
  files there; do not implement host APIs from the older local copy.

### Tiling worktree baseline and dependencies

At this review, `../tiles/` has implemented workspace allocation/status controls,
shared notification/problem feedback, and problems-specific interaction. Phases
1–5 are recorded as human-accepted; phases 6–7 are software-complete with human
feedback pending. Phases 7A–7C are explicitly **planned, not implemented**:

- **7A:** generic tile identity, capabilities, host/action routing, focus/capture,
  pending cancellation, paste start-owner routing, and problems-adapter migration.
- **7B:** shared rounded shell, padding, content geometry, and sizing/fallback.
- **7C:** shared read-only text cursor, Visual selection, and copying.

The working tree already includes `screen/workspace.ml`, problems presentation and
navigation modules, `Controller.cancel_pending`, `Keymap.reset`, and controller
`feedback`/`update_feedback` APIs backed by `Ches_error.Error`. These are useful
existing implementation points, not a promise that the final 7A API is settled.
The tiling controller also differs from this checkout's highlighting-aware
controller: integration must preserve both branches' behavior, not copy either
file wholesale. Much of the reviewed tiling work is uncommitted; a branch HEAD or
merge-base alone does not capture this baseline.

Before integration, reread the latest phase handoff and working interfaces. Use
an agreed committed checkpoint containing the relevant tile work when integrating;
this plan does not authorize committing, copying over, or modifying `../tiles/`.

Inspect the current implementations before refactoring: interfaces alone do not
capture all bookkeeping and ordering behavior. Follow the existing Dune library
dependency direction; core editing must not depend on palette or screen modules.

## Architecture

### 1. Command catalog

Introduce a catalog of user-invokable commands. Proposed names in this document
are illustrative; use names consistent with the surrounding code.

Each entry contains:

- Stable, unique ID, such as `view.toggle-relative-numbers`.
- Human-readable title, such as `Toggle relative line numbers`.
- Optional short description.
- Search keywords/aliases, such as `gutter`, `numbering`, `relativenumber`, `rnu`.
- Typed executable action, initially an existing editor or view action.
- Availability rule evaluated against explicit invocation context.

Keep metadata close to the owning feature, with one composition point assembling
the built-in catalog. A static catalog is sufficient initially; no runtime plugin
registry or separate process is required.

Do not make the catalog a list of key sequences. A command can exist without a
binding, and multiple bindings can invoke one command. Display shortcuts derived
from the active binding configuration where a binding maps directly to that
action. Do not pretend incomplete binding targets are executable commands.

Validate duplicate IDs. Titles and keywords may change without changing identity.
Use IDs, rather than row indices or labels, for execution and selection identity.

Example conceptual entry:

```text
id:       view.toggle-relative-numbers
title:    Toggle relative line numbers
keywords: gutter, numbering, relativenumber, rnu
action:   View Toggle_relative_numbers
shortcut: Space v N   [derived, not stored independently]
```

### 2. Shared action dispatch

After the 7A host/action contract is recorded and its relevant checkpoint is
integrated, inspect whether a reusable command-execution path already exists. Reuse
it, or extract the smallest missing action-execution portion of
`Controller.handle_input`. Keep keymap feeding in `handle_input`, then have it call
that shared path. Coordinate changes to this shared file with the tiling owner.

The tile host's generic adapter-action dispatch and the controller's editor-command
execution are distinct responsibilities. The palette adapter translates acceptance
into the existing editor/view action route; the generic host must not gain knowledge
of command metadata, save semantics, or the feedback reducer.

Both shortcuts and palette acceptance must converge on the same editor effect
handling and screen-side view-command application:

```text
keyboard → keymap ───────────────┐
                                ├→ shared action dispatch → editor / view
palette → catalog action ───────┘
```

Preserve effect ordering, save/reload errors, clipboard delivery, highlighting
updates, message freshness, scroll fitting, and exit short-circuiting. Review
`last_input_dispatched` semantics explicitly: palette-originated commands need
correct feedback even though they did not originate in a keymap feed.

Do not execute palette entries by synthesizing their shortcut keys. Do not call
`Editor.dispatch` directly from the palette and bypass controller effects.

At the screen boundary, share the existing view-action and feedback path rather
than introducing a second implementation for palette-originated view commands.

Use the integrated shared feedback lifecycle, not this checkout's older disposable
message-slot model. Query editing, navigation, opening, and cancellation are not
completed editor commands and must not clear notifications or acknowledge problems.
A palette-dispatched editor command follows the same transient-clearing policy as
its keyboard equivalent. Save/reload failures retain their typed problem identity;
only matching recovery resolves them. Escape cancels the palette without also
falling through to document search clearing or failure acknowledgement.

### 3. Fuzzy matching

Implement a pure, in-process matcher. No external `fzf` executable is required.
Keep its API generic enough to search other item collections later, without
building a provider framework in the first version.

Inputs: query and candidate IDs with searchable fields.
Outputs: ranked candidate IDs, scores, and field-specific match positions.

Initial behavior:

- Case-insensitive matching with a documented normalization policy.
- Ordered subsequence matching within a query token.
- Split the query on whitespace; require every token to match some searchable
  field, allowing tokens to match different fields.
- Prefer exact/prefix matches, contiguous runs, and word-boundary matches.
- Weight title matches above identifier matches, and identifiers above keywords.
- Use a deterministic tie-breaker, such as catalog order then ID.
- Empty or whitespace-only query returns available commands in stable order.
- No matches returns an empty list; accepting it performs no action.

For example, `rel num`, `rln`, and `gutter relative` should discover the relative
line-number command. Keywords supply synonyms; fuzzy matching is not semantic
interpretation and need not tolerate arbitrary misspellings in this milestone.

Document whether offsets refer to bytes or code points. Never treat either as
terminal display-cell positions. Highlight only actual title matches; matches
against a keyword must not be applied as offsets into the title. Ensure non-ASCII
input cannot cause invalid slicing; full Unicode case folding can be deferred
if the initial policy is explicit.

### 4. Palette model

Create a terminal-independent state machine owning:

- Query text.
- Ranked result IDs and selected ID.
- An opaque invocation token supplied by application assembly, or an accept result
  paired with that token by the adapter; no palette-owned workspace ID registry.
- Input transitions and accept/cancel outcomes.

Use normalized semantic events such as query insertion, backspace, previous/next,
accept, and cancel. Return an execution request containing command identity and
target, rather than executing effects inside the model.

Initial query editing can be append plus backspace; full cursor editing is not
required. Backspace must remove a complete code point. Define paste handling
explicitly for this single-line prompt, including newlines and control characters.

On query changes, retain the selected ID if it still matches; otherwise select
the first result. Clamp navigation at the ends. An empty result set has no
selection. Selection movement and query changes never execute commands.

The headless model may implement this small command-specific reconciliation policy
before 7A lands. At integration, use shared list interaction primitives where
available and keep one authoritative selected key; do not maintain separate model
and host selections. Palette policy determines which command survives a filter;
shared interactions supply generic movement/viewport behavior where applicable.
Keep viewport-dependent result scrolling out of the matcher. Do not grow a second
generic list/text widget toolkit in this worktree.

### 5. Generic host and presentation

The palette is a content adapter on the 7A host and 7B shell. A minor tile may
advertise an input field: the tiles plan explicitly separates role from input,
cursor, and paste capabilities. Register the query as input-capable; do not make
the whole tile impersonate an editable document or read-only problems pane.

The tiling workstream owns:

- Placement and allocated rectangles; floating/overlay support requires an explicit
  host extension agreement and is not promised by the current 7A–7B scope.
- Borders, clipping, resizing, visibility, and focus lifecycle.
- Routing input exclusively to the focused content.
- Terminal cursor ownership and focus restoration.
- Shared list viewport/navigation and optional text-selection/copy interactions.

Palette-specific presentation owns:

- Query prompt, result rows, selection style, and match highlighting.
- Shortcut hints and optional descriptions.
- Empty-result display and supplying the selected key to shared viewport handling.

The host need not understand command IDs, scoring, or editor actions. The palette
backend need not know whether its content appears floating or docked.

**Host readiness:** runtime integration requires the 7A routing contract and 7B
content-rectangle/shell contract. Stage backend work and content snapshots before
then, rather than adding temporary palette-specific capture fields or borders.
If floating presentation is not ready, agree on a docked host milestone or keep
the backend headless until host support lands. Docking does not satisfy the desired
floating presentation; record that remaining work explicitly. Do not independently
implement an overlay allocator or compositor in the palette branch.

7C is not a prerequisite for an editable query plus selectable results. If result
text inspection/copying is added later, consume 7C instead of implementing a parallel
read-only cursor, Visual selection, or clipboard route.

## Cross-worktree contract

Agree on these semantics before either side builds an adapter. Exact OCaml types
should follow the workspace implementation rather than being guessed here.

| Operation | Contract |
| --- | --- |
| Open | Capture the invoking document/view target and context; clear pending document key sequences; activate palette content |
| Input | Shared host delivers input to the captured destination, with documented workspace-navigation precedence; paste belongs to its start owner and is delivered atomically under the advertised capability |
| Render | Shared shell supplies padded content geometry; palette supplies query/row snapshots, selection, and local cursor intent, never independent outer-frame geometry |
| Cancel | Close without dispatching; restore prior focus when the target still exists |
| Accept | Resolve selected ID and recheck availability/target validity, dismiss palette, restore valid target focus, dispatch exactly once |
| Target disappears | Cancel safely with feedback; never silently execute on a different document |
| Resize | Change layout and visible rows without changing query or selected command identity |
| Hide/zen/compact fallback | Apply the host's recorded capture-release/focus-restoration policy; never execute a selection merely because the tile disappears |

Resolve and record the remaining adapter policies with 7A before runtime work:
whether a hidden palette retains or discards its query; what happens if its view
closes during a paste; and how workspace shortcuts coexist with query text. Reuse
host guarantees rather than inventing alternate paste ownership or Escape routing.

Opening the palette changes focus, not the execution target. A view command such
as toggling line numbers applies to the originating document view, not the palette.

Initially Ches has one document; keep this contract explicit without implementing
a speculative multi-document registry. The workspace layer supplies stable target
identity through its 7A view contract, even with only one document. Keep invocation
tokens abstract until that contract lands; do not define a competing `Pane_id`.

`Space c c` is a Normal-mode binding. Represent opening the palette as a UI or
workspace interaction at the appropriate routing boundary, not a core editing
command. Agree with the tiling worktree on the action type that carries it.

## Initial catalog and interaction scope

Include directly executable, useful commands:

- Save, quit, and explicitly labeled quit-discarding-changes.
- Undo and redo.
- Toggle absolute and relative line numbers.
- Toggle centered layout and animated smear cursor.
- Reset layout.
- Existing fixed-step tile movement and width adjustments, with explicit labels
  such as `Widen document tile by 10 columns`.

Use existing command semantics, including refusing ordinary quit with unsaved
changes. Do not add palette-specific behavior to those commands.

For the first milestone, expose Normal-mode-appropriate entries and open only
from Normal mode. Availability is still checked at acceptance. Later mode support
must explicitly preserve selection and insertion semantics.

Proposed adapter-local interaction: `Space c c` opens; typing filters; backspace edits the query;
`Ctrl-n`/`Ctrl-p` navigate; Enter accepts; Escape cancels. Arrow keys may be added
if supported by the normalized input layer. Ordinary `j` and `k` enter query text.
Confirm bindings and workspace-navigation precedence against 7A before wiring them.
For the initial milestone, opening is from the focused Normal-mode document, not
an arbitrary supporting tile whose execution target would be ambiguous.

Deferred: argument prompts, operator completion, command history/frecency,
semantic search, external fzf adapters, plugin registration, and searching files
or buffers. These should not block a usable command palette.

## Implementation stages

### Stage 1 — Add isolated catalog and matching (ready now)

1. Define catalog entries, stable IDs, context, and availability.
2. Register the initial command set and validate unique IDs.
3. Derive display shortcuts using public binding accessors where available. If a
   shared API addition is needed, defer its wiring and test against supplied binding
   descriptions; do not edit the keymap to unblock backend work.
4. Implement deterministic field-aware fuzzy matching.
5. Test realistic search queries and ranking rather than exact incidental scores.

Deliverable: headless query-to-ranked-command results. Prefer new modules and focused
tests; keep the pure matcher independent of screen, controller, and error libraries.
Catalog entries may reference existing editor/view action types. Feature metadata
can start in a new catalog module rather than editing every command-owner file.

### Stage 2 — Add palette state machine (ready after stage 1)

1. Implement query editing, paste policy, selection, acceptance, and cancellation.
2. Track selected command identity across filtering.
3. Accept an opaque invocation token and emit execution requests without effects.
4. Test availability with supplied context and target validation with a fake adapter;
   production target validation belongs to stage 3/4 assembly.

Deliverable: fully testable headless palette interaction. This stage can complete
before generic floating-window support lands.

### Stage 3 — Integrate shared execution (coordinated checkpoint)

Prerequisite: record the 7A APIs, integrate the agreed tiling checkpoint, and assign
one owner for controller/UI dispatch edits. Carry forward this branch's highlighting
behavior as well as the tile branch's shared feedback and cancellation behavior.

1. Trace the integrated controller and screen dispatch end to end.
2. Reuse the execution route or extract only the missing typed-action entry point.
3. Make keyboard and palette execution converge, preserving effects and feedback.
4. Test keyboard/direct equivalence, retained save failures and matching recovery,
   view actions, clipboard/highlighting behavior, and stopping after Exit.

Deliverable: supported command execution without synthetic key presses or a second
feedback/host dispatch system. No speculative host refactor is part of this stage.

### Stage 4 — Integrate with the generic host

Prerequisites: stage 3, integrated 7A routing and 7B shell contracts, and an agreed
placement mode. 7C is needed only if text-inspection/copy capabilities are included.

1. Finalize remaining adapter policies and reuse the generic host demonstrated by
   the tiles worktree's unrelated static list/report fixture. Do not copy its
   problems-specific prototype capture/navigation implementation.
2. Add `Space c c` and the open-palette routing action.
3. Render query, ranked rows, selection, and shortcuts inside shared shell content
   geometry; reuse shared viewport/selection primitives as appropriate.
4. Connect input capture, paste routing, close/restore, and shared dispatch.
5. Handle tiny rectangles and resize without exceptions or leaked document input.

Deliverable: usable command palette in the terminal editor.

### Stage 5 — Verify and document

1. Run the relevant focused tests, then `dune build` and `dune runtest` using the
   OxCaml switch documented in `README.md`.
2. Add a terminal smoke scenario following existing scripts once UI integration
   exists: open, search, accept, reopen, and cancel.
3. Update `README.md` keys and explain keyword search and command availability.
4. Document how a new feature registers a command without copying execution logic
   or manually maintaining shortcut labels.

## Acceptance criteria

- `Space c c` opens the palette from Normal mode.
- `rel num`, `rln`, and `gutter relative` find the relative-number toggle.
- Enter executes the selected command once against the invoking view.
- Escape leaves document contents and view preferences unchanged.
- Query typing and pasting never insert into the document or trigger its bindings.
- Empty queries show a stable list; no-result acceptance is a no-op.
- Matching and selection are deterministic and testable without a terminal.
- Selection remains valid after filtering and resizing.
- Displayed shortcuts reflect active bindings rather than duplicated defaults.
- Palette save/quit/undo behavior follows the same effects and feedback paths as
  keyboard invocation; ordinary quit still respects unsaved changes.
- Line-number toggles do not change text, undo history, or dirty state.
- Unavailable commands or stale targets cannot dispatch silently.
- No external fzf installation is needed.
- Generic host code does not depend on command metadata or matching rules.
- Palette integration reuses 7A focus/capture, paste start-owner routing, pending
  cancellation, cursor ownership, and 7B shell geometry; no parallel implementation
  of these exists in palette modules.
- Escape does not leak into document acknowledgement/search behavior. Query changes
  and hide/zen/resize do not resolve or acknowledge existing problems.
- Regression checks include coexisting document/status/problems views, focus return,
  a paste interrupted by a visibility transition, and nonzero content origins.
- Floating presentation is marked complete only when supplied by the agreed host;
  a headless or docked intermediate milestone is reported accurately.

## Suggested work allocation

For agents reviewing or implementing this plan:

1. **Palette backend now:** catalog, matcher, query state, command-key reconciliation,
   supplied-context availability, and headless tests (stages 1–2).
2. **Tiles workstream:** 7A host/routing and shared interactions, 7B shell/geometry,
   and optional 7C read-only text capabilities. Palette work supplies concrete input
   requirements but does not implement those foundations independently.
3. **Named integration owner later:** stage 3 shared execution and stage 4 palette
   adapter, binding, rendering, and cross-feature regression tests on an agreed base.

### Collision-prone files and ownership

Until that integration checkpoint, palette agents should avoid runtime edits to:

- `screen/ui_state.ml`/`.mli`, `screen/workspace.ml`/`.mli`, and `screen/frame.ml`/`.mli`.
- `input/keymap.ml`/`.mli`, `input/view_command.ml`/`.mli`, and `input/bindings.ml`/`.mli`.
- `app/controller.ml`/`.mli`, `core/editor.ml`/`.mli`, and shared feedback modules.
- `ui/editor_view.ml`, shared theme/style/shell code, and `scripts/smoke.sh`.

These are integration surfaces actively touched by tiles, not places to stage
temporary palette plumbing. Coordinate small Dune/test-stanza changes; isolate new
backend modules/tests in a dedicated library/directory if consistent with the build.
Any necessary shared-file exception should have an explicit owner and small agreed
patch, rather than two independently refactored versions.

Each handoff should record the checkpoint/API it used, files touched, checks run,
and unresolved integration requirements. New user-facing interactions also receive
the tiles plan's software-complete/human-feedback-pending handoff. Headless backend
work can be software-verified without waiting for UI human acceptance.

The next implementation assignment is **stage 1, then stage 2**. Do not begin with
the old dispatch-first sequence. The feature is complete only after host integration;
headless completion is a useful, independently deliverable intermediate milestone.
