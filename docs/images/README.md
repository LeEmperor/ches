# README screenshots

## Personal editing sessions

The root README features five screenshots supplied by the author on 2026-11-03.
They show Ches being used on an OCaml/Hardcaml networking project, rather than
this editor's own source. These are unmodified copies of the supplied PNGs;
terminal chrome, local paths, source, and shell output are retained.

| Asset | Original filename | Contents |
| --- | --- | --- |
| `daily-workspace.png` | `~/main_work.png` | Full tile workspace with source, directory browser, tabs, status, problems, and history. |
| `daily-zen.png` | `~/Documents/zenmode.png` | Focused Zen editing with relative line numbers. |
| `daily-completion.png` | `~/Documents/completion_zenmode.png` | LSP and buffer completions in Zen mode. |
| `daily-tile-term.png` | `~/Documents/work_with_tileterm.png` | Floating shell running a Hardcaml RTL generator. |
| `daily-git.png` | `~/Documents/main_with_vcs.png` | Source and completion alongside Git status, branches, history, and a README diff. |

The capture script below does not generate or overwrite these `daily-*` assets.

## Reproducible terminal-frame captures

The five original PNGs below show the real Ches executable editing this repository's source,
captured on 2026-11-03. All are **1728 × 1056**, RGB, with embedded `Description`
and `Capture` text metadata. The theme is the default **Vim Classic**; absolute
line numbers are explicitly enabled for these captures.

| Asset | Contents |
| --- | --- |
| `editor.png` | Framed Zen editor on `completion/snippet.ml`, including its snippet types and `grouped` implementation. Suggested hero. |
| `workspace.png` | Zen off: actual `completion/` directory browser, source editor, Status, Problems and History support tiles. No active problems; the history entry is the actual snippet-loader notification. |
| `tile-terms.png` | Floating Tile Term in Insert mode running read-only Git, line-count and Dune-version commands against this checkout. |
| `navigation.png` | Project file picker filtering `source/lsp_client.ml`, showing actual on-disk source in its preview. |
| `references.png` | Real **ocamllsp** results for `grouped`: three locations in `completion/snippet.ml`, with selected source preview. |

## Reproduce

From the repository root, with the OCaml development environment active:

```sh
dune build -j6 bin/ches.exe
python3 -m venv /tmp/opencode/ches-image-venv
/tmp/opencode/ches-image-venv/bin/python -m pip install Pillow==13.0.0
/tmp/opencode/ches-image-venv/bin/python scripts/capture_readme.py
```

The parent `/tmp/opencode` must exist. Other requirements: `tmux`, real `ocamllsp`,
`rg`, `git`, `wc`, `clear`, and `dune` on `PATH`, and DejaVu Sans Mono fonts installed under
`/usr/share/fonts/truetype/dejavu`. The checkout needs its built OCaml artifacts
for language-server navigation; the capture above used the existing development
build. No fake language server or synthetic diagnostics are used. If needed,
build the development targets first with `dune build -j6`.

Options: `--binary /absolute/path/to/ches.exe` and `--font-dir /path/to/fonts`.
The script does not build or run the full test suite. It regenerates only these
five PNGs in the checkout. The root README is maintained separately.

### Exact UI sequence

The script launches `_build/default/bin/ches.exe completion/snippet.ml` from the
repository root, with LSP enabled. Sequences below continue from the preceding
row; `Space` denotes the Normal-mode leader and shell commands end with Enter.

| Capture | Input |
| --- | --- |
| Editor | `Space c c`, type `Toggle absolute line numbers`, Enter; `22G`. |
| Workspace | `Space v z`, `Space d s`, Tab (return focus to source). |
| Tile Term | `Space v z` (Zen on); `Space /`; Ctrl-Space (terminal Normal); `5-` (shrink five steps); `i` (terminal Insert). Run the commands below. |
| Navigation | Ctrl-Space, `Space /` (hide terminal); `Space f f`, type `source/lsp_client.ml`. |
| References | Escape (cancel file picker); `22G0w` (the `grouped` identifier); `g r`. |

Commands executed in the real Tile Term shell:

```sh
cd ..
clear
git ls-files 'completion/*.ml'
wc -l completion/snippet.ml source/lsp_client.ml
dune --version
```

The terminal starts in the current file's `completion/` directory; `cd ..` returns
to the checkout root. The manually resized float is **82 × 30 cells**, including
its frame; it does not illustrate the default **132 × 40** size. After the last
capture, Escape closes references and `Space q` exits Ches. No source edits or
saves are issued.

## Capture and rendering details

`scripts/capture_readme.py` follows the private tmux harness pattern in
`scripts/terminal_smoke.py`, `scripts/picker_smoke.py`, and `scripts/lsp_smoke.py`.
Each run creates a new `/tmp/opencode/ches-readme-*` evidence directory and tmux
socket, uses `-f /dev/null`, and disables tmux status. The PTY is **144 columns ×
44 rows**. It isolates `HOME` and all XDG config/cache/data/state/runtime
directories, launches `/bin/sh` with empty `ENV` and `BASH_ENV`, and sets
`LC_ALL=C.UTF-8`, `TERM=tmux-256color`, `SHELL=/bin/sh`, and `PS1='ches $ '`. No
personal shell startup or Ches configuration is loaded. It kills only its private
tmux server, including on failure.

Frames are captured with `tmux capture-pane -e -p`, then rasterized with **Pillow
13.0.0**, **DejaVu Sans Mono 20 px**, and **12 × 24 px** cells, without scaling.
The renderer honors SGR RGB/indexed colors, bold, underline and reverse, retaining
SGR state across rows; terminal default colors are `(211, 211, 211)` on black.
Bold uses DejaVu Sans Mono Bold. These are **ANSI-frame rasterizations, not
graphical-terminal screenshots**. Application text, layout and colors come from
the executable. No added chrome, annotations, cursor overlays, fabricated output
or hidden compositing is used. Tmux's capture does not include the terminal's
hardware cursor. Font/box-drawing appearance can differ from a graphical terminal.

All five final PNGs were opened and visually inspected. The workspace naturally
clips long source lines to its narrower editor tile; the picker and references
previews explicitly report their own truncation. The images retain actual local
checkout paths and actual tool output. File counts, paths, reference counts and
tool versions can change on another checkout.

The evidence directory printed by the script contains each frame as `.ansi` and
plain `.txt`, `git-before.txt`, `git-after.txt`, and `metadata.json` with dimensions,
descriptions, keys and source SHA-256 hashes. It verifies both pictured source
files are byte-for-byte unchanged and that staged content is unchanged. Git is
queried with `GIT_OPTIONAL_LOCKS=0` to avoid optional index refresh writes; the script
never stages, commits, or resets work. Staged-content checks are not a claim about
all external-tool state or concurrent work in the checkout.

## Suggested README embeds

Paths below are relative to the repository-root README:

```markdown
![Ches Zen editor showing real OCaml snippet implementation with syntax highlighting and line numbers.](docs/images/editor.png)
![Ches workspace with directory browser, source editor, status and support tiles.](docs/images/workspace.png)
![Ches Tile Term running read-only project commands over the source editor.](docs/images/tile-terms.png)
![Ches file picker with source/lsp_client.ml preview.](docs/images/navigation.png)
![Real ocamllsp references and source preview for the snippet implementation.](docs/images/references.png)
```
