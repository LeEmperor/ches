#!/usr/bin/env python3
"""VCS view terminal smoke: drives the built ches in tmux over a sandbox repository.

    python3 scripts/vcs_smoke.py [PATH-TO-CHES]     (default _build/default/bin/ches.exe)

Builds a sandbox with scripts/vcs_sandbox.sh in a fresh temporary directory (removed
on exit), runs ches on its work/a.txt in a private tmux server, and walks one short
pass per VCS phase (2-8): the view and its placements, hunk and line staging,
discarding, committing, fetch, a refused fast-forward pull, a rebase pull stopped on a
conflict, resolved and continued, a push, a merge stopped and aborted, the log graph,
log scopes and Space g l. Each step waits for the screen to show its result, then
checks the repository with git. It ends by quitting while a fetch runs and checks
that no git lock file is left and that the terminal is restored.

Needs tmux (tested with 3.4), git, bash and a UTF-8 locale. Git runs with
GIT_CONFIG_GLOBAL=/dev/null and GIT_CONFIG_NOSYSTEM=1 (the sandbox repositories have
their own identity); the remote is a local bare repository, so nothing touches the
network. Colored captures of the review screens are kept in a directory printed at
the end. Not checked here: how glyphs and colors look, flicker, and latency.
"""
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WIDTH, HEIGHT = 120, 40
SESSION = "vcs"


class Abort(Exception):
    """A step whose result never showed: the rest of the run would be meaningless."""


class Smoke:
    def __init__(self, binary, work, screens):
        self.binary = binary
        self.work = work
        self.screens = screens
        self.repo = work / "sandbox" / "work"
        # A socket path must stay short (108 bytes), whatever TMPDIR is.
        self.socket_dir = Path(tempfile.mkdtemp(prefix="ches-vcs-tmux.", dir="/tmp"))
        self.tmux = ["tmux", "-S", str(self.socket_dir / "sock"), "-f", "/dev/null"]
        self.section = ""
        self.passed = 0
        self.failures = []
        self.captures = 0

    # tmux

    def t(self, *args):
        return subprocess.check_output(self.tmux + list(args), text=True)

    def screen(self, ansi=False):
        return self.t("capture-pane", "-p", *(["-e"] if ansi else []), "-t", SESSION)

    def rows(self):
        return self.screen().splitlines()

    def display(self, fmt):
        return self.t("display-message", "-p", "-t", SESSION, fmt).strip()

    def keys(self, *names):
        """Named keys (Space, Tab, Escape, Enter) or single characters, in order."""
        for name in names:
            if len(name) == 1:
                self.t("send-keys", "-t", SESSION, "-l", "--", name)
            else:
                self.t("send-keys", "-t", SESSION, name)

    def type(self, text):
        self.t("send-keys", "-t", SESSION, "-l", "--", text)

    def resize(self, width, height):
        self.t("resize-window", "-t", SESSION, "-x", str(width), "-y", str(height))

    def save(self, label):
        self.captures += 1
        name = f"{self.captures:02}-{label}.ansi"
        (self.screens / name).write_text(self.screen(ansi=True))
        return name

    # reporting

    def start(self, name):
        self.section = name
        print(f"== {name}", flush=True)

    def ok(self, label):
        self.passed += 1
        print(f"ok   [{self.section}]: {label}", flush=True)

    def fail(self, label, detail=""):
        self.failures.append(f"[{self.section}] {label}")
        name = self.save("failure")
        print(f"FAIL [{self.section}]: {label}{detail}", flush=True)
        print("---- screen ----")
        print("\n".join("  | " + row for row in self.rows()))
        print(f"---- saved as {name}", flush=True)

    # waiting and checking

    def poll(self, predicate, timeout=10.0):
        deadline = time.monotonic() + timeout
        while True:
            if predicate():
                return True
            if time.monotonic() >= deadline:
                return False
            time.sleep(0.05)

    def wait(self, label, predicate, timeout=10.0, fatal=True):
        """Polls the screen until [predicate(screen)]; a timeout fails the check, and
        with [fatal] stops the run."""
        if self.poll(lambda: predicate(self.screen()), timeout):
            self.ok(label)
            return True
        self.fail(label, " (timed out)")
        if fatal:
            raise Abort(label)
        return False

    def shows(self, *texts, absent=(), fatal=True, timeout=10.0):
        label = "screen shows " + ", ".join(repr(text) for text in texts)
        if absent:
            label += " and not " + ", ".join(repr(text) for text in absent)
        return self.wait(
            label,
            lambda s: all(text in s for text in texts) and not any(text in s for text in absent),
            timeout=timeout,
            fatal=fatal,
        )

    def footer(self):
        """The view frame's bottom border (the footer), or ''."""
        for row in reversed(self.rows()):
            if row.startswith("╰"):
                return row
        return ""

    def footer_is(self, prefix, fatal=True):
        return self.wait(f"footer starts '{prefix}'",
                         lambda _s: self.footer().startswith("╰─ " + prefix), fatal=fatal)

    def selected(self, text, fatal=True):
        """The lists column's selected row ('│ >' marks it) contains [text]."""
        return self.wait(
            f"cursor on '{text}'",
            lambda s: any(row.startswith("│ >") and text in row.split("│")[1]
                          for row in s.splitlines()),
            fatal=fatal,
        )

    def check(self, label, condition, detail=""):
        """A non-fatal check of something other than the screen (git state, files)."""
        if condition:
            self.ok(label)
        else:
            self.fail(label, f": {detail}" if detail else "")

    def check_poll(self, label, predicate, detail=lambda: "", timeout=10.0):
        """A git-state check that may need the running job to finish first."""
        if self.poll(predicate, timeout):
            self.ok(label)
        else:
            self.fail(label, f": {detail()}")

    # git

    def git(self, *args, cwd=None):
        env = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1",
                   LC_ALL="C.UTF-8")
        result = subprocess.run(["git", "-C", str(cwd or self.repo), *args], env=env,
                                text=True, capture_output=True)
        return result.stdout

    def git_ok(self, *args):
        env = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1")
        return subprocess.run(["git", "-C", str(self.repo), *args], env=env,
                              capture_output=True).returncode == 0

    def status(self):
        return self.git("status", "--porcelain").splitlines()

    # the editor

    def focus_list(self, number, name):
        """Focuses list panel [number] ([name]) from wherever the view's focus is."""
        if self.footer().startswith("╰─ Diff"):
            self.keys("Tab")
            self.wait("Tab leaves the diff",
                      lambda _s: not self.footer().startswith("╰─ Diff"))
        self.keys(str(number))
        self.footer_is(name)


