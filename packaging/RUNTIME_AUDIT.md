# Ches runtime and distribution audit

Audited 2026-11-03. This report owns only this new file. No builds, downloads,
source changes, or Git mutations were performed. Paths below refer to the
existing executable and installed switch, not a proposed rebuild.

## Result for the packaging owner

**Technically usable as a relocatable Linux x86-64 executable on a compatible
glibc host; not a universally static executable. Public distribution is not yet
license/source-complete.** A tarball or amd64 deb need not ship OCaml/opam,
Tree-sitter shared libraries, grammar/query files, or libvterm shared libraries
for ordinary editing. The current executable requires **glibc >= 2.38**.

The two concrete public-release gaps are the statically linked **GPLv3 GAS
grammar**, whose combined-binary distribution requires applicable GPLv3 notices
and corresponding source, and the unresolved Tree-sitter runtime/OCaml-grammar/
Unicode provenance and notices already documented in
`highlight_tree_sitter/ASSETS.md:34-47`. Project metadata says MIT; no root
`LICENSE` was present at inspection. This audit does not choose or change a
project license, and an MIT field alone is not the missing license text.

## Exact binary and ABI evidence

Input: `_build/default/bin/ches.exe`, 114,924,832 bytes, unstripped with debug info.

- SHA-256: `959cc2651fda924eb577e47e7b7097a4e036ecf6ce04398b89d7baa0d6f045ce`.
- ELF build ID: `d19a9681d3f1709ae88c2b250a789fbff3d2d5f9`.
- `file`: ELF 64-bit little-endian PIE, x86-64, dynamically linked, GNU/Linux
  ABI tag 3.2.0. That tag is **not** a demonstrated minimum supported kernel.
- `readelf -l`: interpreter `/lib64/ld-linux-x86-64.so.2`.
- `readelf -d`: NEEDED entries exactly `libm.so.6`, `libc.so.6`, and
  `ld-linux-x86-64.so.2`. **No RPATH or RUNPATH.**
- `ldd`: libm and libc resolve under `/lib/x86_64-linux-gnu/`; loader resolves
  under `/lib64/`. No switch-specific shared-library dependency appears.
- `readelf -V` / `readelf --dyn-syms --wide`: highest requested GLIBC version is
  **2.38**, including `fmod`, `fmodf`, and `__isoc23_strtol`; other imports include
  GLIBC_2.34/2.35. Host `dpkg-query -W libc6`: `2.39-0ubuntu8.9` amd64.
- `.comment`: GCC `13.3.0-6ubuntu2~24.04.1` (Ubuntu).

Consequences: this particular file is suitable for a compatible amd64/glibc
system (Ubuntu 24.04 is the observed host environment), not stock Debian 12
(glibc 2.36), Ubuntu 22.04 (2.35), Alpine/musl, ARM, macOS, or Windows. A lower
glibc floor requires a rebuild against that older baseline and reinspection.
Do not copy the host's libc/loader into the ordinary tarball to imply portability.
The directory-operation C stub `app/directory_fs_stubs.c:10-17` directly calls
Linux `renameat2(RENAME_NOREPLACE)`; directory saves require kernel/filesystem
support for that operation. Full minimum-kernel compatibility was not tested.
ELF architecture identifies x86-64, but does not prove all older x86-64 CPUs
support every instruction emitted by the installed OxCaml/native libraries.

## Relocation and isolated execution performed

Copied the existing binary to
`/tmp/opencode/ches-runtime-audit.Ej6Vya/ches`; its checksum matched the input.
Created private empty `home`, `config`, `cache`, and `empty-path` directories
there. Executed from that scratch directory, outside the workspace, with an
environment consisting only of:

```text
HOME=<scratch>/home
XDG_CONFIG_HOME=<scratch>/config
XDG_CACHE_HOME=<scratch>/cache
PATH=<scratch>/empty-path
LANG=C.UTF-8
TERM=xterm-256color
```

`--listthemes` was tried as requested: it exits with an unknown-flag error.
The actual supported spelling is **`--list-themes`** (`bin/ches.ml:63-64`). That
command exited 0 and printed 52 built-in themes without a terminal or external
commands. A second probe started the copied executable on a private, nonexistent
`unsaved.ml` with `--no-lsp` in a 100x24 pseudo-terminal; Normal-mode `Space q`
exited 0, with 7,641 terminal-output bytes and no detected fatal/error markers.
No save was requested. This exercises ordinary UI startup and the OCaml
highlighting route without an OCaml compiler or tools on PATH; it is not a full
feature or old-distro compatibility test. Host system resources and the original
workspace remained accessible, so these probes are relocation/environment tests,
not a chroot proof of all filesystem access.

