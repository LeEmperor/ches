# Linux packaging tooling (technical handoff)

From the repository root, in the intended opam switch:

```sh
python3 scripts/package_release.py --version snapshot -j 6
python3 scripts/package_release.py --version snapshot --strip -j 6
python3 -m unittest discover -s packaging/tests -v
CHES_PACKAGE_INTEGRATION=1 python3 -m unittest discover -s packaging/tests -v
python3 packaging/smoke.py /path/to/ches-VERSION-linux-ARCH.tar.gz
```

Pass one binary tarball path to the smoke test. `--version` is required; `snapshot`
expands to `0.1.0-dev+YYYYMMDD.<commit>[.dirty]`, with the date from the chosen
archive epoch. Explicit release versions are filename-safe, not inferred releases.
`SOURCE_DATE_EPOCH` defaults to HEAD's commit timestamp even for dirty trees.
The manifest records HEAD, dirty state, epoch, executable/source hashes, tool
versions, native architecture, build OS/glibc and ELF runtime requirements.

Default build: `opam exec -- dune build -j 6 bin/ches.exe`. `-j/--jobs` accepts
1..20, with a hard cap. No dependency installation, downloads, git writes, system
installation or config changes occur. `--no-build` packages an existing executable;
its association with the current source is explicitly unattested. `--binary PATH`
can select another trusted native ELF. `ldd` executes loader machinery: package
only a trusted executable. Python 3.10+, opam, readelf (binutils), ldd and the
already installed development switch are required. No patchelf dependency.

`--strip` optionally removes symbols using GNU strip from a private **copied**
executable, never `_build/default/bin/ches.exe` (no hard links). It uses
`--strip-all --enable-deterministic-archives`, with no timestamp preservation or
insertion; tar timestamps still use the chosen epoch. The manifest records
`input_binary_sha256`/`input_binary_size` for the original executable and
`binary_sha256`/`binary_size` for the shipped ELF, plus `strip.enabled`, `version`
and `flags`. ELF metadata is checked before and after stripping, and runtime
dependency resolution, package checksums and shipped hashes use the staged copy.
Source association still refers to the original build. Bundled shared libraries
are not stripped. Reproducibility comparisons must use the same strip mode and
binutils version. Do not run both example build commands into the same output:
artifact names deliberately do not change with `--strip`; use a fresh output
directory or version for comparisons.

## Artifacts and reproducibility

`dist/` receives a binary `.tar.gz`, matching `-source.tar.gz`, external manifest
and a version/architecture-scoped `.sha256` checksum file. The binary archive has
`bin/ches`, README, notices/licenses, `metadata/`, `sources/`, and `SHA256SUMS`.
The source archive is both embedded and adjacent so it accompanies copied binary
archives. Tar entries are sorted regular files, uid/gid 0, empty owner names,
normalized 0644/0755 modes and fixed epoch. Gzip filename is empty and mtime zero.
Same executable, working-tree contents, epoch, inventory and tool/runtime metadata
produce identical artifacts with `--no-build` in two fresh output directories.
This does not claim reproducible OCaml compilation across hosts/toolchains; gzip
bytes can vary with zlib versions. `build.performed` differs between build and
no-build runs, so compare like-for-like invocations.

Sources use current bytes of tracked files, not committed blobs. Tracked deletions
are omitted. New packaging tooling is included before commit. Other untracked
files require explicit `--include-source relative/path` (repeatable), preventing
accidental inclusion of personal nonignored files. Check the source file inventory
when adding new application code. `_build`, `.git`, `dist`, opam/node/Python caches
and `.vibe-wise` are excluded. Symlinks/submodules are rejected rather than
following paths outside the tree. The source inventory includes existing docs
as source inputs without modifying them. Do not modify the tree during packaging.
Explicit directory includes reject symlinks (including ancestor components)
before traversal, and prune excluded directories before walking their contents.
For the final manager build after the documentation updates, add:

```sh
--include-source docs/images --include-source docs/releases.md --include-source scripts/capture_readme.py
```

These opt in the new documentation assets/script without broadly including
arbitrary untracked files. Tracked grammar sources and `ASSETS.md` audit/provenance
records remain included; this does not establish third-party source completeness.

Output inside this checkout is restricted to `dist/`; external output directories
must have an existing parent. Existing artifact names are never overwritten,
including symlinks. Temporary staging is private and automatically cleaned;
publication uses exclusive hard links on the same filesystem. No cache deletion
or recursive output-directory cleanup is performed. A failed invocation may leave
an empty output directory; unrelated files remain intact.

## Runtime libraries

The inspected development binary needs only libc, libm and ld-linux (GLIBC 2.38
symbols); these remain OS dependencies. All `ldd`-resolved non-glibc dependencies
must be explicitly named with `--bundle-library SONAME=/absolute/file`, matching
actual loader resolution, plus `--extra-notices DIR`. Only named needed objects
are copied, not an entire opam `lib/` tree. Transitive dependencies also require
explicit selection. Bundled mode uses `libexec/ches`, `lib/SONAME` and a `bin/ches`
launcher setting a package-relative `LD_LIBRARY_PATH`. Launch that path directly;
an external symlink to the launcher is not supported. Absolute ELF RPATH/RUNPATH
entries are rejected. Minimum glibc includes bundled objects. Bundled dependencies'
license/source suitability is the caller's audit responsibility; no blanket
permission to bundle is inferred. No extra libraries are needed for this sample.

## Source/license audit integration

The GPLv3 GAS source is included in full as retained in the repository, with its
build/regeneration records. `--dependency-source /local/archive.tar.gz` (repeatable)
adds locally obtained dependency source archives. `--extra-notices /local/audit`
adds audit findings and license texts. Neither option downloads anything. The
installed-switch inventory is deliberately a superset and installed license
collection is best effort. The unresolved combined-work/source/license audit
must be resolved before labeling a redistributable final release; manifests do
not claim verified complete corresponding source. See `NOTICES.md`.

## Validation and scope

Tests cover path/version validation, no-overwrite behavior, safe source selection,
tar metadata, deterministic stripped/unstripped bytes, unchanged input hashes and
mtimes, strip-failure isolation, and package checksums. The opt-in integration test
prints executable/archive size comparisons and smoke-tests the stripped archive.
`smoke.py` extracts only
safe regular entries to a temporary directory outside the checkout, verifies all
checksums, runs `--list-themes` under a clean environment and uses a private tmux
PTY to edit/save a highlighted OCaml file, execute the embedded shell and quit.
It uses an empty HOME/XDG config, no opam environment and a minimal PATH without
an OCaml compiler or language server. A second PTY startup supplies an OCaml
configuration and asserts fallback to defaults without a compiler. Requires tmux; no personal tmux server is
touched. The test's shell is `/bin/sh` and test output is ephemeral.

Tarball is the supported initial format. A `.deb` is intentionally deferred:
distribution-specific dependency mapping and package maintainer metadata need
their own validation; a tarball is sufficient to extract and run this snapshot.
No portability beyond the measured native Linux/glibc target is asserted.