def run(smoke):
    s = smoke
    repo = s.repo
    remote = repo.parent / "remote.git"

    s.start("launch")
    shell_env = {
        "HOME": str(s.work / "home"),
        "PATH": os.environ["PATH"],
        "LC_ALL": "C.UTF-8",
        "TERM": "tmux-256color",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "PS1": "$ ",
    }
    (s.work / "home").mkdir()
    s.t("new-session", "-d", "-s", SESSION, "-x", str(WIDTH), "-y", str(HEIGHT),
        "-c", str(repo),
        "env -i " + " ".join(f"{k}={shlex.quote(v)}" for k, v in shell_env.items())
        + " bash --norc --noprofile")
    s.t("set-option", "-g", "window-size", "manual")
    s.t("set-option", "-t", SESSION, "status", "off")
    before, after, code = (s.work / name for name in ("stty.before", "stty.after", "exit-code"))
    s.type(f"stty -g > {before}; {shlex.quote(str(s.binary))} --no-lsp a.txt; "
           f"printf '%s' $? > {code}; stty -g > {after}\n")
    s.wait("ches starts", lambda sc: s.display("#{alternate_on}") == "1" and "NORMAL" in sc)
    # Hide status, problems and history: the checks read the view's rows.
    s.keys("Space", "v", "t", "Space", "v", "b", "Space", "v", "m")
    s.shows("line 5 changed", absent=("Problems (", "History:", "─ Status"))

    s.start("phase 2: the view")
    s.keys("Space", "g", "g")
    s.shows("VCS: work (main)", "Head: main", "Upstream: origin/main, ahead 1",
            "1 Files (3)", "Untracked files (1)", "Unstaged changes (1)", "Staged changes (1)",
            "2 Branches (4)", "3 Commits (200)", "Recent commits (first 200)",
            "modified   src/main.ml", "notes.txt")
    s.check("tab strip labels the view 'VCS: main'", "[2:VCS: main]" in s.rows()[0],
            s.rows()[0])
    s.save("view")
    s.footer_is("Files 1/6")
    s.keys("Space", "v", "?")
    s.footer_is("Files 1/6 | ? help, s x S U, Enter fold, Tab diff, c commit")
    s.keys("Space", "v", "?")
    s.footer_is("Files 1/6 ─")
    s.keys("Space", "g", "s")
    s.wait("Space g s puts the view in the split beside the editor",
           lambda sc: "─ VCS in split" in sc and "╭─ a.txt" in sc.splitlines()[0]
           and "╭─ VCS: work (main)" in sc.splitlines()[0])
    s.save("split")
    s.keys("Space", "g", "t")
    s.wait("Space g t moves it back to a tab",
           lambda sc: "VCS in tab strip" in sc and "[2:VCS: main]" in sc.splitlines()[0])
    s.keys("@")
    s.shows("@ Command log", "[exit 0] git status --porcelain=v2")
    s.save("command-log")
    s.keys("@")
    s.shows("1 Files (3)", absent=("@ Command log",))

    s.start("phase 3/4: stage a hunk, selected lines, discard")
    s.keys("j", "j", "j")
    s.shows("0 Diff: Unstaged: a.txt", "+line 25 changed")
    s.keys("Tab")
    s.footer_is("Diff 1-24/24")
    s.keys("2", "]", "s")  # the second hunk: line 25
    s.footer_is("Diff 1-15/15")
    s.check_poll("s staged only the hunk at the cursor",
                 lambda: "+line 25 changed" in s.git("diff", "--cached", "a.txt")
                 and "+line 25 changed" not in s.git("diff", "a.txt")
                 and "+line 5 changed" in s.git("diff", "a.txt"),
                 lambda: s.git("diff", "--cached", "a.txt"))
    # The cursor is on the remaining hunk's header; select -line 5 .. +line 5 changed.
    s.keys("4", "j", "V", "2", "j")
    s.footer_is("Diff 1-15/15 | VISUAL LINE")
    s.keys("s")
    s.shows("@@ -3,6 +3,7 @@")
    s.check_poll("V s staged only the selected lines",
                 lambda: "+line 5 changed" in s.git("diff", "--cached", "a.txt")
                 and "+line 6 changed" not in s.git("diff", "--cached", "a.txt")
                 and "+line 6 changed" in s.git("diff", "a.txt"),
                 lambda: s.git("diff", "a.txt"))
    s.keys("x")
    s.shows("Discard hunk 1/1 of a.txt? Its unstaged lines are lost.", "n no (default)")
    s.save("discard-question")
    s.keys("Escape")
    s.shows("+line 6 changed", absent=("Discard hunk",))
    s.check("Escape declines the discard", "+line 6 changed" in s.git("diff", "a.txt"))
    s.keys("x")
    s.shows("Discard hunk 1/1 of a.txt?")
    s.keys("y")
    s.check_poll("y discards: a.txt has no unstaged changes",
                 lambda: s.git("diff", "a.txt") == "", lambda: s.git("diff", "a.txt"))
    s.shows("Reloaded from disk: a.txt", absent=("Discard hunk",))
    s.check("the open a.txt keeps its staged state", s.status() ==
            ["M  a.txt", "M  src/main.ml", "?? notes.txt"], s.status())

    s.start("phase 5: commit")
    s.keys("c")
    s.shows("╭─ Commit", "-s  Add Signed-off-by line (--signoff)", "c  Commit")
    s.save("commit-popup")
    s.keys("c")
    s.shows("CHES_COMMIT_EDITMSG", "# On branch main", "#       modified:   src/main.ml")
    s.keys("i")
    s.type("Smoke commit")
    s.keys("Escape", "Space", "g", "c")
    s.shows("] Smoke commit", "[2:VCS: main]", "Upstream: origin/main, ahead 2")
    s.check_poll("git log -1 is the new commit",
                 lambda: s.git("log", "-1", "--format=%s").strip() == "Smoke commit",
                 lambda: s.git("log", "-1", "--format=%s"))
    s.check("it holds a.txt and src/main.ml; the work tree is clean but notes.txt",
            s.git("show", "--name-only", "--format=", "HEAD").split() == ["a.txt", "src/main.ml"]
            and s.status() == ["?? notes.txt"], s.status())
    s.check("the message file is gone", not (repo / ".git/CHES_COMMIT_EDITMSG").exists())

    s.start("phase 6: fetch and a refused pull")
    s.shows("Upstream: origin/main, ahead 2", absent=("behind",))
    s.keys("f")
    s.shows("Fetch: done", "Upstream: origin/main, ahead 2, behind 1")
    s.save("fetched")
    head = s.git("rev-parse", "HEAD")
    s.keys("p")
    s.shows("╭─ Pull", "-r  Rebase local commits onto the upstream (--rebase)",
            "p  Pull from origin/main")
    s.keys("p")
    s.shows("Pull from origin/main failed: The branch and its upstream have diverged: "
            "pull with rebase (p -r p)")
    s.check("the refused pull changed nothing", s.git("rev-parse", "HEAD") == head)

    s.start("phase 7: rebase pull, resolve, continue, push")
    s.keys("p", "-", "r", "p")
    s.shows("Rebasing main onto", "(press r)", "Conflicted (1)", "both modified   a.txt",
            "Stopped on conflicts")
    s.check("git is rebasing with a.txt unmerged",
            (repo / ".git/rebase-merge").is_dir() and "UU a.txt" in s.status(), s.status())
    s.save("rebase-stopped")
    s.resize(80, 24)
    s.wait("at 80 columns the lists column shows the whole 'Rebasing ... (press r)' row",
           lambda sc: any("Rebasing main onto" in row and "(press r)" in row.split("│")[1]
                          for row in sc.splitlines() if row.count("│") >= 2),
           fatal=False)
    s.save("rebase-80-columns")
    s.resize(WIDTH, HEIGHT)
    s.wait("back to 120 columns", lambda sc: len(sc.splitlines()[1]) >= WIDTH - 1)
    s.focus_list(1, "Files")
    s.keys("g", "g", "j")
    s.selected("both modified   a.txt")
    s.shows("0 Diff: Conflicted: a.txt", "<<<<<<<")
    s.keys("x")
    s.shows("╭─ Resolve a.txt", "o  Take ours (the upstream)", "t  Take theirs (your commit)",
            "m  Restore the conflict markers")
    s.save("resolve-popup")
    s.keys("t")
    s.shows("Take theirs (your commit) for a.txt?", "y yes   n no (default)")
    s.keys("y")
    s.shows("Staged changes (1)", absent=("Conflicted (",))
    s.check("a.txt is resolved and staged", "M  a.txt" in s.status(), s.status())
    s.keys("r")
    s.shows("╭─ Rebasing", "r  Continue", "a  Abort", "s  Skip this commit")
    s.keys("r")
    s.shows("Upstream: origin/main, ahead 2", "[2:VCS: main]", absent=("Rebasing main",))
    s.check_poll("the rebase finished on top of origin/main",
                 lambda: not (repo / ".git/rebase-merge").exists()
                 and s.git_ok("merge-base", "--is-ancestor", "origin/main", "HEAD")
                 and s.git("log", "-1", "--format=%s").strip() == "Smoke commit",
                 lambda: s.git("log", "-3", "--oneline"))
    s.keys("P")
    s.shows("╭─ Push main", "p  Push to origin/main", "u  Push to origin/main, set upstream")
    s.keys("p")
    s.shows("Push main to origin/main: done", "Upstream: origin/main, up to date")
    s.check_poll("the remote has the rebased main",
                 lambda: s.git("rev-parse", "main", cwd=remote) == s.git("rev-parse", "HEAD"),
                 lambda: s.git("log", "-2", "--oneline", "main", cwd=remote))

    s.start("phase 7: a merge stopped on conflicts, aborted")
    s.focus_list(2, "Branches")
    s.keys("g", "g", "j")
    s.selected("conflict-me")
    s.keys("m")
    s.shows("╭─ Merge", "-n  Always create a merge commit (--no-ff)", "m  Merge conflict-me")
    s.keys("m")
    s.shows("Merging", "(press m)", "both modified   a.txt", "deleted by them src/main.ml")
    s.check("git is merging", (repo / ".git/MERGE_HEAD").exists())
    s.save("merge-stopped")
    s.keys("m")
    s.shows("╭─ Merging", "m  Commit the merge", "a  Abort")
    s.keys("a")
    s.shows("y yes   n no (default)")
    s.keys("y")
    s.shows("Upstream: origin/main, up to date", absent=("Merging", "Conflicted ("))
    s.check_poll("m a aborted the merge",
                 lambda: not (repo / ".git/MERGE_HEAD").exists() and s.status() == ["?? notes.txt"],
                 lambda: str(s.status()))

    s.start("phase 8: log and history")
    s.focus_list(3, "Commits")
    s.shows("Recent commits (first 200) (200)", "● ", "(HEAD -> main, origin/main) Smoke")
    s.keys("+")
    s.wait("+ reads more: the title drops 'first 200'",
           lambda sc: re.search(r"Recent commits \(2[0-9][0-9]\)", sc) is not None
           and "first 200" not in sc)
    s.keys("G")
    s.shows("(tag: v1, doomed) Initial commit", "●─╮", "●─╯", "│ ●")
    s.save("graph")
    s.focus_list(2, "Branches")
    s.keys("g", "g", "j", "j", "j")
    s.selected("feature  Feature: add feature.txt")
    s.keys("l")
    s.shows("╭─ Log", "* -g  Show the graph (--graph)", "b  Log feature")
    s.save("log-popup")
    s.keys("b")
    s.shows("Commits on feature (3)", "(origin/feature, feature) Feature")
    s.footer_is("Commits")
    s.keys("l", "a")
    s.shows("All branches (first 200)")
    s.keys("q")
    s.wait("q leaves the view for the file tab", lambda sc: sc.startswith("[1:a.txt]"))
    s.keys("Space", "g", "l")
    s.shows("History of a.txt (6)", "[2:VCS: main]")
    s.footer_is("Commits")
    s.save("file-history")

    s.start("quit while a fetch runs")
    s.keys("f", "q", "Space", "q")
    s.wait("ches exits", lambda _s: s.display("#{alternate_on}") == "0" and after.exists()
           and after.stat().st_size > 0)
    s.check("exit status 0", code.read_text() == "0", code.read_text())
    s.check("terminal modes restored", before.read_bytes() == after.read_bytes())
    s.check("cursor visible", s.display("#{cursor_flag}") == "1")
    locks = sorted(str(p.relative_to(repo)) for p in (repo / ".git").rglob("*.lock"))
    s.check("no git lock file left", not locks, ", ".join(locks))


