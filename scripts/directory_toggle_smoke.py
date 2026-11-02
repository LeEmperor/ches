#!/usr/bin/env python3
"""Real frontend main-directory toggles, checked against the rendered tmux screen."""
import shlex
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def main():
    executable = Path(sys.argv[1] if len(sys.argv) > 1 else
                      Path(__file__).resolve().parents[1] / "_build/default/bin/ches.exe").resolve()
    root = Path(tempfile.mkdtemp(prefix="directory-toggle-", dir="/tmp"))
    filename = "b-current-file-with-a-long-directory-entry-name.txt"
    marker = "MAIN_FILE_EDITOR_SENTINEL"
    (root / filename).write_text(marker + "\n")
    (root / "a-other.txt").write_text("OTHER_FILE_MUST_NOT_OPEN\n")
    tmux = ["tmux", "-S", str(root / "sock"), "-f", "/dev/null"]

    def t(*args):
        return subprocess.check_output(tmux + list(args), text=True)

    def screen():
        return t("capture-pane", "-p", "-t", "toggle")

    def wait(predicate, label):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            rendered = screen()
            if predicate(rendered):
                return rendered
            time.sleep(0.05)
        raise AssertionError(f"{label}:\n{screen()}")

    def send(keys):
        t("send-keys", "-t", "toggle", "-l", "--", keys)

    def assert_file(label):
        wait(lambda s: marker in s and "OTHER_FILE_MUST_NOT_OPEN" not in s, label)

    def assert_major(label):
        # A sidebar still leaves the file body visible. Main placement must show
        # the listing instead, with room for an entry wider than the side pane.
        rendered = wait(lambda s: "Directory:" in s and filename in s and marker not in s, label)
        assert "OTHER_FILE_MUST_NOT_OPEN" not in rendered, rendered
        (root / f"{label}.screen").write_text(rendered)

    try:
        command = shlex.join([str(executable), "--no-lsp", "--workspace", filename])
        t("new-session", "-d", "-s", "toggle", "-x", "100", "-y", "24", "-c", str(root),
          "env TERM=xterm-256color LC_ALL=C.UTF-8 " + command)
        t("set-option", "-t", "toggle", "status", "off")
        assert_file("startup")
        for scenario in ("visible", "hidden", "zen"):
            send(" ds")
            wait(lambda s: "╭─ Directory" in s and marker in s, "sidebar visible")
            # From the directory, Space o must return to the file, retaining Side.
            send(" o")
            wait(lambda s: "╭─ Directory" in s and marker in s, "side toggle returns file")
            if scenario == "hidden":
                send(" dh")
            elif scenario == "zen":
                send(" vz")
            if scenario != "visible":
                wait(lambda s: "0 marked |" not in s and marker in s, "sidebar suppressed")
            send(" o")
            assert_major(scenario + "-major")
            # Enter must open the selected current file, rather than a-other.txt.
            t("send-keys", "-t", "toggle", "Enter")
            assert_file(scenario + " Enter returns selected file")
            send(" o")
            assert_major(scenario + "-repeated-major")
            send(" o")
            wait(lambda s: "0 marked |" not in s and marker in s, "major toggle returns file")
        send(" q")
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if subprocess.run(tmux + ["has-session", "-t", "toggle"],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
                break
            time.sleep(0.05)
        else:
            raise AssertionError("clean quit timed out")
        assert (root / filename).read_text() == marker + "\n"
        assert (root / "a-other.txt").read_text() == "OTHER_FILE_MUST_NOT_OPEN\n"
        print("PASS: frontend Space o visible/hidden/Zen side -> major, selected-file Enter,")
        print("      side return, repeated major return, unchanged file contents")
        print("Fixture:", root)
    finally:
        subprocess.run(tmux + ["kill-server"], stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    main()