`strings` found 47 distinct `/home/wayne/...` paths, including old switch build
directories for Tree-sitter, Core, Notty, and OxCaml, and Ches C-stub build
directories. These are consistent with compiler/debug information; there is no
ELF loader search path to them. Do not claim the file contains no developer paths.
Normal startup succeeded after relocation. This audit did not strip the binary.

## What is embedded and what must exist at runtime

| Component | Evidence and packaging consequence |
| --- | --- |
| Native OCaml application, runtime and linked OCaml libraries | `bin/dune` builds a native executable; ELF symbol `caml_startup` is defined. No `ocamlrun`, `ocamlc`, opam switch, `.cma`, or `.cmxs` is required for default editing. |
| Tree-sitter C runtime and OCaml grammars | Installed `lib/tree-sitter/dune-package:57-75,101-132` records native foreign archives and OCaml grammar objects. Defined ELF symbols include `ts_parser_new` and `tree_sitter_ocaml`. The installed switch also has `.so` stubs for bytecode, but this executable does not list them in NEEDED; do not ship them merely because they exist. |
| SystemVerilog and GAS grammars | `highlight_tree_sitter/{grammar,gas_grammar}/dune` expand `parser.c.gz` at build time and compile C foreign stubs. Both `tree_sitter_systemverilog` and `tree_sitter_gas` are defined in the executable. No grammar download, gzip, Node, or Tree-sitter CLI is needed by end users. |
| Highlight queries | `ocaml_queries.ml`, `systemverilog_queries.ml`, `gas_queries.ml` are linked OCaml string data, referenced by `highlight_tree_sitter/dune`. No runtime `.scm` resource installation is needed. |
| Terminal emulation | `terminal/emulator/dune:1-11` compiles the vendored libvterm 0.3.3 C files into foreign stubs. `vterm_new` is defined in ELF. No system `libvterm.so` dependency. |
| Themes and configuration API | Themes are built in; listing works without resources. `config/dune:7-12` embeds `config/ches_config.ml` into generated `Api_source.source`; there is no installed development-source-path requirement for that API. |
| Dynamic loading | No `dlopen` or `Dynlink` calls were found in Ches `.ml/.mli/.c` sources. Native runtime symbols `caml_dlopen` / `caml_natdynlink_open` exist, but presence alone is not evidence that Ches loads plugins. Config is a separate compiled subprocess, not a dynamically loaded native plugin. Host libc facilities and optional children can use their own resources. |
| Terminal/font/locale | Editing requires terminal stdin (`bin/ches.ml:100-114`) and a capable terminal emulator; a UTF-8 environment such as `C.UTF-8` is the tested setting. Fonts are rendered by the user's terminal, not loaded from Ches assets. Unicode glyph coverage affects appearance; no font file or mandatory Nerd Font dependency was found. No Ches locale catalog installation is needed. |
| Shells/PTY | Tile Terms use the host's PTY devices and an absolute `$SHELL`, falling back to `/bin/sh -i`; child TERM is `xterm-256color` (`terminal/host/pty_stubs.c:92-126`). Shell binaries and their resources are external. This feature was source-inspected, not launched in this audit. |

### Feature-dependent external programs

- **ripgrep (`rg`)**: file discovery (`file_picker/discovery/provider.ml:57`)
  and project content search (`content_picker/provider/provider.ml:27`). It is
  optional for starting/editing a supplied file, but needed for those pickers.
- **git**: external commands used by the Git workspace; not an ELF library and
  not required for basic editor startup. Supply via host package for that feature.
- **ocamllsp**: OCaml semantic diagnostics/completion/navigation; looked up in
  PATH (`source/lsp_client.ml:49-69`). Highlighting is independently embedded.
- **slang-server**: Verilog/SystemVerilog LSP; `$SLANG_SERVER`, PATH, then
  `~/slang-server/build/bin/slang-server` (`source/lsp_client.ml:91-105`). This is
  a deliberate user-home fallback, not a hardcoded developer path. LSP can be
  disabled with `--no-lsp`. Ches does not run `dune build --watch` for the user.
- **ocamlc plus its matching standard library and bytecode runtime**: required
  when evaluating an existing user configuration
  `$XDG_CONFIG_HOME/ches/config.ml` or `~/.config/ches/config.ml`.
  `config/loader.ml:223-315` writes the embedded API and user code into
  `/tmp/ches-config-*`, invokes `ocamlc -o config.exe ...`, then executes the
  result. Absence of the config returns defaults without compiling. The helper
  normally has an absolute `ocamlrun` shebang; copying only `ocamlc` is insufficient.
  Writable/executable temporary space is needed for this feature. Cache location
  is `$XDG_CACHE_HOME/ches/config` or `~/.cache/ches/config`; the cache fingerprints
  compiler, standard-library inputs and runtime (`config/compiled_cache.ml`).

