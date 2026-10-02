# Ches

A small modal programmer's editor in OCaml, with a UI-independent editing core
and a [Bonsai_term](https://github.com/janestreet/bonsai_term) terminal
frontend. See [`ches_editor_prototype_brief.md`](ches_editor_prototype_brief.md)
for the long-term direction and [`mvp0_plan.md`](mvp0_plan.md) for the current
milestone.

**Status: MVP0 phase 6A.** `ches PATH` is a working terminal editor: it opens,
edits, scrolls, saves, and quits, in a centered, bordered document tile with a
line-number gutter and a status line. Phase 6B adds layout controls (`Space v`)
and the visual design pass; until then the colors are provisional.

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
| `bonsai`, `bonsai_term`, `core`, `async`, `ppx_jane`, `ppx_expect` | `v0.18~preview.130.106+341` |
| `notty-community` | `0.2.4+ox2` |

To set up a matching switch from scratch, follow the OxCaml install
instructions to create a `5.2.0+ox` switch with the `ox` repository, then:

```sh
opam install dune core core_unix async bonsai bonsai_term ppx_jane
```

## Build, test, run

From this directory, with the OxCaml switch active
(`eval $(opam env --switch=5.2.0+ox)`):

```sh
dune build            # builds everything, including the `ches` executable
dune runtest          # runs the expect tests
dune exec ches -- PATH   # edits PATH
scripts/smoke.sh      # drives the built editor in tmux; see below
```

`dune build` also regenerates `ches.opam` from `dune-project`; edit
`dune-project`, not `ches.opam`.

`ches PATH` exits with an error if `PATH` cannot be opened: a directory or
special file, a read error, or text that is not valid UTF-8 with LF line
endings. A path where nothing exists opens an empty document; saving creates it.

## Keys

| Mode | Keys | Action |
| --- | --- | --- |
| Normal | `h` `j` `k` `l` | Move left, down, up, right |
| Normal | `i` | Insert at the cursor |
| Normal | `x` | Delete the character under the cursor |
| Normal | `u` / `Ctrl-r` | Undo / redo |
| Normal | `Space w` | Save |
| Normal | `Space q` | Quit; refused while there are unsaved changes |
| Normal | `Space Q` | Quit, discarding unsaved changes |
| Normal | `Escape` | Cancel a pending `Space` sequence |
| Insert | text, `Enter`, `Backspace`, `Delete` | Edit |
| Insert | `Tab` | Insert spaces to the next multiple of 2 columns |
| Insert | `Escape`, or `j` then `k` | Back to Normal mode |
| Both | `Ctrl-c` | Nothing, except a hint to use `Space q` |

Pasting (with a terminal that supports bracketed paste) inserts the text
literally in Insert mode and is ignored in Normal mode. Arrow keys and the
mouse are not used. SIGTERM or SIGHUP ends the editor, discarding unsaved
changes, after restoring the terminal.

## Screen

The text sits in a tile centered on the screen, 100 cells wide when there is
room. The status line at the bottom shows the mode, filename, `[+]` when there
are unsaved changes, pending keys, the line and column (one-based; the column
counts code points), and the latest message. On a small screen the border goes
first, then the gutter; status fields are dropped from the least important up.

Text is shown safely: a TAB expands to the next multiple of 8 cells, and
control characters, C1 controls, and bidi controls appear as visible escape
forms (`^[`, `<85>`, `<202e>`) instead of reaching the terminal.

## Layout

```text
dune-project   project and package metadata (generates ches.opam)
core/          ches_core: pure editing library; depends only on `core`
input/         ches_input: terminal-independent keys and modal keymap
app/           ches_app: file loading/saving and the controller that runs input
screen/        ches_screen: Bonsai-free screen model: cell mapping, geometry,
               scrolling, UI state and transition, rendered frames
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
restored after every exit. It covers editing, saving, reopening, undo/redo,
quitting, a save error, scrolling, resizing down to 1x1, control characters,
a fast burst of keys with a paste, Ctrl-C, and an exit by SIGTERM. It needs
tmux (tested with 3.4) and a UTF-8 locale, and is not run by `dune runtest`:

```sh
dune build && scripts/smoke.sh
```

It exits nonzero and names each failed check. It also saves colored captures
of review screens and prints their directory (`cat` a file to view it). It
cannot check the cursor shape (tmux does not report it), how the colors look,
or flicker; check those in a real terminal.

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
