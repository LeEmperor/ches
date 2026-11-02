# Development

[Documentation index](README.md) · [Architecture](architecture.md) · [Project status](project_status.md)

## Toolchain

Development uses the OxCaml opam switch `5.2.0+ox` and Jane Street
`v0.18~preview` packages. The project declares Dune language version 3.17 and
pins `tree-sitter` to 0.1.0. This is a locally maintained toolchain rather than a
general-purpose installation recipe; package declarations live in
[`dune-project`](../dune-project).

The bundled SystemVerilog and GAS parsers require a C compiler and `gzip` at
build time. The GAS grammar is GPLv3, with local patches; see
[`ASSETS.md`](../highlight_tree_sitter/gas_grammar/ASSETS.md) for provenance,
notices, regeneration, and distribution implications.

Picker libraries additionally use Async, Yojson, and Base64. File/content
provider tests and probes require `rg` on `PATH`; neither `fzf` nor ripgrep is
needed for ordinary editing or the command palette. Tile Terms vendor libvterm
0.3.3 and do not require a system libvterm installation; see its
[provenance](../terminal/VENDOR.md).

## Build and run

With the local switch active, run from the repository root:

```sh
dune build -j 12
dune runtest -j 12
dune exec -j 12 ches -- PATH
```

The executable is `_build/default/bin/ches.exe`. A local shell command or symlink
can expose it as `ches`.

`ches.opam` is generated from `dune-project`; package metadata changes belong in
`dune-project`.

Keep the combined job pool at **20 or fewer** across concurrent commands. The
commands here leave headroom; reduce `-j` further when other builds are running.

## Terminal smoke tests

The headless test suite covers editing, input, file I/O, highlighting, screen
geometry, terminal emulation, and frontend behavior. Real-terminal smoke tests
are separate from `dune runtest` and exercise screen output, saved bytes, process
cleanup, and outer-terminal restoration.

They use tmux or PTYs and require the relevant tools on `PATH`: `tmux`, Python 3,
Bash, Git, ripgrep, and a UTF-8 locale. Some scenarios also use fake language-server
fixtures built by Dune.

```sh
# Every smoke suite, serialized by a shared lock:
dune build -j 4 @smoke

# Headless tests plus all smoke suites:
dune build -j 4 @test-all

# Individual suites:
dune build -j 4 @scripts/smoke-terminal
dune build -j 4 @scripts/smoke-theme
dune build -j 4 @scripts/smoke-embedded-terminal
dune build -j 4 @scripts/smoke-directory
dune build -j 4 @scripts/smoke-picker
dune build -j 4 @scripts/smoke-vcs
dune build -j 4 @scripts/smoke-lsp
```

After building, scripts can also be run directly:

```sh
scripts/smoke.sh
scripts/smoke.sh --bare-only
scripts/smoke.sh --palette-only
python3 scripts/directory_workspace_smoke.py
python3 scripts/picker_smoke.py
python3 scripts/theme_smoke.py
python3 scripts/terminal_smoke.py
python3 scripts/vcs_smoke.py
python3 scripts/lsp_smoke.py
```

The LSP smoke uses deterministic fake servers by default. To exercise installed
`ocamllsp` and `slang-server` together through the real frontend, run
`python3 scripts/lsp_smoke.py --real`. To check only the managed backend inventory,
run `dune exec -j 6 source/bench/mixed_lsp_probe.exe`.

The VCS smoke suite uses a sandbox repository created by
[`scripts/vcs_sandbox.sh`](../scripts/vcs_sandbox.sh). Its scenarios exercise
staging, commits, a conflict-stopped rebase pull, pushing, and history, and check
the resulting Git state. See [VCS manual tests](testing/vcs_manual.md) for remaining
human checks.

Visual checks and the `ppx_expect` source-path workaround are documented in the
[editor reference](editor_reference.md#terminal-smoke-test). Historical validation
and outstanding acceptance work are recorded in [project status](project_status.md#validation-and-handoff).
