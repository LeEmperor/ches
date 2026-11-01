#!/usr/bin/env python3
"""Dynamic-theme terminal checks. Run after dune build; requires tmux.

Uses a private socket and retains ANSI captures under the system temp dir ($TMPDIR or /tmp) for diagnosis.
The existing smoke.sh bare and palette scenarios remain independent.
"""
from pathlib import Path
import re
import shutil
import shlex
import subprocess
import sys
import tempfile
import time


def main():
    binary = Path(sys.argv[1] if len(sys.argv) > 1 else
                  Path(__file__).resolve().parents[1] / "_build/default/bin/ches.exe").resolve()
    listing = subprocess.run([str(binary), "--list-themes"], input="", text=True,
                             capture_output=True, check=True).stdout
    rows = [row.split("\t") for row in listing.splitlines()]
    assert len(rows) >= 40 and all(len(row) == 3 for row in rows), listing
    assert {row[2] for row in rows} == {"dark", "light"}, listing
    assert {"crimson", "glacier"} <= {row[0] for row in rows}, listing
    invalid = subprocess.run([str(binary), "--theme", "nonexistent-theme"], input="",
                             text=True, capture_output=True)
    assert invalid.returncode and "--list-themes" in invalid.stderr, invalid
    missing = subprocess.run([str(binary)], input="", text=True, capture_output=True)
    assert missing.returncode and "PATH is required" in missing.stderr, missing
    print("ok: CLI catalog, light/dark kinds, invalid theme and required edit path")

    root = Path(tempfile.mkdtemp(prefix="theme-terminal-"))
    fixture = root / "document.txt"
    original = b"THEME document\nsecond line\n"
    fixture.write_bytes(original)
    # A socket path must stay short (108 bytes), whatever TMPDIR is.
    socket_dir = Path(tempfile.mkdtemp(prefix="ches-theme-tmux.", dir="/tmp"))
    tmux = ["tmux", "-S", str(socket_dir / "sock"), "-f", "/dev/null"]

    def t(*args):
        return subprocess.check_output(tmux + list(args), text=True)

    def screen(ansi=False):
        return t("capture-pane", "-p", *( ["-e"] if ansi else []), "-t", "theme")

    def wait(predicate, label):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(.05)
        (root / "failure.ansi").write_text(screen(True))
        raise AssertionError(f"{label}:\n{screen()}")

    def send(text):
        t("send-keys", "-t", "theme", "-l", "--", text)

    def key(name):
        t("send-keys", "-t", "theme", name)
        time.sleep(.12)

    def colors(label):
        ansi = screen(True)
        (root / f"{label}.ansi").write_text(ansi)
        # First document row lies outside the centered float. Its SGR colors must
        # change during preview even though its text and geometry do not change.
        row = next(row for row in ansi.splitlines() if "THEME document" in row)
        prefix = row.split("THEME document")[0]
        rgb = [re.findall(rf"{channel};2;\d+;\d+;\d+", prefix)
               for channel in (38, 48)]
        assert all(rgb), f"No truecolor attributes in {row!r}"
        return tuple(channel[-1] for channel in rgb)

    def alternate():
        return t("display-message", "-p", "-t", "theme", "#{alternate_on}").strip()

    def launch(theme):
        send(f"stty -g > before; {shlex.quote(str(binary))} --no-lsp --bare "
             f"--theme {theme} document.txt; printf '%s' $? > exit-code; stty -g > after\n")
        wait(lambda: alternate() == "1" and "THEME document" in screen(), "startup")
        time.sleep(.15)

    def finish():
        send(" q")
        wait(lambda: alternate() == "0" and (root / "after").exists(), "terminal exit")
        assert (root / "exit-code").read_text() == "0"
        assert (root / "before").read_bytes() == (root / "after").read_bytes()
        assert t("display-message", "-p", "-t", "theme", "#{cursor_flag}").strip() == "1"
        assert fixture.read_bytes() == original
        (root / "after").unlink()

    try:
        t("new-session", "-d", "-s", "theme", "-x", "140", "-y", "44", "-c", str(root),
          "env LC_ALL=C.UTF-8 TERM=tmux-256color bash --norc --noprofile")
        t("set-option", "-t", "theme", "status", "off")
        launch("glacier")
        light = colors("startup-glacier")
        finish()
        launch("crimson")
        dark = colors("startup-crimson")
        assert dark != light
        send(" vT")
        wait(lambda: "╭─ Choose theme" in screen(), "theme picker")
        send("glacier")
        wait(lambda: colors("preview-glacier") == light, "live preview")
        key("Escape")
        wait(lambda: colors("cancel-crimson") == dark, "cancel restores original")
        send(" ccChoose theme")
        wait(lambda: "> Choose theme" in screen(), "palette command")
        key("Enter")
        wait(lambda: "╭─ Choose theme" in screen(), "palette opens theme picker")
        send("glacier")
        key("Enter")
        wait(lambda: "╭─ Choose theme" not in screen() and colors("accepted-glacier") == light,
             "Enter accepts")
        send(" vB")
        wait(lambda: "NORMAL" in screen(), "workspace presentation")
        assert colors("workspace-glacier") == light
        send(" vB")
        key("l")
        key("h")
        wait(lambda: colors("bare-glacier") == light, "bare retains theme")
        send(" w")
        wait(lambda: "Wrote" in screen(), "save")
        assert fixture.read_bytes() == original
        finish()
        print("ok: distinct startup RGB; live preview/cancel/accept; palette; shared presentation theme")
        print("ok: unchanged save bytes, clean exits, restored terminal modes and visible cursor")
    finally:
        subprocess.run(tmux + ["kill-server"], check=False, capture_output=True)
        shutil.rmtree(socket_dir, ignore_errors=True)
        print(f"Theme terminal captures: {root}")


if __name__ == "__main__":
    main()
