# Ches command palette implementation plan

Status: stages 1–5 software-complete (docked milestone; floating presentation is later
work). Human feedback on the terminal UI is pending. Stage 3, the host extensions,
stage 4, and the word-delete follow-up are uncommitted.
The tiling system (7A–7C, 8, diagnostic sources) is merged into `oxcaml` (`ef77f9a`)
and this branch (`4ccde73`). See
[Progress](#progress) and
[Tiling status and integration blockers](#tiling-status-and-integration-blockers-2026-10-06).

## Progress

### Stage 1 — catalog and matching: done (2026-10-05, commit `0a80828`)

New library `ches_palette` in `palette/` (depends on `ches_core`, `ches_input`,
`core` only), with headless tests in `palette/test/` (`ches_palette_test`). No
shared or collision-prone file was edited; `test/dune` is untouched.

- `palette/fuzzy.ml(i)`: pure field-aware matcher depending only on `Core`.
  Ordered-subsequence matching per whitespace-separated token; every token must
  match some field. Scoring is modelled on fzf's algorithm (simplified constants:
  16 per character, word-boundary/camel/consecutive bonuses, affine gap penalty,
  doubled first-character bonus, whole-field bonus). Field weights scale scores;
  ties keep input order. ASCII-only case folding; malformed UTF-8 decodes as
  U+FFFD. Positions are byte offsets at code-point starts, per field.
- **Minimum-quality cutoff (owner decision, 2026-10-06: keep 50%).** A token's
  match in a field counts only if it scores at least 50% of the token appearing
  contiguously at a word boundary (`min_quality` in `fuzzy.ml`). Drops letters
  scattered through unrelated words (`abs` in "relative numbers", `rel num` in
  "Narrow document tile…") while keeping initials (`rln`), letters skipped within a
  word (`tgl` → "Toggle"), contiguous runs inside a word (`save` in "unsaved"), and
  any single character. Real fzf has no such cutoff; this is a deliberate
  difference. Known borderline survivor: `numb` → "Narrow document tile by…" (~72%).
- `palette/catalog.ml(i)`: `Id`, `Context` (`{ mode }`), `Entry` (ID, title,
  optional description, keywords, `Keymap.Action.t`, availability defaulting to
  Normal mode only), validated `create` (malformed/duplicate IDs, empty titles),
  `default` (16 entries at stage 1: 5 editor, 11 view; 33 since stage 4), `find`, `search` (title 100 > ID 80 > each keyword 70,
  available entries only), `title_positions` (empty when only ID/keywords matched).
- The default catalog has save, quit, force quit, undo, redo, and the view commands
  common to this branch and tiles before the merge (line numbers, centered, smear,
  reset, shift ±2/±10, width ±10). Stage 4 added the merged view commands (status
  toggle/position/size, zen, problems, history, demo report, source restart).
- `palette/shortcut.ml(i)`: derives hints such as `Space v N` from supplied
  `(Key.t list * Bindings.Target.t)` pairs; only `Editor`/`View` targets count.
  Wired in stage 4 through `Bindings.to_list` and `Keymap.bindings`. Originally
  not wired: `Bindings` exposed no table accessor, and `input/bindings.ml`
  is a collision surface, so tests supply a copy of the default table. At
  integration, add an accessor (e.g. `Bindings.to_list`) and pass it through.

### Stage 2 — palette state machine: done (2026-10-06, commit `d342f31`)

- `palette/palette.ml(i)`: `create catalog context ~token` (opaque `'token` names
  the invoking target); `update : 'token t -> Event.t -> 'token t` for `Insert`,
  `Paste`, `Backspace`, `Next`, `Previous`. Because `update` returns only state, query
  edits and navigation cannot execute by construction.
- `accept t ~context` takes the target's *current* context (`None` if the target is
  gone) and returns `Execute { token; id; action }`, `No_selection` (stay open, no-op),
  `Target_gone token`, or `Unavailable { token; id }` (both: close without
  dispatch and report). Cancel has no function: the adapter discards the palette and
  restores focus from `token`.
- Selection is by ID: kept while it still matches, otherwise the best match; none
  when empty; Next/Previous clamp.
