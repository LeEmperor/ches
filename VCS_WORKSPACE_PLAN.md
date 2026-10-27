# VCS Workspace: a lazygit/Magit hybrid inside Ches

Status: re-scoped on 2026-10-14 after a feature brainstorm. Phases 0A, 0B and 0C
are implemented and committed (237e9dd). Owner terminal acceptance (2026-10-25): the
`?` help float, view tabs (`Space s t`) and the split (`Space s s`) confirmed; the
palette's local-command ordering not separately confirmed; 0C's floats have no real
requester until phase 3. Follow-ups after acceptance (2026-10-25..27): counts repeat
the resize and shift steps, `Space s c` closes the split from either pane, and
placement/close notices typed inside a view reach the status line. Phase 1 (VCS
core, git parsing, async runner) and phase 2 (the read-only VCS view, Space g)
complete and uncommitted (2026-10-27), owner terminal acceptance of phase 2 pending.
Phases 3-6 not started.

## Goal

Move the owner's everyday git work from a spare terminal into Ches: see what
changed, stage (files, hunks, lines), commit, push/pull/fetch, and switch/create
branches. The surface combines **lazygit's layout** (list panels beside a large
diff panel, with a command log) and **Magit's interaction** (context keys that exist
only while the VCS view is focused, popup menus with switches, the commit message
written in an ordinary Ches buffer).

Git is the first backend. Mercurial (and possibly jj) are later backends, so the
backend-agnostic layer must not assume a staging index.

“VCS workspace” is the umbrella name. Use `vcs` for backend-agnostic code and `git`
for the git backend.

### Observed workflow (2026-10-14)

Shell history is almost entirely `git add`, `git commit -m`, `git push`, plus one
`git reset`. The repository uses feature branches (`bpurtell/*`), has merge-conflict
and stacked-commit pain in its history, and has no stashes, extra worktrees or tags.
The first milestone targets that loop: status → stage → commit → push, plus branch
switching and pull.

## Owner decisions (2026-10-14)

- **Layout:** hybrid. List panels on the left (Files, Branches, Commits), a diff
  panel on the right showing the current selection, and a toggleable command log.
- **Placement:** both. The VCS view can be an entry in the **file-tab strip** (it
  fills the editor area while active and cycles with `Space b n`/`Space b p`), or
  open in a **split**, a peer major pane beside the editor with an adjustable ratio.
  (This replaces the earlier narrow "Side" slot idea for VCS.)
- **View-local commands:** keys like `s`, `u`, `c`, `P` exist only while the VCS
  view is focused. `?` inside the view lists them, and the command palette shows
  the focused view's commands first.
- **Commit** is finished by an explicit command (`Space g c`), aborted with
  `Space g a`, never by save or close.
- **First milestone** includes push, pull and fetch.
- **Registry first:** no new per-name wiring in `Ui_state`/`View_command`.
- **Open:** which tier-2 item comes after this plan: merge/conflict resolution or
  log/history browsing.

## Interaction model

### Workspace bindings (leader)

| Keys | Command |
| --- | --- |
| `Space g g` | Open VCS (as a tab, activated) or focus it where it already is |
| `Space g t` | Move the VCS view into the tab strip |
| `Space g s` | Move the VCS view into the split |
| `Space g h` | Close the VCS view (repository state is just re-read on reopen) |
| `Space g f` | Toggle focus between the VCS view and the editor (split) |
| `Space g c` | Finish commit: only in a pending commit-message buffer |
| `Space g a` | Abort commit: close the message buffer without committing |

Generic split commands (resize, swap sides, focus the other pane) come from phase 0B
and are not VCS-specific. Space is the leader everywhere outside text inputs, so
view-local keys must not use it.

### Inside the VCS view (proposed; agents may adjust collisions and record why)

