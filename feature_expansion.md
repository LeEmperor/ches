# Ches feature expansion — MVP1

**Status (2026-10-02):** phases 1–4B accepted by the owner after the checkpoint
below; no ergonomic corrections were requested. Next: phase 5.

## Purpose

Make single-file editing comfortable for someone accustomed to Vim. MVP0 is
complete; this is a new milestone, not additional MVP0 acceptance work.

The owner's first priorities are counted movement (`20j`, `20k`), familiar
Insert entry (`a`, `o`), and matching-delimiter navigation (`%`). The current
document layout and scrolling are satisfactory. Expand everyday editing before
adding workspace or language-tooling infrastructure.

Read alongside:

- [`mvp0_plan.md`](mvp0_plan.md): established architecture, cursor, text, history,
  and effect contracts, plus implementation-session conventions.
- [`README.md`](README.md): current behavior, build commands, and limitations.
- [`ches_editor_prototype_brief.md`](ches_editor_prototype_brief.md): long-term
  direction. Its future ideas are not requirements for this milestone.

This plan extends MVP0 contracts only where stated. Follow existing code naming
and organization rather than treating illustrative API names as mandatory.

## Instructions for implementation agents

- **Do not mutate Git state.** The owner manages Git. Do not run `git add`,
  `git rm`, `git commit`, `git push`, `git pull`, checkout/switch, branch creation
  or deletion, stash, reset, clean, restore, rebase, merge, tag, or any other
  Git command that changes the index, worktree, repository, or remotes. In
  particular, do not stage, delete through Git, commit, or push. Read-only
  `git status`, `git diff`, and `git log` are fine. Ordinary source edits needed
  for the assigned phase are expected; preserve unrelated user work.
- Implement only the assigned phase and demonstrably necessary prerequisites.
  Do not start the next phase because context or time appears available.
- Inspect applicable `AGENTS.md`, this plan's contracts, the assigned phase,
  and relevant interfaces before editing. Read implementation/tests selectively.
- Keep keys out of the editing core and terminal dependencies out of core/input.
- Preserve existing bindings, `jk`, soft tabs, bracketed paste, layout controls,
  text validation, and dirty/save semantics unless this plan explicitly changes
  them.
- Verify dependency APIs rather than guessing. Do not change storage or introduce
  an async framework as incidental feature work.
- Run the phase checks and report failures and unchecked behavior honestly.
- Do not commit or push at the end of a phase. Deliver a concise handoff instead.

## Session size and execution

Each numbered phase is intended for **one fresh implementation session within a
basic Opus 5.5-sized context window, without compaction**. This is a scope target,
not a guarantee about a particular model's capacity. Avoid loading the whole
repository, all tests, or dependency sources into context.

- Use the preceding handoff to locate relevant modules and outstanding issues.
- Read shared contracts once, then only the assigned phase and needed code.
- Keep one coherent feature boundary per session. Do not bundle adjacent phases.
- If investigation reveals substantially more work, split the phase into named
  checkpoints before continuing. Record the revised scope here.
- If context is becoming tight, stop at a coherent boundary and write a precise
  handoff. **Do not rely on compaction to finish the phase.** Incomplete checks
  or implementation must be explicitly identified.

Suggested assignment:

> Implement phase N of `feature_expansion.md`. Follow its scope and shared
> contracts. Do not mutate Git state, stage, commit, or push. Run its checks and
> provide a handoff. Stop before context compaction becomes necessary.

Handoff contents:

1. Implemented behavior and changed files/interfaces.
2. Commands run and results, including incomplete checks.
3. Decisions or deviations added to this plan.
4. Remaining work and exact prerequisites for the next session.

## Scope and priorities

| Delivery | Phases | Result |
| --- | --- | --- |
| Movement and Insert entry | 1–4 | Counts, words/lines, `a/A/I/o/O`, `%` |
| View controls | 4A–4B | Line-number styles; `Ctrl-e/y/d/u`, `zz/zt/zb` |
| Common edits | 5–7 | Operators, internal copy/paste, replacement and joining |
| Finding text | 8–10 | Character finds and document search |
| Selection and repetition | 11–13 | Visual selection, indentation, dot repeat |
| Acceptance | 14 | Reproducible, documented MVP1 |

Every phase should leave a buildable, usable editor. Phases 1–4B are the first
useful delivery and should be tried by the owner before proceeding further.
Phases 4A and 4B were added at the owner's request after phase 2; they keep the
numbering of later phases unchanged.

Deferred: full Vim compatibility, text objects (`iw`, `i"`, etc.), macros,
named/numbered registers, system clipboard integration, blockwise Visual mode,
regex search/substitution, `:` prompt, multiple files/panes, syntax highlighting,
LSP, runtime binding files, plugin/configuration languages, storage replacement,
CRLF/grapheme support, and viewport redesign beyond phases 4A–4B (soft wrap,
scroll margins, horizontal scroll commands, persisted view preferences). Safer file saving and external
modification detection remain separate follow-up work.

## Shared architectural and behavioral contracts

### Commands and bindings