def main():
    binary = Path(sys.argv[1] if len(sys.argv) > 1
                  else ROOT / "_build/default/bin/ches.exe").resolve()
    if not shutil.which("tmux"):
        raise SystemExit("vcs_smoke: tmux is required")
    if not binary.is_file():
        raise SystemExit(f"vcs_smoke: {binary} is not built; run dune build bin/ches.exe")
    base = os.environ.get("TMPDIR", "/tmp")
    work = Path(tempfile.mkdtemp(prefix="ches-vcs-smoke.", dir=base))
    screens = Path(tempfile.mkdtemp(prefix="ches-vcs-smoke-screens.", dir=base))
    smoke = Smoke(binary, work, screens)
    started = time.monotonic()
    aborted = None
    try:
        sandbox = subprocess.run(
            [str(ROOT / "scripts/vcs_sandbox.sh"), str(work / "sandbox")],
            env=dict(os.environ, LC_ALL="C.UTF-8"), capture_output=True, text=True)
        if sandbox.returncode != 0:
            raise SystemExit(f"vcs_smoke: the sandbox failed:\n{sandbox.stderr}")
        try:
            run(smoke)
        except Abort as error:
            aborted = str(error)
    finally:
        subprocess.run(smoke.tmux + ["kill-server"], capture_output=True)
        shutil.rmtree(work, ignore_errors=True)
        shutil.rmtree(smoke.socket_dir, ignore_errors=True)
    elapsed = time.monotonic() - started
    print(f"Screens: {screens}")
    if smoke.failures or aborted:
        if aborted:
            print(f"Stopped after: {aborted}")
        print(f"FAIL: {len(smoke.failures)} of {smoke.passed + len(smoke.failures)} checks "
              f"({elapsed:.1f}s)")
        for failure in smoke.failures:
            print(f"  {failure}")
        sys.exit(1)
    print(f"PASS: {smoke.passed} checks ({elapsed:.1f}s)")


if __name__ == "__main__":
    main()
