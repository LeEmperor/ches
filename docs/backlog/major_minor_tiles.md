# Backlog: major/minor tile generalization

Deferred by the owner on 2026-10-06 to close out the workspace-tiles feature set after
phase 10. Moved verbatim from [`workspace_tiles_design.md`](../workspace_tiles_design.md).

**What is done:** phases 7A–7C (human-accepted) built the shared foundation:
- the `ches_tile` host (view ids, focus/capture/routing);
- the rounded `Tile_shell` with padding;
- the comfortable allocation;
- the read-only text cursor, selection, and copying.

Problems, history, and the demo report are minor tiles on it. The editor is the only
major tile. The role and boundary contract that remains in force is in the [design doc](../workspace_tiles_design.md)
under "Shared tile direction — Major/minor roles and consumer-independent plumbing".

**What is not done:**
- A generic minor-view registry. `Ui_state` still wires each minor tile by name
  (visibility flags, `leave`, `synchronize`, `feed_capture`, `text_view`), and
  `View_command` has per-consumer commands such as `Focus_problems` and
  `Focus_demo_report`.
- Moving `Tile_shell` out of `ches_screen` into a library that dune keeps away from
  `ches_error`.
- Any specialized major tile, such as a Hardcaml report or workbench.
- Unanswered comfort questions from 7B.

The command palette (being built on another branch) is expected to replace the
provisional per-view bindings, so the registry design should follow it.

## Phase 7B open questions (carried forward, 2026-10-06)

The manual check asked about these, and acceptance did not answer them. They are
not blockers for phase 7C; revisit them when the owner next reviews tile comfort.

- **Padding density.** Minor tiles have one cell of side padding; the editor has
  `left_padding` 2. Is one cell tight next to the editor?
- **Hint legibility.** Can the muted `Hint` text in the bottom border be read on
  the open look's backdrop, on both the laptop and the monitors?
- **Band height.** Are ten rows (`Workspace.preferred_band_height`, eight content
  rows) right on each display?
- **Shell boundary.** `Tile_shell` stays error-free only by convention inside
  `ches_screen`. Moving it into a library that dune keeps away from `ches_error`
  (as `ches_tile` is) is still open. Also open: `Ui_state` still wires each minor
  tile by name (visibility flags, `leave`, `synchronize`, `feed_capture`), and
  `View_command` still has commands named per consumer (`Focus_problems`,
  `Focus_demo_report`). Adding a third minor tile, or the per-view state 7C needs,
  means editing each of these.

## Later major-tile specialization

After these shared boundaries work, expand the major-tile contract only for a
concrete consumer. The editor keeps its richer editing/undo/file behavior behind
its content adapter; a future Hardcaml report/workbench could supply structured
reports, charts, drill-down, or source actions while reusing the shell and applicable
read-only interactions. Choose producer/data contracts and required overrides in a
separate assignment. Neither minor tiles nor a read-only major report require the
error system or editor buffer model merely to participate in the workspace.