The core receives semantic actions, never key strings. A counted movement has a
motion and count; opening a line is an editing command, not simulated `o` input.

Keep three concerns distinct:

1. **Default bindings:** centralized mappings from keys/sequences to semantic
   input actions. Alternative bindings can be supplied in code and tested.
2. **Input grammar:** counts, pending operators, argument characters, prefixes,
   cancellation, and prompt focus. This lives in `input/`, not core or renderer.
3. **Editing semantics:** motion resolution, ranges, mutations, registers,
   transactions, and repeatable changes. This lives in `core/`.

The grammar may recognize structural digits and sequence states; do not scatter
checks for `j`, `d`, or other default action keys through editor logic. A modest
typed binding configuration is enough. Validate ambiguous/duplicate bindings
with a clear configuration error rather than choosing silently. Runtime
configuration and arbitrary user-defined grammars are not required.

Keep pending counts/operators visible using the existing status mechanism.
Escape cancels the whole pending sequence without an edit. Invalid continuations
cancel with feedback and must not leak counts or operators into the next input.
Paste is literal text in Insert/prompt contexts and never a stream of commands.

Counts are positive, bounded integers (maximum 999,999). Reject overflow or an
excessive count with feedback and reset pending input; never wrap or allocate
based directly on a count. Operator and motion counts multiply, subject to the
same bound. `0` starts a line-start motion when no count is active; otherwise it
extends the count. Track whether a count was explicit: bare `G` and `1G` differ.
Commands that do not support counts reject them rather than ignoring them.

### Motions, cursor destinations, and ranges

Introduce a small pure motion layer instead of extending one large dispatch
match with duplicated traversal logic. Preserve byte-offset/code-point contracts
and preferred-column behavior from MVP0.

A motion must provide enough information to distinguish a cursor destination
from an operator range: characterwise versus linewise, inclusive versus
exclusive, direction, and failure. Use validated half-open byte ranges for actual
edits. Normal-mode cursor normalization must not lose the inclusive last
character of a range.

Define and test range behavior before exposing operators. In particular:

- `$`, `e`, and a successful `%` include the destination character for operators.
- `w` normally excludes the next word's first character. For `dw`, when that
  destination is on a later line and the current line has text remaining, stop
  at the current line end instead of consuming its newline/next-line indentation.
- On nonblank text, `cw` changes through the end of the current word, preserving
  following whitespace. On whitespace it uses the ordinary `w` range.
- Vertical and absolute-line motions are linewise under operators.
- Failed target searches (`%`, later `f/t`, document search) do not mutate text
  or registers. Boundary-clamped ordinary movement can resolve an empty range.
- Linewise deletion handles the last line without a final LF and leaves one
  empty logical line when deleting the whole document.

Before phase 5 implementation, record concrete examples for ambiguous newline
and backward-motion cases. Prefer familiar Vim behavior for supported commands;
document deliberate simplifications rather than claiming full compatibility.

### Words and delimiters

Small words use three classes: whitespace, identifier characters, and
punctuation. Initially identifiers are ASCII letters/digits/underscore plus
non-ASCII code points; whitespace is space, TAB, and LF. This deliberately avoids
adding Unicode property dependencies. `W/B/E` use non-whitespace runs. Preserve
valid UTF-8 boundaries and test empty lines and document ends.

`%` matches **delimiters**: `()`, `[]`, and `{}`. Find the first delimiter at or
after the cursor on the current line, then search in the appropriate direction
for its properly nested mate, across lines. Use a stack for mixed delimiter
types; mismatched nesting or an absent mate produces feedback and no movement.
No delimiter on the current line is also a no-op with feedback.

This first version is lexical: delimiters in strings/comments count too. Syntax
awareness and Vim's count-as-percentage form (`50%`) are deferred; reject a count
on `%` explicitly. A successful operator with `%` includes both delimiters when
starting on one; from before one, its range starts at the original cursor.

### History, registers, and repeat

- Counted edits and whole operator applications are each one undo transaction.
- `o/O`, `cc`, and `c{motion}` start a transaction before their initial mutation;
  subsequent Insert typing belongs to it until the usual closing boundary.
- Cursor-only movement, search, selection changes, and yanking add no undo step.
- Use one unnamed internal register with characterwise/linewise kind. Delete,
  change, and yank populate it; paste does not overwrite it. Empty/failed
  operations do not destroy its contents. Undo restores text/cursor, not registers.
- Preserve exact final-newline behavior except where the requested edit
  necessarily inserts/removes a newline. Specify linewise paste at EOF in tests.
- Plan dot repeat around a semantic change record, not physical key replay.
  Include inserted text and meaningful Insert edits. Movement, yanking, search,
  undo, and redo do not replace the last repeatable change; failed/no-op edits
  do not replace it either. Defer implementation until phase 13.

### Verification and documentation

For each phase run `dune build` and `dune runtest` in the documented OxCaml
switch. Add focused behavioral tests, including direct core commands and key
sequences where relevant. Update README bindings and supported limitations as
features land. Extend and run `scripts/smoke.sh` for new terminal interactions;
headless tests should cover semantic edge cases instead of duplicating all of
them in tmux. Retain the existing smoke checks.

