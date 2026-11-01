# VCS view: hand-validation checklist

Owner terminal acceptance for VCS phases 2–8 (`VCS_WORKSPACE_PLAN.md`). Each phase's
checks are in the order you'd run them in one sandbox session, and later phases rely
on what earlier ones did. Tick a box when it looks right; note anything odd under the
phase. Key reference: `docs/editor_reference.md`, "VCS view" and after.

## Setup

```sh
cd ~/devel/ches
dune build -j 10
scripts/vcs_sandbox.sh                 # wipes and builds /tmp/ches-vcs-sandbox
./_build/default/bin/ches.exe /tmp/ches-vcs-sandbox/work/a.txt
```

The sandbox (`/tmp/ches-vcs-sandbox/work`, on `main`) has:

- **History:** a `v1` tag, a `--no-ff` merge of `feature`, a rename (`old_name.txt` →
  `new_name.txt`, then edited), a binary `logo.bin`, and 210 "Counter" commits, so
  more than 200 commits in all.
- **Branches:** `feature` (merged), `conflict-me` (conflicts with main on `a.txt` and
  deletes `src/main.ml`, which main modified), and `doomed` (for you to delete by
  hand).
- **Remote:** `origin` is a local bare repo with a commit main doesn't have. Main has
  one origin doesn't. Both edit `a.txt` line 1.
- **Dirty work tree:** `a.txt` changed in two far-apart places (two hunks),
  `src/main.ml` staged, `notes.txt` untracked.

Re-run the script any time to start over. Also test at a narrow width (about 80
columns) and a wide one at least once.

## Phase 2: read-only view (and the view plumbing under it)

- [ ] `Space g g` opens a tab labelled `VCS: main`. The head summary shows the branch
  and upstream, and the left column has Files, Branches and Commits.
- [ ] Files shows Untracked `notes.txt`, Unstaged `a.txt` and Staged `src/main.ml`.
  The diff panel follows `j`/`k`, and a section header shows the combined diff.
- [ ] `1` `2` `3` focus the three panels. `0` or `Tab` focuses the diff, and `Tab`
  goes back.
- [ ] `Enter` on a header folds and unfolds it. `y` copies a path, branch or hash
  (paste it in the editor with `p`).
- [ ] In the diff, counts work: `10j`, `5k`, `12G`. `1`/`2`/`3` don't switch panels
  there.
- [ ] `@` shows and hides the command log, with git commands and exit statuses.
- [ ] `?` lists the keys for where the cursor is, and closing it returns you.
- [ ] `Space g s` moves the view into the split beside the editor and `Space g t`
  moves it back to a tab. In the split, the lists stack above the diff when narrow.
- [ ] `Space g g` toggles focus between the view and the editor. `q` leaves, and
  `Space g h` closes the view.
- [ ] Padding: one blank column on each side of the diff, and blank rows between the
  panels.
- [ ] Edit `a.txt` in the editor and save it (`Space w`): the view refreshes once.
  `g r` refreshes too.
- [ ] Open a file outside any repository (e.g. `/tmp/x.txt`), then `Space g g`:
  `VCS: not a repository`, and `g r` looks again.
- [ ] Quitting Ches while a refresh runs leaves no `.git/index.lock` behind.

Notes:

## Phase 3: stage, unstage, discard

- [ ] `s` on `notes.txt` stages it and the cursor stays sensibly placed. `u` unstages
  it again.
- [ ] `s` / `u` on a section header acts on every file in it. `S` stages all, `U`
  unstages all.
- [ ] In `a.txt`'s diff, `]` / `[` move between the two hunks, `s` stages only the
  hunk at the cursor, and the cursor lands on the hunk that takes its place.
- [ ] On a file's header lines in the diff, `s` acts on the whole file.
- [ ] `x` on an unstaged hunk asks first. Any key but `y` (Escape, `n`, Enter) does
  nothing; `y` discards.
- [ ] `x` on untracked `notes.txt` deletes it after confirming. Recreate it with
  `echo scratch > /tmp/ches-vcs-sandbox/work/notes.txt`, then `g r`.
- [ ] Unsaved buffer: edit `a.txt` without saving, then `x` in the view is refused
  and names `a.txt`. Undo the edit and it works.
- [ ] After a discard, an open unchanged `a.txt` buffer reloads from disk, keeping its
  cursor and scroll.
- [ ] Pressing an action again while one runs says `Busy: ...` (hard to catch; skip
  if too fast).

Notes:

## Phase 4: staging selected lines

- [ ] In `a.txt`'s unstaged diff, `V` on just the `line 5` `-`/`+` pair, then `s`:
  only those lines are staged ("Stage 2 lines of a.txt") and line 6 stays unstaged.
- [ ] In the staged diff, `V` and `u` unstage selected lines.
- [ ] `v`/`V` across two hunks of one file, then `s`: one patch, and both are staged.
- [ ] A selection reaching a second file's header: "Select lines within one file;
  nothing ran", and the selection is kept.
