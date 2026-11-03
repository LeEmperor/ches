# Ches documentation

[Back to Ches](../README.md)

## Using Ches

- [OCaml configuration](configuration.md): startup settings, session-only changes,
  reload behavior, and an editable example.
- [Snippet collections](snippets.md): SV, OCaml, and Hardcaml templates, triggers,
  collection controls, and dependencies.
- [Editor reference](editor_reference.md): startup defaults, complete keybindings,
  editing semantics, workspace controls, Git, diagnostics, and Tile Terms.
- [Directory workspace](directory_workspace.md): file tabs, directory navigation,
  marks, creation, rename, copy, move, deletion, and recovery.
- [Pickers](pickers.md): current-document lines, project files, content search,
  setup, provider limits, and integration status.
- [Project status](project_status.md): platform support, limitations, and
  validation handoff notes.

## Building and understanding Ches

- [Release packaging](releases.md): Linux tarballs, runtime requirements,
  installation, checksums and source/license audit status.
- [Development](development.md): toolchain, dependencies, builds, tests, and smoke suites.
- [Architecture](architecture.md): code layout and boundaries between editing,
  application state, rendering, and asynchronous hosts.
- [Screenshot assets](images/README.md): README images and capture notes.
- [Tile Terms backend](../terminal/README.md): terminal protocol, PTY lifecycle,
  libvterm, and focused backend checks.
- [Testing and acceptance](testing/README.md): automated suites and manual checks.
- [VCS manual checks](testing/vcs_manual.md): Git view acceptance coverage.

## Design and implementation notes

These pages describe design decisions and implementation history. For current
user-facing behavior, start with the guides above.

- [Project direction](ches_editor_prototype_brief.md)
- [Workspace and tile design](workspace_tiles_design.md)
- [Rendering design](rendering_design.md)
- [Command palette design](command_palette_plan.md)
- [Syntax-highlighting latency](syntax_highlighting_latency_plan.md)
- [Long-line rendering](long_line_rendering.md)
- [Picker performance and backend comparison](picker_performance_recommendation.md)
- [AI integration design](ai_integration_design.md)
- [Implementation plans](plans/README.md)
- [Backlog](backlog/README.md): snippet collections/catalog and deferred workspace work.
- [Archived implementation plans](archive/)

Detailed plans and handoffs are grouped under [`plans/`](plans/README.md):
[directory workspace](plans/directory_workspace.md),
[file picker](plans/file_picker.md),
[floating tiles](plans/floating_tiles.md),
[VCS workspace](plans/vcs_workspace.md), and
[performance tests](plans/performance_tests.md).
