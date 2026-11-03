# Ches

**A modal terminal editor with a tile-based workspace.**

*THIS IS MY PERSONAL EDITOR; FEEL FREE TO CLONE AND BUILD FROM SOURCE BUT ALL DECISIONS ARE MINE*
Ches brings Vim-style editing, floating shells, file navigation, diagnostics, and
Git into one keyboard-driven workspace. Written in OCaml, with a
[Bonsai_term](https://github.com/janestreet/bonsai_term) frontend.

[Getting started](#getting-started) · [Keybindings](docs/editor_reference.md#keys) ·
[Documentation](docs/README.md) · [Development](docs/development.md)

![Ches editing syntax-highlighted OCaml in its default Vim Classic Zen view.](docs/images/editor.png)

## A workspace that stays out of your way

- **Modal editing.** Normal, Insert, and characterwise, linewise, and blockwise
  Visual modes, with counted motions, operators, search, indentation, and undo.
- **Tiles when you need them.** Start in Zen, open supporting views around your
  document, or switch to borderless Bare mode. Keep independent files in tabs.
- **Find your place.** Fuzzy file and current-document pickers, project content
  search, and editable directory listings for working across a project.
- **Git without leaving the editor.** A lazygit/Magit-inspired view for diffs,
  staging, commits, branches, history, and merge or rebase conflicts.
- **Language-aware feedback.** Tree-sitter highlighting for OCaml, Verilog,
  SystemVerilog, and GAS assembly, with language-server diagnostics for OCaml and
  Verilog/SystemVerilog. Inspect attached servers with `Space l i`.
- **Make it yours.** A command palette, live theme previews, dark and light
  palettes, adjustable layouts, and optional key hints.

## Tile Terms

An interactive shell, one toggle away. **`Space /`** opens or hides a Tile Term;
**`3 Space /`** selects terminal 3. Each numbered session keeps its shell, jobs,
screen, and preferred size while hidden.

![Tile Term 1 floating over the editor, showing the output of running the OCaml file.](docs/images/tile-terms.png)

Toggle directly from Normal or Insert mode. Use rapid **`jk`** to enter terminal
Normal mode, then navigate, select, and yank text into the editor. **`i`** returns
to the shell; **`+` / `-`** resize the float.

See the [Tile Terms guide](docs/editor_reference.md#floating-terminal) for modes,
numbered sessions, and Insert-mode shortcut timing.

## Getting started

With the [development toolchain](docs/development.md#toolchain) available:

```sh
dune build -j 12 bin/ches.exe
_build/default/bin/ches.exe .
```

Open a directory to browse a project, or pass a file path to edit it. If you have
`ches` on your `PATH`:

```sh
ches src/main.ml             # Vim Classic theme, Zen layout
ches --workspace .           # Full tile workspace
ches --bare src/main.ml      # Borderless editing (also --superzen)
ches --theme glacier .       # Choose a different theme
ches --list-themes           # Browse available palettes
```

### A few keys to start

`Space` below means the spacebar. Unless noted, editor commands use Normal mode.

| Keys | Action |
| --- | --- |
| `h` / `j` / `k` / `l` | Move |
| `i` / `Escape` | Enter Insert / return to Normal |
| `u` / `Ctrl-r` | Undo / redo |
| `Space w` / `Space q` | Save / quit |
| `Space c c` | Open the command palette |
| `Space f f` / `Space f g` / `Space f l` | Find files / search contents / find lines |
| `Space o` | Show the file's parent in the main area / return to file |
| `Space b n` / `Space b p` | Next / previous file tab |
| `Space g g` | Open the Git view |
| `Space l i` | Inspect attached language servers and their status |
| `Space /` / `N Space /` | Toggle Tile Term / select numbered session; also works in Insert |
| `Space v z` / `Space v B` | Toggle Zen / Bare |
| `Space v T` | Choose a theme |

The [editor reference](docs/editor_reference.md) covers the full keymap, directory
operations, and terminal controls. `ches --help` lists command-line options.

## Documentation

- [Editor reference](docs/editor_reference.md) — keys, modes, workspace, Git, and Tile Terms.
- [Directory workspace](docs/directory_workspace.md) — browsing and filesystem operations.
- [Pickers](docs/pickers.md) — file navigation and project search.
- [Development](docs/development.md) — toolchain, builds, and tests.
- [Architecture](docs/architecture.md) — source layout and module boundaries.
- [Project status](docs/project_status.md) — support, limitations, and validation notes.

For design notes, backlogs, and implementation history, see the
[documentation index](docs/README.md).