- [ ] A selection with only context lines: "No changes selected; nothing ran".
- [ ] `V` then `x` asks "Discard N lines of a.txt? ..."
- [ ] Line actions on untracked `notes.txt`: "Stage the whole untracked file first
  ...". On `logo.bin` (after changing it), a refusal for a binary file.

Notes:

## Phase 5: popups and committing

- [ ] `c` opens the commit popup with switches `-n` `-s` `-e` and actions `c` `a`
  `e`. `-` then `s` marks `* -s`, and Escape clears a pending `-`.
- [ ] `?` inside the popup lists its keys and closing returns to the popup. `q` and
  `Tab` close it without running anything.
- [ ] Unstage everything (`U`), then `c c`: "Nothing staged; ...". With `-e` it goes
  ahead.
- [ ] Stage everything (`S`) and `c c`: `.git/CHES_COMMIT_EDITMSG` opens as a tab with
  a `#` comment block naming the branch and the staged files.
- [ ] Type a subject, then `Space g c`: the tab closes, the view comes back, the
  summary `[main abc1234] Subject` is reported, and the commit is at the top of
  Commits.
- [ ] `c c` again with something staged, then `Space g a`: "Commit aborted", and the
  message file is gone.
- [ ] `c c` while a message is already open: "A commit message is already open: ..."
- [ ] `c a` opens HEAD's message for amending. Change it and `Space g c`: HEAD is
  reworded.
- [ ] `c e` with something staged adds it to HEAD, keeping the message.
- [ ] Hook failure: `printf '#!/bin/sh\necho nope >&2; exit 1\n' >
  /tmp/ches-vcs-sandbox/work/.git/hooks/pre-commit; chmod +x` that file. Then
  `c c`, a subject, `Space g c`: "Commit failed: nope (exit 1)" and the message stays
  open. Abort, reopen with `c - n c`: it commits. Delete the hook afterwards.
- [ ] `c -s c`: the message ends with a `Signed-off-by:` line.

Notes:

## Phase 6: remotes and branches

- [ ] `f` fetches. The head summary shows `Fetch...` while it runs, then
  "Fetch: done". Main now shows ahead 1, behind 1 against `origin/main`.
- [ ] `p p` (fast-forward only) fails, with a hint to pull with rebase (`p -r p`).
  Don't run that yet: it's phase 7's first step.
