# Ches Linux snapshot

Extract the whole archive and run `./bin/ches --list-themes`, then
`./bin/ches --no-lsp path/to/file.ml`. Keep the package directory together.
The executable contains its themes, Tree-sitter grammars/queries and terminal
emulator; it does not need the source checkout or an opam environment to edit.

This is a native Linux/glibc build, not a universally portable static executable.
See `metadata/manifest.json` for architecture, build OS, ELF interpreter and
minimum required GLIBC symbol version. That version is a necessary requirement,
not proof of compatibility with every distribution. Test on your target machine.
glibc and the loader are supplied by your OS, never by this archive.

Use a UTF-8 locale and a terminal supporting ANSI/truecolor. Basic keys: `i` enters
Insert mode; Escape returns to Normal; Space then `w` saves; Space then `q` quits;
Space then `/` opens/hides the embedded terminal. The terminal uses the configured
absolute `$SHELL`, falling back to `/bin/sh`. Git is needed for the Git view, and
ripgrep (`rg`) for file discovery/project-content search; neither is required for
editing an explicit file path.

LSP and user configuration are optional. `--no-lsp` disables language servers;
without a configured/installed server, editing and built-in highlighting remain
available. Configuration written in OCaml needs a separately installed compiler
and its matching standard library/bytecode runtime; this archive does not install
an OCaml toolchain or require the editor's development libraries for configuration.
When a configuration cannot be compiled, startup reports the problem and uses
defaults. Use a clean configuration directory to avoid that warning when those
tools are unavailable. `--help` describes the supported CLI controls.

Verify the extracted files with `sha256sum -c SHA256SUMS` from the package root.
Verify the downloaded archives against the adjacent `*.sha256` before extraction.
The embedded source archive is the same archive supplied alongside the binary;
`metadata/source-files.sha256` records its working-tree file contents.

See `NOTICES.md` and `licenses/` before redistributing. In particular, the embedded
GAS grammar is GPLv3. The source archive contains that locally modified grammar
and generated parser, but is not by itself a verified complete corresponding-source
distribution of all statically linked dependencies. This development snapshot's
dependency inventory/source coverage must be reviewed for redistribution.