| Scope | Keys | Action |
| --- | --- | --- |
| Whole view | `1` `2` `3` | Focus Files / Branches / Commits panel |
| | `0`, `Tab` | Focus the diff panel; `Tab` again returns to the list |
| | `?` | Help float listing every view-local key for the focused panel |
| | `gr` | Refresh |
| | `@` | Toggle the command log |
| | `c` | Commit popup |
| | `P` / `p` / `f` | Push popup / pull popup / fetch |
| | `q`, `Escape` | Leave the view (host's normal return) |
| Files | `j` `k` `gg` `G` | Move; the diff panel follows the selection |
| | `Enter` | Fold a section header; on a file, focus the diff panel |
| | `s` `u` `x` | Stage / unstage / discard (confirmed) the file or section |
| | `S` `U` | Stage all / unstage all |
| | `e` | Open the file in the editor (the other pane when split) |
| Branches | `Enter` | Check out the branch |
| | `n` | New branch from HEAD (name prompt), checked out |
| | `-` | Check out the previous branch |
| Commits | `Enter` | Focus the diff panel showing that commit (`git show`) |
| | `y` | Copy the abbreviated hash |
| Diff panel | `Text_view` keys | `j k w b 0 $ gg G Ctrl-d Ctrl-u v V y` |
| | `s` `u` `x` | Act on the hunk at the cursor, or on Visual-selected lines |
| | `]` `[` | Next / previous hunk |
| | `e`, `Enter` | Open the file at the corresponding line |

### Panels

- **Files:** grouped into Conflicted, Untracked, Unstaged and Staged section headers
  (foldable, Magit-style), a flat path list beneath each. Head summary above them:
  branch, upstream, ahead/behind, and any merge/rebase in progress.
- **Branches:** local branches, current marked, with upstream and ahead/behind.
- **Commits:** recent history of HEAD (bounded, e.g. 200), read-only in this plan.
- **Diff:** the selected file's unstaged or staged diff, a section header's combined
  diff, or the selected commit's `git show`. Styled added/removed/hunk lines.
- **Command log:** recent git commands with exit status and stderr/stdout tail.

At narrow widths (a split, a small terminal) the list panels and the diff stack
vertically instead of side by side; below a minimum, only the focused part shows.

### Proposed defaults (finalize during implementation; record in handoffs)

- Selection identity is stable across refresh (section + path, branch name, commit
  hash). After an action removes the selected item, select the next in the same
  section, else the previous, else the header.
- Refresh triggers: on open, on `gr`, after every VCS command, and (coalesced) after
  a Ches save of a file inside the repository. No polling or file watching.
- The VCS view occupies exactly one placement at a time: tab, split, or closed.
  Moving it never duplicates it.
- Zen hides the split pane and restores it afterwards. If the split pane cannot fit
  its minimum width beside the editor (and any side directory tile), it is hidden
  with a notice and stays in split placement until it fits again.
- Destructive actions (discard, delete untracked files, force-with-lease push) use a
  confirmation float. The default answer is No; only `y` confirms.
- Commands that rewrite working-tree files (discard, checkout, pull) are refused
  while any Ches file buffer inside the repository is dirty. The notice names
  the buffers. The user saves or discards first.
- Commit message file is `$(git rev-parse --git-path CHES_COMMIT_EDITMSG)`, never
  `COMMIT_EDITMSG` itself (git rewrites that during `commit -F`). It is opened as
  an ordinary session file buffer with a `#`-commented summary of staged files, and
  committed with `git commit --cleanup=strip -F <file> [switches]`. Amend pre-fills
  HEAD's message.
- Network: `fetch` = `git fetch --prune`; pull defaults to `--ff-only` (switches for
  `--rebase`); push to the configured upstream, or offers `-u origin <branch>` when
  there is none. See the authentication constraints below.

## Architectural boundaries

### Existing seams (rechecked 2026-10-27, after phases 0A-0C)

- `tile/` (`ches_tile`, depends on `ches_core`/`ches_input` only): host
  focus/capture/routing, `Spec` (including `accepts_tab`), `Navigation` (lists and
  `Selection`), `Text_view` (read-only cursor, Visual, yank), `Local_command`
  (view-local commands); `View_id` re-exports `ches_input`'s.
- `screen/view_registry.ml`: installed views as adapters (`Adapter.t`), placements
  `Hidden | Band | Tab | Split`, local commands, `Ask` questions (confirm/prompt).
  `screen/ui_state.ml` (~2500 lines) no longer wires minor tiles by name: generic
  paths go through the registry (problems, history and the report keep typed
  wrapper accessors). It owns the single float slot (palette, pickers, help,
  confirm, prompt); `Floating` gives centered geometry.
- `screen/workspace.ml`: allocation of the document pane, side directory, status,
  band views and the major split (`Major_split`). `screen/tab_strip.ml` interleaves
  view tabs with the session's file tabs.
- `app/session.ml`: buffers, the file-tab list (file buffers only), and the
  directory presentation (`Major | Side`), unchanged by 0B.
- `input/view_command.mli`, `input/bindings.ml`, `palette/`: commands, bindings,
  palette catalog. Views are named by `View_id` (`Toggle_view`, `Focus_view`,
  `Place_view`, `Run_view_command`); `Focus_problems` and the like are gone.
- Async precedents outside the transition path: `file_picker/{discovery,host}`,
  `content_picker/{provider,host}`, `source/`. Results enter as `Ui_state.Input`
  events (`File_picker_update`/`File_picker_work`, `Content_picker_snapshot`,
  `Source`) and are rejected when stale (run/request identity; `Source_event.Owned`
  generations). The frontend wiring is in `ui/editor_view.ml` (`ches_ui`), not
  `bin/` (which only builds the source and calls `Editor_view.run`). `ches_source`
  is the closest precedent for a long-lived runner: its event type lives in pure
  `ches_error`, requests leave `Ui_state` as data (`take_source_requests`), and
  `Editor_view` pumps `Source.next_batch` into `Ui_state.Input.Source`. `ches_app`,
  `ches_screen`, `ches_core`, `ches_input`, `ches_tile` stay free of Async.
- `docs/backlog/major_minor_tiles.md`: records what 0A-0C finished.

### Target libraries

```text
vcs/          ches_vcs        pure, backend-agnostic, no Async, no ches_app:
                              panel/section models with stable selection identity,
                              popup ("transient") model, command spec (argv, env,
                              read | mutate | network), backend signature
vcs/git/      ches_vcs_git    pure: porcelain v2 / diff / log / branch parsers,
                              patch builder (hunk or selected lines -> patch),
                              git actions -> command plans
vcs/host/     ches_vcs_host   Async: process runner, one-mutation-at-a-time queue,
                              streaming output for network commands, generation
                              stamps, timeouts, cancellation on quit
screen/       adapters        VCS view (panels + diff + log), popup float
```

- The backend-agnostic layer never mentions an index. Backends declare their own
  panels' item kinds, actions and popups; git's stage/unstage live in `ches_vcs_git`.
- Shell out to the `git` CLI (2.43 here), not libgit2. Use `--no-pager`,
  `-c color.ui=false`, `-c core.quotepath=false`, NUL-separated output where
  available, `--no-ext-diff`, `GIT_OPTIONAL_LOCKS=0` for read commands, stdin from
  `/dev/null`. Never pass user text through a shell.
- Results return as `Ui_state.Input` events carrying a generation; stale ones are
  dropped. Mutations and network commands are serialized and followed by a refresh.
- Failures (non-zero exit, stderr) go to the command log and shared feedback/history
  with the command line. They never crash or block the editor.
- Diffs are bounded: per-file byte/line limits with a placeholder beyond. Binary,
  submodule, mode-only and rename-only changes render as headers without line actions.

### Authentication constraints (network commands)

Ches owns the terminal, so a git child must never prompt on it. `ssh` opens
`/dev/tty` directly for passphrase and host-key prompts, which would corrupt the UI.
Run network commands with `GIT_TERMINAL_PROMPT=0`, and when the user has not set
`GIT_SSH_COMMAND`/`core.sshCommand`, `GIT_SSH_COMMAND="ssh -o BatchMode=yes"`.
Credentials come from ssh-agent or a credential helper. On authentication failure,
show a clear notice (e.g. "ssh-agent has no key loaded") and the stderr in the log.
The owner's remote is `git@github.com:` over SSH.

### Open-buffer reconciliation (introduced in phase 3, reused by phase 6)

There is no filesystem watching. After any VCS command that can change working-tree
files (discard, checkout, pull), for retained file buffers inside the repository:
- reload clean buffers whose on-disk content changed (preserving cursor/scroll where
  possible) and mark deleted ones missing;
- dirty buffers cannot be affected, since such commands are refused while one exists.
Staging/unstaging never touches the working tree. Staging a file whose buffer is
dirty warns that the unsaved text is not staged.

## Phased implementation

Phases run strictly sequentially. Within a phase, work may be split across up to
three agents (see the protocol). Each phase lands in a usable, tested state and
appends a handoff below.

### Phase 0A: View registry and view-local commands

- Replace per-name minor-tile wiring in `Ui_state` (visibility flags, `leave`,
  `synchronize`, `feed_capture`, `text_view`, ...) with a registry of installed
  views and adapter callbacks. Migrate problems, history and the demo report with
  unchanged behavior.
- Replace per-consumer view commands (`Focus_problems`, `Toggle_history`, ...) with
  commands parameterized by `View_id` where practical. Existing keybindings and palette
  entries/titles keep working.
- View-local commands: an adapter can declare its commands (name, keys, description)
  for the focused state. Add a generic `?` help float listing them (a read-only
  list on the float slot), and make the command palette list the focused view's
  commands first and dispatch them to that view.
- Prove extensibility with a test-only view: installing it and its local commands
  requires no per-name branches in `Ui_state`.
- Update `docs/backlog/major_minor_tiles.md` to say what is now done.

### Phase 0B: Views in the tab strip, and the major split

- Tab entries become `File of Buffer_id | View of View_id` (names may differ). A view
  tab fills the editor area while active, has a label from its adapter, takes part in
  next/previous/close, and renders in both buffer presentations (top strip and
  status rows). Closing a view tab closes the view through its adapter. File-tab
  behavior, directory presentation, and quit/dirty checks are unchanged.
- A major split: the editor area holds the active tab on one side and one view on
  the other, peer-sized, with an adjustable ratio, a focus-other-pane command, and
  swap sides. It coexists with the side directory tile and status per the defaults
  (fit/hide rules, zen).
- A view occupies one placement at a time (tab, split, closed). Generic commands
  move a view between placements.
- Prove with the test-only view from 0A: tab, split, move between them, resize,
  focus, zen, and narrow-terminal behavior, headlessly.

### Phase 0C: Confirmation and prompt floats

- Confirmation float: title, message, `y` confirms, `n`/`Escape`/`Ctrl-c` cancel;
  returns a typed decision to the requester; refuses to open (with feedback) when it
  cannot fit; follows the single-float policy.
- Single-line prompt float (for branch names and similar): title, text input with
  paste, validation callback with inline error, `Enter` accepts, `Escape` cancels.
  Reuse the palette's text-input handling.
- Headless tests: fit/refusal, routing, focus return, cancel paths, paste.

### Phase 1: VCS core, git parsing, and the async runner

- `ches_vcs`: panel/section models, stable selection identity across snapshots,
  popup model, command spec, backend signature.
- `ches_vcs_git`: repository detection (`rev-parse --show-toplevel --git-dir`),
  `status --porcelain=v2 -z --branch` (renames, conflicts, submodules, untracked),
  branch list with upstream/ahead/behind (`for-each-ref`), bounded log, in-progress
  merge/rebase detection, `diff`/`diff --cached`/`show` parsing into files and hunks.
- `ches_vcs_host`: Async runner with generation stamps, serialized mutations,
  streaming output for long commands, timeouts, the authentication environment
  above, cancellation on quit; wired from the frontend like the file-picker host.
- Tests: pure parser tests over captured outputs, plus fixture repositories in
  isolated temp directories (see protocol), including a local bare "remote" for
  later network tests. No UI yet.

### Phase 2: Read-only VCS view

- The hybrid view on the 0A registry and 0B placements: Files, Branches and
  Commits panels, the diff panel following the selection, the command log, the
  narrow-width stacking rule, `?` help, refresh triggers, and the `Space g`
  placement commands with palette entries.
- `e`/`Enter` from the diff opens the file at the corresponding line, in the other
  pane when split.
- Not-a-repository state renders a clear message instead of failing.

### Phase 3: Stage, unstage, discard for files and hunks

- `s`/`u`/`x` on files, section headers and the hunk at the diff cursor; `S`/`U`.
  Hunk actions apply a generated patch with `git apply --cached` (reverse for
  unstage; working-tree reverse for discard), checked with `--check` first.
  Untracked: stage = `git add`, discard = delete after confirmation.
- Confirmation for every discard; the dirty-buffer refusal; open-buffer
  reconciliation; selection anchoring after actions.

### Phase 4: Line-level staging from a Visual selection

- Pure patch builder: from a hunk and selected lines, unselected `-` lines become
  context and unselected `+` lines are dropped, with recomputed headers; reverse for
  unstage; `\ No newline at end of file` handling. Refuse line actions on binary,
  rename-only and mode-only items.
- `s`/`u`/`x` with a Visual selection in the diff panel act on the selected lines.
  A selection spanning hunks applies per hunk; one spanning files is refused.
- Exhaustive pure tests, plus fixture tests that verify the index after applying.

### Phase 5: Popups and the commit flow

- Generic popup float on the `ches_vcs` popup model: a titled grid of switches
  (toggle with `-` + key) and actions (single key), showing enabled switches;
  `Escape`/`q` closes. The popup's keys appear in `?` help.
- Commit popup (`c`): actions `c` commit, `a` amend, `e` extend (amend `--no-edit`);
  switches `-n` `--no-verify`, `-s` `--signoff`, `-e` `--allow-empty`. Refuse commit
  with nothing staged unless `--allow-empty`.
- Commit/amend open the message buffer (see defaults) as a file tab, with the VCS view
  kept where it was, and remember the pending switches. `Space g c` saves and commits.
  On success the buffer closes, the file is removed and the view refreshes. On failure
  (hook rejection, empty message) the buffer stays open and stderr is shown.
  `Space g a` closes without committing. Both refuse outside a pending commit
  buffer. Extend runs immediately.

### Phase 6: Remotes and branches

- `f` fetch; pull popup (`p`: `p` pull, switches `--rebase`, `--ff-only` default);
  push popup (`P`: `p` push, `u` push and set upstream to `origin/<branch>`, switches
  `-f` `--force-with-lease` (confirmed), `-n` `--no-verify`). Progress streams into
  the command log; the view stays usable while it runs. Authentication per the
  constraints above.
- Branches: checkout (`Enter`), new branch (`n`, prompt float, validated with
  `git check-ref-format --branch`), previous branch (`-`). The dirty-buffer refusal
  and reconciliation apply to checkout and pull.
- If a pull leaves a merge or rebase in progress, the head summary says so and offers
  only abort (`git merge --abort` / `git rebase --abort`), confirmed. Resolution is
  deferred.
- Fixture tests against a local bare remote: push, set-upstream, ff-only pull
  refusal on divergence, rebase pull, fetch prune, auth-failure handling (simulated).

## Agent execution and handoff protocol

Phases run strictly sequentially. An orchestrating session splits each phase across
at most three implementation agents, with disjoint files and contracts fixed before
any parallel work starts; it reviews, runs the full suite, and writes the handoff.
Every agent starts by reading this plan, all earlier handoffs, and the current
interfaces. Earlier phases may have changed the architecture described here.

- **Load limit (2026-10-25):** the total dune job budget is 10. Every dune
  invocation passes `-j 10` and goes through one shared lock, so at most one runs
  at a time: `flock /tmp/claude-1000/ches-dune.lock dune build -j 10`, likewise
  `dune runtest -j 10`. (Dune itself aborts a second instance in the same tree with
  "Another Dune instance is currently running".) Agents working in parallel build
  only their own directories (e.g. `dune build -j 10 @vcs/git/runtest`) until
  the final full run. Never background or watch mode. The host is unstable under
  heavy load.
- **No attributable git actions in this repository:** no `git add`, `commit`,
  `push`, `stash`, `checkout`, `reset`, `restore`, branch or config changes, and no
  Co-Authored-By lines anywhere. Read-only git (`status`, `diff`, `log`, `show`) is
  fine. Leave all changes uncommitted for the owner.
- **Fixture repositories** live in fresh temp directories only. Isolate them with
  `GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_NOSYSTEM=1`, and a neutral identity
  (`Ches Test <ches-test@example.invalid>`); "remotes" are local bare repositories.
  Never run feature mutations against the Ches repository itself, and never contact
  a real network remote.
- Implementation agents do not spawn further agents. Do not run the interactive
  TUI. Drive behavior headlessly through `Ui_state`, as existing tests do.
- Keep the library boundaries above. Match the surrounding code style and `.mli`
  documentation density.
- Record the baseline (`dune build -j 10`, `dune runtest -j 10`, through the lock)
  before changing code so pre-existing failures are not attributed to the phase.
  Known flake: `content_picker/host/test/test_runtime.ml` (empty pid file read
  mid-write); rerun that directory once before treating it as a failure.
- Do not claim a phase complete if a required behavior is stubbed or a check could
  not run. Human terminal acceptance is separate and stays pending.

Append a handoff for each phase:

```text
Phase / date / status:
Implemented behavior:
Changed modules and new public contracts:
Policy decisions settled:
Checks run and results:
Known gaps or blockers:
Next-phase integration notes:
```

## Deferred beyond this plan (tier 2 and later)

- Merge a branch, and conflict resolution (pick ours/theirs/both per hunk,
  continue/abort).
- Log graph, commit file lists, file history, blame.
- Interactive rebase as an editable todo buffer applied on save (the directory-buffer
  pattern), fixup/squash, cherry-pick, revert.
- Stash, reflog, undo; branch delete/rename; tags; worktrees; submodules; bisect.
- A VCS summary in the status tile.
- Mercurial backend (no index: Monky-style in-memory staging or `commit -i`), jj.
- Filesystem watching and automatic refresh on external changes.

## Phase 1 contracts (stage 1, 2026-10-27)

Stage 1 fixed the contracts so that agent G (`ches_vcs_git`) and agent H
(`ches_vcs_host`) can work in parallel. `ches_vcs` and the fixture are implemented
and tested; the git and host `.mli` files are the contracts, with compiling stubs
(`failwith "TODO phase 1: agent G"` / `"... agent H"`; grep `TODO phase 1`).

```text
vcs/              ches_vcs           pure, core only            stage 1, done
  exec            Kind (Read < Mutate < Network), Stdin (Null | Data), Stream,
                  Spec {prog; args; cwd; env; kind; stdin; timeout; stdout_limit;
                  stderr_limit; stream}, Status, Result {status; stdout(+truncated);
                  stderr(+truncated); timed_out; cancelled; elapsed}
  job             Id {generation; sequence}, File_read, Step (Run spec | Read_file),
                  Step.Outcome (Ran | Read | Skipped), Step_report, t {id; lane;
                  steps}, Report {id; lane; kind; steps; cancelled}, never_started
  event           Started | Output {line; transient} | Finished of Job.Report.t
  stamps          consumer-side ids and staleness (generation + latest per lane)
  panel           Panel/Section/Item, Position (Header | Item {section; key}),
                  Cursor {selected; folded}: rows, reconcile (the selection rule),
                  select, toggle_fold
  popup           Switch {key; flag; description; group}, Action {key; description;
                  run : enabled:string list -> 'a}, State, press/escape/help
  diff            Diff.t {preamble; files; cut}, File (paths, change, modes, raw
                  header, hunks, binary/submodule/combined, truncated), Hunk, Line,
                  Limits; mode_only / rename_only / line_actions
  backend         Detection, Refresh, Summary, Plan + Plan.Decision
                  (Run | Confirm | Refused), module type S
vcs/test/         ches_vcs_test                                 stage 1, done
vcs/fixture/      ches_vcs_fixture   test-only: Fixture_repo   stage 1, done
vcs/fixture/test/ ches_vcs_fixture_test                         stage 1, done
vcs/git/          ches_vcs_git       pure: Cli, Repository, Status, Branch_list,
                  Log, In_progress, Diff_output, Backend (: Ches_vcs.Backend.S)   G
vcs/git/test/     ches_vcs_git_test                                               G
vcs/host/         ches_vcs_host      Async: Runner, Auth                          H
vcs/host/test/    ches_vcs_host_test                                              H
```

Backend signature (`Ches_vcs.Backend.S`): `detect ~cwd` / `detected` (repository
detection), `refresh repo r` -> steps, `snapshot repo r reports` -> `Snapshot.t
Or_error.t`, `summary`, `panels`, `diff_target snapshot panel position`, `diff` ->
steps, `parse_diff`, `plan repo snapshot action` -> `Plan.Decision.t`. Parse
functions get the `Job.Report.steps` of a job built from exactly the steps returned,
in order.

Ownership. G: `vcs/git/*.ml` and everything under `vcs/git/test/`. H:
`vcs/host/*.ml` and everything under `vcs/host/test/`. Each may add private modules
(new `.ml`/`.mli`) in its own directory and libraries to its own `dune` files
within the boundaries (`ches_vcs_git`: no Async, no Unix; `ches_vcs_host`: no
`ches_screen`/`ches_ui`). Frozen for both: `vcs/*.ml(i)`, `vcs/test/`,
`vcs/fixture/`, and the `.mli` files of `vcs/git/` and `vcs/host/`; a needed
contract change goes to the orchestrator and into the handoff. Neither library
depends on the other: H's tests build specs by hand (or via the fixture), never via
`Ches_vcs_git`, whose stubs fail until G lands. Helpers either agent wants beyond
`Fixture_repo` live in its own test directory.

Frontend wiring decision: phase 1 adds no `Ui_state.Input` case and no `ches_ui`
wiring; phase 2 does both when the view exists. Following `ches_source`, the seam is
already in the types: `Ches_vcs.Event.t` and `Ches_vcs.Job.t` are pure, so phase 2
adds `Ui_state.Input.Vcs of Ches_vcs.Event.t` and a `take_vcs_jobs` (requests leave
the transition as data), and `Editor_view` submits jobs to one `Runner.t`, pumps
`Runner.next_batch` into inputs, and calls `Runner.stop` on exit. The view keeps a
`Stamps.t` and drops reports it does not accept. A stub input now would have no
producer or consumer to test.

Deviations from the target libraries and git CLI rules, with reasons:
- The command-spec module is `Ches_vcs.Exec`, not `Command`: `open! Core` shadows
  any library-local `Command` with `Core.Command`.
- Detection runs `rev-parse --show-toplevel --absolute-git-dir` (not `--git-dir`,
  which is relative to the cwd) so the git directory can be read directly.
- Jobs may contain `Read_file` steps beside commands: merge/rebase/am/cherry-pick/
  revert/bisect state is detected from the git directory's state files (as git and
  Magit do) without a process per file.
