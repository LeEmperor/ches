# VCS view: hand-validation checklist

[Testing and acceptance](README.md) · [VCS implementation plan](../plans/vcs_workspace.md)

Run commands from the repository root; inline source paths are relative to it.

**The behaviour checks are automated now.** `python3 scripts/vcs_smoke.py` runs the
built binary in tmux over a fresh `scripts/vcs_sandbox.sh` sandbox and walks one pass
per phase (2–8), checking the screen and the resulting git state; `dune runtest`
covers the rest headlessly (about 170 view tests in `screen/test/test_vcs_*.ml`, plus
`vcs/` and `vcs/git/test/`). What is left below is what tests cannot judge: how it
looks and feels in your terminal, and a real remote. Key reference:
`docs/editor_reference.md`, "VCS view" and after.

## Automated coverage

```sh
cd ~/devel/ches
dune build -j 4 bin/ches.exe
python3 scripts/vcs_smoke.py           # about 4 s; prints PASS/FAIL per check
dune runtest -j 4
```

The smoke builds its own sandbox in a temporary directory (never
`/tmp/ches-vcs-sandbox`), runs git with `GIT_CONFIG_GLOBAL=/dev/null`, and keeps
colored captures of the review screens in a directory it prints (`less -R` them, or
`cat` them in your terminal to see its colors). In order, it checks:

| Phase | The smoke | Headless tests |
| --- | --- | --- |
| 2 | `Space g g`: tab `VCS: main`, summary, the three panels and Files sections; footer hints after `Space v ?`; `Space g s` / `Space g t`; `@` | `test_vcs_view.ml`, `test_vcs_workspace.ml` |
| 3 | `2]` `s` stages the second hunk of `a.txt` only (`git diff --cached`); `x` asks, Escape declines, `y` discards (`git diff` empty, buffer reloaded) | `test_vcs_actions.ml`, `test_vcs_workspace.ml` |
| 4 | `V` over three lines, `s`: exactly those lines staged | same |
| 5 | `c` popup, `c c`, a subject, `Space g c`: `git log -1`, the message file deleted | `test_vcs_commit.ml` |
| 6 | `f`: ahead 2, behind 1; `p p` refused with the `p -r p` hint, HEAD unchanged | `test_vcs_remote.ml` |
| 7 | `p -r p` stops (`UU a.txt`, `(press r)` also at 80 columns); `x t y` resolves; `r r` continues; `P p` pushes (the bare remote has it); `m m` on `conflict-me` stops with both conflicts, `m a y` aborts | `test_vcs_conflicts.ml`, `test_vcs_remote.ml` |
| 8 | `3`: `Recent commits (first 200)`, `●` rows with `(HEAD -> main, origin/main)`; `+` drops `first 200`; `G` shows `●─╮` `│ ●` `●─╯`; `l b` on feature, `l a`; `Space g l` from `a.txt` | `test_vcs_log.ml` |
| quit | `f`, `q`, `Space q` at once: exit 0, terminal modes restored, cursor visible, no `.git/*.lock` | |
| hints | | `test_vcs_hints.ml`: every footer with hints on |

## What only you can judge

Setup, as before (the sandbox's contents are described at the top of
`scripts/vcs_sandbox.sh`; re-run it to start over):

```sh
scripts/vcs_sandbox.sh                 # wipes and builds /tmp/ches-vcs-sandbox
./_build/default/bin/ches.exe /tmp/ches-vcs-sandbox/work/a.txt
```

- [ ] **Glyphs in your font.** In Commits, `+` then `G`: the merge reads `●─╮`, the
  side lane `│ ●`, the join `●─╯`, and the lanes line up column for column. Also `l a`
  (lanes for `conflict-me` and `origin/*`). Borders, `>` cut marks and `…` look right.
- [ ] **Colours** in the themes you use (at least one dark and one light, `Space v
  T`): diff `+`/`-`/`@@`/header lines, a commit's file list, conflict markers, the
  `*` of an enabled popup switch, the muted footer hints, error rows in the summary.
- [ ] **Flicker**: `j`/`k` through Files and Commits (the diff follows), saving a file
  (one refresh), `g r`, the stage/discard round trip, opening and closing popups.
- [ ] **Latency on a big repository** (read-only: open the view on a large repo you
  don't mind, and only browse): moving through Commits, `+` up to 12800, `l a`, the
  diff of a large commit, `g r`. Nothing should stall typing in the editor.
- [ ] **The `Fetch...` progress row** while a slow fetch runs, and `Busy: ...` for a
  second action meanwhile. The smoke's local remote is too fast to show either; the
  tests feed synthetic progress.
- [ ] **A real ssh remote** (optional): point a scratch clone's `origin` at one. `f`,
  `p p`, `P p` work, there is never a terminal prompt, and a missing ssh-agent key or
  an unknown host gives Ches's explanation rather than a hang.
- [ ] **Narrow and wide layouts**: 80 columns (the stacked layout, only the focused
  part when short), the split at a narrow width, and a very wide terminal.
- [ ] **Footer hints** (`Space v ?`): read them in the view. `test_vcs_hints.ml`
  records the texts; the decisions in the next section are yours.

## Decisions pending

The hint problems the tests found (footers cut at ordinary widths, `- switch` in
popups without switches, hints naming refused keys) were fixed on 2026-11-01: every
panel footer starts with `? help` and fits in 100 columns, and `test_vcs_hints.ml`
pins them.

- **The empty log's title** (phase 8 gap): a logged branch deleted outside Ches, then
  `g r`, shows `3 Commits (0)` / `(none)` with no title naming the log. Left as is
  for now (owner, 2026-11-01); `test_vcs_log.ml`'s last test records it.

## Not covered anywhere

- That the smoke's quit really lands while git runs: it sends `f q Space q` at once,
  but a fetch from a local remote may finish first. The lock check is meaningful
  either way; the race itself is not proven.
- Copying with `y` into the system clipboard (Ches's register is tested; the
  terminal's clipboard is not).
- Cursor shape and the smear cursor in the view (tmux does not report them).

The previous step-by-step checklist (phases 2–8, every feature by hand) is in git
history. Use `git log --follow -- docs/testing/vcs_manual.md` to find older
revisions across the move if you want to walk a phase yourself; the smoke and
tests above replace it for behaviour.

## Afterwards

Write findings under the sections above (or just tell Claude). When you are happy
with the look and feel, the handoffs' "No owner terminal acceptance" gaps can be
closed in `docs/plans/vcs_workspace.md`.
