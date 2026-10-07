#!/usr/bin/env python3
"""Real file/content picker smoke; private tmux and /tmp/opencode fixtures only.

Requires tmux, rg and a built ches. Captures are automated evidence, not visual,
ranking or performance acceptance. Fixtures/captures are retained for diagnosis.
"""
import os
import shlex
import subprocess
import tempfile
import time
from pathlib import Path


def main():
    binary = Path(__file__).resolve().parents[1] / "_build/default/bin/ches.exe"
    root = Path(tempfile.mkdtemp(prefix="picker-terminal-", dir="/tmp/opencode"))
    artifacts = root / ".captures"
    artifacts.mkdir()  # Hidden: screenshots must never become search candidates.
    (root / "dune-project").write_text("")
    original = "START document\n"
    (root / "alpha.txt").write_text(original)
    (root / "beta.txt").write_text("BETA document\n")
    (root / "target.txt").write_text("padding\n" * 80 + "界\tneedle\n")
    (root / "gone.txt").write_text("vanishing\n")
    (root / "stale.txt").write_text("stale-literal\n")
    (root / "nav").mkdir()
    (root / "nav/a.txt").write_text("NAV_A_PREVIEW\n")
    (root / "nav/b.txt").write_text("NAV_B_PREVIEW\n")
    (root / "large-lines.txt").write_text("LARGE_PREFIX\n" * 150)
    (root / "large-bytes.txt").write_text("BYTE_PREFIX" + "x" * 100000)
    (root / "empty.txt").write_text("")
    (root / "binary.txt").write_bytes(b"\x00binary")
    (root / "controls.txt").write_text("\t界é\x1b[31m\r\x01\u202ertl\nshort\n")
    tmux = ["tmux", "-S", str(root / "tmux.sock"), "-f", "/dev/null"]
    captures = 0

    def t(*args):
        return subprocess.check_output(tmux + list(args), text=True)

    def screen():
        return t("capture-pane", "-p", "-t", "picker")

    def save(label):
        nonlocal captures
        captures += 1
        (artifacts / f"{captures:02}-{label}.txt").write_text(screen())
        (artifacts / f"{captures:02}-{label}.ansi").write_text(
            t("capture-pane", "-p", "-e", "-t", "picker"))

    def wait(text, absent=()):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            output = screen()
            if text in output and all(word not in output for word in absent):
                return output
            time.sleep(.05)
        save("failure")
        raise AssertionError(f"Waiting for {text!r}, absent={absent}:\n{screen()}")

    def send(text):
        t("send-keys", "-t", "picker", "-l", "--", text)

    def key(name):
        t("send-keys", "-t", "picker", name)
        time.sleep(.15)

    def files(query=""):
        send(" ff" + query)
        wait(query or "beta.txt", ("Loading", "Filtering"))
        time.sleep(.15)

    def content(query, result):
        send(" fg" + query)
        wait(result, ("Loading", "Debouncing"))

    def resize(width, height):
        t("resize-window", "-t", "picker", "-x", str(width), "-y", str(height))
        time.sleep(.3)

    try:
        t("new-session", "-d", "-s", "picker", "-x", "140", "-y", "30",
          "-c", str(root))
        t("set-option", "-t", "picker", "status", "off")
        t("set-window-option", "-t", "picker", "window-size", "manual")
        send(f"stty -g > before; {shlex.quote(str(binary))} --no-lsp alpha.txt; "
             "printf '%s' $? > exit-code; stty -g > after\n")
        wait("START document")
        send("iDIRTY")
        key("Escape")
        files("alpha")
        wait("buffer r")
        wait("  1 DIRTYSTART document")
        assert "Enter, Esc" not in screen() and "Tab/Shift-Tab" not in screen()
        resize(180, 48)
        wait("  1 DIRTYSTART document")
        rows = screen().splitlines()
        top = next(i for i, row in enumerate(rows) if "Files |" in row)
        bottom = next(i for i, row in enumerate(rows) if "matches" in row and "╰" in row)
        assert bottom - top + 1 == 40
        assert rows[top].index("╮") - rows[top].index("╭") + 1 == 175
        save("preferred-175x40-hidden-controls")
        resize(140, 30)
        wait("  1 DIRTYSTART document")
        save("dirty-selected-preview")
        key("Escape")
        # Existing global toggle, also discoverable through the command palette.
        send(" ccToggle tile hotkey hints")
        wait("> Toggle tile hotkey hints")
        key("Enter")
        files("alpha")
        wait("Enter, Esc")
        wait("Tab/Shift-Tab")
        save("file-controls-requested")
        key("Escape")
        send(" v?")
        files("alpha")
        wait("buffer r", ("Enter, Esc", "Tab/Shift-Tab"))
        key("Escape")
        # Real terminal Tab and CSI Z (tmux BTab), not normalized test inputs.
        files("nav/")
        wait("Preview | nav/a.txt")
        wait("NAV_A_PREVIEW")
        key("Tab")
        wait("Preview | nav/b.txt")
        wait("NAV_B_PREVIEW", ("NAV_A_PREVIEW",))
        key("BTab")
        wait("Preview | nav/a.txt")
        wait("NAV_A_PREVIEW", ("NAV_B_PREVIEW",))
        # A-B-A burst followed by selected acceptance must not use an old payload.
        t("send-keys", "-t", "picker", "Tab", "BTab", "Tab")
        wait("NAV_B_PREVIEW", ("NAV_A_PREVIEW",))
        save("native-tab-selected-preview")
        key("Enter")
        wait("NAV_B_PREVIEW", ("Preview |",))
        files("alpha")
        key("Enter")
        wait("DIRTYSTART document", ("Preview |",))
        # Palette navigation uses the selected command, not the query's first hit.
        send(" ccgutter")
        wait("> Toggle absolute line numbers")
        key("Tab")
        wait("> Toggle relative line numbers")
        key("BTab")
        wait("> Toggle absolute line numbers")
        key("Tab")
        key("Enter")
        wait("Line numbers: relative", ("Commands",))
        save("native-palette-selected-acceptance")
        for query, expected in [("large-lines", "100 lines"),
                                ("large-bytes", "64 KiB"),
                                ("empty.txt", "Empty file"),
                                ("binary.txt", "Unsupported binary file")]:
            files(query)
            wait(expected)
            save(query + "-preview")
            key("Escape")
        files("controls.txt")
        wait("<202e>rtl")
        wait("^[[31m^M^A")
        save("safe-controls-preview")
        resize(90, 25)
        wait("controls.txt", ("Preview |",))
        resize(140, 30)
        wait("Preview | controls.txt")
        wait("<202e>rtl")
        save("wide-preview-restored")
        key("Escape")
        files("nav/")
        key("Tab")
        key("Escape")
        files("nav/")
        wait("NAV_A_PREVIEW", ("NAV_B_PREVIEW",))
        save("reopened-first-preview")
        key("Escape")
        files("beta")
        save("file-query")
        key("Enter")
        wait("BETA document")
        files("alpha")
        wait("buffer r")
        wait("  1 DIRTYSTART document")
        save("inactive-dirty-buffer-preview")
        key("Enter")
        wait("DIRTYSTART document")
        # Dirty revisits are neither disk reloads nor implicit writes.
        assert (root / "alpha.txt").read_text() == original
        files()
        key("C-n")
        key("Escape")
        wait("DIRTYSTART document")
        files("no-such-result")
        wait("No matching")
        key("Enter")
        wait("No matching")
        key("Escape")
        files("gone")
        (root / "gone.txt").unlink()
        # Resize invalidates the ready disk snapshot while keeping discovery/results.
        resize(120, 30)
        wait("File missing")
        save("missing-selected-preview")
        key("Enter")
        wait("file no longer exists")
        assert not (root / "gone.txt").exists()
        wait("DIRTYSTART document")
        save("file-failed-open")
        # On-disk content, Unicode/TAB location conversion and real viewport reveal.
        content("needle", "target.txt:81")
        save("content-query")
        key("C-n")  # Clamped one-hit selection.
        key("Enter")
        wait("81:3")
        wait("needle")
        save("content-open-location")
        send("ggiELSEWHERE")
        key("Escape")
        content("needle", "target.txt:81")
        key("Enter")
        wait("81:3")
        send("iCHANGED")
        key("Escape")
        content("needle", "target.txt:81")
        key("Enter")
        wait("Content result changed")
        wait("CHANGED")
        send("u")
        content("needle", "target.txt:81")
        key("Enter")
        wait("81:3")
        content("stale-literal", "stale.txt:1")
        (root / "stale.txt").write_text("replacement\n")
        key("Enter")
        wait("Content result changed")
        save("content-stale")
        send(" ccSearch project contents")
        key("Enter")
        wait("ON DISK")
        key("Escape")
        send(" ccFind project files")
        key("Enter")
        wait("beta.txt", ("Loading", "Filtering"))
        key("Escape")
        # Zen cancel restores the actual document/cursor, not merely file bytes.
        send(" vz")
        time.sleep(.3)
        baseline = screen()
        cursor = t("display-message", "-p", "-t", "picker", "#{cursor_x} #{cursor_y}")
        files("beta")
        key("Escape")
        assert screen() == baseline
        assert t("display-message", "-p", "-t", "picker", "#{cursor_x} #{cursor_y}") == cursor
        content("needle", "target.txt:81")
        key("Escape")
        assert screen() == baseline
        files("beta")
        resize(90, 25)
        wait("beta.txt", ("Filtering",))
        resize(14, 5)
        wait("> beta")
        save("minimum")
        resize(13, 4)
        resize(100, 30)
        assert "> beta" not in screen()
        # Paste collected by the old float cannot escape after a closing resize.
        files()
        send("\x1b[200~LATE")
        resize(13, 4)
        send("LEAK\x1b[201~")
        resize(100, 30)
        assert "LATE" not in screen() and "LEAK" not in screen()
        content("needle", "target.txt:81")
        resize(13, 4)
        resize(100, 30)
        content("needle", "target.txt:81")
        send("\x1b[200~CONTENT-LATE")
        resize(13, 4)
        send("CONTENT-LEAK\x1b[201~")
        resize(100, 30)
        assert "CONTENT-LATE" not in screen() and "CONTENT-LEAK" not in screen()
        content("needle", "target.txt:81")
        key("Escape")
        resize(140, 30)
        files("nav/")
        wait("NAV_A_PREVIEW")
        send("\x1b[200~PREVIEW-LATE")
        resize(13, 4)
        send("PREVIEW-LEAK\x1b[201~")
        resize(140, 30)
        files("nav/")
        wait("NAV_A_PREVIEW", ("PREVIEW-LATE", "PREVIEW-LEAK", "NAV_B_PREVIEW"))
        save("preview-interrupted-paste-reopen")
        key("Escape")
        send(" Q")
        deadline = time.monotonic() + 5
        while not (root / "after").exists() and time.monotonic() < deadline:
            time.sleep(.05)
        assert (root / "exit-code").read_text() == "0"
        assert (root / "before").read_text() == (root / "after").read_text()
        assert (root / "alpha.txt").read_text() == original
        assert (root / "target.txt").read_text() == "padding\n" * 80 + "界\tneedle\n"
        # A directory startup has no file tab; picker acceptance creates one using
        # the same retained startup project root, then content search uses it too.
        send(f"{shlex.quote(str(binary))} --no-lsp .; "
             "printf '%s' $? > exit-directory; stty -g > after-directory\n")
        wait("Directory")
        files("beta")
        key("Enter")
        wait("BETA document")
        content("needle", "target.txt:81")
        key("Enter")
        wait("81:3")
        save("directory-startup-scope")
        send(" q")
        deadline = time.monotonic() + 5
        while not (root / "after-directory").exists() and time.monotonic() < deadline:
            time.sleep(.05)
        assert (root / "exit-directory").read_text() == "0"
        assert (root / "before").read_text() == (root / "after-directory").read_text()
        print("PASS: real file/content binding+catalog, query/select/cancel/accept, dirty revisits,")
        print("      failed/stale opens, Unicode location, undo, zen, resize/tiny, both late pastes,")
        print("      file/directory startup scope and tty restore")
        print("      native Tab/Shift-Tab file+palette selected acceptance, bounded/dirty/missing")
        print("      previews, safe controls, narrow/wide resize, A-B-A, reopen/interrupted paste")
        print("      175x40 preferred float, hidden-default/requested controls and existing toggle")
        print("Fixtures and captures:", root)
    finally:
        try:
            save("final")
        finally:
            subprocess.run(tmux + ["kill-server"], check=False)


if __name__ == "__main__":
    main()