- Query policy: single line of valid UTF-8. CR LF, LF, CR, and tab become a space;
  other C0/DEL/C1 controls are dropped; malformed UTF-8 becomes U+FFFD; Backspace
  removes one code point. Typed and pasted text share this sanitizing.
- Tests use a fake adapter (tokens are view numbers mapped to their current mode)
  for target-gone and availability rechecks.

Not done in stage 2, by design: key-to-event mapping (`Ctrl-n`/`Ctrl-p`, Enter,
Escape) awaits 7A binding/precedence confirmation; the palette's own small
selection policy should adopt tiles' shared list navigation (`tile/navigation.ml`
in the tiles worktree) at integration; hidden-palette query retention and
workspace-shortcut coexistence remain open adapter policies.

Checks: `dune build` and `dune runtest` pass on the OxCaml switch.

### Stage 3 — shared execution: done (2026-10-06, uncommitted)

Traced keyboard execution end to end: `Ui_state.feed` → `Controller.handle_input` →
`Keymap.feed` → private `perform_all` (editor dispatch, effects, feedback) →
highlighting update and `Exit` close → view commands back to `Ui_state`. `perform_all`
already took `Keymap.Action.t list`, so only the entry point was missing.

- `app/controller.ml(i)`: new `Controller.dispatch : t -> Keymap.Action.t list ->
  t * View_command.t list * Status.t`. `handle_input` and `dispatch` share one private
  `run` (editor commands, effects, `Command_completed` clearing, save/reload problem
  identity, clipboard and save hand-off, highlighting with reload reset, `Exit` cutoff
  and close). `handle_input` keeps the keymap feed and the idle-Escape `Acknowledge`.
  `dispatch` leaves the keymap alone and never acknowledges.
  `last_input_dispatched` now covers both routes.
- `screen/ui_state.ml`: `feed`'s tail is extracted as the private `finish_step`
  (applies view commands in order, then one notification). A keymap notice is passed
  only by the keyed route, so a palette dispatch never re-posts a stale keymap notice.
  Behavior of `feed` is unchanged. Stage 4's accept path calls `Controller.dispatch` then
  `finish_step`, inside `apply_running`'s Key branch so refit, animation and `exited`
  bookkeeping apply as for keys. No public `Ui_state` dispatch was added, since it would
  bypass that bookkeeping.
- Tests (`test/test_controller.ml`, `test/test_highlighting.ml`):
  - Key/dispatch equivalence: whole observable state, including file on disk, for
    save, undo, undo+redo, yank (clipboard), dirty quit refusal, force quit, and a
    view command.
  - A dispatched save failure is retained across another dispatch, and dispatching
    `Clear_search_highlight` does not acknowledge it; a matching save resolves it.
  - Dispatch stops at `Exit` (later actions neither run nor return) and keeps a
    pending keymap prefix.
  - Highlights stay current through dispatched undo/redo/reload, and a reload reparses.

Decided here: `dispatch` does not cancel a pending prefix itself; the adapter calls
`cancel_pending` on open, as the cross-worktree contract says.

Checks: `dune build` and `dune runtest` pass on the OxCaml switch.

### Stage 4 — host integration: done, docked (2026-10-06, uncommitted)

- **Input.** `View_command.Open_palette`, bound to `Space c c` (`input/bindings.ml`,
  documented in `input/keymap.mli`). `Bindings.to_list` and `Keymap.bindings` expose
  the active table for shortcut hints. `screen` now depends on `ches_palette`.
- **Adapter** `screen/palette_tile.ml(i)` (`Palette_tile`, view `palette`,
  `Spec.text_input` titled "Commands"): wraps `Palette.t` with the document's
  `View_id` as token. It keeps a `Navigation.Selection` only for the viewport `top`;
  the palette's selected ID stays authoritative (`fit` feeds it in). Keys: characters
  (Space, `j`, `k` included) insert, Backspace, Ctrl-n/Ctrl-p, Enter accepts; Escape,
  Tab, and Ctrl-c are the host's. Rows: `> query` prompt, then one result per row with
  a `> ` selection marker, matched title letters in `Pending`, and the first bound
  shortcut right-aligned in `Stale`, dropped when the title would not fit. The query
  keeps its end visible with a `<` marker. Cursor: a bar after the query on row 0,
  always inside the content. Footer: `i/n | Enter run, Ctrl-n/p, Esc`, or the host notice.
