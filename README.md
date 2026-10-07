# Ches

Ches is a personal modal text editor written in OCaml, with a
UI-independent editing core and a
[Bonsai_term](https://github.com/janestreet/bonsai_term) terminal frontend.
It combines Vim-style editing with a tile-based workspace for the document,
status, diagnostics, and notification history.

The project is developed for a local workflow. Its toolchain, keybindings, and
runtime defaults are maintained in the repository; it is not currently packaged
for general distribution.

## Capabilities

- **Modal editing:** Normal, Insert, and characterwise, linewise, and blockwise
  Visual modes; counted motions, delete and yank operators, paste, and undo/redo.
- **Navigation and search:** word and delimiter motions, literal forward and
  backward search, character finds, and independent viewport scrolling.
- **Workspace:** adjustable document placement and width, configurable status
  placement, line-number styles, zen mode, and supporting views with read-only
  selection and copying.
- **Command palette:** centered floating fuzzy search over Normal-mode commands,
  with shortcuts derived from the active bindings; works in zen without resizing
  the document or docked tiles.
- **Syntax highlighting:** local Tree-sitter highlighting for OCaml, Verilog,
  and SystemVerilog, including incremental parsing.
- **Diagnostics:** `ocamllsp` for OCaml and `slang-server` for Verilog and
  SystemVerilog, with a problems view, freshness tracking, and explicit restart
  controls.

Ches edits one document per session. It accepts UTF-8 text with LF line endings
and preserves the file's contents, including whether it ends with a newline.

## Usage

The local shell command points to the built executable at
`_build/default/bin/ches.exe`:

```sh
ches PATH
```

An existing file is opened for editing; a nonexistent path starts an empty
document that is created on save. Directories, special files, invalid UTF-8,
CR line endings, and NUL bytes are rejected. Standard input must be a terminal.

| Keys | Action |
| --- | --- |
| `h` / `j` / `k` / `l` | Move the cursor; prefix with a count to repeat |
| `i` / `a` | Enter Insert mode before / after the cursor |
| `Escape`, or `j` then `k` in Insert mode | Return to Normal mode |
| `v` / `V` / `Ctrl-v` | Start characterwise / linewise / blockwise selection |
| `u` / `Ctrl-r` | Undo / redo |
| `/` / `?`, then text and `Enter` | Search forward / backward |
| `Space w` | Save |
| `Space q` | Quit if there are no unsaved changes |
| `Space Q` | Quit and discard unsaved changes |
| `Space c c` | Open the command palette |
| `Space v o` | Focus the problems view or return to the document |
| `Space v M` | Show and focus notification history |

See the [editor reference](docs/editor_reference.md) for the complete keybindings,
editing semantics, workspace controls, and diagnostic-source behavior.
`ches -help` also provides a command-line summary.

The command palette prefers an 80×14 framed window, clamped to the terminal with
a one-cell margin where possible. Filtering keeps its size fixed and scrolls results
inside it. `Escape` or `Tab` cancels; `Enter` runs the selection once. It requires at
least 14 columns and 4 rows: opening below that size reports why, and shrinking an
open palette below it closes without execution. Closing discards the query and
restores the covered workspace; an interrupted palette paste is dropped, never
redirected to the document.

## Architecture

Editing state and commands are independent of the terminal frontend. The core
returns a new state and effects; the application controller performs file I/O
and updates highlighting. A separate screen model handles geometry, focus,
scrolling, and rendered frames. Bonsai_term adapts terminal events and displays
those frames.

| Directory | Responsibility |
| --- | --- |
| `core/` | Text storage, motions, selections, registers, and undo history |
| `input/` | Terminal-independent keys, bindings, and modal keymap |
| `app/` | Editing controller, file loading/saving, and highlight cache |
| `highlight/` | Provider-independent highlight ranges and snapshots |
| `highlight_tree_sitter/` | Tree-sitter providers, grammars, and queries |
| `error/` | Notifications, active problems, and bounded history |
| `source/` | Asynchronous diagnostic sources and language-server client |
| `tile/` | Shared tile host, focus, and input routing |
| `palette/` | Command catalog and fuzzy matching |
| `screen/` | Screen geometry, workspace state, and frame rendering |
| `ui/` | Bonsai_term frontend, event adapter, and theme |
| `bin/` | Command-line entry point |

The editing core, input layer, and application controller have no Bonsai or
terminal-library dependencies. The screen model is also independent of Bonsai;
it uses Notty's character-width table to keep editing and rendering aligned.
These boundaries allow most behavior to be tested headlessly.

## Development

Development uses the OxCaml opam switch `5.2.0+ox` and Jane Street
`v0.18~preview` packages. The project declares Dune language version 3.17 and
pins `tree-sitter` to 0.1.0. The bundled SystemVerilog parser also requires a C
compiler and `gzip` at build time.

With the local switch active:

```sh
dune build
dune runtest
dune exec ches -- PATH
scripts/smoke.sh
# Just the floating palette's terminal scenarios:
scripts/smoke.sh --palette-only
```

`ches.opam` is generated from `dune-project`; package metadata changes belong in
`dune-project`.

The test suite covers editing, input, file I/O, highlighting, screen geometry,
and frontend behavior. The separate terminal smoke test uses tmux, bash, and a
UTF-8 locale to check the built editor's screen output, saved bytes, and terminal
restoration. Visual checks and the `ppx_expect` source-path workaround are
documented in the [editor reference](docs/editor_reference.md#terminal-smoke-test).

## Current limitations

- **Saving:** writes are synchronous and in place, without atomic replacement
  or `fsync`. A failed write can leave a truncated file. External file changes
  are not detected; `:e!` explicitly discards changes and reloads the file.
- **Scale:** edits copy the document string, undo history retains whole-text
  snapshots without a limit, and highlighting queries the full syntax tree
  after each change. Large files and long sessions can be expensive.
- **Unicode and display:** movement and deletion use code points rather than
  grapheme clusters. CRLF is unsupported, and long lines scroll horizontally
  rather than wrap.
- **Editing and tooling:** one document at a time, literal search, an unnamed
  register, and a limited `:` prompt. Language-server integration currently
  consumes diagnostics only.
- **Configuration:** keybindings and editing defaults are defined in code.
  Layout preferences and history are session-local.

## Design notes

- [Project direction](docs/ches_editor_prototype_brief.md)
- [Workspace and tile design](docs/workspace_tiles_design.md)
- [Rendering design](docs/rendering_design.md)
- [Syntax-highlighting latency](docs/syntax_highlighting_latency_plan.md)
- [AI integration design](docs/ai_integration_design.md)
- [Deferred workspace work](docs/backlog/README.md)
- [Archived implementation plans](docs/archive/)
