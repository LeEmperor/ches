# Ches

A small modal programmer's editor in OCaml, with a UI-independent editing core
and a [Bonsai_term](https://github.com/janestreet/bonsai_term) terminal
frontend. See [`ches_editor_prototype_brief.md`](ches_editor_prototype_brief.md)
for the long-term direction, [`mvp0_plan.md`](mvp0_plan.md) for the first
milestone, and [`feature_expansion.md`](feature_expansion.md) for MVP1, in
progress (phases 1–2, counted movement and word, line, and document motions, are
done).

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
| OS | Linux 7.0 (x86_64) |
| tmux, bash (smoke test only) | 3.4, 5.2.21 |

To set up a matching switch from scratch (see the OxCaml install instructions
for system prerequisites):

```sh
opam update
opam switch create 5.2.0+ox \
  --repos ox=git+https://github.com/oxcaml/opam-repository.git,default
eval $(opam env --switch=5.2.0+ox)
opam install dune core core_unix async bonsai bonsai_term ppx_jane
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
| Normal | `gg` / `G` | First / last line, or line N with a count (`20G`) |
| Normal | `i` / `a` | Insert before / after the character under the cursor |
| Normal | `I` / `A` | Insert at the first non-blank / end of the line |
| Normal | `o` / `O` | Open a new line below / above, indented like this one |
| Normal | `x` | Delete the character under the cursor |
| Normal | `u` / `Ctrl-r` | Undo / redo |
| Normal | `Space w` | Save |
| Normal | `Space q` | Quit; refused while there are unsaved changes |
| Normal | `Space Q` | Quit, discarding unsaved changes |
| Normal | `Space v c` | Toggle the centered tile / full width |
| Normal | `Space v h` / `Space v l` | Move the tile 2 cells left / right |
| Normal | `Space v H` / `Space v L` | Move the tile 10 cells left / right |
| Normal | `Space v -` / `Space v +` (or `=`) | Text width 10 cells narrower / wider |
| Normal | `Space v r` | Reset the layout: centered, width 100, offset 0 |
| Normal | `Escape` | Cancel a pending count or `Space` sequence |
| Insert | text, `Backspace`, `Delete` | Edit |
| Insert | `Enter` | New line, indented like the current one |
| Insert | `Tab` | Insert spaces to the next multiple of 2 columns |
| Insert | `Escape`, or `j` then `k` | Back to Normal mode |
| Both | `Ctrl-c` | Nothing, except a hint to use `Space q` |

Movement stops at the ends of a line: `h` and `l` do not wrap to the next line.
`j` and `k` keep the column you were aiming for across shorter lines; every other
motion sets that column to where it lands (after `$`, unlike Vim, `j` and `k` do
not stick to line ends). Leaving Insert mode steps the cursor back one character,
as in Vim. Motions never change the text, the undo history, or `[+]`.

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
  of an all-blank line).
- `G` goes to the last line, and `gg` to the first, at its first non-blank. With a
  count, both go to that line: `20G` and `20gg` are line 20, and `999G` stops at
  the last line. A file ending in a line break has an empty last line after it,
  so `G` (and `w` after the last word) goes there.

### Counts

In Normal mode, digits before a movement key repeat it: `20j` moves down 20
lines, `5l` moves right 5 characters, and `3w` moves 3 words. A count stops at the
edge rather than failing: `999j` near the end goes to the last line, and `20l` on a
short line goes to its last character. The status line shows a count while you
type it, with any keys of the sequence after it (`20 g`).

- `1`–`9` start a count, and any digit, including `0`, extends it. A bare `0` is
  the line-start motion: `10j` moves 10 lines, and `0` then goes to the line start.
- Counts go up to 999999. Typing a larger one cancels it with a message.
- `$` with a count N goes to the end of the Nth line, counting the current line as
  the first. `G` and `gg` with a count go to that line.
- `0` and `^` take no count, nor does any command other than a motion. A count
  before one, such as `3^`, `3x`, or `2 Space w`, is rejected with a message, and
  the command does not run.
- `Escape` cancels a pending count silently. A key that is not bound after a count,
  `Ctrl-c`, or a paste also cancels it. Nothing typed before a cancellation
  carries over to the next key.

Soft tabs work like Vim's `softtabstop`: `Tab` inserts spaces up to the next
multiple of 2 columns, and in Insert mode `Backspace` deletes spaces back to the
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

## Text

Ches edits UTF-8 text with LF line endings. Opening a file fails with a clear
error, instead of silently converting it, if the file has invalid UTF-8, a CR
byte (CRLF or bare CR line endings), or a NUL byte. Typed and pasted text follows
the same rules: text that breaks them is rejected with a `Rejected text: ...`
message. Saving writes the text back exactly as it is, including whether it
ends with a newline.

Cursor movement and deletion work on Unicode code points, and the status-line
column counts code points. On screen, characters take their terminal width (CJK
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
On a small screen the border goes first, then the gutter; status fields are
dropped from the least important up.

The view scrolls only as far as it must to keep the cursor visible: there is no
scroll margin, and long lines scroll sideways rather than wrap. When the terminal
is resized, the tile, gutter, and scroll are fitted to the new size at once,
without waiting for a key. Any size works, down to 1×1; when no text cell fits,
the cursor is hidden until there is room again.

The cursor is a steady block in Normal mode and a steady bar in Insert mode, where
the terminal supports cursor shapes. Quitting restores the terminal's own cursor.

### Layout controls

The default layout is a centered tile with a text width of 100 cells and an
offset of 0. The text width counts only text cells, not the gutter or border.
`Space v r` returns to this default.

The `Space v` commands change the layout, never the document: they make no
edits, move no cursor, and leave undo history and the dirty state alone. Moving
the tile or changing its width also switches back from full width to centered.
The requested text width is kept within 20–500 cells and the offset within
±500. When the screen is too small for a request, the tile is clamped to fit, and
the request is kept, so the layout comes back when the screen grows. The status
line shows the request and, when it differs, what fits: `Width 110 (74 fit)`,
`Offset +40 (+12 fit)`. Toggling and resetting report `Centered`, `Full width`,
or `Layout reset`. Layout preferences last for the session only: every run
starts with the default layout.

### Colors and safe display

The colors are one dark theme, near-black neutral grays with a few colored
accents, defined in `ui/theme.ml`.
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
   saved, not whatever is current when it finishes.
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
core/          ches_core: pure editing library; depends only on `core`
input/         ches_input: terminal-independent keys and modal keymap
app/           ches_app: file loading/saving and the controller that runs input
screen/        ches_screen: Bonsai-free screen model: cell mapping, geometry,
               scrolling, UI state and transition, status fields and their
               layouts, rendered frames
ui/            ches_ui: Bonsai_term frontend (event adapter, theme, app)
test/          core, input, and app tests (expect tests, Quickcheck, temp-dir file tests)
screen/test/   headless screen-model tests
ui/test/       event adapter tests and Bonsai_term_test tests of the app
scripts/       smoke.sh, the terminal smoke test
bin/ches.ml    command-line entry point
```

`ches_core`, `ches_input`, and `ches_app` must never depend on Bonsai,
Bonsai_term, Async, Notty, or any other terminal library. You can build them on
their own with
`dune build ./core/ches_core.cmxa ./input/ches_input.cmxa ./app/ches_app.cmxa`.
Only `ches_app` touches the filesystem. `ches_screen` must not depend on Bonsai
or Bonsai_term; it uses Notty only for its code-point width table, so that its
cell counts agree with what Notty draws.

## Terminal smoke test

`scripts/smoke.sh` drives the built binary in a private tmux server
(`tmux -L ches-smoke`), on copies of fixtures in a temporary directory, and
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
- word, line, and document motions (`w b e W B E 0 ^ $ gg G`) with counts,
  including a pending and cancelled `g`, and `G` with and without a count
- Insert entry (`a A I o O`): indentation copied by `o`, `O`, and `Enter` and kept
  when nothing more is typed, undoing an opened line, and `3o` rejected
- tabs, wide characters, and control characters
- a fast burst of keys with a paste in it, and a paste in Normal mode
- every `Space v` command, with clamping and restoring on resize
- exits by SIGTERM and SIGHUP, a file that cannot be opened, and standard input
  that is not a terminal

It needs tmux (tested with 3.4), bash, and a UTF-8 locale. It is not run by
`dune runtest`. A run takes about 15 seconds:

```sh
dune build && scripts/smoke.sh               # tests _build/default/bin/ches.exe
scripts/smoke.sh path/to/ches                # or another binary
```

It prints `ok` or `FAIL` for each check, with a screen dump after each failure,
and exits nonzero if any check failed. It never touches your own tmux sessions,
and it deletes its temporary directory on exit. It also saves colored captures
of review screens (Normal, Insert and dirty, pending `Space` and `Space v`, a
moved tile, and a save error at 80x24 and 160x48, plus tiny sizes) and prints
their directory (`cat` a file to view it).

### Checks to do by hand

The smoke script cannot check these, so check them in a real terminal:

- The cursor is a block in Normal mode and a bar in Insert mode, and the shell's
  own cursor shape comes back after quitting from Insert mode and after an error
  exit. tmux does not report cursor shape.
- The colors look right: the review screens, and a live session at about 80×24
  and 160×48.
- Nothing flickers while typing fast, scrolling, or resizing.
- Pasting from the terminal's own clipboard inserts text literally in Insert mode.
  This depends on the terminal; the script pastes through tmux.

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
- One document at a time. There is no `:` prompt, no operators (`dd`, `dw`), no
  `%`, no search, and no syntax highlighting. Word motions use the
  simple character classes above, not Unicode word properties.
- Large files are slow to edit and undo history grows without limit; see
  [Storage](#storage).
- No configuration file: tab width, the `j k` escape, and key bindings are set in
  code, and layout preferences are not saved between runs.

## Next milestones

These come after MVP0 and are not part of it. Roughly in order:

1. `%` and composable operators such as `dd` and `dw` (MVP1; see
   [`feature_expansion.md`](feature_expansion.md)).
2. A small `:` prompt (`:w`, `:q`, `:wq`, `:q!`) using the existing commands and
   effects.
3. Better Unicode (grapheme clusters) and line-ending support (CRLF).
4. Measure real editing latency and memory, and replace the string storage with a
   rope or piece tree if the numbers justify it.
5. Search, then language tooling once the core is stable.

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
