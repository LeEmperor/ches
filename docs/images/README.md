# README screenshots

These PNGs show the real Ches terminal UI, captured on 2026-11-02 from
`_build/default/bin/ches.exe` after `dune build -j6 bin/ches.exe`.

| Asset | Contents | Dimensions |
| --- | --- | --- |
| `editor.png` | Default Vim Classic theme and framed Zen editor, with syntax-highlighted OCaml in `demo.ml`. | 1584 × 1056 |
| `tile-terms.png` | Tile Term 1 in Insert mode, running `ocaml demo.ml` over the same editor. | 1584 × 1056 |

## Capture recipe

1. Create a synthetic, non-sensitive `demo.ml` in a temporary directory under
   `/tmp/opencode`. The pictured fixture is an immutable task board with
   `Todo`, `In_progress`, and `Done` states. Its entry point filters tasks tagged
   `ches` and prints `[done] Explore the editor` and
   `[in progress] Keep the flow`.
2. Start a private tmux server with `-S /tmp/opencode/ches-readme-capture/sock
   -f /dev/null`, a **132-column × 44-row** session, and tmux status disabled.
   Use `LC_ALL=C.UTF-8`, `TERM=tmux-256color`, `SHELL=/bin/sh`, `ENV=`, and
   `PS1='ches $ '` for the shell environment.
3. In the fixture directory, launch the built executable with
   `--no-lsp demo.ml`. Leave theme and presentation at their defaults. Move to
   line 16 with `16G`, then capture the editor.
4. Open Tile Term with `Space /`. Press `Ctrl-Space` for terminal Normal mode,
    type `7-` to shrink the float from its then-default 120 × 36 to 50 × 22 cells,
   then `i` to resume Insert. Run `ocaml demo.ml`, wait for the prompt to return,
   and capture again. The displayed output is from the actual OCaml interpreter.
5. Capture each frame with `tmux capture-pane -e -p` and render its ANSI SGR
   foreground/background colors, bold, underline, and reverse attributes into
   fixed **12 × 24 pixel** cells using Pillow and **DejaVu Sans Mono, 20 px**
   (the Bold font for bold cells). Preserve SGR state across rows. Use RGB
   `(211, 211, 211)` on black for terminal defaults; honor explicit truecolor
   and indexed colors from the capture. Save as RGB PNG without scaling.
6. Close Ches and stop the private tmux server. Check the fixture is unchanged.

The images preserve the application's text, layout, and colors. Font rasterization
is provided by Pillow rather than a graphical terminal emulator. They contain no
added window chrome or overlays. Language servers and synthetic diagnostics are
disabled. The PNGs were opened and visually inspected after rendering.

The default Tile Term size has since increased to 132 × 40; the captured float
was manually resized and does not illustrate the default size.

## Suggested README embeds

Paths below are relative to the repository-root README:

```markdown
![Ches in its default Vim Classic Zen view, editing a syntax-highlighted OCaml task board.](docs/images/editor.png)

![Ches Tile Term floating over the editor, showing a real OCaml run of demo.ml.](docs/images/tile-terms.png)
```
