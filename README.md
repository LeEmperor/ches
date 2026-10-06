# Ches

A small modal programmer's editor in OCaml, with a UI-independent editing core
and a [Bonsai_term](https://github.com/janestreet/bonsai_term) terminal
frontend. See [`ches_editor_prototype_brief.md`](ches_editor_prototype_brief.md)
for the long-term direction, [`mvp0_plan.md`](mvp0_plan.md) for the first
milestone, and [`feature_expansion.md`](feature_expansion.md) for MVP1, in
 progress (phases 1–6 and 8 are done: counted movement, word, line, and document
motions, Insert entry, `%`, line-number styles, and view scrolling).

**Status: MVP0 complete (2026-10-01).** `ches PATH` is a working terminal
editor: it opens, edits, scrolls, saves, and quits, in a
centered, bordered document tile with a line-number gutter and a status line,
and `Space v` moves and resizes the tile. It edits one file at a time, with
Normal and Insert modes and undo/redo; see [Next milestones](#next-milestones)
for what it does not do yet.

## Toolchain

Ches builds against the **OxCaml** opam switch. The `v0.18~preview` Jane Street
packages that provide `bonsai_term` are published only in the OxCaml opam
repository; the ordinary-OCaml `default` switch on the development machine has
no Bonsai or Dune installed.

Tested environment:

| Component | Version |
| --- | --- |
| opam | 2.1.5 |
| opam switch | `5.2.0+ox` (`ocaml-variants.5.2.0+ox`) |
| opam repositories | `ox` (`git+https://github.com/oxcaml/opam-repository.git`), `default` |
| Dune | 3.24.2 (project declares `lang dune 3.17`) |
| `bonsai`, `bonsai_term`, `core`, `core_unix`, `async`, `ppx_jane`, `ppx_expect` | `v0.18~preview.130.106+341` |
| `notty-community` | `0.2.4+ox2` |
| `tree-sitter` (runtime and OCaml grammars) | `0.1.0` |
| OS | Linux 7.0 (x86_64) |
| tmux, bash (smoke test only) | 3.4, 5.2.21 |

To set up a matching switch from scratch (see the OxCaml install instructions
for system prerequisites):

```sh
opam update
opam switch create 5.2.0+ox \
  --repos ox=git+https://github.com/oxcaml/opam-repository.git,default
eval $(opam env --switch=5.2.0+ox)
opam install dune core core_unix async bonsai bonsai_term ppx_jane tree-sitter.0.1.0
```

The smoke test also needs tmux (`apt install tmux` or similar).

## Build, test, run

From this directory, with the OxCaml switch active
(`eval $(opam env --switch=5.2.0+ox)`):

```sh
dune build            # builds everything, including the `ches` executable
dune runtest          # runs the expect tests
dune exec ches -- PATH   # edits PATH (the binary is _build/default/bin/ches.exe)
scripts/smoke.sh      # drives the built editor in tmux; see below
```

`dune build` also regenerates `ches.opam` from `dune-project`; edit
`dune-project`, not `ches.opam`.

`ches PATH` exits with an error if `PATH` cannot be opened: a directory or
special file, a read error, or text that is not valid UTF-8 with LF line
endings. A path where nothing exists opens an empty document; saving creates it.
It also exits with an error if its standard input is not a terminal.
`ches -help` prints a short summary of the keys.

## Keys

| Mode | Keys | Action |
| --- | --- | --- |
| Normal | `h` `j` `k` `l` | Move left, down, up, right; with a count, e.g. `20j`, that many |
| Normal | `w` / `b` / `e` | Next word start / previous word start / word end |
| Normal | `W` / `B` / `E` | The same for blank-separated words |
| Normal | `0` / `^` / `$` | Line start / first non-blank / line end |
| Normal | `_` / `g_` | First / last non-blank; with a count N, of the line N-1 below |
| Normal | `gg` / `G` | First / last line, or line N with a count (`20G`) |
| Normal | `%` | Matching `()`, `[]`, or `{}` (see [Matching delimiters](#matching-delimiters)) |
| Normal | `f` / `F` / `t` / `T` + character | Find character forward/backward, on/before it |
| Normal | `;` / `,` | Repeat the last find / repeat it in the opposite direction |
| Normal | `/` / `?` then text and `Enter` | Search forward / backward (literal, case-sensitive) |
| Normal | `n` / `N` | Repeat the last search / repeat it in the opposite direction |
| Normal | `*` / `#` | Search the small word under the cursor forward / backward |
| Normal | `i` / `a` | Insert before / after the character under the cursor |
| Normal | `I` / `A` | Insert at the first non-blank / end of the line |
| Normal | `o` / `O` | Open a new line below / above, indented like this one |
| Normal | `d{motion}`, `dd`, `D` | Delete by motion, whole line(s), or through line end |
| Normal | `diw` | Delete the small word under the cursor |
| Normal | `x` / `X` | Delete character(s) under / before the cursor |
| Normal | `y{motion}` / `yy` | Yank by motion / whole line(s) |
| Normal | `p` / `P` | Paste the unnamed register after / before the cursor or line |
| Normal | `v` / `V` / `Ctrl-v` | Start characterwise / linewise / blockwise Visual selection |
| Normal | `Space v e` | Cycle retained problem details |
| Normal | `Space v b` | Show/hide the read-only bottom problems preview |
| Normal | `Space v f` | Switch problems preview between workspace/current document |
| Normal | `Space v o` | Show/focus problems, or return to the document |
| Normal | `Space v d` / `Space v D` | Show/hide, or show/focus, the static demo report (`--demo-report` only) |
| Normal | `Space v m` / `Space v M` | Show/hide, or show/focus, the notification history |
| Normal | `:e!` then `Enter` | Discard buffer changes and force-reload the file |
| Normal | `Ctrl-e` / `Ctrl-y` | Scroll the view down / up a line, or N with a count |
| Normal | `Ctrl-d` / `Ctrl-u` | Scroll view and cursor down / up half a screen, or N lines |
| Normal | `zz` / `zt` / `zb` | Put the cursor line at the middle / top / bottom of the view |
| Normal | `u` / `Ctrl-r` | Undo / redo |
| Normal | `Space w` | Save |
| Normal | `Space q` | Quit; refused while there are unsaved changes |
| Normal | `Space Q` | Quit, discarding unsaved changes |
| Normal | `Space v c` | Toggle the centered tile / full width |
| Normal | `Space v h` / `Space v l` | Move the tile 2 cells left / right |
| Normal | `Space v H` / `Space v L` | Move the tile 10 cells left / right |
| Normal | `Space v -` / `Space v +` (or `=`) | Text width 10 cells narrower / wider |
| Normal | `Space v n` | Toggle absolute line numbers (Vim's `number`) |
| Normal | `Space v N` | Toggle relative line numbers (Vim's `relativenumber`) |
| Normal | `Space v s` | Toggle the animated smear cursor (on by default) |
| Normal | `Space v t` | Show/hide the status cell (hidden by default) |
| Normal | `Space v p h/l/k/j` | Place status left/right/above/below and show it |
| Normal | `Space v p -/+` | Shrink/grow requested status size by 2 cells (`=` aliases `+`) |
| Normal | `Space v z` | Toggle zen: hide status temporarily, retaining compact feedback |
| Normal | `Space v r` | Reset the layout: centered, width 100, offset 0, no line numbers |
| Normal | `Escape` | Cancel pending input; when idle, clear search highlights and acknowledge the presented problem |
| Visual | motions, `%` | Extend the selection |
| Visual | `v` / `V` / `Ctrl-v` | Switch the selection's kind, preserving its anchor |
| Visual | `d` / `c` / `y` | Delete / change / yank the selected range |
| Visual | `I` / `A` | On a block: insert before / append after it on every line; `2I` repeats the text |
| Visual | `Escape` | Cancel selection without moving the cursor |
| Insert | text, `Backspace`, `Delete` | Edit |
| Insert | `Enter` | New line, indented like the current one |
| Insert | `Tab` | Insert spaces to the next multiple of 2 columns |
| Insert | `Escape`, or `j` then `k` | Back to Normal mode |
| Both | `Ctrl-c` | Nothing, except a hint to use `Space q` |

Movement stops at the ends of a line: `h` and `l` do not wrap to the next line.
`j` and `k` keep the column you were aiming for across shorter lines; every other
motion sets that column to where it lands, except that after `$`, as in Vim, `j`
and `k` stick to line ends. As in Vim, that column is a screen column, so `j` and
`k` line up on screen around TABs and wide characters, landing on whichever
character covers the column; on a TAB the cursor aims for the TAB's last cell
(its first cell in Insert mode, and in Visual mode at or before where the
selection started). Leaving Insert mode steps the cursor back one character,
as in Vim. Motions never change the text, the undo history, or `[+]`.

### Workspace status

Status can occupy a cell on any side of the document. It shows mode, file/dirty
state, position, pending keys, and current feedback; it never takes keyboard focus.
Side-by-side width starts at 28 cells, stacked height at 6 rows, and each requested
size is remembered separately. Small windows fall back to the bottom status row;
expanding restores the requested layout automatically. Wider windows never turn
status on by themselves.

Zen keeps the bottom row for essential feedback without changing document placement
or saved workspace requests. Status controls used in zen update the saved layout;
toggle zen off to see it. `Space v r` still resets only document placement.
All settings are session-local. Save and reload failures remain visible across editing,
layout changes, compact status, and zen until acknowledged. An idle Normal-mode
`Escape` acknowledges the currently displayed problem and clears search highlighting.
Leaving Insert/Visual mode or cancelling a command, count, or search takes precedence;
press Escape again once idle to acknowledge. Acknowledgement leaves the problem active
and does not change dirty state. Status then shows an unresolved-problem count;
`Space v e` cycles retained details without retrying the operation. Repeated failure
renews attention without adding another entry. Successful save and reload resolve only
the corresponding failure for that file. Routine feedback, including refused quit,
clears on the next completed editor command or is replaced by newer routine feedback.
Pending prefixes, ignored keys, resize, and animation do not clear it.

The status-workspace milestone is human-accepted, as are the phase 7A shared tile
host, the phase 7B shared shell (rounded frames, padding, and spacing for status
and supporting views), and phase 7C read-only text selection and copying in
supporting views. The problems view and its navigation (phases 6 and 7) are
human-accepted too, as is phase 8's notification history.
See [`workspace_tiles_design.md`](workspace_tiles_design.md).

### Problems pane

`Space v b` toggles a bottom preview; `Space v f` switches workspace/current-file
filtering. `Space v o` shows and focuses the pane. It remains read-only:

| Pane keys | Action |
| --- | --- |
| `j/k`, `gg/G`, `Ctrl-d/u` | Select problems; move the text cursor while inspecting details |
| `yy` / `Y` | Copy the selected problem's whole description |
| `e` | Toggle full wrapped details for the selected problem, as read-only text (below) |
| `a` | Acknowledge only the selected problem, without resolving it |
| `Enter` | Jump to a valid current-file location and return to the editor |
| `Escape` | Cancel a prefix, end a selection, close details, then return to the editor |
| `Tab` or `Space v o` | Return directly to the editor |
| `Space v …` | Layout controls; editor commands and document scrolling are rejected |

Supporting views (problems, the demo report, and a dedicated status cell with room
for it) share one rounded, padded frame with their title in the top border and key
hints, notices, or a pending prefix in the bottom border; side-by-side tiles are
separated by a one-cell gap. The bottom band takes up to ten rows, never more than a
third of the window. Frames sit on the dark backdrop, so their rounded borders alone
separate tiles. The
`>` marker, the `Problems*` title, and an accent-coloured
frame show selection/focus; the terminal cursor is hidden in a pane's list and marks
the text cursor in its details. Hiding, zen, or resizing too small returns focus
to the editor. Pane pastes are ignored atomically, not treated as commands.
Focus, Escape/Tab/prefix precedence, workspace bindings, and paste ownership come
from the shared tile host (`tile/`), not the problems pane; any other supporting
view gets the same rules.
Missing/out-of-range locations and cross-file jumps are explained without touching the
document. Currently save/reload failures have no locations; location navigation
can be tried with the opt-in synthetic demo below, not a language server or multiple buffers.

To try navigation on a file with several lines:

```sh
dune exec ches -- --demo-problems PATH
```

Press `Space v o`, then `G` to select the last demo finding and `Enter` to jump to
the file's last line. Refocus with `Space v o`; try `gg` and `j/k` to navigate,
or `G` then `e` to inspect the long final finding (`j/k` scroll details;
Escape closes them).

The flag adds eight clearly labelled **DEMO** entries, initially acknowledged so
they do not demand failure attention. It does not change your text or write files;
normal editing/saving still works. Entries are session-local and disappear on
restart without the flag. Their locations are a startup snapshot, not refreshed
after edits/reload. Short/empty files have repeated locations; use a multiline file
to see distinct jump targets. No demo problems are added in an ordinary launch.

### Demo report (tile-system fixture)

```sh
dune exec ches -- --demo-report PATH
```

This installs a static, error-free report of ten labelled **DEMO REPORT** rows. It
exercises the shared tile host without the problems system. `Space v d` shows it in
the bottom band (beside problems when both are shown); `Space v D` focuses it.
`j/k`, `gg/G`, and `Ctrl-d/u` select, `e` or `Enter` toggles wrapped details (the
last row's details scroll), and Escape/Tab/`Space v …` behave as in problems.
`Space v o` and `Space v D` move focus between the two views. The report never
posts feedback, touches problems, or edits the file. Without the flag, `Space v d`
and `Space v D` only report that it is unavailable.

### Notification history

`Space v m` shows the history in the bottom band (beside problems and the report);
`Space v M` focuses it, like `:messages` in Vim. It lists past feedback oldest first,
numbered `#N`: editor messages and keymap notices, and each problem's failures
(`problem`, `problem again` when it was still active) and resolutions. Layout
feedback and a view's own notices (such as a rejected paste) are not kept. An event
repeated back to back is counted on one entry (`×3`). The newest 200 entries are kept
in memory; the title counts any older ones dropped. Nothing persists across launches.

History is a record, not current state: problems live in the problems pane. Resolving
a problem adds a `resolved` entry and keeps the earlier failure. Clearing the history
leaves active problems alone. The focused list follows the newest entry until you move.
`j/k`, `gg/G`, `Ctrl-d/u` select, `yy` copies an entry, `e`/`Enter` opens it as
read-only text (below), and `X` clears the history. Escape, Tab, and `Space v …`
behave as in problems.

### Read-only text in supporting views

Open details (problems, the demo report, and history) are read-only text, like a read-only
buffer in a Neovim split, with the terminal cursor on the text cursor:

| Details keys | Action |
| --- | --- |
| `h/l`, `0` `^` `$`, `w/b` | Move within the text (`0`/`$` and `^` use the whole logical line, not the wrapped row) |
| `j/k`, `gg/G`, `Ctrl-d/u` | Move by wrapped row, to the first/last row, or by half the view |
| `v` / `V` | Characterwise / linewise Visual selection; again to end it, `o` swaps ends |
| `y` (Visual), `yy` / `Y` | Copy the selection, or the cursor's whole line |
| `e` | Close details (`Enter` also jumps in problems, `a` acknowledges) |
| `Escape` | End a selection, then close details, then return |

A copy goes where an editor yank goes: the unnamed register, so `p` in the editor
pastes it, and the system clipboard. It copies the text itself, never the wrapping,
padding, border, or markers, and shows `Copied …` in the view's footer. Copying and
selecting never acknowledge, resolve, or jump. Edit keys (`i`, `x`, `d`, `p`, `u`,
…) and pastes are rejected with a notice. If a problem's text changes while its
details are open, the view takes the new text and ends any selection, saying so.

### Words and lines

`w`, `b`, and `e` treat a run of identifier characters (ASCII letters, digits,
`_`, and every non-ASCII character) as a word, and a run of other non-blank
characters (punctuation, such as `+=` or `(`) as another. `W`, `B`, and `E` treat
any run of non-blank characters as one word. Blanks are space, TAB, and line
breaks. As in Vim, `w` and `b` stop on empty lines and `e` skips them.

- `w` goes to the start of the next word; after the last word it goes to the end
  of the text. `b` goes to the start of the current or previous word. `e` goes to
  the end of the current or next word, and stays put when there is none.
- `^` goes to the first character that is not a space or TAB (the last character
  of an all-blank line). `_` does the same, but takes a count like `$`: `3_` is
  the first non-blank two lines down. (Later, under operators, `_` is linewise.)
- `g_` goes to the last character that is not a space or TAB (the start of an
  all-blank line), with the same count rule. Without trailing blanks it lands
  where `$` does.
- `G` goes to the last line, and `gg` to the first, at its first non-blank. With a
  count, both go to that line: `20G` and `20gg` are line 20, and `999G` stops at
  the last line. A file ending in a line break has an empty last line after it,
  so `G` (and `w` after the last word) goes there.

### Matching delimiters

`%` finds the first `(`, `)`, `[`, `]`, `{`, or `}` at or after the cursor on its
line and jumps to its mate: forward from an opening delimiter, backward from a
closing one, across lines, skipping properly nested pairs of all three kinds.

- Matching is lexical: delimiters in strings and comments count too.
- Mixed kinds nest on one stack, so in `( ] )` the `(` has no match. A misnested or
  missing mate shows `No match for (` and the cursor stays.
- With no delimiter from the cursor to the line end, it shows
  `No delimiter on this line` and the cursor stays.
- It takes no count: `50%` (Vim's jump to a percentage of the file) is rejected.

### Counts

In Normal mode, digits before a movement key repeat it: `20j` moves down 20
lines, `5l` moves right 5 characters, and `3w` moves 3 words. A count stops at the
edge rather than failing: `999j` near the end goes to the last line, and `20l` on a
short line goes to its last character. The status line shows a count while you
type it, with any keys of the sequence after it (`20 g`).

- `1`–`9` start a count, and any digit, including `0`, extends it. A bare `0` is
  the line-start motion: `10j` moves 10 lines, and `0` then goes to the line start.
- Counts go up to 999999. Typing a larger one cancels it with a message.
- `$`, `_`, and `g_` with a count N go to the Nth line, counting the current line
  as the first. `G` and `gg` with a count go to that line.
- `0`, `^`, `%`, and `zz`/`zt`/`zb` take no count. `x`, `X`, `p`, and `P` take a
  count; operator and motion counts multiply (`2d3w` deletes and `2y3w` yanks six
  words). A count before
  an unsupported command, such as `3^` or `2 Space w`, is rejected with a message.
- `Escape` cancels a pending count silently. A key that is not bound after a count,
  `Ctrl-c`, or a paste also cancels it. Nothing typed before a cancellation
  carries over to the next key.

### Delete, yank, and paste

`d` waits for a supported motion: `dw`, `db`, `de`, `d$`, `dj`, `dgg`, `dG`,
`d_`, `dg_`, `d%`, and `diw` are available. `dd` deletes the current line, `D` is
`d$`, and `x`/`X` delete forward/backward without crossing a line break. A
successful delete replaces the unnamed internal register (characterwise,
linewise, or blockwise). Escape cancels a pending `d` sequence without changing text or that
register. Every complete delete, including a counted one, is one undo step.

`y` accepts the same supported motions (apart from the deliberately narrow `diw`
text object); `yy` yanks logical lines. Yanking changes neither text, cursor,
history, nor dirty state. `p` inserts characterwise text after the cursor and `P`
before it; linewise text goes below/above the current line. A paste count repeats
the register in one undo step. Characterwise paste leaves the cursor on its last
inserted code point; linewise paste puts it at the first non-blank of its first
inserted line. An unset register reports feedback. Undo and redo do not restore
the register.

Whenever a delete or yank replaces the register, ches also copies its text to the
system clipboard, like Vim's `clipboard=unnamedplus`. Linewise text ends with a
newline, and a block's rows are joined by newlines. The copy is an OSC 52 escape
sequence sent to the terminal, so it reaches the clipboard of the machine running
the terminal, including over SSH. The terminal must allow it: Ghostty, kitty and
WezTerm do by default; under tmux, set `set-clipboard on`. `p`
still pastes the internal register; paste from the system clipboard with the
terminal's own paste.

`dw` stops at a line end rather than consuming its newline and the next line's
indentation. `d%` includes both matching delimiters; an unmatched `%` does
nothing. Linewise deletes at EOF preserve the editor's invariant that an empty
document has one logical empty line.

### Visual selection

`v` anchors a characterwise selection at the cursor and `V` anchors a linewise
selection. Ordinary motions (including counted motions and `%`) move the active
end; reversing direction is supported. `v` and `V` switch its kind without
losing the anchor. Selection highlighting takes precedence over search and
current-line highlighting while the terminal cursor remains visible. `d`, `c`,
and `y` use the same typed unnamed register and range behavior as their Normal
mode counterparts. Delete and change are each one undo step; yank returns to
Normal mode at the selected range's start without changing history. Visual paste,
text objects, and search prompts in Visual mode are not supported.

As in Vim, `l`, `j`, `k`, and `$` in Visual mode can put the cursor on the line
break after the last character, so `v$` selects through the end of the line
including its newline (`v$d` on `abc` / `def` leaves `def`). Leaving Visual mode
steps back off the line break.

`Ctrl-v` selects a rectangle of screen columns, as in Vim. Each corner covers the
whole character it is on, so a corner on a TAB or wide character covers all of
its cells; reversed and upward selections give the same rectangle. After `$` the
block reaches each line's own end until another horizontal move. TAB cells are
highlighted only where they fall inside the block, a wide character cut by an
edge is highlighted whole, and lines shorter than the block show no highlight.
Selecting changes nothing.

`d` and `y` on a block put it in the register as one row per line, as Vim does:
a line too short to reach the block contributes a row of spaces (one that ends at
the block's first column, nothing), a line ending inside it only its text, and a
TAB or wide character cut by an edge spaces for its cells inside the block. `d`
removes the selected cells, leaving spaces for the outside cells of a cut TAB or
wide character, in one undo step; both leave the cursor at the block's top-left.
`p`/`P` with a block register put each row after/before the cursor's column on
successive lines: short lines are padded up to the column, a TAB under it is split
into spaces, a wide character under it moves right, and rows past the last line
add lines (keeping a final newline final). Rows are padded to the block's width
when text follows them, so it stays lined up; a count repeats each row along its
line. A paste is one undo step with the cursor at its top-left. Unlike Vim,
padding measures a TAB inside a row where it lands rather than as a full tab
stop.

`I` and `A` on a block start a block insert: Insert mode with an insertion point
on every line of the block, before its left edge for `I` and after its right edge
for `A` (after `$`, at each line's own end). `c` deletes the block and inserts at
its left edge. Unlike Vim, which copies the text to the other lines when you leave
Insert mode, typing appears on every line as you type. Every insertion point is
drawn as a colored cell: the cursor itself, on the top line, in blue, and its copies
on the other lines in light grey (the terminal's own cursor is hidden meanwhile;
change the colors with `Block_cursor` and `Block_copy` in `ui/theme.ml`).
As in Vim, `I` and `c` skip lines too short to reach the left edge, `A` pads short
lines with spaces, a TAB under the insertion column is split into spaces, and a
wide character there moves right. Backspace (and soft-tab Backspace) removes only
what was typed in this insert. Enter, a paste containing a newline, and Delete are
refused with a message, because they would make the lines differ. A count (`2I`)
repeats the typed text when you leave. The whole insert, including `c`'s
deletion, is one undo step, and none if nothing was typed. After `I` or `A` the
cursor goes to the block's top-left, as in Vim. `I` and `A` on a characterwise
or linewise selection are not supported (they report so).

`f{character}`/`F{character}` find a literal code point strictly forward or
backward on the current line; `t`/`T` stop just before/after it. Counts repeat
the find, `;` repeats the last successful find, and `,` repeats it in the
opposite direction without changing what `;` means. They work as operator
motions too (`df)` and `dt,`); Escape cancels while waiting for the literal
argument, and a failed find retains the previous successful one.

Search results are highlighted while a query is active; the current result uses
a distinct highlight. Searches use smart ASCII case by default: a query with an
upper-case ASCII letter is case-sensitive, while an all-lowercase query matches
ASCII letter case-insensitively. The core's `Editor.create` also accepts a
`search_case` preference (`Smart`, `Sensitive`, or `Insensitive`) for alternate
frontends. `*` and `#` search the small word under the cursor as a
whole word (so `cat` does not match `scatter`); on whitespace they report that
there is no word. The query and highlighting are derived from the current text,
so edits cannot retain stale match positions. In Normal mode, `Escape` clears
the highlighting while retaining the query for `n`/`N`. While typing `/` or
`?`, its nonempty query highlights matches immediately but does not move the
cursor; cursor-following incremental search is deferred as a future setting.

### Reloading a file

In Normal mode, type `:e!` then `Enter` to discard all unsaved buffer changes
and replace the buffer with the current contents of its associated file. It
also clears undo/redo history. Escape cancels the small command prompt. This is
deliberately the only `:` command currently supported; an unknown command
reports feedback without changing the buffer.

Soft tabs work like Vim's `softtabstop`: `Tab` inserts spaces up to the next
multiple of 2 screen columns (a TAB before the cursor counts for its width), and in Insert mode `Backspace` deletes spaces back to the
previous multiple, or one character if there is no space before the cursor.
`Backspace` at the start of a line joins it to the line above, and `Delete` at
the end of a line joins the line below. `x` never deletes a line break.

`j` is inserted when you type it; a `k` straight after it deletes the `j` and
returns to Normal mode. No timeout is involved, and typed text is never held back,
but you cannot type `jk` itself (paste it instead). Tab width, the `j k` escape,
and the Normal-mode bindings are settings in `Keymap.Config`, chosen in code; there
is no configuration file. The bindings are a table (`input/bindings.ml`) checked when
it is built: a key sequence bound twice, a sequence that is a prefix of another
(which could never run, since there is no timeout), a sequence starting with
`1`–`9` (which starts a count), or one using `Escape` or `Ctrl-c` is an error.

### Entering Insert mode and autoindent

`a` on an empty line inserts at the cursor, and `I` on an all-blank line inserts
at its end. `o` and `O` work on the last line with or without a final line break
and in an empty file. Opening a line and the typing that follows are one undo
step, which restores the cursor to where it was before `o`/`O`. These commands
take no count (`3o` is rejected with a message); Vim's repeated insertion is not
supported.

Autoindent is literal and knows nothing about the language: `o` and `O` copy the
current line's leading spaces and TABs, and `Enter` copies the part of them that
is before the cursor (so `Enter` inside the indentation copies only what is to its
left). Text after the cursor moves to the new line unchanged, leading blanks
included. Unlike Vim, the copied indentation stays when you leave Insert mode
without typing anything. A paste is inserted literally, without indentation.

`Space` starts a sequence only in Normal mode. While a sequence is pending, the
status line shows its keys. An unbound continuation such as `Space z` does
nothing except report `Space z is not bound`. Sequences have no timeout.

Pasting (with a terminal that supports bracketed paste) inserts the text
literally in Insert mode and is ignored in Normal mode. Arrow keys and the
mouse are not used. SIGTERM or SIGHUP ends the editor, discarding unsaved
changes, after restoring the terminal.

## Syntax highlighting

Ches highlights OCaml implementation (`.ml`) and interface (`.mli`) files locally
with Tree-sitter. Suffix detection is case-sensitive: `.ML`, extensionless files,
other languages, and buffers without an associated path stay plain text. No
language server, network access, external query files, or Neovim installation is
needed at runtime. Syntax highlighting does not change editing, `%`, saved bytes,
registers, dirty state, or undo/redo.

Keywords, strings/escapes, numbers, nested comments and structural type/function/
module/constructor constructs receive colors. This is grammatical highlighting,
not semantic name resolution; it does not know a symbol's meaning across files.
Incomplete and malformed code is normal input and can still receive useful colors.
If provider initialization or parsing fails, the current document renders as plain
text rather than keeping stale colors. This does not block editing or saving or
replace editor feedback; a later text change or successful reload retries it.

The controller caches highlights by document identity, revision, language and query
version. Text changes use incremental parsing with a private copied/edited prior
tree; `:e!` resets it. Movement, search, selection, scrolling, resizing, animation
and saving unchanged text do not parse. The full tree is still queried and all
ranges normalized after every change. This synchronous work, whole-string editing
and diff scans remain file-size dependent: a local 205 KB generated OCaml fixture
took about **70 ms per edit**, down from about 91 ms before incremental parsing.
These are measurements, not a guarantee; larger files can still lag. Native memory
release relies on binding GC finalizers, with limited external-memory accounting.

Colors live in `ui/theme.ml`: violet keywords, green strings, orange numbers,
gray comments, cyan types/properties, blue functions, teal modules, and amber
constructors/constants/escapes. Variables/operators/punctuation use ordinary text
color. Special-display escapes/clip markers take precedence over syntax; interaction
overlays on complete glyphs take precedence over both. Clipped wide/escape fragments
keep their special treatment, and combining marks retain their base text style.
Block-insert points override selection, which
overrides search; syntax returns when the overlay clears. Current-line background
is independent, and blank padding is not syntax-colored. No theme/config engine
or extra font styles are required.

The pinned **`tree-sitter.0.1.0`** opam package supplies the compiled-in runtime and
both grammars (`tree-sitter` and `tree-sitter.ocaml` Dune libraries). Building it
needs a C compiler, not Node, a Tree-sitter CLI or grammar regeneration. The queries
are Ches-owned, predicate-free strings in `highlight_ocaml/queries.ml`. Packaging,
ownership and unresolved bundled-asset provenance/license-notice findings are
recorded in [`highlight_ocaml/ASSETS.md`](highlight_ocaml/ASSETS.md); technical
verification is not a license-compliance finding.

Regression tests run with `dune runtest`; explicit performance probes are separate:

```sh
opam exec --switch=5.2.0+ox -- dune exec ./scripts/syntax_incremental_probe/probe.exe
opam exec --switch=5.2.0+ox -- dune exec ./scripts/syntax_live_probe/probe.exe
```

Implementation and automated regression checks are complete. The owner reviewed
the palette and reported live behavior satisfactory; the detailed terminal checklist
below remains available for further review. See
[`syntax_highlighting_plan.md`](syntax_highlighting_plan.md) for measurements,
check outcomes and the acceptance handoff.

## Text

Ches edits UTF-8 text with LF line endings. Opening a file fails with a clear
error, instead of silently converting it, if the file has invalid UTF-8, a CR
byte (CRLF or bare CR line endings), or a NUL byte. Typed and pasted text follows
the same rules: text that breaks them is rejected with a `Rejected text: ...`
message. Saving writes the text back exactly as it is, including whether it
ends with a newline.

Cursor movement and deletion work on Unicode code points, and the status-line
column counts code points; `j`/`k` and soft tabs use screen columns. On screen, characters take their terminal width (CJK
characters take two cells), a TAB expands to the next multiple of 8 cells, and
control characters are drawn as escape forms (see [Screen](#screen)).

## Undo

`u` and `Ctrl-r` work in Normal mode, and they restore both the text and the
cursor.

- Everything typed in one visit to Insert mode, including Backspace, Delete,
  Enter, and pastes, is one undo step. Leaving Insert mode ends the step.
- Each Normal-mode edit (`x`) is its own step.
- Moving and switching modes add no steps.
- A new edit after an undo discards the redo history.
- `[+]` means the text differs from what was last saved. Undoing back to the
  saved text clears it, so a plain `Space q` then works.

History is kept for the session only, as whole-text snapshots (see
[Storage](#storage)).

## Screen

The text sits in a tile centered on the screen, 100 cells wide when there is
room, with the filename in its top border. The status line at the bottom shows
the mode, filename, `[+]` when there are unsaved changes, pending keys, the line
and column (one-based; the column counts code points), and the latest message.
Between the left border and the gutter (or the text, with no gutter) are 2 blank
cells of padding, outside the text width. On a small screen the border goes
first, then the padding and gutter together; status fields are dropped from the
least important up.

Line numbers are off by default. `Space v n` and `Space v N` toggle Vim's
`number` and `relativenumber` switches independently, giving four styles: off
(neither, with no gutter), absolute (`n` only), relative (`N` only; the cursor
line shows `0`), and hybrid (both: the cursor line shows its own number,
left-aligned, and every other line its distance from the cursor). The gutter is `max(3, digits in the line count)` cells plus a separator
in every numbered style, so switching between them or moving the cursor never
shifts the text. With numbers off, a centered tile with room keeps its text width
and narrows, so the text moves left by about half a gutter; at full width, or when
the screen limits the width, the text gets the gutter's cells instead. Numbers
off also lets the border fit on a slightly narrower screen.

The view scrolls only as far as it must to keep the cursor visible: there is no
scroll margin, and long lines scroll sideways rather than wrap. When the terminal
is resized, the tile, gutter, and scroll are fitted to the new size at once,
without waiting for a key. Any size works, down to 1×1; when no text cell fits,
the cursor is hidden until there is room again.

The cursor is a steady block in Normal mode and a steady bar in Insert mode, where
the terminal supports cursor shapes. Quitting restores the terminal's own cursor.

### Scrolling the view

`Ctrl-e` and `Ctrl-y` scroll the view down and up by a line, or by N with a
count, as in Vim. The cursor stays on its line while that line is visible;
when it would scroll out of view, the cursor moves to the nearest visible line,
keeping its column as `j` and `k` do. `Ctrl-d` and `Ctrl-u` move both the view
and the cursor by half the text rows (at least 1), or by N lines with a count
(for that use only; Vim's `scroll` setting is not supported). `zz`, `zt`, and
`zb` put the cursor line at the middle, top, or bottom of the view without moving
the cursor; they take no count.

- At the end, `Ctrl-e` can scroll until the last line is at the top, and `zt`
  can put the last line there. Moving the cursor within the view then leaves it
  as it is. `Ctrl-d` stops scrolling once the last line is at the bottom but
  keeps moving the cursor, so repeating it reaches the last line.
- At the start, scrolling stops at line 1, and `Ctrl-u` then moves only the
  cursor. Nothing happens at either end once there is nowhere to go, and there is
  no message.
- A resize fills a view scrolled past the end, so it is not partly empty while
  earlier lines are hidden; so does the first key typed after a resize. Ordinary
  movement does not.
- These keys are Normal-mode only; in Insert mode they do nothing. They never
  edit: no undo step, no dirty marker.

### Layout controls

The default layout is a centered tile with a text width of 100 cells, an
offset of 0, and no line numbers. The text width counts only text cells, not
the padding, gutter, or border. The left padding has no key; it is
`left_padding` in `Geometry.Prefs.default` (`screen/geometry.ml`).
`Space v r` returns to this default.

The `Space v` commands change the layout, never the document: they make no
edits, move no cursor, and leave undo history and the dirty state alone. Moving
the tile or changing its width also switches back from full width to centered.
The requested text width is kept within 20–500 cells and the offset within
±500. When the screen is too small for a request, the tile is clamped to fit, and
the request is kept, so the layout comes back when the screen grows. The status
line shows the request and, when it differs, what fits: `Width 110 (74 fit)`,
`Offset +40 (+12 fit)`. Toggling and resetting report `Centered`, `Full width`,
or `Layout reset`; the line-number toggles report the new style, noting when the
screen is too small for a gutter: `Line numbers: relative (no room)`. They take
no count. Layout preferences last for the session only: every run
starts with the default layout.

### Colors and safe display

The colors are one dark theme, near-black neutral grays with a few colored
accents, defined in `ui/theme.ml`.
Font styles (bold, italic, underline) are set per part of the screen by
`Theme.Font.default` and can be replaced in code with `Editor_view.run ~font`;
the terminal still chooses the typeface, and a terminal without italics may
ignore them.
Document styles are composable records under `Ches_screen.Style.Document`:
syntax category (or plain), current-line background, special-display treatment, and
interaction overlay. The `~font` callback still takes `Style.t`; custom callbacks
that previously matched flat document variants must now inspect the record, e.g.
`Document { special = true; _ }` instead of `Special | Special_cursor_line`.
Chrome variants such as `Title` and `Status` are unchanged.
Everything is also readable without color: the mode, `[+]`, and messages are
text, and escape forms are bracketed.

Text is shown safely: a TAB expands to the next multiple of 8 cells, and
control characters, C1 controls, and bidi controls appear as visible escape
forms (`^[`, `<85>`, `<202e>`) instead of reaching the terminal.

## Architecture

One key press goes through these steps:

1. **`ui/`** (Bonsai_term) receives a terminal event. `Terminal_input` turns it
   into a terminal-independent `Key.t`, or into the start or end of a paste.
2. **`screen/Ui_state`** collects any paste and passes the input to the
   controller.
3. **`app/Controller`** feeds it to **`input/Keymap`**. The keymap tracks pending
   counts, `Space` sequences, and the `j k` escape, looks Normal-mode sequences up
   in its **`input/Bindings`** table, and returns *actions*. An action is either an
   editor command, such as a counted move, or a view command.
4. Editor commands go to **`core/Editor.dispatch`**, a pure function from state
   and command to a new state plus a list of *effects*, such as "write this exact
   text to this path" or "exit". The controller runs the effects synchronously
   and reports each outcome back to the editor. A save marks the text it wrote as
    saved, not whatever is current when it finishes. After the final text revision
    change, `app/Highlighting` updates the immutable highlight snapshot using its
    privately owned provider; no parsing happens in frame drawing or Bonsai rendering.
5. View commands (`Space v`) come back to `Ui_state`, which changes its layout
   preferences. They never touch the editor.
6. **`screen/Frame`** draws the editor, keymap, and UI state as rows of styled
   spans plus a cursor, as plain data. `ui/` turns the spans into Bonsai_term
   views with `ui/theme.ml`'s colors.

Only `ui/` uses Bonsai, so everything from `Ui_state` down to the finished frame
is tested headlessly with key sequences. `ui/` contains only event conversion,
colors, and the Bonsai_term app.

```text
dune-project   project and package metadata (generates ches.opam)
error/         ches_error: pure shared notification, active-problem lifecycle, and bounded history
core/          ches_core: pure editing library; depends only on `core`
input/         ches_input: terminal-independent keys and modal keymap
app/           ches_app: file loading/saving, input controller and highlight cache
highlight/     ches_highlight: provider-independent byte ranges, categories,
               snapshot keys, normalization/lookup and incremental edit descriptions
highlight_ocaml/ ches_highlight_ocaml: privately owned Tree-sitter provider and queries
screen/        ches_screen: Bonsai-free screen model: cell mapping, geometry,
               scrolling, UI state and transition, status fields and their
               layouts, rendered frames
ui/            ches_ui: Bonsai_term frontend (event adapter, theme, app)
test/          core, input, and app tests (expect tests, Quickcheck, temp-dir file tests)
highlight/test/, highlight_ocaml/test/  range/edit and fresh/incremental provider tests
screen/test/   headless screen-model tests, including live syntax/overlay geometry
ui/test/       event adapter tests and Bonsai_term_test tests of the app
scripts/       smoke.sh plus explicitly invoked syntax feasibility/performance probes
bin/ches.ml    command-line entry point
```

`ches_core`, `ches_input`, and `ches_app` must never depend on Bonsai,
Bonsai_term, Async, Notty, or any other terminal library. You can build them on
their own with
`dune build ./core/ches_core.cmxa ./input/ches_input.cmxa ./app/ches_app.cmxa`.
Only `ches_app` touches the filesystem. `ches_screen` must not depend on Bonsai
or Bonsai_term; it uses Notty only for its code-point width table, so that its
cell counts agree with what Notty draws. The cell layout itself lives in
`ches_core` (`Cell_layout`) with the width function passed in: the frontend
creates the editor with the same `Cell_map.width` it draws with, so screen
columns in editing semantics and on screen cannot disagree.

## Terminal smoke test

`scripts/smoke.sh` drives the built binary in a private per-run tmux server
(`tmux -S "$work/tmux.sock"`), on copies of fixtures in a temporary directory, and
checks the screen text, cursor position and visibility, the alternate screen,
saved file bytes, exit statuses, and that `stty` settings and the cursor are
restored after every exit. It goes through every binding in the [Keys](#keys)
table, including the Insert-mode editing keys, soft tabs, `j k`, and an unbound
`Space` key. It also covers:

- saving, reopening, and undo/redo, including undoing a whole Insert session
- a plain quit refused while there are unsaved changes, and a forced quit
- a save error
- empty and new files
- scrolling tall and wide files, and resizing down to 1x1
- counted movement: the pending count on the status line, clamping at the ends
  of the document and of lines, the column kept across short lines, and counts
  cancelled by overflow, `Escape`, an unbound key, or a command that takes none
- word, line, and document motions (`w b e W B E 0 ^ $ _ g_ gg G`) with counts,
  including a pending and cancelled `g`, and `G` with and without a count
- `%` across 150 lines and back, from before a delimiter, on a line without one,
  and with a rejected count
- Insert entry (`a A I o O`): indentation copied by `o`, `O`, and `Enter` and kept
  when nothing more is typed, undoing an opened line, and `3o` rejected
- tabs, wide characters, and control characters
- a fast burst of keys with a paste in it, and a paste in Normal mode
- every `Space v` command, with clamping and restoring on resize
- workspace status on all four sides, separate width/height requests, scrolling and
  cursor alignment, hide/show, zen and saved-layout changes, compact fallback and
  restoration, edit/undo/redo/save, and error visibility across layout transitions
- line-number styles: both toggles from the default (none), a rejected count,
  `Space v r`, renumbering as the cursor moves, and a toggle while too small
- view scrolling: `Ctrl-e`/`Ctrl-y` with counts and a pushed cursor, `Ctrl-d`/
  `Ctrl-u`, `zt`/`zb`/`zz` and a rejected count, scrolling past the end, resizing
  after scrolling, tiny terminals, and Insert mode
- exits by SIGTERM and SIGHUP, a file that cannot be opened, and standard input
  that is not a terminal

It needs tmux (tested with 3.4), bash, and a UTF-8 locale. It is not run by
`dune runtest`. It waits for screen/cursor updates rather than assuming a fixed runtime:

```sh
dune build && scripts/smoke.sh               # tests _build/default/bin/ches.exe
scripts/smoke.sh path/to/ches                # or another binary
```

It prints `ok` or `FAIL` for each check, with a screen dump after each failure,
and exits nonzero if any check failed. It never touches your own tmux sessions,
and it deletes its temporary directory on exit. It also saves colored captures
of review screens (Normal, Insert and dirty, pending `Space` and `Space v`, a
moved tile, relative and no line numbers, and a save error at 80x24 and
160x48, plus tiny sizes) and prints
their directory (`cat` a file to view it).

Cursor assertions poll for a visible cursor at the expected position within five
seconds, rather than sampling hidden cursor coordinates during smear. This fixed
the five timing failures recorded in the syntax-highlighting handoffs; three
consecutive isolated runs passed all checks. Each run owns its own socket, so it
cannot interfere with another smoke run. Automated checks still cannot replace
the manual checks below.

### Checks to do by hand

The smoke script cannot check these, so check them in a real terminal:

- The cursor is a block in Normal mode and a bar in Insert mode, and the shell's
  own cursor shape comes back after quitting from Insert mode and after an error
  exit. tmux does not report cursor shape.
- The colors look right: the review screens, and a live session at about 80×24
  and 160×48.
- During a block insert (`Ctrl-v`, `2j`, `I`, then type), the cursor's cell is
  blue, the other lines' insertion points are grey cells, and none of them flicker
  while you type, including while the smear animation runs.
- Nothing flickers while typing fast, scrolling, or resizing.
- Pasting from the terminal's own clipboard inserts text literally in Insert mode.
  This depends on the terminal; the script pastes through tmux.
- Syntax acceptance: open `highlight_ocaml/provider.ml`, `core/text_buffer.mli`
  and `README.md` to compare `.ml`, `.mli` and plain-text fallback. Check readability
  under `/` search/current matches, character/line/block selections and block-insert
  points, then clear overlays and confirm syntax returns. Insert a multiline comment
  above the viewport and undo/redo it; try unfinished strings/comments and malformed
  code. Include TABs, controls, wide/combining characters and tiny dimensions while
  typing, pasting, scrolling, resizing and running smear. Record observed flicker
  or palette problems rather than treating headless tests as visual sign-off.

## Storage

The document is an immutable OCaml string behind the abstract `Text_buffer.t`.
Every edit copies the string, and line lookups scan it. That is the simplest
thing that is clearly correct, and it is fast enough for source-sized files.
Only `Text_buffer` knows how text is stored. Its interface works in byte offsets
at UTF-8 code-point boundaries and in line numbers, so it can later become a rope
or piece tree without changing the editor, keymap, or screen code.

The cost is that editing time and undo memory grow with file size. Undo history
keeps a whole snapshot of the text for each step (neighboring steps share one),
and it is never trimmed. Very large files will be slow to edit, and a long session
uses memory roughly in proportion to file size times the number of undo steps.

## Saving: current limitations

Saving is synchronous and writes the file in place (truncate, then write). It is
not crash-safe: a crash or full disk mid-save can leave the file truncated. It
does not `fsync`. Symlinks are followed and kept, existing permissions are kept,
and changes made to the file by other programs are not detected.

## Known limitations

- Grapheme clusters are not handled: cursor movement and deletion work on code
  points, and widths are per code point. A complex cluster such as an emoji
  ZWJ sequence may look wrong, but the layout around it stays aligned.
- A combining mark is drawn with the character before it only when that
  character is drawn as itself; after a TAB, an escape form, or the left edge
  of the view it is not drawn.
- No soft wrapping: long lines scroll horizontally.
- One document at a time. The only `:` command is `:e!`; there is no general Ex
  prompt. Search and local OCaml syntax highlighting are supported; semantic tokens,
  other languages and language-server features are not. Word motions use the
  simple character classes above, not Unicode word properties.
- Large files are slow to edit and undo history grows without limit; see
  [Storage](#storage) and [Syntax highlighting](#syntax-highlighting). Incremental
  parsing still runs a full-document query and normalization after each text change.
- No configuration file: tab width, the `j k` escape, and key bindings are set in
  code, and layout preferences are not saved between runs.

## Next milestones

These come after MVP0 and are not part of it. Roughly in order:

1. Yank/paste, changes, replacement, and the remaining MVP1 editing features
   (see [`feature_expansion.md`](feature_expansion.md)).
2. More `:` commands (`:w`, `:q`, `:wq`, `:q!`) on the narrow prompt used by
   `:e!`.
3. Better Unicode (grapheme clusters) and line-ending support (CRLF).
4. Measure real editing latency and memory, and replace the string storage with a
   rope or piece tree if the numbers justify it.
5. Further language tooling after syntax-highlight acceptance; LSP and extra
   languages need separate authorization.

## Known toolchain quirk: ppx_expect source path

`ppx_expect v0.18~preview` drops the directory when it registers an expect
test's file, then rebuilds the path from the bare filename plus the
`-source-tree-root` that Dune passes (the project root). As a result,
`dune runtest` fails with `Sys_error "./../<file>.ml: No such file or
directory"` even when every expectation passes. Each library that has inline
tests works around this in its `dune` file:

```dune
(inline_tests
 (flags
  (:standard -source-tree-root .)))
```

The trailing flag wins and points at the runner's working directory, where
Dune has copied the sources. Real expectation failures still produce a diff
and a nonzero exit. Remove the workaround once a fixed `ppx_expect` is
installed.