For a deb of this exact binary, use **Architecture: amd64** and an actual
`libc6 (>= 2.38)` dependency (or the stricter result of shlib dependency tooling
on the final staged file). No opam, Tree-sitter, or libvterm runtime package
dependency follows from this ELF. `ripgrep` and `git` are appropriate feature
recommendations; OCaml tooling is an optional configuration/LSP installation,
with its purpose explained. These choices must be reflected in the artifact's
usage notes so optional features are not advertised as bundled.

## Installed dependency versions and notice inventory

Switch: `/home/wayne/.opam/5.2.0+ox`; `ocamlc -version`: `5.2.0+ox`.
`opam list --installed` reports `ocaml 5.2.0`, `ocaml-variants 5.2.0+ox`,
`oxcaml-compiler 5.2.0minus39`, and Dune `3.24.2`. Thus this is not evidence of
a build using only stock upstream OCaml 5.2. The dependency constraints in
`ches.opam` are not a reproducibility lock.

In the following table, `S` means `/home/wayne/.opam/5.2.0+ox`. Preserve full
notice texts and upstream copyright notices, not just SPDX labels in a summary.

| Incorporated dependency / asset | Version / license evidence | Available notice or source location |
| --- | --- | --- |
| Ches | `dune-project:7`, `ches.opam:6`: MIT | Root `LICENSE` absent at inspection; owner must supply the intended text/copyright notice. |
| Core, Core_unix, Async, Bonsai, Bonsai_term, ppx_jane | All installed `v0.18~preview.130.106+341`; installed `lib/<package>/opam` metadata MIT | `S/doc/{core,core_unix,async,bonsai,bonsai_term,ppx_jane}/LICENSE.md`; build-time PPX packages are not all runtime code, but linked PPX runtime support also needs its notices. |
| Yojson | `2.2.2+ox`, BSD-3-Clause | `S/doc/yojson/LICENSE.md`, copyright Martin Jambon; binary redistributions must reproduce notice/conditions/disclaimer. |
| Base64 | `3.5.2`, ISC | `S/lib/base64/opam`, `S/doc/base64/LICENSE.md`. |
| Lsp, Jsonrpc | Installed `1.19.0+ox2`, ISC; installed `lib/{lsp,jsonrpc}/opam` instead embeds version `1b5b095` | `S/doc/{lsp,jsonrpc}/LICENSE.md`; `S/.opam-switch/sources/{lsp,jsonrpc}.1.19.0+ox2/` retained. Preserve this version discrepancy in source provenance rather than assuming pristine release sources. |
| OCaml/OxCaml stdlib/runtime | Headers in `S/lib/ocaml/stdlib.ml:11-13` and `S/lib/ocaml/caml/memory.h:10-12` explicitly say LGPL 2.1 **with linking exception** | Full applicable compiler/runtime LICENSE and exception text were not found in inspected installed notice locations. Obtain exact OxCaml-source notices; do not describe the embedded stdlib as MIT or bare GPL. The exception matters for linking and does not erase notices or modified-library obligations. |
| Tree-sitter OCaml binding | opam `tree-sitter 0.1.0`, ISC | `S/doc/tree-sitter/LICENSE`: copyright 2025 Thibaut Mattio. Existing `highlight_tree_sitter/ASSETS.md` pins Mosaic `bbaec9a2b49eccc7be958df1a3fc3f53443787b8`, archive SHA-256 `9e4e90d17f9b2af1b07071fe425bc2c519c849c4f1d1ab73cde512be2d874849`. |
| Bundled Tree-sitter C runtime / OCaml grammars / Unicode tables | Existing ASSETS record identifies MIT runtime/grammar projects and separate Unicode notice; exact bundled revisions unresolved | Installed binding's ISC LICENSE is insufficient for the whole C bundle. Retrieve and verify exact bundled source and runtime/grammar/Unicode notices before publishing. No network retrieval performed. |
| SystemVerilog grammar | `d6be6119fe4d04c65c567e7b79625aa6280fea34`, MIT | `highlight_tree_sitter/grammar/{LICENSE,ASSETS.md,parser.c.gz,tree_sitter/parser.h,node-types.json}`. Copyright 2024–2025 Gonzalo M. Larumbe. |
| GAS grammar | `60f443646b20edee3b7bf18f3a4fb91dc214259a`, local `ches-gas-grammar-v2`, GPLv3 | `highlight_tree_sitter/gas_grammar/{LICENSE,ASSETS.md,grammar.js,parser.c.gz,node-types.json,tree_sitter/parser.h}`. ASSETS records modifications and checksums; no explicit upstream “or later” grant established. |
| GAS generated parser header | Tree-sitter CLI 0.22.6, MIT | `highlight_tree_sitter/gas_grammar/LICENSE.tree-sitter`; keep alongside GPL notice rather than conflating the grants. |
| libvterm | Vendored 0.3.3, MIT | `terminal/libvterm-0.3.3/LICENSE`, copyright 2008 Paul Evans; vendored source tree present. |

