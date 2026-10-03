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
named/numbered registers, system clipboard integration, blockwise Visual mode
(now proposed as the post-MVP1 expansion below),
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
  end-of-line column (`curswant = MAXCOL`) is deferred. *(Superseded 2026-10-03:
  `$` is now sticky, as in Vim; see the column model decision below.)*
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

**Done (2026-10-02).** Visual state is owned by `Editor` as an anchor, active
endpoint, and characterwise/linewise kind. `v`/`V` enter or switch Visual mode;
ordinary motions, counts, and `%` extend it. `d`, `c`, and `y` act on the
resolved selection, with change entering Insert in the same transaction. The
frame maps selections to cells (including clipped and wide glyphs) with priority
over search highlighting, while retaining the terminal cursor.

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

## Proposed post-MVP1 expansion — blockwise Visual and block insert

**Status (2026-10-02): owner-requested proposal; not part of MVP1 acceptance.**

The desired workflow is Vim/Neovim's `Ctrl-v`, followed by motions to select a
rectangle and `I` to insert the same edit on every selected line. During block
insert, show the affected insertion points and apply typing to every line live,
rather than showing only one cursor and replicating the completed edit on exit.
This is a bounded block-insert feature, not authorization for a general
multi-cursor command system.

### Column model decision

A block is rectangular in visible columns, but the core currently addresses
text by byte offsets and code-point columns while `screen/Cell_map` computes
terminal display cells. These differ in ordinary source text:

- A TAB is one code point but can occupy one to eight display cells. For
  example, the `a` after a leading TAB is code-point column 1 but display column
  8 with the current tab stop.
- A wide character such as `界` is one code point but normally occupies two
  display cells, while a combining mark may occupy zero.
- A requested block column may lie beyond a short line's end, where there is no
  byte offset at all. Supporting that position requires a virtual column policy:
  skip the line, clamp to its end, or pad it with spaces when editing.
- A block edge can visually fall inside a TAB or wide glyph even though edits
  can occur only at code-point boundaries. The selection and edit policy must
  say whether to include the whole glyph, place the edge before/after it, or
  split/expand a TAB.

A cheaper implementation would use code-point columns and clamp each line with
`Text_buffer.offset_of_column`. It would be internally simple, but rectangles
would stop lining up on screen around TABs and wide characters and would likely
need semantic rework later.

**Status (2026-10-03): shared mapping extracted.** `core/cell_layout.ml` now
holds the glyph layout with an injected width function; `screen/Cell_map` is
that layout with Notty's widths, and `Editor.create` takes the same function
(`~cell_width`). The preferred column of `j`/`k` and soft-tab widths are display
columns, checked against Vim 9.1 for TABs, wide and combining characters, short
lines, and Insert-mode insertion points (`test/test_motion.ml`,
`test/test_editor.ml`, `test/test_cell_layout.ml`).

**Decision (owner, 2026-10-03): follow Vim for every open column question.** Sticky
`$` and the Visual-mode TAB rule below are implemented and tested; the rest are
the reference examples for Phases 15-17.

### Settled column semantics (Vim 9.1 reference)

Observed with `vim -Nu NONE` (default `tabstop=8`, `selection=inclusive`,
`virtualedit=`, empty `backspace`). Columns are zero-based display cells. In the
examples `·` is a space and `<T>` a TAB; "block 3-5" means a `Ctrl-v` selection of
display columns 3 to 5 inclusive.

**Preferred column (implemented).**
- `$` sets the preferred column to "end of line": later `j`/`k` go to each line's
  last character, through empty lines, until another move resets it. A count on
  `$` sticks too. `g_`, `A`, and every horizontal move do not stick.
- On a TAB the preferred column is the TAB's last cell in Normal mode, its first
  cell in Insert mode, and in Visual mode its first cell when the cursor is at or
  before the anchor (`\tab`: `l v h j` lands on column 0, `x\tab`: `v l j` on
  column 7). Entering Visual mode does not recompute it.

**Block bounds.** The block spans from the smallest first cell to the largest last
cell of its two corners, so a corner on a TAB or wide glyph covers the whole
glyph (anchor on a leading TAB, cursor below: block 0-7). Reversed and
upward/leftward blocks resolve to the same rectangle; `v`/`V`/`Ctrl-v` keep the
anchor. After `$` the block extends to every line's own end. In Visual mode `$`
puts the cursor on the line break, so `v$d` on `abc`/`def` leaves `def` (this
also changes characterwise Visual `$`; do it with Phase 15).

