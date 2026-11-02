# Ches documentation

[Back to Ches](../README.md)

## Using Ches

- [Editor reference](editor_reference.md): startup defaults, complete keybindings,
  editing semantics, workspace controls, Git, diagnostics, and Tile Terms.
- [Directory workspace](directory_workspace.md): file tabs, directory navigation,
  marks, creation, rename, copy, move, deletion, and recovery.
- [Pickers](pickers.md): current-document lines, project files, content search,
  setup, provider limits, and integration status.
- [Project status](project_status.md): platform support, limitations, and
  validation handoff notes.

## Building and understanding Ches

- [Development](development.md): toolchain, dependencies, builds, tests, and smoke suites.
- [Architecture](architecture.md): code layout and boundaries between editing,
  application state, rendering, and asynchronous hosts.
- [Screenshot assets](images/README.md): README images and capture notes.
- [Tile Terms backend](../terminal/README.md): terminal protocol, PTY lifecycle,
  libvterm, and focused backend checks.
- [VCS manual checks](../VCS_MANUAL_TEST.md): Git view acceptance coverage.

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
- [Deferred workspace work](backlog/README.md)
- [Archived implementation plans](archive/)

Detailed plans also remain at the repository root:
[directory workspace](../DIRECTORY_WORKSPACE_PLAN.md),
[file picker](../FILE_PICKER_PLAN.md),
[floating tiles](../FLOATING_TILES_PLAN.md),
[VCS workspace](../VCS_WORKSPACE_PLAN.md), and
[performance tests](../PERFORMANCE_TEST_PLAN.md).