The executable's embedded C debug paths additionally confirm incorporated code
from Base, base_bigstring, base_internalhash_types, basement, bin_prot,
ocaml_intrinsics_kernel, string_dict, time_now and PPX runtime support at the
same Jane Street preview version; `cstruct 6.3.0`,
`notty-community 0.2.4+ox2`, `spawn v0.15.1+ox`, `uutf 1.0.4+ox`, and
`ppxlib 0.33.0+ox2` also appear. Installed Notty, Cstruct and Uutf metadata
identify ISC; Jane Street metadata generally identifies MIT. Their notices are
under `S/doc/<package>/` and metadata under `S/lib/<package>/opam`.
This is evidence of incorporation, **not a complete static-link notice manifest**:
debug paths do not enumerate all OCaml archives. Packaging must capture the final
native link's complete archive closure (including transitive libraries and PPX
runtime code), map it to installed package versions and full license texts, and
review embedded third-party subcomponents. Do not use all installed switch
packages as a claim about what is linked.

## Concrete distributable contents and remaining source work

For a usable **runtime tarball**: executable `bin/ches` (mode 0755), usage notes
stating Linux amd64/glibc >= 2.38 and the optional feature programs above, and
the complete applicable license/copyright notices. No grammar/query resource
directory is technically required at runtime. For a **deb**: the same executable
under `/usr/bin/ches`, dependency metadata above, and notices/copyright under
`/usr/share/doc/ches/`. A stripped staged copy may reduce size; that would be a
new artifact and should get its own checksum and relocation smoke test.

For public delivery of the current GPL-containing combined binary, accompany it
with an applicable GPLv3 corresponding-source delivery arrangement. A concrete,
manageable starting source bundle is the exact Ches source/build snapshot,
including Dune files, `dune-project`, `ches.opam`, config embed generator/input,
C stubs, query modules, complete vendored libvterm source, and both vendored
grammar directories **including compressed generated C, headers, patched GAS
`grammar.js`, notices and ASSETS records**. Keep GAS's recorded modifications
and regeneration recipe (CLI 0.22.6/ABI 14) with those assets. Include the pinned
original GAS and SystemVerilog upstream source archives as provenance and
preferred grammar sources; an archive URL/checksum alone is not a delivered
source archive. The current vendored SystemVerilog directory contains generated
parser artifacts, not its upstream grammar development source.

That project-source bundle is **not yet demonstrated to be complete
corresponding source for the combined executable**. Resolve the precise linked
dependency source closure and applicable system-library/tool exclusions, and
provide exact non-excluded incorporated library sources and local patches plus
the scripts/instructions needed to build/install. In particular, recover the
pinned Mosaic C bundle and exact OxCaml/Jane Street preview sources and patches;
floating version constraints cannot reproduce them. Use retained installed
switch sources where available, verifying their identity; do not bundle an
entire unrelated switch or massive user repositories.

At inspection `S/.opam-switch/build/` was empty and
`S/.opam-switch/sources/` held only `bonsai_web`, `hardcaml_asic`,
`jsonrpc.1.19.0+ox2`, `lsp.1.19.0+ox2`, `ocaml-lsp-server.1.19.0+ox2`,
`ocamlformat-lib.0.26.2+ox2`, and `ocamlformat.0.26.2+ox2`. Thus a full matching
Tree-sitter/compiler/Core source set is not available in those inspected switch
directories. Installed `.ml`/headers and binary archives are not a substitute
for all preferred source and build scripts. No claim is made that all local
caches or repositories lack recoverable copies; no new source was fetched.

**Handoff:** tar/deb staging can proceed with the current dynamic ABI facts and
embedded-resource layout. Before public release of that binary, supply the
missing project license text, finish the full linked notice inventory and
Tree-sitter provenance, and complete the GPLv3-compatible combined-work notice
and corresponding-source arrangement. Existing MIT metadata remains as found;
shipping only that label with this executable is not an accurate inventory.