**Short lines** (block 3-5 over `abcdefgh` / `ab` / `abcdefgh`):

| Op | Result | Register |
|---|---|---|
| `d` | `abcgh` / `ab` / `abcgh` | `def`, `···`, `def` (block width 3) |
| `IXY` | `abcXYdefgh` / `ab` / `abcXYdefgh` (short line skipped) | |
| `AXY` | `abcdefXYgh` / `ab····XY` / `abcdefXYgh` (padded) | |
| `cXY` | `abcXYgh` / `ab` / `abcXYgh` | as `d` |

A line ending inside the block (block 2-5 over `abcd`) loses `cd` and yanks `cd`
unpadded; `A` pads it (`abcd··XY`). An empty line reaches column 0, so `I` from
column 0 inserts on it. With `$` (block from column 1 over `abcdefgh` / `ab` /
`abcd`): `d` leaves `a` on each line and yanks `bcdefgh`, `b`, `bcd` (width 7,
ragged); `AXY` appends at each end; `IX` gives `aXbcdefgh` / `aXb` / `aXbcd`.

**Block paste.** Row *i* goes to the same display column on the *i*th line from
the cursor. Lines shorter than that column are padded with spaces; lines past
the end of the document are appended (`abcd`/`efgh`, yank block `ab`/`ef`, `jp`
gives `eabfgh` / `·ef`). When text follows the insertion point every row is
padded to the block width, `$` registers included (`xyb······z`); at a line end
no trailing padding is added. A count repeats each row horizontally (`2p` gives
`xababyz`).

**Edges inside a TAB** (TAB at 0-7 on the middle line of `0123456789ab` /
`<T>abc` / `0123456789ab`): the TAB is split into spaces, keeping the cells
outside the block.

| Op | Middle line | Register row |
|---|---|---|
| `d`, block 2-4 | `·····abc` | `···` |
| `d`, block 6-9 | `······c` | `··ab` |
| `IX` at 2 | `··X······abc` | |
| `AX` after 4 | `·····X···abc` | |
| `cX`, block 2-4 | `··X···abc` | `···` |
| `p` of `zw` at 4 | `····zw····abc` | |

A block starting at column 0 or 8 leaves the TAB intact (`X<T>abc`, `<T>Xabc`).

**Edges inside a wide glyph** (`界` at 1-2 on the middle line of `abcdef` /
`a界bcd` / `abcdef`): a glyph cut by a block edge leaves a space for its uncovered
half. `d` of block 2-3 gives `a·cd` and yanks `·b`; block 0-1 gives `·bcd` and
yanks `a·`. Inserting at column 2 (`I`, `A` after column 1, or `p`) pads to the
column and moves the glyph right whole: `a·X界bcd`, `a·zw界b`. Combining marks
stay with their base character.

