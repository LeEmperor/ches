# Backlog: major/minor tile generalization

Deferred by the owner on 2026-10-06 to close out the workspace-tiles feature set after
phase 10. Moved verbatim from [`workspace_tiles_design.md`](../workspace_tiles_design.md).

**What is done:** phases 7A–7C (human-accepted) built the shared foundation:
- the `ches_tile` host (view ids, focus/capture/routing);
- the rounded `Tile_shell` with padding;
- the comfortable allocation;
- the read-only text cursor, selection, and copying.

Problems, history, and the demo report are minor tiles on it. The editor was the only
major tile until the VCS view (phase 2, below).

**Done in VCS workspace phase 0A (2026-10-14):** the generic view registry.
- `screen/view_registry.ml` holds the installed views, each an adapter
  (`View_registry.Adapter.t`: spec, typed state key, fit, leave, text view,
  interpret/escape/hint, perform, local commands, render) with its state and a
  placement (`Hidden | Band`). `Ui_state` allocation, leaving, synchronizing,
  key routing (`feed_capture`), the shared cursor/text-view queries, and `Frame`'s
  minor rendering all go through it by view id. Problems, history and the demo report
  are migrated; `Ui_state.create ~views` installs further views with no per-name code.
- `View_command` has `Toggle_view`, `Focus_view` and `Run_view_command` parameterized
  by `View_id` (now defined in `ches_input` and re-exported by `ches_tile`) instead of
  `Toggle_problems`, `Focus_problems`, `Toggle_demo_report`, `Focus_demo_report`,
  `Toggle_history` and `Focus_history`. Bindings and palette ids/titles are unchanged.
- View-local commands (`Ches_tile.Local_command`): adapters declare them per state;
  `?` opens a read-only help float listing them, and the command palette lists the
  focused view's commands first and runs them in that view.
- Still per-name, by design: the problems-specific commands (`Toggle_problems_filter`,
  `Inspect_problems`), diagnostic anchoring hooks, and the floats (palette, pickers,
  help), which are not registered views. The role and boundary contract that remains in force is in the [design doc](../workspace_tiles_design.md)
under "Shared tile direction — Major/minor roles and consumer-independent plumbing".

**Done in VCS workspace phase 0B (2026-10-14):** view tabs and the major split.
- `View_registry.Placement.t` (= `View_command.Placement.t`) is
  `Hidden | Band | Tab | Split`; a view has exactly one. `screen/tab_strip.ml`
  interleaves view tabs with the session's file tabs and remembers the active view
  tab; the session's file tabs, directory presentation and quit/dirty checks are
  untouched. An active view tab fills the editor area and is drawn by
  `View_registry.render`, in both buffer presentations.
- `Workspace.allocate ?split` divides the editor area between the active tab and
  one split view (`Workspace.Major_split`: side and percent).
- Generic commands: `Place_view` (by id, or the focused view), `Focus_other_pane`,
  `Swap_split`, `Adjust_split`, bound under `Space s` with palette entries.
- Later (2026-10-27): `Close_split` (`Space s c`, `split.close`) closes the split
  view from either pane, through the same path as `Place_view` to `Hidden`, even
  while zen or a narrow editor area keeps it from being shown.

**Done in VCS workspace phase 0C (2026-10-18):** questions a view asks.
- An adapter's outcome may carry a `View_registry.Ask.t`: a confirmation (`y` only;
  `screen/confirm_tile.ml`) or a single-line prompt with validation
  (`screen/prompt_tile.ml`), each naming the view's own action per answer. The
  registry keeps the pending question; `Ui_state` opens it on the single float slot
  over the view and delivers the answer back through `View_registry.answer`.

**Done in VCS workspace phase 2 (2026-10-27):** the first Major registered view.
- `screen/vcs_view.ml` (id `vcs`, role `Major`, `accepts_tab`) is installed by the
  frontend through `Ui_state.create ~views`, hidden and opening in a tab, with no
  per-name code in `Ui_state`: `Space g g/f` are `Focus_view vcs` and
  `Space g t/s/h` are `Place_view { view = Some vcs; ... }` (palette `vcs.open`,
  `vcs.to-tab`, `vcs.to-split`, `vcs.close`). Without a runner the frontend installs
  it as `View_registry.Entry.unavailable` ("VCS unavailable in this session").
- Generic seams it introduced, usable by any later view: background jobs in an
  outcome (`Outcome.jobs`, handed to the frontend by `Ui_state.take_vcs_jobs` and run
  by `ui/vcs_host.ml`, whose events come back as `Input.Vcs`), signals (`Shown`,
  `Saved`, `Job`), `Outcome.open_file`, and `Adapter.text_area`.

**Done in VCS workspace phase 3 (2026-10-27):** the view acts on the repository.
- `s u x S U` in the Files panel and the diff, `]`/`[` between hunks; the backend
  plans each action, the view submits it as one `Mutate` job, asks first with
  `Ask.Confirm` for discards, and refuses work-tree rewrites while a file buffer
  in the repository is dirty.
- Generic seams it introduced: `View_registry.Context` (the session's file buffers,
  dirty or missing, in every `perform`) and `Outcome.reconcile` (reload clean
  buffers under a root from disk, mark deleted ones missing).

**Done in VCS workspace phase 4 (2026-10-27):** line staging from a Visual selection.
- Visual `s u x` in the diff build `Backend.Target.Lines` from
  `Vcs_diff_text.span` of `Text_view.selection` (one file, every touched hunk line);
  the backend applies one patch (`Patch.hunks`) for all of them. No new seams:
  refusals keep the view's Visual selection, running or asking ends it.

**Done in VCS workspace phase 5 (2026-10-28):** popups and the commit flow.
- `c` asks `Ask.Popup` (`Git.Commit.popup`, drawn by `screen/popup_tile.ml`); its
  answer is the view's own action. Commit and amend read the message file as a
  `commit`-lane job, then hand it to the user as a file tab (`Location.contents`);
  `Space g c` / `Space g a` reach the view as `Signal.Request` from that buffer
  (`Context.active`), finishing with `Outcome.save` before the commit job and
  `Outcome.dispose` after it. The view's tab label (`Adapter.label`) names the
  branch.
- Generic seams it introduced (phase 5 agent A): popup questions, `Location.contents`,
  `Outcome.save` / `Outcome.dispose`, `Context.active`, `Signal.Request` with
  `View_command.Request_view`, `Adapter.label`, and a signalled `open_file` that
  applies only while the view is focused.

**What is not done:**
- Moving `Tile_shell` out of `ches_screen` into a library that dune keeps away from
  `ches_error`.
- Any other specialized major tile, such as a Hardcaml report or workbench.
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
  (as `ches_tile` is) is still open. (The per-name wiring noted here originally was
  replaced by the view registry in VCS workspace phase 0A.)

## Later major-tile specialization

After these shared boundaries work, expand the major-tile contract only for a
concrete consumer. The editor keeps its richer editing/undo/file behavior behind
its content adapter; a future Hardcaml report/workbench could supply structured
reports, charts, drill-down, or source actions while reusing the shell and applicable
read-only interactions. Choose producer/data contracts and required overrides in a
separate assignment. Neither minor tiles nor a read-only major report require the
error system or editor buffer model merely to participate in the workspace.