## Phase 1 — Counted movement and configurable default bindings

**Goal:** `20j` and `20k` work, with keys still independent of editing behavior.

Work:
- Add counted `h/j/k/l` semantics to core commands, clamped at boundaries.
- Introduce explicit count/prefix input state and the small in-code binding
  configuration described above; migrate existing defaults without changing them.
- Show pending digits; implement Escape, invalid continuation, and overflow
  handling. Reserve `0` for phase 2's line-start motion when no count is active.
- Resolve a counted command as one semantic action, not a list of thousands of
  single-step commands. Avoid work proportional to counts beyond document bounds.

Acceptance:
- `20j`, `20k`, `5h`, and `5l`; short lines preserve preferred vertical column.
- Counts clamp on tiny files and cannot overflow; cancellation does not leak.
- An alternate binding invokes counted movement without changing core code.
- Existing leader sequences, Insert text, `jk`, paste, and layout controls pass.
- Build, tests, and extended movement smoke checks pass.

Stop before new word motions or editing commands.

**Done (2026-10-01).** Decisions and deviations recorded for later phases:

- Core: `Command.Move` is now `Move of { direction; count }`, and
  `Command.max_count = 999_999`. `Editor.dispatch` clamps counted moves at line
  and document boundaries with work bounded by the line/line count, and raises
  `Invalid_argument` for a count outside 1..`max_count` (like soft-tab widths);
  the keymap never produces one.
- Bindings: `input/bindings.ml` holds the validated Normal-mode table
  (`Bindings.create : (Key.t list * Target.t) list -> t Or_error.t`), carried in
  `Keymap.Config.normal`; `Bindings.default` is the MVP0 table. Targets are
  `Move direction` (takes a count), `Editor command` and `View command` (reject
  counts). `create` reports every problem: empty or duplicate sequences, a
  sequence that is a proper prefix of another, one starting with `1`–`9`, and
  any use of `Escape`/`Ctrl-c`. A sequence may start with `0`. Insert-mode keys
  stay fixed apart from the existing `tab` and `insert_escape` settings.
- Grammar: a count is only recognized before a sequence (`Space 3` is an
  unbound sequence). The keymap keeps `count : int option`, so phase 2 can pass
  explicit-versus-implicit counts to `G`/`gg`; for now an absent count becomes 1
  on `Move`. A bare `0` is looked up as a binding (none by default, so it is
  silently ignored like other unbound keys).
- Feedback: pending shows `20`, `3 Space`; notices are `3 z is not bound`,
  `x does not take a count`, and `Count is too large: the maximum is 999999`.
  Escape cancels silently. After an overflow rejection, further digits start a
  new count.

## Phase 2 — Word, line, and document motions

**Goal:** navigate source efficiently without repeated character steps.

Work:
- Extract/extend the pure motion layer with `w/b/e`, `W/B/E`, `0/^/$`, `gg/G`.
- Bind counts: `3w` repeats word motion; `20gg` and `20G` select line 20;
  bare `gg/G` select first/last line at first nonblank. Clamp line numbers.
- `$` with count N goes to the end of the Nth line including the current line;
  `0/^` reject counts. Preserve preferred-column rules for vertical movement.
- Establish motion metadata needed by later operator ranges without implementing
  operators yet.

Acceptance:
- Words, punctuation, underscores, TABs, multibyte text, empty lines, trailing LF,
  absent trailing LF, and both document boundaries.
- `0` versus `10j`, `gg` cancellation, and explicit versus implicit `G` counts.
- Motions change no text, dirty state, revision, or undo history.
- Build, tests, and navigation smoke checks pass.

**Done (2026-10-01).** Decisions and deviations recorded for later phases:

- Motion layer: `core/motion.ml` (`Motion.t`, `Motion.destination`,
  `Motion.kind`, `Motion.takes_count`, `Motion.keeps_preferred_column`).
  `Command.Move` is now `Move of { motion : Motion.t; count : int option }`;
  `None` means no count was typed. `Command.Direction` is gone. `h/j/k/l` are
  `Left/Right/Up/Down` motions. Added `Text_buffer.uchar_at` for classification.
- Metadata for phase 5: `Up/Down/First_line/Last_line` are linewise;
  `Word_end` and `Line_end` are characterwise inclusive; the rest exclusive.
  Motions do not fail yet; phase 4 must add failure (for `%`) to the result.
  The `dw`/`cw` special cases are not implemented; `destination` is a cursor
  destination only.
- Words: implemented as scans for the next/previous word start (or empty-line
  start) and the next word end, equivalent to Vim's `w/b/e` for cursor motion.
  `e` with no further word end stays at the last end reached (Vim moves to the
  end of the buffer and beeps). Counts repeat steps and stop at the text ends.
- Trailing LF: the empty line after a final LF is a real line in this editor, so
  bare `G` and `w` after the last word go there (Vim has no such line).