- [ ] `P p` is rejected, with a hint to pull first (`p p`).
- [ ] `P -f p` asks before force-pushing ("Commits on origin/main that main does not
  contain are lost ..."). Answer No.
- [ ] In Branches (`2`), `Enter` on `feature` checks it out and the tab label becomes
  `VCS: feature`. `-` returns to main. `Enter` on main: "Already on main; nothing
  ran".
- [ ] Unsaved edit in a buffer, then `Enter` on a branch: refused, naming the buffer.
- [ ] `n` prompts for a name and checks it as you type: `a..b` and `main` are
  refused. `topic` creates and checks out `topic`, keeping changes.
- [ ] On `topic`, before pushing, `p p` says to push it with `P u` first. `P u`
  pushes to `origin/topic` and sets the upstream. Go back to main with `-`.
- [ ] Delete `topic` on the remote (`git -C /tmp/ches-vcs-sandbox/work push origin
  --delete topic`), then `f`: `topic`'s upstream shows as gone.
- [ ] A directory buffer: rename a file in it and save. The VCS view refreshes.
- [ ] ssh/credential messages: optional, only if you want to point `origin` at a real
  remote. There should never be a terminal prompt.

Notes:

## Phase 7: merges and conflicts

Rebase pull first (main is still diverged from origin):

- [ ] `p -r p` stops on conflicts: "Stopped on conflicts: ...". The head summary
  shows `Rebasing main onto <hash> (press r)`, and Conflicted lists `a.txt`
  (`both modified`).
- [ ] `Enter` on `a.txt` shows the markers in its diff. `Enter` on a line opens the
  file there.
- [ ] In the editor, `]n` / `[n` jump between conflicts and `Space x l` keeps the
  lower side. Save with `Space w`, go back to the view and `s` on `a.txt`: it moves
  out of Conflicted.
- [ ] `r` opens the Rebasing popup. `r r` continues, with no editor prompt and the
  message kept. The summary shows the rebase is gone and main is ahead 1, behind 0.
- [ ] Now `P p` succeeds: "Push main to origin/main: done".

Merge next:

- [ ] `2`, select `conflict-me`, then `m`: the merge popup offers `-n` and `-f` (only
  one can be on). `m` merges and stops on conflicts.
- [ ] Conflicted shows `a.txt` (`both modified`) and `src/main.ml` (`deleted by
  them`). The summary shows `Merging <hash> (press m)`.
- [ ] `x` on `src/main.ml`: `Resolve src/main.ml`, with `o` keeping ours and `t`
  deleting it (theirs). Each asks first.
- [ ] `x` on `a.txt`, then `t`: confirmed, and it takes theirs and stages. Or try `m`
  first: it restores the markers and leaves the file conflicted.
- [ ] `m m` with a file still conflicted: "Resolve the conflicted files first ...".
  Once none are left, `m m` commits the merge with git's message and no
  `# Conflicts:` lines.
- [ ] `m` on main: "Cannot merge main into itself". With the cursor on a header: the
  hint to select a branch.
- [ ] Abort path: re-run the sandbox, `S c c` commit, `m m` on `conflict-me`, then
  `m a`: asks, then the tree is back to before the merge.
- [ ] `r` with no rebase: "No rebase in progress; nothing ran".
- [ ] The rebase row's "(press r)" fits in the lists column at 80 columns.

Notes:

## Phase 8: log and history browsing

Rows, title and graph:

- [ ] `3` focuses Commits. The title is `Recent commits (first 200)`, since there are
  more than 200.
- [ ] Rows look like `● 1df0b2f Add a binary file`. HEAD's row has `(HEAD -> main,
  origin/main)` or similar; the initial commit has `(tag: v1)`.
- [ ] The merge is past the first 200, so press `+`, then `G` and go up a few rows
  with `k`: it reads `●─╮`, the side lane `│ ●` for the feature commits, then `●─╯` where it
  joins. Check that the glyphs line up in your terminal font.
- [ ] (Check this on the `+` from the previous step.) `+` doubles the count to 400,
  so the title drops `first 200` (there are about 220 commits), and the cursor stays
  where it was.

The commit's file list:

- [ ] Select the merge commit or "Rename old_name.txt ...". The diff shows the message,
  a blank line, a file list (e.g. `R new_name.txt  +1 -0`), a blank line, then the
  diffs.
- [ ] "Add a binary file": `A logo.bin` with no counts.
- [ ] `Tab` into the diff. `}` / `{` jump between files and `3}` jumps three. At the
  ends: "No next file" / "No previous file".
- [ ] `Enter` on a line of the file list jumps to that file's diff. `e` on it opens
  the file instead.
- [ ] In the diff, `l` is still a cursor motion and does not open the log popup.

The log popup (`l` from Files, Branches or Commits):

- [ ] `l` opens `Log`, with `-g` already marked `*` and actions `l` `b` `a` `f`.
- [ ] `2`, select `feature`, `l b`: Commits is focused and titled `Commits on
  feature`, listing only feature's history. Cursor on the title, and `j` reaches the
  first commit.
- [ ] `l a`: `All branches`, including `origin/*` refs and `conflict-me` (if you
  haven't merged it), with the graph showing the forks.
- [ ] `l - m l`: merges are gone and so is the graph. Reopening `l` shows `* -m`
  still on, and `- m l` again brings merges back.
- [ ] `l - p l`: first parent only, so the feature commits disappear behind the
  merge. The title says `(first parent ...)`.
- [ ] `l l` returns to HEAD (`Recent commits`).
- [ ] `l b` with the Branches cursor on a header: "Select a branch in Branches
  first".
- [ ] Hide the view (`Space g h`) and reopen it (`Space g g`): the chosen log and its
  switches are kept.

File history:

- [ ] In Files, select a file (make one dirty if needed), then `l f`: `History of
  <path>` with no graph.
- [ ] In Commits, put the diff cursor on a line of `new_name.txt`, then `l f`: the
  history includes the commits from before the rename (`--follow`).
- [ ] In that history, each commit's diff opens with the cursor on `new_name.txt`'s
  part (or `old_name.txt` in older commits), not at the top.
- [ ] From an editor buffer of `new_name.txt` with the view hidden: `Space g l`
  shows the view focused on `History of new_name.txt`.
- [ ] Same with the view in the split (`Space g s`, back to the editor, `Space g l`):
  focus moves to the split, on the history.
- [ ] Right after starting Ches, before ever opening the view: `Space g l` from
  `a.txt` opens the view straight onto its history.
- [ ] From a directory buffer: "No file buffer here: Space g l shows the history of
  the file you are in".
- [ ] From a file outside the sandbox (e.g. `/tmp/x.txt`, with the view already open
  on the sandbox): "x.txt is not in the repository at /tmp/ches-vcs-sandbox/work".

Edge cases:

- [ ] `2`, select `doomed`, `l b`, then outside Ches `git -C
  /tmp/ches-vcs-sandbox/work branch -D doomed`, then `g r`. **Known gap:** Commits
  shows `(none)` with no title naming the log, and the summary shows "1 problem
  reading the repository". Tell me whether you want a title there.
- [ ] `+` at the cap is impractical here. The message is "Showing the most commits
  already (12800)", and it's covered by tests.
- [ ] Footer hints (with hints on) mention `l log`, `+ more` and `} { files` where
  they apply. Tests don't cover these.

Notes:

## Afterwards

Write findings under each phase's Notes (or just tell Claude). When a phase passes,
its handoff's "No owner terminal acceptance" gap can be closed in
`VCS_WORKSPACE_PLAN.md`.