- **`Ui_state`.** `palette : Palette_tile.t option`; the palette is open only while
  focused. It goes first in the minor list, so it gets a slot whenever the band
  exists. `open_palette` refuses in Insert/Visual and in zen, and in a layout with no
  band (notice in each case). Opening from another minor view leaves that view: with
  one document the target is unambiguous. `leave` closes it and discards the query,
  so Escape, Tab, a focus change, or the band disappearing (resize, zen) all close it
  without running anything. `route` sends keys to `feed_palette`. Accept closes first
  (`return_to_document`), then `Controller.dispatch` and `finish_step` with no keymap
  notice, returning the controller status so a palette quit exits. `No_selection`
  stays open with a footer notice; `Unavailable` and `Target_gone` close and report.
  `cursor_intent` and `paste_capture` have palette branches.
- **Adapter policies settled.** A hidden palette discards its query. A paste whose
  palette closes before it ends is dropped with "Commands closed; paste dropped".
  Workspace shortcuts: Escape first, then Space (the leader is query text).
- **Frame** renders it via `Palette_tile.render`.
- **Word delete (follow-up).** `Palette.Event.Delete_word` (trailing spaces, then the
  word, as readline's Ctrl-w) on Ctrl-w and Ctrl-h. `ui/terminal_input.ml` now reports
  Ctrl-Backspace (notty's reading of `^H`, what most terminals send) as `Ctrl 'h'`
  instead of `Backspace`. The keymap treats `Ctrl 'h'` as Backspace in Insert mode
  and in the `:` and search prompts, so the editor behaves as before. A terminal that
  sends Ctrl-Backspace as plain `^?` or as an extended-key sequence gives Backspace or
  nothing; Ctrl-w works everywhere.
- **Tests.** `screen/test/test_palette_tile.ml` covers:
  - opening, rendering, and the bar cursor;
  - typed Space/`j`/`k` as query text, with Enter running once on the document and the
    text, dirty state, and cursor unchanged;
  - the acceptance queries (`rel num`, `rln`, `gutter relative`, `rnu`);
  - Ctrl-n/p and filtering keeping the selection;
  - Escape leaving search, prefs, and problem attention unchanged, and reopening fresh;
  - no-match Enter, Ctrl-c, and Tab;
  - paste into the query, and a paste interrupted by the band disappearing;
  - resize keeping query and selection;
  - undo, refused dirty quit, focus problems, and forced quit (exit) through the palette;
  - zen and compact refusals, the full band, and bounded rendering from 80x4 to 120x40.

  Palette backend tests were updated for the larger catalog; the no-match test now
  types `###`, since `z` matches "Toggle zen mode".
- **Smoke.** `scripts/smoke.sh` section "command palette (Space c c)": open, search,
  accept, Escape cancel, bracketed paste, undo via palette, quit via palette, and the
  file's bytes. It passes. The rest of the smoke run also passed.
- **README.** `Space c c` key row and a "Command palette" section, including how to
  add a command.

Not done: floating presentation (docked only, as decided); description lines
(`Entry.description` is unused); arrow keys (the normalized key type has none).
`rel num` also lists *Toggle problems filter (workspace / current document)* second, a weak
fuzzy match that passes the 50% cutoff; retuning is left to the matcher owner.

Checks: `dune build` and `dune runtest` pass on the OxCaml switch; smoke passes.

## Tiling status and integration blockers (2026-10-06)

The tiling work is merged: `oxcaml` at `ef77f9a` ("Feature: Tilling System") and
this branch at `4ccde73`, 0 behind `oxcaml`. The separate `../tiles/` worktree and
its uncommitted state are no longer the reference; read the code in this checkout.
The design doc is now `docs/workspace_tiles_design.md`. `dune build` and
`dune runtest` pass after the merge. The host extensions are written up in the shared doc
[Tile host extensions for the command palette](https://claude.ai/code/artifact/108bae1c-4291-47fe-aec0-ebc01949ae8a).

| Phase | State |
| --- | --- |
| 7A generic host/routing | Merged (`tile/`, library `ches_tile`); human-accepted 2026-10-05 |
| 7B shared shell, padding, gaps, 10-row band | Merged; human-accepted 2026-10-06; open look (frames on the backdrop) |
| 7C read-only text cursor/selection/copy | Merged (`tile/text_view.ml`); human-accepted 2026-10-06; not a palette prerequisite |
| 8 notification history tile | Merged; human-accepted 2026-10-06 |
| Diagnostic sources (synthetic checker, LSP) | Merged (`source/`) |

Also merged and useful here: `Keymap.reset` and `Keymap.lookup` (workspace-only
routing without feeding editor input), `Controller.cancel_pending`, and the shared
`Ches_error.Error` feedback lifecycle. `Space c` has no binding (`Space v c` is
Toggle centered), so `Space c c` is free.

### What the host provides for the palette

- `Ches_tile.View_id.t`: opaque, string-backed view identity. Use it as the
  palette's `'token`; do not define another target ID.
- `Ches_tile.Spec.t`: role plus `focusable`, `accepts_paste`, `owns_cursor`.
  Constructors are `primary`, `read_only`, `read_only_text` (7C) and `companion`;
  none fits the palette (Minor + focusable + accepts paste + owns cursor + takes
  text), so Extension 1 adds one.
- `Host.key` precedence for a captured view: Escape cancels a pending prefix, then
  takes the content's `escape` action, then returns; Ctrl-c gives a notice; Tab
  returns; other keys go to `content : Key.t list -> 'action Content_key.t`. For the
  palette, Escape with no `escape` action is cancel (return), as intended.
- `Host.paste_start`/`paste_key`/`paste_end` already give a paste to its start
  owner when that view accepts paste; only delivery is missing (Extension 3).
- `Navigation.Selection` (`fit`/`select`/`move`, with a viewport `top`). Its
  reconciliation picks the item at the previous index when the key disappears;
  the palette's policy picks the best match. Apply the palette's choice through
  `Selection.select` and use the shared type for viewport `top`, keeping one
  authoritative selection. `Navigation.interpret` binds `j`/`k`/`G`, which must
  stay query text in the palette, so the palette maps its own keys.
- `Tile_shell.layout` / `Ui_state.minor_layout`: the content rectangle the query
  row and result rows render into.
- Not used: `Text_view` (the query is editable, not read-only text).

### Host extensions (originally blockers; done 2026-10-06, uncommitted)

1. **Space cannot be query text.** In `tile/host.ml`, `Host.key` matches
   `_, [] when Key.equal key t.leader -> prefix [ key ]` before the content
   branch, so Space always starts a workspace sequence in a captured view. Proposal:
   `Spec.t` gains `accepts_text` (false in existing constructors), a new
   `Spec.text_input` constructor sets it, and `Host.key` sends the leader to content
   when `(spec t t.focus).accepts_text`. Escape, Ctrl-c and Tab keep their precedence.
2. **Cursor only for `Text_view`.** Since 7C a minor view can own the terminal
   cursor, but `Ui_state.text_cursor` computes it only from `text_view t id`, and
   `screen/frame.ml` always draws it as `Block`. Proposal: the focused view's adapter
   supplies a cursor intent (row and column in `layout.content`, plus `Block` or
   `Bar`); `Text_view` views keep today's computation; clipping and the single
   `Host.cursor_owner` rule are unchanged. The palette reports row 0, the query's
   display width after its prompt, and `Bar`.
3. **Paste is not delivered to minor views.** In `screen/ui_state.ml`, a
   `` `Deliver (owner, _) `` for any owner other than the document becomes the notice
   "Paste is unsupported here". Proposal: route it to the owner's adapter, beside the
   per-view dispatch in `feed_capture`; the palette sanitizes the text itself. If the
   owner is unavailable when the paste ends, drop it with a notice and never
   redirect it.

All three are small changes in tiles-owned files; implement them there or as an
agreed patch, not as palette-side workarounds.

All three were still open after the merge and are now implemented as proposed:

1. **Leader as text.** `Spec.t` has `accepts_text` (false in `primary`, `read_only`,
   `read_only_text`, `companion`). New `Spec.text_input`: Minor, focusable, accepts
   paste and text, owns the cursor. `Host.key` starts a leader sequence only when the
   focused view does not accept text. Escape, Ctrl-c and Tab keep their precedence.
   Test: `tile/test/test_host.ml` "a text-input view takes the leader as text".
2. **Cursor intent.** New `Ches_tile.Cursor` (`{ row; column; shape = Block | Bar }`,
   relative to the content area). `Ui_state.text_cursor` is replaced by
   `Ui_state.minor_cursor`, which returns cell and shape. A private
   `cursor_intent` asks the view's adapter; `Text_view` views give today's block.
   Clipping to the content and the single `Host.cursor_owner` rule are unchanged.
   `Frame` draws the requested shape. The palette adds its branch to `cursor_intent`:
   row 0, the query's display width after the prompt, `Bar`. Existing cursor tests
   pass with the renamed accessor.
3. **Paste delivery.** `` `Deliver `` to a minor owner goes to the private
   `Ui_state.paste_capture`. If the owner is no longer allocated, the paste is dropped
   with "<title> closed; paste dropped" and never redirected. Otherwise the owner's
   adapter takes the text. No adapter accepts paste yet, so today's fallback is a
   "<title>: paste unsupported" notice; the palette adds its branch there and
   sanitizes the text. This path is unreachable until a `text_input` view exists, so
   its tests come with stage 4 (including a paste interrupted by a visibility change).

### Decisions (settled 2026-10-06: palette-side recommendations accepted)

| Question | Decision |
| --- | --- |
| Workspace keys from a text-input view | Escape first, then Space; no second leader chord (implemented by extension 1) |
| Band full | Put the palette first in the minor order while open, so opening never fails for width |
| Zen | Opening in zen gives a notice for the first milestone; revisit later |
| Floating overlay | First palette docks in the bottom band; floating stays recorded as later work |

Opening the palette needs no host change: `Space c c` can be a view command
handled in `Ui_state`, like `Focus_problems`.

### Ownership

The same owner now holds both the tiling and palette work, so the "one named owner
for controller/UI dispatch edits" condition is met on this branch. The host
extensions above can be made here as small, separately reviewable changes in
`tile/` and `screen/`, not as palette-side workarounds.

### Next steps

1. Human check of the palette in a real terminal (look, cursor shape, colors).
2. Remaining stage 5 item and later work: see Stage 4 progress.

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
- `tile/` (`ches_tile`): generic host, view specs, shared navigation, read-only text.
  `docs/workspace_tiles_design.md` is the merged tiling design.

### Tiling worktree baseline and dependencies

*Original 2026-10-05 baseline, kept for history; 7A–7C have since landed — see
[Tiling status and integration blockers](#tiling-status-and-integration-blockers-2026-10-06).*

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
- Reject a token's match in a field that scores below 50% of a contiguous
  word-boundary match, so scattered letters across unrelated words do not match.

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

### Stage 1 — Add isolated catalog and matching (done; see Progress)

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

### Stage 2 — Add palette state machine (done; see Progress)

1. Implement query editing, paste policy, selection, acceptance, and cancellation.
2. Track selected command identity across filtering.
3. Accept an opaque invocation token and emit execution requests without effects.
4. Test availability with supplied context and target validation with a fake adapter;
   production target validation belongs to stage 3/4 assembly.

Deliverable: fully testable headless palette interaction. This stage can complete
before generic floating-window support lands.

### Stage 3 — Integrate shared execution (done; see Progress)

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

### Stage 4 — Integrate with the generic host (done, docked; see Progress)

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

### Stage 5 — Verify and document (done; see Stage 4 progress)

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

Stages 1 and 2 are done, so the headless milestone is reached. The tiling work is
merged and one owner holds both workstreams, so the collision-prone list above no
longer gates work on this branch; keep edits to those files small and focused.
Stages 1–5 are done (docked milestone); human feedback on the terminal UI is pending.