**Block insert.**
- After `d`, `y`, `c`, `I`, `A`, or `p` the cursor is at the block's top-left.
- A count repeats the inserted text (`2IX` gives `XXabc`).
- Escape with nothing typed changes nothing and records no undo step.
- Backspace within the text typed in this session removes it from every line
  (Vim's result for `IXYZ<BS>` is `XY` on each line). At the insertion column it
  does nothing, as with Vim's default empty `backspace`.
- Enter: Vim abandons the replication and only the first line keeps the edit
  (`IX<CR>Y` gives `abX` / `Ycdefgh` / `abcdefgh`). The live equivalent is to
  remove the replicated copies on Enter and continue as an ordinary Insert on the
  first line; decide at Phase 17 whether that or rejecting Enter is preferable.
- Replicating live while typing (rather than on Escape, as Vim does) remains the
  owner-requested deviation.

**Preferred target:** use display-cell columns with behavior close to
Vim/Neovim. Before implementation, settle examples against Neovim for TABs,
wide and combining characters, short lines, reversed selections, `I`/`A`, and
Backspace. Extract or introduce a shared, terminal-independent mapping between
line byte boundaries and display columns so editing semantics and
`screen/Cell_map` cannot disagree; the core must not acquire a Bonsai or
terminal dependency. If that extraction proves disproportionate, stop at the
checkpoint and explicitly approve code-point semantics rather than introducing
them as an undocumented shortcut.

### Phase 15 — Blockwise Visual selection

**Goal:** `Ctrl-v` creates and visibly extends a rectangular selection.

Work:
- Extend Visual selection kind and mode labels with `Blockwise`; bind `Ctrl-v`
  through the existing configurable binding path. The terminal adapter already
  represents Ctrl-letter keys.
- Preserve an anchor and active endpoint plus the selected column bounds under
  ordinary supported motions and counts. Switching among `v`, `V`, and
  `Ctrl-v` keeps the anchor.
- Resolve a block to one range per touched logical line. Keep this separate from
  mutation and order the ranges so callers can edit safely despite shifting byte
  offsets.
- Render rectangular selection by display cells, including horizontal clipping,
  TABs, wide/zero-width characters, empty lines, and the selected empty area of
  short lines when the settled virtual-column policy calls for it.
- Keep one real terminal cursor at the active endpoint. This phase does not yet
  create insertion cursors.

Acceptance:
- Forward and reversed blocks, all four selection directions, counts, empty and
  short lines, TABs, wide/combining characters, clipping, cancellation, and
  switching selection kinds.
- Selection changes do not edit text, alter history, revision, dirty state, or
  registers.
- Build, tests, and representative terminal smoke checks pass.

Stop before block operators or insertion.

**Done (2026-10-03).** ``Visual `Blockwise`` (status `VISUAL BLOCK`) joins the
selection kinds in `Mode`, `Command.Enter_visual`, `Editor.Selection`, and
`Bindings.Target.Visual`; `Ctrl-v` is bound in `Bindings.default`. The new pure
`core/block.ml` resolves a selection: `Block.of_corners` gives the rectangle
(first/last line, first display column, and the column after the last or `None`
after `$`), `Block.rows` one byte range per line ordered last line first, with
`before`/`after` counting the cells of a TAB or wide glyph that stick out past an
edge, and `Block.columns` the cells to draw. `Editor.block` derives the rectangle
from the selection and the sticky-`$` preferred column, so no extra state is
kept. As settled, in Visual mode `l`, `j`/`k`, and `$` may leave the cursor on the
line break (Vim's `selection=inclusive` behavior, checked with `vim -Nu NONE`:
`vlll` on `abc` reaches column 3, and `5l Ctrl-v j` onto `ab` gives block 2-5); this
also makes characterwise `v$` include the LF. The frame splits a TAB at block
edges so only its covered cells are highlighted; wide and escape glyphs cut by an
edge are highlighted whole; short lines show nothing past their text. A TAB cut
by the viewport's edge now keeps its highlight (`Span.of_glyphs`). Until
Phase 16, `d`/`y`/`c` on a block report `Block operators are not supported yet`
and keep the selection. Not done, deliberately: pressing the current kind's key
again does not leave Visual mode (as before for `v`/`V`), and `o` (swap corners)
is not bound. Tests: `test/test_block.ml` (including a property test that rows
tile the selected cells), editor, keymap, and frame expect tests, Visual commands
in the random-command property test, and a smoke section. Four smoke checks
(`cursor row is not line ...`, `wrong character under the cursor`) fail on the
unmodified HEAD as well: they read the cursor while the smear animation runs.

### Phase 16 — Blockwise operators and register

**Goal:** existing Visual operators act predictably on rectangular selections.

Work:
- Add a blockwise register representation that preserves row boundaries and the
  settled column/width information; do not flatten a block into an ambiguous
  characterwise string.
- Implement block `d` and `y` by applying the per-line ranges bottom-to-top.
  Define short-line, empty-row, TAB-edge, final-line, and zero-width behavior.
- Define block `p`/`P` placement and padding before exposing it. Keep each
  delete or paste invocation one undo transaction; yanking changes no history.
- Either implement Visual block `c` using Phase 17's insertion machinery or
  defer it explicitly to that phase; do not approximate it with one ordinary
  Insert cursor.

Acceptance:
- Forward/reversed blocks can be yanked, deleted, pasted, undone, and redone;
  registers survive undo as existing registers do.
- Multibyte text and multiple disjoint line edits retain valid byte boundaries,
  exact final-newline behavior, and one-step undo.
- Build, tests, and representative terminal smoke checks pass.

Stop before `I`/`A` block insert unless implementing `c` requires a shared,
separately tested prerequisite.

**Done (2026-10-03), except Visual block `c`, deferred to Phase 17.**
`Register.t` is now ``Text { text; kind }`` or ``Block { rows; width }``: one row
per line, top first, and the block's width in display cells (the widest row
after `$`). `Block.contents` builds the rows with the settled rules, checked
again with `vim -Nu NONE`: a line shorter than the block's first column gives
`width` spaces, one ending exactly at that column gives `""`, one ending inside
the block its unpadded text, and the inside cells of a TAB or wide glyph cut by an
edge become spaces. Visual block `d` replaces each `Block.rows` range (last line
first) with `before + after` spaces, in one transaction; `d` and `y` leave the
cursor at the block's top-left. An all-empty block (only empty rows) leaves the
register unchanged, as an empty characterwise yank does. `Block.insertion` gives
the byte position, TAB split, and padding for inserting at a display column; it
is meant to be shared with Phase 17's `I`/`A`. Block `p`/`P` follow the settled
paste examples, and each paste is one transaction. Deliberate differences from
Vim: (1) after `$`, a line too short for the block yields `width` spaces where Vim
yields one more; (2) the padding after a pasted row measures a TAB in the row at
the column where it lands, keeping following text aligned, where Vim counts every
TAB as a full tab stop; (3) a block that includes the empty line after a final
LF (a line in this editor, not in Vim) gets a row for it, and rows pasted past
the last line are added before that line so the LF stays final. `c` on a block
still reports `Block change is not supported yet` and keeps the selection.
Tests: `test/test_block.ml` (`contents`, `insertion`), editor expect tests for
the settled delete/yank/paste examples, undo/redo, and register persistence,
block paste and yank in the random-command property test, and a
`blockwise delete, yank, and paste` smoke section. The same five smoke checks
fail with and without this change (smear-cursor timing, as noted for Phase 15).

### Phase 17 — Live block insert and software cursors

**Goal:** `Ctrl-v` selection followed by `I` performs a live replicated Insert
session across its lines; add `A` if its semantics were settled at the column
checkpoint.

Work:
- Add explicit block-insert state containing the participating logical lines,
  insertion columns, and enough information to update every insertion point
  after each edit. Do not model it as repeated independent ordinary Insert
  commands or expose a general multi-cursor API.
- Apply printable typing to every participating line immediately. Perform
  per-line mutations from the end of the buffer toward the start, but expose one
  semantic text change per input and one undo transaction for the complete
  Insert visit.
- Define and test Escape, the configured `jk` escape, Backspace, Delete, soft
  Tab, bracketed paste, invalid text, and lines that become shorter while
  editing. Newline/Enter may be rejected initially if faithful rectangular
  semantics are not settled; report that limitation instead of allowing the
  cursors to diverge silently.
- Render one insertion marker for every visible participating line and update
  them after every input. A terminal has only one hardware cursor, so retain it
  for the active insertion point and draw the others as styled software cursors
  (for example, a bar or highlighted cell) through the frame/UI layers.
- Specify interaction with the animated smear cursor. Prefer disabling smear
  for the software cursors, and avoid animating every replicated cursor unless
  profiling and visual review justify it.
- Complete Visual block `c` by entering the same block-insert machinery after
  deleting the selected cells, if it was deferred from Phase 16.

Acceptance:
- `Ctrl-v`, motions, `I`, typing, and Escape produce aligned edits on all
  selected lines and undo/redo as one step.
- Every live edit visibly updates all on-screen insertion markers; scrolling and
  clipping hide off-screen markers without losing their logical positions.
- `jk`, Backspace, Tab, paste, short lines, empty lines, TABs, wide characters,
  invalid pasted text, and cancellation leave consistent text, cursor, history,
  and dirty state.
- Build, tests, terminal smoke checks, and manual cursor/contrast/flicker review
  pass. Record terminal-dependent visual checks that could not be performed.

### Estimated scope

- Phase 15: one to two focused implementation sessions after the column model is
  settled; display-cell extraction may consume an additional session.
- Phase 16: one to two sessions.
- Phase 17: two to three sessions, including live software-cursor rendering and
  Insert edge cases.

A deliberately limited code-point-column implementation could be smaller, but
the preferred display-cell-compatible feature is expected to take roughly four
to six focused sessions in total. General independent cursors, arbitrary cursor
creation, per-cursor selections, and commands outside block insertion remain
deferred.