- `$` resets the preferred column to the last character's column; Vim's sticky
  end-of-line column (`curswant = MAXCOL`) is deferred.
- `0` is bound to `Line_start` and is a count digit only after another digit.
  `^` rejects counts in the keymap (`3^` → `^ does not take a count`); the
  editor raises `Invalid_argument` for a count on a motion that takes none.
- `gg` and `G` go to the first non-blank (Vim's `startofline`).
- Added after phase 3 at the owner's request: `_` (`First_nonblank_down`, linewise)
  and `g_` (`Last_nonblank`, inclusive). Both take a count N meaning the line N-1
  below, like `$`; on a blank line `g_` goes to the line start, as in Vim. Phase 5
  should include `d_`/`y_` (equivalent to `dd`/`yy`) and `dg_` in its range
  examples.

## Phase 3 — Familiar Insert entry and basic autoindent

**Goal:** `a/A/I/o/O` behave naturally.

Work:
- Add semantic Insert-entry positions: after cursor, line end, first nonblank.
- Add open-line-above/below commands, including empty files and EOF without LF.
- Copy the current line's leading spaces/TABs for `o/O`. Enter copies leading
  whitespace before the insertion point, bounded by the line's indentation.
- Keep autoindent literal and language-independent; no brace heuristics. Retain
  inserted indentation if the user exits without typing additional text.
- Reject counts on Insert-entry commands in this milestone; Vim's counted Insert
  repetition is deferred.

Acceptance:
- Each entry command at first/last character, on empty lines, and at file edges.
- `o/O` plus typing undo in one step, restoring the original text and cursor.
- Enter, `jk`, soft tabs, backspace, paste, redo, and saved-state recovery coexist.
- Build, tests, and Insert-entry smoke checks pass.

**Done (2026-10-01).** Decisions and deviations recorded for later phases:

- Core: `Command.Enter_insert` now carries a `Command.Insert_position.t`
  (`Before_cursor | After_cursor | Line_end | First_nonblank`); added
  `Open_line_below`, `Open_line_above`, and `Insert_newline`. Bindings: `i/a/A/I`
  and `o/O` are plain `Editor` targets, so the keymap already rejects counts
  (`3o` → `o does not take a count`).
- Open line inserts the LF plus the line's indentation as the first edit of the
  Insert transaction (via the existing `edit`), so undo removes the line and the
  typing after it in one step and restores the pre-`o` cursor. Phase 7's `cc`/`c`
  and phase 13's change records can reuse this "mutate, then stay in Insert"
  shape. `O` on the empty final line after a trailing LF inserts above it.
- Autoindent: Enter in Insert mode now sends `Insert_newline` instead of
  `Insert_text "\n"`. It copies the leading spaces/TABs before the cursor
  (`min(indent, cursor column)`); text after the cursor, including its leading
  blanks, moves to the new line unchanged (Vim strips those blanks; deferred).
  `Insert_text` stays literal, so pastes and an `"\n"` in tests do not indent.
  There is no autoindent on/off setting.
- `a` on an empty line inserts at the cursor; `I` on an all-blank line inserts at
  its end, consistent with `^`.

## Phase 4 — Matching-delimiter motion

**Goal:** `%` jumps between parentheses, brackets, and braces.

Work:
- Implement the lexical stack-based matching contract above as a pure motion.
- Bind `%`; retain inclusive range metadata for phase 5.
- Document behavior inside strings/comments and rejection of counted `%`.

Acceptance:
- Both directions, same-line and multiline nesting, mixed delimiter types,
  cursor before a delimiter, unmatched/misnested pairs, and no candidate.
- Multibyte text around pairs and large counts rejected without movement.
- No edit/history changes; cursor remains visible through existing scrolling.
- Build, tests, and a multiline `%` smoke case pass.

## Phase 4A — Line-number styles

**Goal:** line numbers can be turned off, or shown relative to the cursor line,
including the hybrid style: the cursor line shows its true number and every
other line its distance from the cursor (Vim's `number` + `relativenumber`).

Work:
- Add a line-number style to the screen layer's layout preferences
  (`Geometry.Prefs`), not to the editor: `Off`, `Absolute`, `Relative`
  (cursor line shows `0`), and `Hybrid`. Keep it terminal-independent and
  covered by headless tests.
- Model it as Vim's two independent switches: `Space v n` toggles absolute
  numbers and `Space v N` toggles relative numbers (neither = `Off`, both =
  `Hybrid`). Add them as view commands through the binding table; they take no
  count. Report the resulting style in the status line, like other layout
  feedback (`Line numbers: hybrid`). When the screen is too small for the
  gutter, say so as the width feedback does (`Line numbers: hybrid (no room)`).
- Default to `Hybrid` (owner's preference); `Space v r` resets to it. Like
  other layout preferences, the style lasts for the session only.
- Gutter width stays `max(3, digits(line_count))` + separator in every numbered
  style, so toggling between numbered styles or moving the cursor never shifts
  the text. `Off` removes the gutter entirely; the text width request is
  unchanged. When centered with room, the tile narrows and recenters, so the
  text moves about half a gutter left; in full width, or when the screen limits
  the centered width, the text viewport widens instead. Horizontal scroll stays
  fitted either way. The existing small-screen rule (border first, then gutter)
  still applies to numbered styles; with `Off`, the border's width requirement
  excludes the gutter (`2 + min_decorated_text_width`), so `Off` never drops a
  border that would otherwise fit.
- Store the style as the four-way variant and implement the two toggles as pure
  functions over it, so a 4×2 expect test covers every transition.
- Relative numbers are the absolute distance from the cursor line. In `Hybrid`,
  the cursor line's true number is left-aligned (as Vim does) and the others
  right-aligned; in `Relative`, the cursor line shows `0` right-aligned. Keep
  the existing cursor-line gutter styling.
- Numbers derive from the current cursor line at render time; no stored state
  needs updating on movement or edits. Rows past the end of the document keep a
  blank gutter.
- The new default changes every rendered gutter (about 35 smoke expectations
  plus frame and UI-state expect output). Regenerate expect output with
  `dune promote` and check the diff touches only gutter columns. Leave renders
  that are not about line numbers on the new default rather than pinning them
  to `Absolute`. Replace full `Prefs` record literals in tests with
  `{ Prefs.default with … }`.
- Update `rendering_design.md` (the `Space v` table and gutter description),
  the `geometry.mli` header, README bindings and layout section, and add a
  smoke review screen for a non-default style.

Acceptance:
- Every style and both toggles from every style, wide/narrow line counts
  (e.g. 9, 999, 1000, 120000 lines), cursor at first/last line, after edits that
  add or remove lines, and with the gutter dropped on tiny screens.
- `Off` on a screen just wide enough for a border without a gutter keeps the
  border; `Off` in full width widens the text viewport.
- Hybrid's left-aligned cursor-line number is shown on a review screen for the
  owner to judge.
- Toggling changes no text, cursor, history, or dirty state; the cursor stays
  visible and on the same text cell.
- `Space v r` restores `Hybrid` along with the other defaults; existing
  `Space v` behavior and smoke checks still pass (update expected gutter text
  for the new default).
- Build, tests, and line-number smoke checks (including review screens) pass.

Stop before scroll commands.

## Phase 4B — View scrolling commands

**Goal:** scroll the view without losing your place, as with Vim's `Ctrl-e`.

Work:
- `Ctrl-e`/`Ctrl-y` scroll the view down/up by one line, or by N with a count.
  The cursor stays on its line unless that line leaves the viewport; then it
  moves to the nearest visible line, keeping the preferred column.
- `Ctrl-d`/`Ctrl-u` scroll the view and move the cursor by half the text
  viewport height (at least 1 line). A count N scrolls N lines for that
  invocation only; Vim's persistent `'scroll'` setting is deferred.
- `zz`/`zt`/`zb` place the cursor line at the middle/top/bottom of the
  viewport without moving the cursor; they reject counts (Vim's `z<CR>`
  variants and counted forms are deferred).
- Scrolling is view state in `Ui_state`, which alone knows the viewport height.
  Add scroll view commands; the core stays unaware of the viewport. When the
  cursor must follow, `Ui_state` dispatches the existing semantic counted
  `Up`/`Down` move through the controller. Document this as the one deliberate
  exception to "view commands never touch the editor": it moves the cursor only,
  never text, history, or dirty state.
- Decide and document the end-of-file rule. Prefer Vim's: `Ctrl-e` may scroll
  until the last line is the top row, and later cursor movement that stays
  visible does not pull the view back. This changes the MVP0 fit rule that
  lowers `top` to avoid a partly empty viewport; restrict that rule (e.g. to
  resizes) and update `rendering_design.md` and the scroll tests accordingly.
- Clamp at both ends with feedback-free no-ops; bound work by line count, not
  count. With zero text rows, scroll commands change nothing.
- Normal mode only; in Insert mode `Ctrl-e`/`Ctrl-y` stay unbound (Vim's
  Insert-mode meanings are deferred). Bindings go through the binding table;
  the terminal adapter already delivers `Ctrl` + letter.

Acceptance:
- `Ctrl-e`/`Ctrl-y` with and without counts: cursor kept, cursor pushed by the
  top/bottom edge with preferred column preserved, both document ends, files
  shorter than the viewport, and huge counts.
- `Ctrl-d`/`Ctrl-u` at both ends; `zz/zt/zb` near both ends and with
  counts rejected.
- Resizing after scrolling keeps the cursor visible; horizontal scroll unchanged.
- No text, revision, history, or dirty changes; `Ctrl-r` redo and `Ctrl-c`
  hint unaffected.
- Build, tests, and scroll smoke checks (including tiny terminals) pass.

Decisions recorded during implementation:
- End of file: Vim's rule. `Ctrl-e` stops with the last line at the top; the old
  fill rule (lower `top` so the viewport is not partly empty) now applies only
  when the text rows differ from those of the last applied input, i.e. after a
  resize. Resizing away and back with no key in between redraws the view as it
  was.
- `Ctrl-d` stops scrolling once the last line is at the bottom (never scrolling
  back up) but keeps moving the cursor; at the top, `Ctrl-u` moves only the cursor.
- `zz` puts the cursor line on row `(rows - 1) / 2`; `zt` near the end may leave
  the view partly empty, as in Vim; `zb` near the start stops at line 1.
- Scroll commands are a `View_command.Scroll` with a count, bound through a
  `Scroll` binding target so the keymap applies their count rules; the cursor
  follows through `Controller.move`. They produce no message.
- `z` is now a prefix, so tests that used it as an unbound key use `q`.

**Owner checkpoint (passed 2026-10-02: phases 1–4B accepted, no corrections):**
try phases 1–4B on real source files. Record ergonomic
corrections before broadening scope.

## Phase 5 — Delete operator and range semantics

**Goal:** composable deletion with correct ranges and one-step undo.

### Range examples (settled before implementation)

Ranges are half-open byte ranges after motion resolution.  A forward exclusive
motion deletes `[cursor, destination)` and a backward exclusive motion deletes
`[destination, cursor)`; inclusive motions extend the appropriate end through
the destination code point.  Linewise motions expand from the first selected
line's start through the selected last line's LF, or EOF for the final line.

| Start (`|`) | Command | Result | Notes |
| --- | --- | --- | --- |
| `|one two` | `dw` | `two` | `w` is exclusive. |
| `one |two  ` | `de` | `one ` | `e` is inclusive. |
| `one |two` | `db` | `two` | backward exclusive range. |
| `|one\n  two` | `dw` | `\n  two` | crossing `w` stops at the first line end, preserving its LF and next indentation. |
| `one\n|two\nthree` | `dj` | `three` | vertical motions are linewise. |
| `one\ntwo|` | `dgg` | `` | absolute motions are linewise. |
| `(|x)` | `d%` | `` | `%` includes both delimiters when starting on one. |
| `one\n` | `dd` | `` | deleting all text leaves the editor's one empty logical line. |

`d_` and `dg_` are linewise (thus equivalent to `dd` from their current line
through their selected line).  A failed `%` leaves text and the register intact.

Work:
- Specify concrete range examples for all implemented motions, then implement
  the shared range resolver. Keep resolution separate from mutation.
- Add pending-operator input state and `d{motion}`, `dd`, `D`, counted `x`, `X`.
- Support multiplied counts (`2d3w`), doubled line operators (`3dd`), and Escape.
- Add the unnamed typed register; successful deletions populate it.
- Establish the semantic completed-edit boundary for later repeat recording.

Acceptance:
- `dw`, `db`, `de`, `d$`, `dj`, `dgg`, `dG`, `d%`, `dd`, and counted variants.
- Inclusive/exclusive and backward ranges, last-line deletion, whole-document
  deletion, failed matches, and cancellation without register changes.
- Each successful counted deletion is one undo step; redo and dirty recovery work.
- Build, tests, and representative operator smoke checks pass.

Stop before change/yank/paste. Split this phase at the range-resolver boundary
if semantic investigation threatens the session context budget.

**Done (2026-10-02).**

- `core/range.ml` resolves the existing motion metadata into half-open,
  characterwise or linewise ranges before `Editor` mutates text. The `dw`
  cross-line exception and inclusive `$`/`e`/`g_`/`%` endpoints live there.
- The core owns `Delete_motion`, `Delete_lines`, and counted forward/backward
  character deletes. `Register.t` is the typed unnamed register; only a
  successful nonempty delete overwrites it, and history deliberately does not
  restore it.
- The input grammar has a pending `d` state, supports doubled `dd`, `D`,
  `d{motion}`, `d_`/`dg_`, count multiplication with overflow rejection, and
  cancellation. Existing motion bindings remain the source of valid operator
  motions.
- `x` now accepts a count as required by this phase. `X` is added; both remain
  line-local. README and the terminal smoke script cover the new commands.

**Follow-up (2026-10-02, owner request):** Added the narrow `diw` text object
and `:e!` force reload. `diw` is intentionally limited to the small word under
the cursor (or next word from whitespace), rather than starting a general text
object framework. The command prompt accepts only `e!`; its reload is a core
effect performed by the controller, so failed reads leave the buffer untouched.
Successful reloads discard undo/redo history and unsaved buffer text.

## Phase 6 — Yank and paste

**Goal:** copy and move text within the document.

Work:
- Add `y{motion}`, `yy`, `p/P`, and counts using phase 5's range machinery.
- Characterwise paste goes after/before the cursor; linewise paste goes
  below/above the current line. A count repeats contents as one edit.
- Define cursor placement: last inserted code point for characterwise paste;
  first nonblank of the first inserted line for linewise paste.
- An empty register reports feedback. Check resulting size arithmetic before
  constructing repeated text; reject overflow cleanly.

Acceptance:
- `yy p`, `3yy P`, `yw p`, and deleting then pasting lines elsewhere.
- Empty lines, final LF/no LF, multibyte text, repeated paste, and register
  persistence across undo. Yanking preserves text/history and leaves cursor at
  the original position.
- Build, tests, and copy/paste smoke checks pass.

**Done (2026-10-02).**

- `y{motion}` and `yy` share the phase 5 resolver and typed unnamed register with
  deletion. Yanks preserve text, cursor, history, revision, and dirty state.
- `p`/`P` repeat characterwise or linewise register contents in one transaction,
  with checked size arithmetic, EOF newline handling, and the documented cursor
  destinations. An unset register reports `Nothing in register`.
- Core/keymap expect tests and the terminal smoke script cover yanking, counts,
  repeated paste, undo/register persistence, final-LF behavior, and the empty
  register feedback.

## Phase 7 — Change, replace, and join

**Goal:** replace text without manually deleting and entering Insert.

Work:
- Add `c{motion}`, `cc`, `C`, preserving the documented `cw` behavior.
- Linewise change leaves one replacement line, retaining its starting
  indentation; deletion and replacement typing share one transaction.
- Add `r{character}` with optional count; replace only within the current line,
  failing unchanged if insufficient characters remain. Escape cancels; newline
  replacement is deferred.
- Add `J`: join two lines by default, or N lines for a count N >= 2. Remove
  following-line leading whitespace and insert one separating space unless the
  preceding line is empty or already ends in whitespace. No sentence heuristics.

Acceptance:
- `cw`, `ci` as an unsupported continuation, `c$`, `cc`, `3cc`, `c%`, `r`, `3r`,
  and `J`; reject unsupported sequences without accidental edits.
- Change plus typing undoes together; empty replacement, autoindent, `jk`, and
  failed/canceled replacement preserve consistent state.
- Build, tests, and common-edit smoke checks pass.

## Phase 8 — Within-line character finds

**Goal:** precise local motion, also usable with operators.

Work:
- Add `f/F/t/T` plus one code-point argument and optional count.
- Search strictly beyond the cursor on the current line; `t/T` stop before the
  match. Add `;` to repeat and `,` to repeat in the opposite direction without
  changing the stored original direction.
- Ensure repeated till motions advance to a new target instead of finding the
  same adjacent character again. Failed finds retain the previous successful
  find; Escape cancels the pending argument.
- Integrate with operators through shared motion/range resolution.

Acceptance:
- Both directions, repeated targets, multibyte targets, counts, no match,
  `df)`, `ct,`, and repeated till motions.
- Argument characters are literal, including digits and action-binding keys.
- Build, tests, and representative find smoke checks pass.

**Done (2026-10-02), except for `ct,`:** `f/F/t/T` take literal Unicode
code-point arguments, stay on the current line, support counts, and are shared
motions for delete/yank ranges. `;` and `,` repeat the saved successful find;
`,` does not reverse the stored direction, and repeated `t/T` skips its prior
adjacent match. Escape cancels an argument and failures retain the old find.
The acceptance example `ct,` requires Phase 7's change operator, which remains
deferred at the owner's request; `dt,` has the same range behavior.

## Phase 9 — Search prompt and document search

**Goal:** find text anywhere in the current file.

Work:
- Add a small terminal-independent prompt model for `/` and `?`, with text,
  Backspace, paste, Enter acceptance, and Escape cancellation. Keep prompt focus
  separate from core Normal/Insert mode and keep query editing out of undo.
- Implement case-sensitive literal forward/backward search with one wrap.
  On Enter, find strictly beyond the original cursor, wrapping if needed.
- Search only on acceptance in this phase; live incremental preview is deferred.
- Empty Enter reuses the last accepted nonempty query; without one, show feedback.
- Add `n/N` and counts; report wrapped/not-found outcomes. A no-match accepted
  query becomes the repeat query but leaves the cursor unchanged.
- In this milestone search starts from Normal mode only, not operator-pending.

Acceptance:
- Prompt editing/paste/cancellation cannot insert document text or trigger `jk`.
- Both directions, wrap, no match, empty query, repeated query, multibyte matches,
  and a file with only one occurrence. Search preserves history and dirty state.
- Build, tests, and real prompt/search smoke checks pass, including tiny terminals.

**Implemented (2026-10-02).** `/` and `?` use a terminal-independent prompt with
literal text editing, paste, Backspace, Enter, and Escape. Searches are
case-sensitive, wrap once, and begin strictly past the cursor. Empty Enter
reuses the last query; `n` repeats its original direction and `N` reverses it.
Queries that do not match are retained for repetition without moving the cursor.

## Phase 10 — Search highlighting and word search

**Goal:** make search results easy to understand.

Work:
- Add `*`/`#` for whole-small-word search under the cursor; whitespace gives
  feedback without replacing the query. Retain whole-word matching on `n/N`.
- Highlight visible matches, distinguishing the current match. Convert byte
  ranges through existing cell mapping, including clipped TAB/wide characters.
- Keep highlighting derived from current text/query; never retain stale offsets
  after edits. Restrict display work to relevant visible content where practical.
- Normal-mode Escape clears search highlighting while retaining the repeat query;
  canceling a pending input sequence takes precedence.

Acceptance:
- Word boundaries, punctuation words, Unicode policy, edits after a search,
  horizontal clipping, and readable current-line/cursor styling.
- Match styling does not alter cell geometry or cursor position.
- Build, tests, and search-feedback smoke checks pass.

**Implemented (2026-10-02).** `*`/`#` start whole-small-word searches under
the cursor. Visible literal query matches are styled in the frame layer, with
the last accepted search destination distinguished as the current match. Match
locations are recomputed from the current buffer during rendering, including
through horizontal clipping and mapped TAB/wide-character glyphs. Normal-mode
Escape clears the visible highlights but keeps the repeat query.

**Follow-up (2026-10-02):** The search prompt now previews literal matches as
the query is typed, pasted, or erased, without moving the cursor. A
cursor-following `incsearch` behavior is intentionally deferred as a future
configurable option.

## Phase 11 — Characterwise and linewise Visual selection

**Goal:** select text visibly and use existing operators on it.

Work:
- Add core selection state for `v/V`, anchor and active endpoint; bindings belong
  in the input layer. Escape cancels without moving the active cursor.
- Support existing ordinary motions/counts and `%` to extend selections. Prompt
  search within Visual mode is deferred.
- Apply `d/c/y` to selected ranges through the shared range machinery. After yank,
  return to Normal at the start of the selected range; change enters Insert.
- Render selection through byte-to-cell mapping; define precedence over search
  and current-line styling while preserving a visible terminal cursor.

Acceptance:
- Forward/reversed selections, empty lines, newline inclusion, whole-document
  selection, wide characters, clipping, cancellation, and one-step undo.
- Switching `v/V` changes selection kind without losing the anchor.
- Build, tests, and Visual-mode smoke checks pass.

Stop before block selection, selection-specific paste, and text objects.

## Phase 12 — Indent and unindent

**Goal:** adjust blocks without retyping indentation.

Work:
- Add `>{motion}`/`<{motion}`, `>>/<<`, and `>/<` on Visual selections.
- Operate on touched logical lines; Normal counts select the number of lines
  for doubled operators. Visual counts repeat indentation depth.
- Use a configurable semantic indentation width (default two spaces), distinct
  from key spelling. Add spaces; unindent removes up to that many leading spaces,
  or one leading TAB when present. Leave empty lines empty.
- Each invocation is one undo step; exit Visual mode after applying it and place
  the cursor at first nonblank of the first affected line.

Acceptance:
- Mixed indentation, empty lines, counted line operations, reversed selections,
  clamped file edges, and no-op unindent preserving history.
- Build, tests, and indentation smoke checks pass.

## Phase 13 — Repeat last change

**Goal:** `.` repeats an edit semantically at the new location.

Work:
- Record and repeat Insert sessions, open-line edits, delete/change operators,
  replacement, paste, joining, and indentation using semantic change data.
- Preserve Insert editing operations such as Backspace/Delete and newline entry;
  exclude the temporary `j` removed by the `jk` escape. Do not replay raw keys.
- Capture pasted register contents in the change record, so later yanks do not
  silently alter what repeating that paste inserts.
- Dot is one undo step. An explicit count replaces the original effective count
  for countable edits; reject counted dot for changes without count semantics.
- Visual edits do not update the repeat record in this milestone. Document this
  limitation; ordinary `.` still repeats the previous supported change.

Acceptance:
- Change-word-and-type followed by movement and `.`, `o` plus typing and `.`,
  counted deletion, replacement, paste after a new yank, joining, and indentation.
- Insert sessions with `jk`, Backspace/Delete, paste, and autoindent; no-op/failed
  edits and undo/redo do not replace the repeat record.
- Build, tests, and repeat smoke checks pass.

If needed, split into 13A (recording and replaying Normal edits) and 13B (Insert
and change sessions), with a fresh session and explicit handoff between them.

## Phase 14 — Acceptance and documentation

**Goal:** finish the milestone as a reproducible, usable feature set.

Work:
- Run the full build, test suite, and extended terminal smoke script.
- Exercise realistic workflows: navigate a file with counts/words/`%`, open and
  append lines, change words, move/copy blocks, search, select, indent, repeat,
  undo/redo, save, quit, and reopen.
- Complete README bindings grouped by task, supported count behavior, lexical
  delimiter matching, word policy, internal register, and repeat limitations.
- Review architecture boundaries and verify alternate bindings still work without
  core changes. Record performance problems observed on ordinary source files;
  measure before proposing storage work.
- Request owner review of daily-use behavior. Report visual/manual checks not
  possible in the implementation environment rather than claiming them passed.

Acceptance:
- Build, tests, and smoke pass; existing MVP0 behavior remains covered.
- Owner can use the documented features on a real source file.
- No mutative Git commands, staging, commits, or pushes were performed.
- Remaining limitations and follow-up proposals are explicit.

MVP1 ends here. Expand the next milestone from real use rather than silently
adding full Vim compatibility or the original brief's future infrastructure.
