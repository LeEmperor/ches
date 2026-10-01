# Ches

A small modal programmer's editor in OCaml, with a UI-independent editing core
and a [Bonsai_term](https://github.com/janestreet/bonsai_term) terminal
frontend. See [`ches_editor_prototype_brief.md`](ches_editor_prototype_brief.md)
for the long-term direction and [`mvp0_plan.md`](mvp0_plan.md) for the current
milestone.

**Status: MVP0 phase 5.** `ches_core` is a complete, tested editing core:
text buffer, Normal/Insert cursor rules, undo transactions, dirty tracking, and
save/quit decisions expressed as effects. `ches_input` maps normalized key and
paste events to core commands, including the Space-leader bindings.
`ches_app` loads and saves files and runs the keymap and core together; it is
tested against real files. The `ches` executable opens `PATH` (reporting load
errors), but its screen is still the phase 1 placeholder: the editor is not
connected to the terminal until phase 6.

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
dune exec ches -- PATH   # opens PATH, then shows the terminal skeleton
```

`dune build` also regenerates `ches.opam` from `dune-project`; edit
`dune-project`, not `ches.opam`.

`ches PATH` exits with an error if `PATH` cannot be opened: a directory or
special file, a read error, or text that is not valid UTF-8 with LF line
endings. A path where nothing exists opens an empty document; saving creates it.

In the skeleton, press **`q`** or **`Ctrl-C`** to quit. Both keys are
temporary and will be replaced by the Space-leader bindings in phase 6. The
status line shows the current terminal size, and the body shows the last
input event that Bonsai_term delivered.

## Layout

```text
dune-project   project and package metadata (generates ches.opam)
core/          ches_core: pure editing library; depends only on `core`
input/         ches_input: terminal-independent keys and modal keymap
app/           ches_app: file loading/saving and the controller that runs input
test/          core, input, and app tests (expect tests, Quickcheck, temp-dir file tests)
ui/            ches_ui: Bonsai_term frontend (currently the phase 1 skeleton)
bin/ches.ml    command-line entry point
```

`ches_core`, `ches_input`, and `ches_app` must never depend on Bonsai,
Bonsai_term, Async, Notty, or any other terminal library. You can build them on
their own with
`dune build ./core/ches_core.cmxa ./input/ches_input.cmxa ./app/ches_app.cmxa`.
Only `ches_app` touches the filesystem.

## Saving: current limitations

Saving is synchronous and writes the file in place (truncate, then write). It is
not crash-safe: a crash or full disk mid-save can leave the file truncated. It
does not `fsync`. Symlinks are followed and kept, existing permissions are kept,
and changes made to the file by other programs are not detected.

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