- Stdin is `Null` or `Data` (for phase 3's `git apply --cached`): a pipe, never the
  terminal, which is what the "stdin from /dev/null" rule protects.
- Reads also get `LC_ALL=C` (parsed fields such as `%(upstream:track)` are
  translated in other locales); mutations and network commands keep the user's
  locale (hooks run under them).
- `GIT_TERMINAL_PROMPT=0` is forced for every child, not only network ones. The
  `GIT_SSH_COMMAND` batch-mode default is git-specific yet lives in
  `Ches_vcs_host.Auth`, which learns `core.sshCommand` by running
  `git config --get core.sshCommand` before each network step.
- Reads may run concurrently with each other and with the running mutation (git
  reads take no optional locks; a refresh always follows the mutation, and stale
  reads are dropped), so a long push never freezes the view. Mutations and network
  jobs share one FIFO queue.
- Default timeouts: reads 30 s, mutations and network 10 min. Children run in their
  own process group; termination is SIGTERM to the group, then SIGKILL after a grace
  (2 s), so git can remove `index.lock`.
- Git's `action` type is empty in phase 1; constructors arrive with phases 3-6.
  Popups are not yet in `Backend.S`; phase 5 adds them (the model is
  `Ches_vcs.Popup`).
- A test-only library, `ches_vcs_fixture`, holds the isolated fixture repositories
  and a synchronous step runner, so G can test specs against real git without H.

Notes for G and H beyond the `.mli` files:
- git on this host is 2.43.0. Expect tests should not print absolute temp paths
  (replace `t.dir`), and fixture commit hashes are reproducible (fixed dates).
- G: `Fixture_repo.run_steps` executes a backend's steps synchronously; that is the
  intended way to test `Backend` end to end. The unborn-branch log failure
  (exit 128) is normal; `git diff --no-index` exits 1 on differences.
- H: create runners with `~inherited:(Fixture_repo.environment t)`, which already
  drops every inherited `GIT_*` variable (so `GIT_SSH_COMMAND` is unset). Network
  tests push/fetch to `t.remote` (a path); never to a URL. For timeout, streaming and
  termination tests, small helper programs in `vcs/host/test/` are fine (as
  `fake_rg` is elsewhere); keep tests within the job budget and short.

## Phase 2 contracts (stage 1, 2026-10-27)

Stage 1 cleaned up phase 1's contract gaps, built and tested the generic seam for a
registered view to run background jobs, and fixed the contracts so that agent V (the
VCS view, `screen/`) and agent W (wiring: runner, install, bindings, palette, docs,
end-to-end test) can work in parallel. Stubs fail with `"TODO phase 2: agent V"` /
`"... agent W"` (grep `TODO phase 2`); no test runs them.

Phase 1 cleanup (done, tested):
- `vcs/diff.mli`: combined lines have no `old_line`; their `new_line` counts the result
  from the hunk's `new_start`; `Limits.file_bytes` counts line texts only;
  `Change.Unmerged` documented (conflict combined diff or `* Unmerged path` line).
- `vcs/git/diff_output.mli`: the `* Unmerged path X` file and the combined change-type
  rule. `vcs/host/runner.mli`: a Network step's `Started` follows the
  `core.sshCommand` probe (none if cancelled during it).
- `Diff.File.line_actions` is false for `Unmerged` (vcs/test/test_diff.ml; the
  conflict expectations in vcs/git/test now say `no-line-actions`).
- Git `diff_target` is `None` for an Untracked key ending in `/` (nested repository,
  untracked directory); test "an untracked nested repository ..." in
  vcs/git/test/test_backend.ml.

The seam (implemented in `screen/view_registry.ml(i)`, `screen/ui_state.ml(i)`; test
`screen/test/test_view_jobs.ml` with two test-only "worker" views):
- `View_registry.Outcome.t` gains `jobs : Ches_vcs.Job.t list` and
  `open_file : Location.t option` (`{ path; line : int option }`); `Outcome.create`
  takes `?jobs ?open_file`.
- `View_registry.Signal.t = Shown | Saved of string list | Job of Ches_vcs.Event.t`;
  `Adapter.t` gains `signal : 'state -> Signal.t -> 'action option` (the view turns
  a signal into one of its own actions, performed like a key's) and
  `text_area : 'state -> rows -> width -> Geometry.Rect.t option` (where open text
  sits inside the content, so the terminal cursor lands on the diff panel's text).
  Existing adapters return `None` for both.
- `Entry.install ?opens_in` (default `Band`): where `Focus_view`/`Toggle_view` show a
  hidden view. The VCS view opens in `Tab`, so `Space g g` needs no new command.
- `Ui_state.Input.Vcs of Ches_vcs.Event.t`; `Ui_state.take_vcs_jobs`. Ownership:
  Ui_state maps each job id in flight to the view whose outcome carried it (until
  its `Finished`) and routes events there; staleness is the view's own (`Stamps`).
  A job whose id is already in flight (any view) is not submitted: its submitter is
  signalled `Finished (Job.never_started job)` at once, so one runner serves every
  view. Consecutive `Vcs` inputs are one step (one synchronization), like `Source`.
- Signals: `Shown` after the input that moved a view out of `Hidden` (or the first
  input for a view installed placed), not for moves between placements; `Saved`
  after an input that saved files (absolute session paths, all of that input's
  saves in one signal, every installed view); `Job` per event. Saves are peeked
  (`Session.saved`, new), so `take_source_requests` is unchanged.
- A signalled action never moves focus or disturbs the focused view: controller and
  jobs apply; a `` `Post `` notice goes to feedback only; `` `Show ``, effect,
  return and open_file are ignored; a question opens only while the asking view is
  focused, else it is withdrawn. A key's (or palette/answer's) outcome applies in
  the order controller, effect, notice, return, open_file, jobs, ask.
- `open_file` (handled generically in Ui_state, so W does not touch it): like a
  picker, `Session.open_or_activate ~must_exist:true`, the file tab replaces an
  active view tab, focus returns to the editor area (the other pane beside a split
  view), cursor at the line's first column, clamped to the file; failure is the
  view's footer notice.
- `Style.Diff_added | Diff_removed | Diff_hunk | Diff_meta` with theme colors
  (Insert accent, Error, Special on Surface; meta bold).
- `screen/test/vcs_driver.ml`: runs `take_vcs_jobs` synchronously in a
  `Fixture_repo` (`run_steps`) and feeds `Started`/`Finished` back as `Input.Vcs`;
  `settle` repeats until no view submits. `screen/test/dune` now has `ches_vcs`,
  `ches_vcs_git`, `ches_vcs_fixture`.

Dependencies: `ches_screen` now depends on `ches_vcs` and `ches_vcs_git` (both core
only: no Async, no Unix), and stays free of Async; `ches_vcs_host` remains reachable
only from `ches_ui` (`ui/dune` now lists `ches_vcs`, `ches_vcs_host`). No cycle: the
vcs libraries depend on nothing in the UI.

`screen/vcs_view.mli` (V's contract): id `vcs`; spec read-only text, role Major,
`accepts_tab`; title "VCS" (static tab label and notices; the frame title is
"VCS: <root basename> (<branch>)" / "(detached at <rev>)" / "VCS: not a repository");
`create ~cwd`, `entry ?placement ~cwd ()` (hidden, `opens_in:Tab`); state queries
(`repository`, `snapshot`, `panels`, `loading`, `refresh_error`, `focus`,
`list_focus`, `cursor`, `diff`, `text_view`, `log_visible`, `log`, `stamps`); lanes
`detect`/`refresh`/`diff`; refresh on Shown (new generation, re-detect), `g r`, and
`Saved` under the root (or cwd); keys and local-command names; `Layout.compute`
(log: bottom `max 4 (rows/3)` rows when `rows >= 12`; side by side from 80 content
columns, lists `clamp (width*2/5) 30..60` + 1 separator; else stacked from 16 rows,
lists the top half + 1 separator; else only the focused part); `e`/Enter in the diff
returns `open_file` with the line rule in the `.mli`.

`ui/vcs_host.mli` (W's new contract): `create ?config ?inherited ()`, `submit`,
`next_inputs` (a batch as `Input.Vcs`), `busy`, `stop`, `shutdown ?cap` (default 3 s;
`` `Finished | `Timed_out ``).

Ownership.
- V: `screen/vcs_view.ml` (the `.mli` is frozen); new private modules
  `screen/vcs_*.ml(i)` (other than `vcs_view.mli`); new tests
  `screen/test/test_vcs_view*.ml`. V's tests install the view through
  `Ui_state.create ~views:[Vcs_view.entry ~cwd ()]` with their own bindings (as
  `test_view_registry.ml` does), never W's `Space g` defaults, and run git through
  `Vcs_driver` + `Fixture_repo`.
- W: `ui/vcs_host.ml` (`.mli` frozen); `ui/editor_view.ml` and `ui/editor_view.mli`
  (`app ?vcs:Vcs_host.t`, `run ?vcs`: when given, the default initial UI installs
  `Vcs_view.entry ~cwd:starting_directory ()`, else `View_registry.Entry.unavailable
  Vcs_view.id ~title:"VCS" ~notice:"VCS unavailable in this session"`; after each
  transition `take_vcs_jobs` -> `Vcs_host.submit`; a pump loop like the source's
  injecting `next_inputs`; `stop` on Exit and on deactivate; `run` awaits `shutdown`
  after the terminal closes); `bin/ches.ml` (create the host, pass `~vcs`);
  `input/bindings.ml`: `Space g g` and `Space g f` -> `Focus_view vcs`, `Space g t`/
  `g s`/`g h` -> `Place_view { view = Some vcs; placement = Tab | Split | Hidden }`
  (`vcs = View_id.of_string "vcs"`); `palette/catalog.ml`: `vcs.open` "VCS: open or
  focus" (Focus_view), `vcs.to-tab`, `vcs.to-split`, `vcs.close` (Place_view); the
  expectation updates those cause (`palette/test/*`, `screen/test/test_palette_tile.ml`,
  `test/test_keymap.ml`, `ui/test/*` if any); new Async tests of `Vcs_host` in a new
  `ui/vcs_test/` library (fixture repositories, real runner); the end-to-end test
  `screen/test/test_vcs_workspace.ml` (default bindings, `Space g g/t/s/h/f`, the real
  view, `Vcs_driver`, a save refreshing, `e` opening a file from a tab and from the
  split), written last because it needs V's view; README.md,
  docs/editor_reference.md, docs/backlog/major_minor_tiles.md. No new
  `View_command`.
- Frozen for both (changes go to the orchestrator): `screen/view_registry.ml(i)`,
  `screen/ui_state.ml(i)`, `screen/style.ml(i)`, `ui/theme.ml`,
  `screen/vcs_view.mli`, `ui/vcs_host.mli`, `screen/test/{helpers,vcs_driver,
  test_view_jobs}.ml`, `screen/dune`, `screen/test/dune`, `ui/dune`, `app/`, `vcs/`.
- Both edit inside `ches_screen`/`ches_screen_test`, which W's builds also compile:
  leave no non-compiling file between dune runs; if a build fails in the other
  agent's files, wait and rerun instead of editing them. V builds
  `@screen/runtest`; W builds `@ui/runtest @palette/runtest @input/runtest
  @test/runtest` and its new directories, and `@screen/runtest` only for its own files.

Decisions and deviations from the plan, with reasons:
- Ui_state work listed for W (refresh after save, opening a file at a line) is in the
  stage 1 seam instead: both are generic (signals, `open_file`), so `ui_state.ml`
  stays frozen and W's files stay disjoint from V's. W verifies them end to end.
- No new `View_command`: `opens_in:Tab` makes `Focus_view vcs` "open as a tab or
  focus it where it is". `Space g f` is the same command as `Space g g` rather than
  `Focus_other_pane` when split: `Focus_view` already toggles focus between a split
  view and the editor (and between a focused view tab and the file tab), with no
  conditional binding.
- `q` leaves through `Outcome.return` (the host's return stays in an active view tab
  under the 0B policy, so it would do nothing there); Escape keeps the host's return
  from a list panel. `accepts_tab`, so Tab is the view's own list/diff switch.
- The view is written against `Ches_vcs.Backend.S` where it can, but over the git
  backend concretely: item display needs git's types (`Backend.S.Item.t` is
  abstract). A second backend would add a display function to `Backend.S` or make
  the view a functor.
- `Adapter.text_area` is new: 0A placed the cursor as if open text filled the whole
  content, which a diff panel beside lists does not.
- Signal outcomes may not steal focus or touch the focused view's footer (which
  would cancel a typed prefix); background state is drawn in the view's body.
- Command log: detection and refresh commands and failed diffs, not every
  successful diff read (one per selection move would bury the rest).
- Known gaps: directory-buffer applies are not `Saved` (Session records only file
  saves; `g r` refreshes); saved paths are compared without resolving symlinks; a
  job id collision between views is answered as never started (no view does that
  today: there is one VCS view).

Notes for V and W beyond the `.mli` files:
- `Stamps.issue` starts at sequence 1 (`g0.1`); ids never repeat within a view.
- A view's `fit` must not change its `text_view` text (Ui_state would post "Details
  updated" and cancel a prefix): change the diff text only in `perform`.
- Fixture paths are under `/tmp`: replace `Fixture_repo.t.dir` in expect output.
  Promote only named files (`dune promote <file>`), never a bare `dune promote`.
- W: `Bonsai.Apply_action_context.schedule_event` for submissions, as for source
  requests; inject each `next_inputs` batch as one list; never call it again before
  the previous is determined; `stop` on Exit (the `was_running` branch) as for the
  source; the pump must not keep exit waiting.

## Implementation handoffs

```text
Phase / date / status:
  0A, 2026-10-14, complete (headless checks only; human terminal acceptance pending).
  Uncommitted in the working tree.

Implemented behavior:
  - View registry: problems, history and the demo report are installed views in
    screen/view_registry.ml. Ui_state allocation, leave, synchronize (fit and the
    "Details updated" notice), feed_capture key routing, text_view/cursor queries,
    focus/toggle commands and their feedback, and Frame's minor rendering go through
    it by View_id. Existing keys, palette ids/titles, notices and the band order
    (problems, report, history) are unchanged; the existing suite passes untouched
    apart from one test's custom binding (Focus_problems -> Focus_view Problems_tile.id).
  - View commands: Toggle_problems/Focus_problems/Toggle_demo_report/
    Focus_demo_report/Toggle_history/Focus_history are replaced by
    Toggle_view of View_id.t, Focus_view of View_id.t, and
    Run_view_command { view; command }. An id registered as unavailable (the demo
    report without --demo-report) gives its notice; an unknown id gives
    "View <id> unavailable".
  - View-local commands: adapters declare Local_command.t lists per state. Problems,
    history and the report declare theirs (actions, copy, list motions; text-view
    movement/Visual/copy while details are open).
  - "?" help float: in a focused registered view whose own keys leave "?" unbound,
    opens a read-only, scrollable list (keys + description) on the float slot over
    the view, without leaving it. q, ?, Escape, Tab close it and refocus the view
    (document if the view is gone). It closes itself if it cannot fit or its view
    loses its allocation (hide, zen). "?" in the editor (backward search), the
    directory (editor keymap), and text-input floats (query text) is unchanged.
  - Palette: opened over a registered view (or its help) it lists that view's
    commands first (ids local.<view>.<command>, titles "<Title>: <description>",
    their keys as shortcuts) and does not leave the view. Accepting one closes the
    palette, refocuses the view, and runs the command exactly as its keys would.
    Other commands and Escape return to the document as before.
  - Test-only "counter" view (screen/test/test_view_registry.ml) proves the contract:
    installed via Ui_state.create ~views, bound via ordinary bindings, with a
    state-dependent command, and no per-name code in Ui_state or Frame.

Changed modules and new public contracts:
  - input/view_id.ml(i) (new): View_id moved into ches_input so View_command can name
    views; tile/view_id re-exports it (Ches_tile.View_id.t = Ches_input.View_id.t).
  - input/view_command, input/bindings, palette/catalog: commands above.
  - tile/local_command.ml(i) (new): { name; keys; description }. Names are
    [a-z0-9.-], unique within a view and stable across its states. Contract: the
    declared keys must reach the view's own interpret as an Action in the state
    that lists it (not Escape/Tab/leader, which the host owns), because running by
    name is View_registry.run = interpret keys, then perform.
    Navigation.commands, Text_view.commands, Text_view.item_commands share the
    common declarations.
  - screen/view_registry.ml(i) (new), the registry contract:
      Adapter.t = { spec; key : 'state Type_equal.Id.t; fit; leave; text_view;
        interpret; escape; hint; perform (returns state * Outcome.t);
        commands : 'state -> Local_command.t list; render }.
      Outcome.t = { controller; effect; notice (`Post | `Show); return }, applied by
        Ui_state in that order (same order the per-name code used).
      Entry.install ?placement adapter state | Entry.unavailable id ~title ~notice.
      Placement.t = Hidden | Band. Registry order = band allocation order.
      Generic ops: specs, ids, installed, placements, band, set_placement, leave,
        fit ~viewport, text_view, commands, render, key (Host.key routing returning
        Step.t: Handled | Return | Notice | Workspace | Help | Performed), run,
        find/map by typed key (for app-specific hooks such as problems anchoring).
  - screen/help_tile.ml(i) (new): the help float content (Spec.read_only "help").
  - screen/{problems,history,report}_tile: key, commands, adapter.
  - screen/palette_tile: create ?shortcuts for entries no binding runs.
  - screen/ui_state: create ?views; views, view_visible, help, help_layout. Old
    accessors (problems_visible, problems_tile, report, history_tile, ...) remain
    as typed wrappers over the registry.
  - screen/frame: minor content via View_registry.render; help float layer.
  - docs/backlog/major_minor_tiles.md: records what 0A finished.

Policy decisions settled:
  - The palette and help do not leave the view they open over (so state-dependent
    commands match what was listed). Visible difference: a view's open details stay
    drawn under the palette instead of closing when it opens; they still close when
    the palette closes or runs a non-local command, as before.
  - Workspace commands typed inside a captured view still post no layout feedback
    (unchanged); Run_view_command refused from the document posts its notice.
  - Toggle_problems_filter and Inspect_problems stay problems-specific commands;
    the floats (palette, pickers, help) and the directory are not registered views.
  - Help is read-only (Enter does nothing); running commands is the palette's job.

Checks run and results:
  Baseline (before changes):
    dune build -j 5 2>&1 | tail -30     -> exit 0, no output
    dune runtest -j 5 2>&1 | tail -60   -> exit 0, no output
  After:
    dune build -j 5 2>&1 | tail -30     -> exit 0, no output
    dune runtest -j 5 2>&1 | tail -60   -> exit 0, no output
    git diff --check                    -> clean (new untracked files grepped
                                           for trailing whitespace: none)
  One intermediate full run failed once in content_picker/host/test/test_runtime.ml
  ("stall" test: Pid.of_string "" reading a pid file mid-write, an Async timing
  race in code this phase does not touch). It passed in 3 sequential reruns of that
  directory and in the final full run. Treat it as a pre-existing flake.

Known gaps or blockers:
  - No human terminal acceptance yet (help float look, palette ordering).
  - The help list is a snapshot of the view's commands when opened; it does not
    refresh if a feedback change alters the view's state while help is open.
  - A malformed local command name or empty description is silently left out of the
    palette (help still lists it); nothing validates names at install time because
    commands are per state.

Next-phase integration notes (0B seam):
  - Placement is the registry's, not the adapter's: add Tab and Split constructors to
    View_registry.Placement.t. Workspace allocation already takes band ids from
    View_registry.band; 0B adds the tab/split rects and extends Ui_state.view_layout_in
    to resolve Tab/Split placements. Every generic path (fit viewport via
    minor_rows/minor_width, cursor, availability/focus, key routing, rendering)
    already asks view_layout, so adapters need no change.
  - view_visible means "placement <> Hidden"; Toggle_view currently flips
    Hidden <-> Band and Focus_view shows a hidden view in Band. 0B should decide
    what toggling a tab/split-placed view means and add move-between-placement
    commands taking a View_id (no per-view commands).
  - Spec.role is still Minor for all registered views; a VCS adapter can declare
    Major. Spec.title serves as the tab label unless 0B adds an adapter field.
  - A view tab's close should go through the registry (set Hidden, adapter.leave);
    add an adapter callback there if a view must release resources.
  - Frame renders registered views only from workspace.minors; 0B must render the
    active view tab / split pane through View_registry.render as well.
```

```text
Phase / date / status:
  0B, 2026-10-14, complete (headless checks only; human terminal acceptance pending).
  Uncommitted in the working tree, layered on 0A. The host hard-reset mid-phase
  (~21:53 UTC); work resumed on 2026-10-15 from the surviving edits, every changed
  file re-read and checked for truncation/NUL bytes, _build rebuilt from clean.

Implemented behavior:
  - One placement per view: View_registry.Placement.t = View_command.Placement.t =
    Hidden | Band | Tab | Split. Placing a view in Split closes the previous split
    view (hidden, then adapter.leave).
  - View tabs: screen/tab_strip.ml interleaves view tabs with the session's file
    tabs (Session is unchanged: file order, activation, close-neighbour policy,
    directory Major/Side, quit/dirty checks). A tab is inserted after the active
    entry and activated. While active it fills the editor area (below the strip,
    above compact feedback), drawn through View_registry.render, and is the editor
    area's input owner: Escape/Tab/closing a float return to it, and synchronize
    never leaves the hidden document focused. Space b n/p cycle file and view tabs
    together. Space b c / b C on an active view tab close the view through the
    registry and show the active file tab. Labels are Spec.title; the top strip and
    status rows both show them (Ui_state.tab_items). Status fields name the view
    (no dirty/position) while it is active. Showing a file leaves the view tab:
    another active file, opening/activating a file (pickers, Ui_state.open_file,
    a directory entry), a newly shown major directory or Space d m, Space o back
    from a directory, and an adapter Outcome with return = true (problem jumps).
    Side-directory focus moves (Space d f, Tab, Space d h) keep it.
  - Major split: Workspace.allocate ?split divides the document's allocation (after
    the side directory, status and band) side by side with a gap. Default view on
    the right at 50%; 20..80% in 10-point steps; each side keeps its minimum
    (document 16, split view Workspace.min_split_width = 24). The active tab (file
    or view) is on the other side. Zen leaves the split unallocated (placement
    kept). Below 41 editor-area columns it is hidden; a resize posts
    "<Title> split hidden: needs 41 columns" / "<Title> split restored".
  - Toggle_view: Hidden -> Band, any other placement -> Hidden (close).
    Focus_view: Hidden -> shown in Band and focused (unchanged); Band/Split ->
    focus or return; Tab -> activate and focus; on the focused active tab, show the
    active file tab instead.

Changed modules and new public contracts:
  - input/view_command: Placement; Place_view { view : View_id.t option;
    placement } (None = the focused registered view; from the palette, the view it
    was opened over); Focus_other_pane; Swap_split; Adjust_split of int.
  - input/bindings (all free leader keys; Space g untouched):
      Space s t / s s / s b / s h  Place the focused view: Tab / Split / Band / Hidden
      Space s f                    Focus_other_pane
      Space s x                    Swap_split
      Space s + / s = / s -        Adjust_split +10 / +10 / -10
  - palette/catalog: views.to-tab, views.to-split, views.to-band, views.close,
    split.focus-other, split.swap, split.grow-view, split.shrink-view.
  - screen/view_registry: Placement re-exported; tabs, split, close (= Hidden +
    leave); set_placement Split evicts the previous split view.
  - screen/tab_strip.ml(i) (new): Entry.t = File of Buffer_id.t | View of View_id.t,
    Item.t (label/active/modified/missing), entries ~files ~views, active, add
    ~after, activate.
  - screen/workspace: Major_split (Side, percent, swap, adjust), min_split_width,
    allocate ?split; the split view is the last of [minors].
  - screen/ui_state: tab_entries, tab_items, active_tab_view, view_title, split;
    view_layout resolves the active view tab and the split pane, so fit, cursor,
    focus availability, routing and help need no adapter change.
  - screen/file_tabs, buffer_rows: render_items over Tab_strip.Item (the file-only
    render functions remain); status_tile.body takes items; frame draws the active
    view tab; status names it.
  - README key table; docs/backlog/major_minor_tiles.md records what 0B finished.

Policy decisions settled:
  - The active view tab stands in for the document as the editor area's input
    owner, so "return" (Escape, Tab, floats) stays in it; leaving a view tab is
    explicit (Space b n/p, Focus_view, close, or showing a file).
  - Space s t/s/b/h act on the focused registered view; commands by id (for
    Space g t/s in phase 2) are Place_view { view = Some id; ... }.
  - Tab and Split placement focus the view when it can be shown; Band and Hidden
    do not change focus except to return from a closed view.
  - Closing never releases view state (no new adapter callback); a view's state
    survives Hidden like the band views'.
  - Workspace commands typed inside a captured view still post no layout feedback
    (0A policy); the placement notice is shown in the view's footer instead.
    Corrected 2026-10-27: a placement that closes the view or takes focus from it
    (also typed in help or a question over it) posts its notice to the feedback line.
  - Side directory + split: the side directory keeps its width; the split gives way
    first. When the split view hides on resize, focus returns to the editor area's
    input owner (the side directory if it had input).

Checks run and results:
  Baseline (before 0B, recorded before the reset):
    dune build -j 5     -> exit 0, no output
    dune runtest -j 5   -> exit 0, no output
  After (rebuilt from clean after the reset):
    dune build -j 5     -> exit 0, no output
    dune runtest -j 5   -> exit 0, no output (after promoting the expectations
                           below; the stall flake did not occur)
    git diff --check    -> clean; new files checked for trailing whitespace and NULs
  New tests: screen/test/test_view_placement.ml (counter view from 0A): tab fill,
    strip and status rows, focus return, palette over a tab, zen, Focus_view
    toggling, mixed-tab cycling and order, view-tab close vs. dirty file close,
    open_file leaving the tab, split allocation/render/focus-other/resize/swap,
    moving tab <-> split <-> band <-> hidden, split eviction, zen hide/restore,
    narrow hide/restore notices, side directory + split.
  Expectation updates to existing tests (catalog size only): palette/test/
    test_catalog.ml (+8 listed entries), test_palette.ml ("... N more" counts),
    screen/test/test_palette_tile.ml (1/55 -> 1/63, and the "Tab to the end" loop
    from 60 to 80 presses, since the catalog now has more than 60 entries).

Known gaps or blockers:
  - No human terminal acceptance (split look, tab labels, Space s keys).
  - View_registry.create does not reject two views installed as Split; the first in
    registry order is the split view and the other is allocated nowhere.
  - The split's compact feedback row is only on the tab side when status is hidden.
  - A view tab's strip label is the static Spec.title (no adapter label field).
  - No pure Workspace unit test for allocate ?split; it is covered through
    Ui_state (exact rects at 40/41/72/80 columns, both sides, 20..80%).

Next-phase integration notes:
  - 0C: floats keep the single-float policy; a float over an active view tab or the
    split view returns to it (palette_origin precedent). Nothing in 0B changes the
    float slot.
  - Phase 2: install the VCS view with View_registry.Entry.install (Hidden), Spec
    role Major if wanted. Space g g = Focus_view (it activates a tab) or
    Place_view { view = Some vcs; placement = Tab } when hidden; Space g t/s =
    Place_view Tab/Split; Space g h = Place_view Hidden (or Toggle_view);
    Space g f = Focus_other_pane when split, else Focus_view. "e" opening a file
    should return Outcome.return = true (shows the file tab); "in the other pane
    when split" needs the session's active file to change, which the split shows.
  - If the VCS view must cancel runs or drop snapshots on close, add an adapter
    close callback in View_registry.close (today: Hidden + leave only).
```

```text
Phase / date / status:
  0C, 2026-10-18, complete (headless checks only; human terminal acceptance pending).
  Uncommitted in the working tree, layered on 0A and 0B.

Implemented behavior:
  - A registered view asks a question by returning it in its outcome; the answer is
    delivered back as one of the view's own actions (typed per adapter), so the
    requester keeps no bookkeeping of its own.
  - Confirmation float: title, word-wrapped message, and an always-visible
    "y yes   n no (default)" row. Only y confirms; n, Escape, Tab and Ctrl-c
    decline. Other keys (Y, Enter, q, ...) give the hint and answer nothing. Leader
    workspace keys still work (the float is read-only, like help).
  - Prompt float: title, a "> " input row editing like the palette query
    (Ches_palette.Query: sanitized, one line; Backspace, Ctrl-w/Ctrl-h; paste
    accepted), and an error row. Every character is text, including Space, q and ?.
    Validation runs once the text was edited or Enter was refused; Enter accepts
    only valid text (otherwise stays open with the error). Escape, Tab, Ctrl-c
    cancel.
  - Both open on the single float slot over the asking view, which is not left, and
    an answer closes the float, refocuses the view (document if it is gone), and
    performs the named action, whose outcome may ask again (prompt -> confirm).
  - Refusal: if the float cannot fit (confirm 20x4, prompt 20x4 outer) or the view
    is not shown, nothing opens, the question is withdrawn, and a notice says
    "<Title> cannot fit; needs at least 20 columns and 4 rows; nothing ran".
  - Withdrawal: a float that loses its room on resize or its view (hidden, zen,
    tab left), or that is left another way (another float such as the palette, a
    return to the document), closes with "<Title> closed; nothing ran" where it
    closed itself, and performs nothing.

Changed modules and new public contracts:
  - screen/view_registry: Ask.t ('action: Confirm { title; message; yes; no } |
    Prompt { title; initial; validate : string -> string option (Some error);
    accept : string -> 'action; cancel }), Ask.Question.t (the action-free form the
    application sees), Answer.t (Yes | No | Text), Outcome.t is now 'ask t with
    ask : 'ask option (adapters return 'action Ask.t Outcome.t; Step.Performed and
    run carry Ask.Question.t Outcome.t). Entries keep a pending question; new
    asking, answer (re-validates prompt text; a mismatched answer declines),
    withdraw; leave also withdraws.
  - screen/confirm_tile.ml(i), screen/prompt_tile.ml(i) (new floats, ids "confirm"
    and "prompt"; specs read_only and text_input).
  - screen/ui_state: confirm, confirm_layout, prompt, prompt_layout; apply_outcome
    opens the question last (after notice and return); routing, paste, cursor,
    synchronize withdrawal, leave/return paths include both floats.
  - screen/frame: draws both floats (prompt owns a bar cursor).
  - screen/problems_tile: its record-built outcome sets ask = None (no behavior
    change).
  - docs/backlog/major_minor_tiles.md records what 0C finished.

Policy decisions settled:
  - Decline and withdraw are distinct: decline performs the view's no/cancel action
    (if any); withdraw (no room, view gone, left another way) performs nothing.
  - Tab declines (the host's Tab returns), matching Escape.
  - Hotkey hints stay hidden by default for the prompt footer; the confirmation's
    answer row is content, so it is always shown.
  - A new question replaces one still pending in the same view.

Checks run and results:
  Baseline (2026-10-18, before 0C, after the Oct 16 resets):
    dune build -j 5     -> exit 0, no output
    dune runtest -j 5   -> exit 0, no output
  After:
    dune build -j 5     -> exit 0, no output
    dune runtest -j 5   -> exit 0, no output
    git diff --check    -> clean; new files checked for trailing whitespace
  New tests: screen/test/test_view_ask.ml (test-only "shelf" view): confirm render,
    y-only, every decline key, decline with no action, prompt render and cursor,
    inline validation, text keys (Space, q, ?), word delete, paste into the prompt
    (sanitized) and into the confirmation (rejected), chained prompt -> confirm,
    fit refusal at 19 columns, withdrawal on resize, on hiding the view from the
    float, and on opening the palette, and a local command run from the palette
    asking over its view. No existing expectations changed.

Known gaps or blockers:
  - No human terminal acceptance (float look, wrap, prompt cursor).
  - The prompt has no cursor movement within the text (append/delete at the end
    only, like the palette query).
  - A confirmation message longer than the float's rows is cut, not scrollable.

Next-phase integration notes:
  - Phase 3 discard / Phase 6 force push: return
    Ask.Confirm { yes = Discard ...; no = None } from perform.
  - Phase 6 new branch: Ask.Prompt with validate from a cached
    git check-ref-format result is not possible synchronously; validate cheaply
    (non-empty, no whitespace) in the prompt and let the async command's failure
    report the rest, or validate with a pure ref-name check in ches_vcs_git.
  - Async results that need a question (e.g. after a fetch) must arrive through an
    adapter action so the outcome can carry it; there is no other way to ask.
```

```text
Phase / date / status:
  1, 2026-10-27, complete (headless checks only; nothing user-visible until phase 2).
  Uncommitted, layered on 237e9dd plus the post-acceptance UI follow-ups. Run as three
  agents: stage 1 fixed the contracts ("Phase 1 contracts" above), then G (vcs/git)
  and H (vcs/host) in parallel, serialized on the dune lock.

Implemented behavior:
  - ches_vcs (pure): Exec spec/result, Job (Run | Read_file steps, lanes), Event,
    Stamps, Panel (stable selection identity and the removed-item rule), Popup,
    Diff, Backend.S. As specified in the contracts section.
  - ches_vcs_git: Cli (read/mutate/network spec builders per the git CLI rules),
    Repository (rev-parse detection: Found | Not_a_repository | No_work_tree |
    Failed), Status (porcelain v2 -z --branch, incl. every unmerged XY, renames and
    copies, submodules, untracked/ignored, cut output), Branch_list (for-each-ref,
    In_sync | Ahead_behind | Gone), Log (bounded, cut-safe), In_progress (merge,
    rebase merge/apply, am, cherry-pick, revert, bisect from state files),
    Diff_output (diff / --cached / show / --no-index into Ches_vcs.Diff, incl.
    combined conflict diffs, C-quoted names, CRLF, bounded per file with omitted
    counts, cut output), Backend (Backend.S; degraded snapshots carry one-line
    problems instead of failing), Step_failure (one-line failure text).
  - ches_vcs_host: Runner (Async; reads run concurrently under a small semaphore,
    Mutate/Network jobs one at a time FIFO stopping at the first failed step; lanes
    supersede; cancel, timeout and stop terminate the child's process group with
    SIGTERM then SIGKILL after 2 s; stdout head / stderr tail limits; streamed lines
    with \r progress as transient; Not_started instead of exceptions; batches via
    next_batch), Auth (GIT_TERMINAL_PROMPT=0 for every child; for Network,
    GIT_SSH_COMMAND="ssh -o BatchMode=yes" unless the user set GIT_SSH_COMMAND,
    GIT_SSH or core.sshCommand, probed per network step).
  - ches_vcs_fixture (test-only): isolated temp repositories and a local bare remote,
    deterministic hashes, run_steps for synchronous end-to-end tests.

Changed modules and new public contracts:
  - New: vcs/, vcs/git/, vcs/host/, vcs/fixture/ (libraries ches_vcs, ches_vcs_git,
    ches_vcs_host, ches_vcs_fixture) and their tests. No existing file changed except
    this plan. No Ui_state/bin wiring (decision recorded in the contracts section).
  - Orchestrator edit after H: Auth.environment also respects GIT_SSH (git's
    precedence is GIT_SSH_COMMAND > core.sshCommand > GIT_SSH), with a test.
  - Capture (vcs/host) and Step_failure (vcs/git) are public only because the frozen
    dune files have no private_modules; treat them as internal.

Policy decisions settled:
  - Reads may run beside the single mutation queue; Read jobs run every step even
    after a failure, mutations stop at the first failure (rest Skipped).
  - The runner never drops results: staleness is the consumer's job (Stamps),
    including the never_started report for a reused id.
  - "* Unmerged path X" lines (diff during a conflict; every conflict under --cached)
    parse as their own Unmerged file with no hunks. Combined files are Unmerged when
    the index line's result side is all zeros, else Modified/Added/Deleted (a merge
    commit's show).
  - Diff.Limits.file_bytes counts line text bytes only; combined lines have
    old_line = None.

Checks run and results:
  - Baseline before stage 1: dune build -j 10 / dune runtest -j 10 -> exit 0.
  - G and H each ran their own targets, then one full build/runtest -> exit 0; H ran
    vcs/host tests twice in a row -> exit 0 both times.
  - Orchestrator final (2026-10-27): dune build -j 10 -> 0; dune runtest -j 10 -> 0;
    git diff --check clean; no trailing whitespace in vcs/; no TODO stubs left; no
    stray processes or /tmp/ches-vcs* directories. 88 new expect tests.
  - git 2.43.0. Ches repository untouched by git mutations (HEAD 237e9dd).

Known gaps or blockers:
  - Contract docs to fold in (phase 2 stage 1): the Unmerged-path and combined
    change-type rules in diff_output.mli; combined line numbering and file_bytes in
    diff.mli; Started following the core.sshCommand probe in runner.mli.
  - Untracked/Ignored keys may be directories ending in "/" (nested repository,
    ignored directory); diff_target returns a target whose diff then fails. Proposed:
    diff_target returns None for such paths. Diff.File.line_actions should also be
    false for Unmerged files (harmless today: they have no hunks).
  - Streamed Output events are not capped by stdout_limit (a chatty streaming
    mutation emits every line). Revisit in phase 6 if it matters.
  - _build/.promotion-staging holds stale promotions from several directories; never
    run a bare `dune promote` without checking what it would apply.

Next-phase integration notes:
  - Wiring (from H): one Runner.t in ui/editor_view.ml; Ui_state hands out jobs via
    take_vcs_jobs; pump Runner.next_batch like Source.next_batch, as one transition
    per batch of Ui_state.Input.Vcs events, never calling next_batch again before
    the previous one is determined; Runner.stop on exit, then await
    Runner.finished with a cap (up to the 2 s grace plus reaping) so git can drop
    index.lock; the pump loop must not hold exit open (next_batch never resolves
    after stop).
  - GIT_OPTIONAL_LOCKS=0 and LC_ALL=C come from Cli.read specs; the runner adds only
    the auth environment. Output lines are raw bytes: sanitize before rendering.
    Log lines: Started's spec to_string_hum and Exec.Result.status_hum.
  - Snapshot (from G): problems are one line each (command log material). During a
    rebase, summary.branch = None and operations say "Rebasing main onto ...". Gone
    upstreams have gone = true, ahead/behind 0. Item keys: file paths (may contain
    control bytes: escape for display), short branch names, full commit hashes.
  - Diff rendering: Unmerged files and rename-only files are header-only; combined
    files have two-character prefixes; mode-only/binary/submodule are flagged
    (line_actions); File.truncated draws the placeholder; Diff.t.cut means the
    command output itself was cut; show's preamble is the commit header, the message
    indented 4 spaces, and a blank line.
```

```text
Phase / date / status:
  2, 2026-10-27, complete (headless checks only; owner terminal acceptance pending).
  Uncommitted, layered on phase 1. Run as three agents: stage 1 (contracts, the
  generic job seam, phase 1 cleanups; see "Phase 2 contracts"), then V (the view)
  and W (wiring) in parallel on the dune lock. V and W were interrupted by an API
  session limit at 06:22 UTC and resumed from their saved state after the reset.

Implemented behavior:
  - Generic seam (stage 1): Outcome.jobs / Outcome.open_file; adapter signal field
    (Shown | Saved paths | Job event); Entry.install ?opens_in; text_area for the
    terminal cursor; Ui_state.Input.Vcs, take_vcs_jobs, job ownership by in-flight
    id; open_file handled like a picker (other pane when split); Session.saved.
  - VCS view (V, screen/vcs_view.ml, screen/vcs_diff_text.ml): head summary, Files
    (Conflicted/Untracked/Unstaged/Staged, foldable), Branches, Commits, the diff
    following the selection (styled; header-only for binary/submodule/mode-only/
    rename-only and "* Unmerged path"; combined conflict hunks shown; truncation and
    cut notes), the command log (@), loading/error/not-a-repository/no-work-tree
    states, wide/stacked/single layouts, the read-only keys (1 2 3 0 Tab j k gg G
    Ctrl-d Ctrl-u Enter g r @ y q, Text_view keys in the diff), e/Enter opening the
    file at a line, ? help and palette-first local commands, stable selection.
  - Wiring (W, ui/vcs_host.ml, ui/editor_view.ml, bin/ches.ml): one runner per real
    session; jobs submitted after each transition; next_batch pumped as one batch
    per transition; stop on exit and at_shutdown, then shutdown awaits finished with
    a 3 s cap; the view installed hidden, opening as a tab (or the unavailable entry
    "VCS unavailable in this session" without a host).
  - Keys: Space g g / Space g f = Focus_view vcs; Space g t/s/h = Place_view
    (Tab/Split/Hidden). Space g c / Space g a stay unbound (phase 5). Palette:
    vcs.open, vcs.to-tab, vcs.to-split, vcs.close.

Changed modules and new public contracts:
  - New: screen/vcs_view.ml(i), screen/vcs_diff_text.ml(i), ui/vcs_host.ml(i),
    ui/vcs_test/, screen/test/{vcs_driver,test_view_jobs,test_vcs_view,
    test_vcs_workspace}.ml. Changed: view_registry, ui_state, session (saved),
    style/theme (Diff_* styles), the existing views (two default adapter fields),
    bindings, catalog, editor_view, bin/ches.ml, dune files, vcs/ cleanups, README,
    docs/editor_reference.md (new "VCS view" section), major_minor_tiles backlog.
  - Orchestrator edit: vcs_view.mli documents V's two deviations (below).

Policy decisions settled:
  - Unmerged files show their combined hunks (conflict markers, openable at the
    result line) when git gives them; only "* Unmerged path" files are header-only.
    (Deviation from the stage 1 .mli, accepted: headers alone hide the conflict.)
  - Frame title "VCS: no work tree" for a bare repository or .git.
  - e/Enter line rule: + and context -> new_line; - -> the next line in the hunk with
    a new_line, else max 1 new_start; hunk header -> new_start; file headers ->
    line 1; a deleted file -> notice "<path> was deleted: nothing to open". A commit's
    diff opens the work-tree file at the commit's line numbers.
  - q leaves via Outcome.return; Tab is the view's list/diff switch; Escape in a list
    is the host's return. Signalled outcomes never move focus.
  - The command log keeps detection/refresh commands, failed diffs and snapshot
    problems (capped at 200, newest first), not every successful diff read.
  - The view is written over the git backend (Backend.S.Item.t is abstract); a second
    backend adds a display function to Backend.S or makes the view a functor.

Checks run and results:
  - Stage 1 baseline and final: full build/runtest -> 0.
  - V: 21 expect tests; W: 5 Async host tests (ui/vcs_test) and the end-to-end
    workspace test, plus keymap/palette updates.
  - Orchestrator final (2026-10-27): dune build -j 10 -> 0; dune runtest -j 10 -> 0;
    git diff --check clean; no TODO stubs; no stray git processes or
    /tmp/ches-vcs* dirs; HEAD 237e9dd, nothing committed.

Known gaps or blockers:
  - No owner terminal acceptance yet (see W's checklist in the session report:
    open/split/focus/close, save refresh, e from tab and split, outside a repo,
    quitting mid-refresh, no ssh/credential prompts).
  - Saving a directory buffer sends no Saved signal; g r refreshes. Saved paths are
    compared to the repository root without resolving symlinks.
  - Cosmetic: unfocused panel title rows draw on the Backdrop background
    (Style.Title/Hint); a content-level panel-title style may look better.
  - The tab label is the static "VCS" (no branch); the frame title carries it.
  - W once copied a staged promotion by hand after a concurrent dune run cleared the
    promotion list; the file's expectations were reviewed and pass.

Next-phase integration notes (phase 3):
  - Actions: Backend.S.plan -> Run | Confirm | Refused; git's action type is still
    empty. Mutations go through Outcome.jobs as Mutate jobs (the runner serializes
    them); refresh after each via the view's own stamps.
  - Discard confirmations: return Ask.Confirm from perform (0C); the dirty-buffer
    refusal needs the session's dirty buffers inside the repository, which the view
    does not see today: add it to the signal/seam rather than per-name wiring.
  - Open-buffer reconciliation after working-tree changes is new seam work (reload
    clean buffers, mark deleted ones missing).
  - Hunk staging: Diff_text lines already carry kind and open targets; add the hunk
    identity for s/u/x at the cursor. Line staging (phase 4) needs Visual ranges
    mapped back to Diff lines.
```

### Post-phase-2 tweaks (owner feedback, uncommitted)

- Counts in every read-only Text_view (`Action.Move_count`): `N` before
  `h l j k w b Ctrl-d Ctrl-u` repeats, `N G` / `N gg` go to line N. Inside the VCS
  diff, digits are counts, so `1 2 3` switch panels only from a list (Tab/Esc back
  first); the phase 2 key list above predates this.
- VCS padding: one blank column each side of the diff (pane >= 10 columns;
  `diff_text_rect` feeds `diff_area` and `text_area`), and blank rows after the head
  summary, between panels, and at the bottom of the lists column (dropped when the
  column is too short to keep three panels).
