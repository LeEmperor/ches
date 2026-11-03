# Linux download packages

[README](../README.md) · [Development](development.md) · [Runtime audit](../packaging/RUNTIME_AUDIT.md)

## Current deliverable

The initial package format is an **extract-and-run Linux tarball**, accompanied by
a source snapshot, build/runtime manifest and SHA-256 checksums. Packaging is
implemented and smoke-tested; it does not upload assets or create a Git release.

The current binary is **Linux x86-64, glibc 2.38 or newer**, built and tested on
Ubuntu 24.04. Its dynamic dependencies are libc, libm and the system loader. There
are no opam-specific shared libraries or absolute loader search paths. This does
not establish compatibility with older CPUs, every kernel/filesystem, musl/Alpine,
ARM, macOS or Windows. Stock Ubuntu 22.04 and Debian 12 have older glibc versions
and cannot run this artifact; a lower baseline requires a rebuild on that baseline.

### Can the executable run on its own?

**Yes, on the compatible platform above.** The OCaml runtime and native libraries,
Tree-sitter runtime/grammars/queries, built-in themes, config API source, and
libvterm terminal emulator are linked into it. Default editing does not need the
source checkout, opam, an OCaml compiler, grammar downloads, or a separate libvterm.

Optional features use host programs:

| Feature | External requirement |
| --- | --- |
| File discovery and project-content search | `rg` (ripgrep) |
| Git workspace | `git` |
| OCaml language intelligence | `ocamllsp` and the project's build environment |
| Verilog/SystemVerilog language intelligence | `slang-server` and project configuration |
| Executable `config.ml` | `ocamlc`, its matching standard library and bytecode runtime |
| Tile Terms | A working PTY environment and `$SHELL`, or `/bin/sh` |

A missing `config.ml` uses defaults without invoking a compiler. If one exists
but cannot compile, Ches reports the error and uses defaults. `--no-lsp` disables
language-server startup. Use a UTF-8 locale and a capable terminal; the user's
terminal supplies fonts, so the archive does not need screenshot fonts.

## Build a package

With the development switch active, from the repository root:

```sh
python3 scripts/package_release.py --version snapshot --strip -j 6
```

Or choose an explicit development/release version:

```sh
python3 scripts/package_release.py --version 0.1.0-dev.20261103 --strip -j 6
```

`--strip` removes debug symbols from a private copy, never the development
executable. On this host it reduced the executable from about 115 MB to 92 MB and
the binary archive from about 31 MB to 24 MB. OCaml compilation itself is not
claimed bit-for-bit reproducible across toolchains; archive metadata is normalized
and packaging identical inputs is tested for determinism.

The script defaults to six Dune jobs and rejects values above 20. Reduce the job
count when other builds are running. Existing artifact names are never overwritten;
use another version or output directory when regenerating a package.

Output under `dist/`:

```text
ches-VERSION-linux-x86_64.tar.gz
ches-VERSION-source.tar.gz
ches-VERSION-linux-x86_64.manifest.json
ches-VERSION-linux-x86_64.sha256
```

The binary tarball also embeds the same source archive under `sources/`, so it
travels with the binary. Its manifest records source/executable hashes, architecture,
glibc requirements, compiler/build environment and distribution-audit status.
`dist/` is ignored by Git.

### Uncommitted snapshots

Packaging reads current **tracked working-tree bytes**, not just committed blobs.
New packaging tooling is included automatically; other intended untracked files
need `--include-source`. This avoids silently collecting unrelated local files.
For the initial screenshot/README refresh before it has been committed, use:

```sh
python3 scripts/package_release.py --version 0.1.0-dev.20261103 --strip -j 6 \
  --include-source docs/images \
  --include-source docs/releases.md \
  --include-source scripts/capture_readme.py
```

The manifest marks a dirty tree. No staging, commits, tags or pushes are performed.
Do not change sources during packaging. `--no-build` is available for archive
verification experiments, but then the binary/source association is explicitly
unattested. `SOURCE_DATE_EPOCH` controls archive timestamps; by default it is HEAD's
commit timestamp, including for dirty snapshots.

## Extract, verify and run

After obtaining the archive and its adjacent checksums/manifest/source archive:

```sh
sha256sum -c ches-VERSION-linux-x86_64.sha256
tar -xzf ches-VERSION-linux-x86_64.tar.gz
```

From inside the extracted `ches-VERSION-linux-x86_64` directory:

```sh
sha256sum -c SHA256SUMS
./bin/ches --list-themes
./bin/ches --no-lsp /path/to/file.ml
```

Keep the package directory together with its notices and sources. Put its `bin/`
directory on `PATH` if desired. The current package contains a native executable
at `bin/ches`; optional future library-bundled packages use a relative launcher,
so moving only that launcher is not generally supported.

## Why a tarball before a `.deb`?

A tarball is easy to extract, test and remove, and it communicates the measured
ABI target without implying compatibility with every Debian-derived system.
A `.deb` would not make this executable run on older glibc. A subsequent Debian
package should use `Architecture: amd64`, actual shared-library dependencies
(currently at least `libc6 (>= 2.38)`), proper maintainer metadata and distribution
testing. The initial tooling produces tarballs, not `.deb` files.

## Verification

```sh
python3 -m unittest discover -s packaging/tests -v
CHES_PACKAGE_INTEGRATION=1 python3 -m unittest discover -s packaging/tests -v
python3 packaging/smoke.py dist/ches-VERSION-linux-x86_64.tar.gz
```

Tests cover safe source/output selection, deterministic metadata and bytes,
checksums, no-overwrite behavior and strip isolation. The smoke extracts to a
temporary directory outside the checkout and exercises themes, highlighting,
editing/saving, Tile Term, missing language-server handling and compiler-less
configuration fallback through a private tmux PTY with isolated HOME/XDG state.
No personal tmux session or system installation is modified.

## Before publishing a final public release

The packages are currently **development snapshots with an incomplete distribution
audit**, not a claim of complete license/source coverage. The executable includes
a modified GPLv3 GAS grammar. Its source and notices accompany the project snapshot,
but matching source/notices for the complete incorporated dependency set have not
yet been verified. Existing Tree-sitter runtime/OCaml-grammar/Unicode provenance
gaps and the absence of a root project license text also remain recorded.

See [distribution notices](../packaging/NOTICES.md) and the
[runtime/source audit](../packaging/RUNTIME_AUDIT.md) for the concrete outstanding
items. The packager supports `--dependency-source` and `--extra-notices` to add
locally collected dependency source archives and audited notices. It does not
silently assert that an installed-package inventory is complete corresponding
source, change the project's license, or download dependencies.
