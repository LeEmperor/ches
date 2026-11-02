#!/usr/bin/env python3
"""Embedded-terminal smoke against built ches; Python stdlib, tmux and POSIX tools.

Run after dune build (optionally pass the executable). Uses a private tmux server,
an isolated /bin/sh environment, and temporary fixtures. Captures/results are kept
under the system temp directory for diagnosis. No git or package dependencies.
"""
from pathlib import Path
import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import time


# Run inside the *embedded* PTY, so assertions cover Notty decoding, the frontend,
# libvterm key encoding and the PTY, rather than just tmux's outer input stream.
PROBE = r'''
import json, os, select, sys, termios, time, tty
from pathlib import Path

root = Path(sys.argv[1])
fd = sys.stdin.fileno()
saved = termios.tcgetattr(fd)
cases = [
    ("up", [b"\x1b[A", b"\x1bOA"]),
    ("down", [b"\x1b[B", b"\x1bOB"]),
    ("left", [b"\x1b[D", b"\x1bOD"]),
    ("right", [b"\x1b[C", b"\x1bOC"]),
    ("home", [b"\x1b[H", b"\x1bOH", b"\x1b[1~"]),
    ("end", [b"\x1b[F", b"\x1bOF", b"\x1b[4~"]),
    ("delete", [b"\x1b[3~"]),
    ("backspace", [b"\x7f", b"\x08"]),
    ("tab", [b"\x09"]),
    ("shift-tab", [b"\x1b[Z"]),
    ("ctrl-a", [b"\x01"]),
    ("ctrl-underscore", [b"\x1f"]),
    ("alt-x", [b"\x1bx"]),
    ("f5", [b"\x1b[15~"]),
    ("paste", [b"\x1b[200~paste \xe4\xb8\xad\tline\nnext\x1b[201~"]),
]
results = []
try:
    tty.setraw(fd)
    # Ask both emulator and frontend to preserve bracketed-paste semantics.
    os.write(1, b"\x1b[?2004h")
    for name, expected in cases:
        os.write(1, ("\r\nCHES_PROBE_READY=" + name + "\r\n").encode())
        data = b""
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if not select.select([fd], [], [], max(0, deadline - time.monotonic()))[0]:
                break
            data += os.read(fd, 4096)
            if data in expected or not any(item.startswith(data) for item in expected):
                break
        results.append({"key": name, "hex": data.hex(),
                        "ok": data in expected})
        (root / "input-results.tmp").write_text(json.dumps(results, indent=2))
        (root / "input-results.tmp").replace(root / "input-results.json")
        if data not in expected:
            raise AssertionError((name, data, expected))
finally:
    os.write(1, b"\x1b[?2004l")
    termios.tcsetattr(fd, termios.TCSANOW, saved)
print("CHES_PROBE_DONE", flush=True)
'''


def main():
    binary = Path(sys.argv[1] if len(sys.argv) > 1 else
                  Path(__file__).resolve().parents[1] / "_build/default/bin/ches.exe").resolve()
    if not binary.is_file():
        raise SystemExit(f"Build ches first; executable not found: {binary}")
    if shutil.which("tmux") is None:
        raise SystemExit("tmux is required")
    root = Path(tempfile.mkdtemp(prefix="ches-terminal-"))
    project = root / "project"
    project.mkdir()
    fixture = project / "document.txt"
    original = b"TERMINAL_SMOKE_DOCUMENT\nunchanged editor contents\n"
    fixture.write_bytes(original)
    (root / "input_probe.py").write_text(PROBE)
    # exec retains the recorded PID: Ctrl-C must terminate a genuine foreground
    # sleep, not merely clear an idle shell's input line.
    (root / "foreground.sh").write_text(
        f"printf '%s' \"$$\" > {shlex.quote(str(root / 'sleep.pid'))}\nexec sleep 30\n")
    socket_dir = Path(tempfile.mkdtemp(prefix="ches-term-tmux.", dir="/tmp"))
    tmux = ["tmux", "-S", str(socket_dir / "sock"), "-f", "/dev/null"]
    target = "terminal:0.0"

    def t(*args):
        return subprocess.check_output(tmux + list(args), text=True, stderr=subprocess.STDOUT)

    def screen(ansi=False):
        return t("capture-pane", "-p", *(["-e"] if ansi else []), "-t", target)

    def capture(label):
        (root / f"{label}.ansi").write_text(screen(True))
        (root / f"{label}.txt").write_text(screen())

    def wait(predicate, label, timeout=8):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(.05)
        capture("failure")
        raise AssertionError(f"{label}:\n{screen()}")

    def send(text):
        t("send-keys", "-t", target, "-l", "--", text)

    def key(name):
        t("send-keys", "-t", target, name)

    def command(text):
        send(text)
        key("Enter")

    def marker(name):
        # The complete marker never appears in the echoed command itself.
        command(f"printf 'CHES_%s\\n' {shlex.quote(name)}")
        wait(lambda: f"CHES_{name}" in screen(), name)

    def prefix(name):
        key("C-\\")
        key(name)

    def hide():
        prefix("C-n")
        wait(lambda: "Ctrl-\\ Ctrl-n hides" not in screen()
             and "TERMINAL_SMOKE_DOCUMENT" in screen(), "hide terminal")

    def reopen():
        send(" tt")
        wait(lambda: "Ctrl-\\ Ctrl-n hides" in screen(), "open terminal")

    def alive(pid):
        try:
            os.kill(pid, 0)
            return True
        except ProcessLookupError:
            return False

    def size(label):
        path = root / f"{label}.size"
        command(f"stty size > {shlex.quote(str(path))}; "
                f"read rows cols < {shlex.quote(str(path))}; "
                f"printf 'CHES_%s=%s,%s\\n' {label} \"$rows\" \"$cols\"")
        wait(lambda: path.exists() and len(path.read_text().split()) == 2
             and f"CHES_{label}=" in screen(), f"stty size {label}")
        result = tuple(map(int, path.read_text().split()))
        assert all(n > 0 for n in result), result
        capture(label)
        return result

    try:
        t("new-session", "-d", "-s", "terminal", "-x", "120", "-y", "40",
          "-c", str(root),
          "env LC_ALL=C.UTF-8 TERM=tmux-256color SHELL=/bin/sh ENV= PS1='OUTER> ' /bin/sh")
        t("set-option", "-t", "terminal", "status", "off")
        command(f"stty -g > before; {shlex.quote(str(binary))} --no-lsp --bare "
                "project/document.txt; result=$?; stty -g > after; "
                "printf '%s' \"$result\" > exit-code")
        wait(lambda: t("display-message", "-p", "-t", target, "#{alternate_on}").strip() == "1"
             and "TERMINAL_SMOKE_DOCUMENT" in screen(), "editor startup")
        reopen()
        command("PS1='CHILD> '; CHES_SMOKE_VALUE=persist-token; "
                "printf 'CHES_%s=%s\\n' CWD \"$PWD\"; "
                f"printf '%s' \"$$\" > {shlex.quote(str(root / 'shell.pid'))}")
        wait(lambda: f"CHES_CWD={project}" in screen() and (root / "shell.pid").exists(),
             "shell cwd and marker")
        shell_pid = int((root / "shell.pid").read_text())
        capture("startup")
        print("ok: Space tt opens a real shell in the editor file's directory")

        # Output must continue to be drained while the float is hidden, and reopening
        # must retain the same process/variables instead of starting a new shell.
        command("(sleep .4; printf 'CHES_%s\\n' BACKGROUND; "
                f": > {shlex.quote(str(root / 'background.done'))}) &")
        hide()
        wait(lambda: (root / "background.done").exists(), "hidden shell output")
        reopen()
        wait(lambda: "CHES_BACKGROUND" in screen(), "retained background output")
        command("printf 'CHES_%s=%s:%s\\n' PERSIST \"$CHES_SMOKE_VALUE\" \"$$\"")
        wait(lambda: f"CHES_PERSIST=persist-token:{shell_pid}" in screen(), "persistent shell")
        capture("persistent")
        print("ok: Ctrl-backslash Ctrl-n hides; reopen retains PID, variables and hidden output")

        command(f"{shlex.quote(sys.executable)} {shlex.quote(str(root / 'input_probe.py'))} "
                f"{shlex.quote(str(root))}")
        keys = ["Up", "Down", "Left", "Right", "Home", "End", "DC", "BSpace",
                "Tab", "BTab", "C-a", "C-_", "M-x", "F5"]
        names = ["up", "down", "left", "right", "home", "end", "delete", "backspace",
                 "tab", "shift-tab", "ctrl-a", "ctrl-underscore", "alt-x", "f5", "paste"]
        for name, input_key in zip(names, keys + [None]):
            wait(lambda name=name: f"CHES_PROBE_READY={name}" in screen(), f"input probe {name}")
            if input_key is not None:
                key(input_key)
            else:
                # Inject real outer bracket markers, not an ordinary paste of ESC
                # text. The child explicitly enabled its own bracketed-paste mode.
                send("\x1b[200~paste 中\tline\nnext\x1b[201~")
            wait(lambda name=name: (root / "input-results.json").exists()
                 and any(item["key"] == name for item in
                         json.loads((root / "input-results.json").read_text())), f"received {name}")
            results = json.loads((root / "input-results.json").read_text())
            assert results[-1]["ok"], results[-1]
        wait(lambda: "CHES_PROBE_DONE" in screen(), "input probe completion")
        capture("input")
        print("ok: arrows, Home/End, Delete/Backspace, Tab/Shift-Tab, Ctrl, Alt, F5 and UTF-8 bracketed paste")

        # Exercise canonical shell editing as well as the raw byte assertions.
        # /bin/sh need not provide readline-style arrow editing/completion.
        send("printf 'CHES_%s\\n' EDIx")
        key("BSpace")
        send("T")
        key("Enter")
        wait(lambda: "CHES_EDIT" in screen(), "backspace edits the shell command")
        send("printf")
        key("Tab")
        send("'CHES_%s\\n'")
        key("Tab")
        send("TAB_COMMAND")
        key("Enter")
        wait(lambda: "CHES_TAB_COMMAND" in screen(), "Tab reaches shell command parsing")
        print("ok: Backspace edits a real shell command; Tab reaches the shell as whitespace")

        command(f"/bin/sh {shlex.quote(str(root / 'foreground.sh'))}")
        wait(lambda: (root / "sleep.pid").exists(), "foreground sleep started")
        sleep_pid = int((root / "sleep.pid").read_text())
        assert alive(sleep_pid), "foreground sleep exited before Ctrl-C"
        time.sleep(.15)
        key("C-c")
        wait(lambda: not alive(sleep_pid), "Ctrl-C interrupts foreground sleep", timeout=4)
        marker("AFTER_INTERRUPT")
        capture("interrupt")
        print("ok: Ctrl-C terminates a foreground sleep and returns control to the child shell")

        initial = size("INITIAL")
        t("resize-window", "-t", "terminal:0", "-x", "76", "-y", "24")
        # Resize notification/PTY ioctl are asynchronous; wait for shell-observed
        # geometry to settle before checking dimensions.
        time.sleep(.3)
        smaller = size("SMALLER")
        assert smaller[0] < initial[0] and smaller[1] < initial[1], (initial, smaller)
        t("resize-window", "-t", "terminal:0", "-x", "120", "-y", "40")
        time.sleep(.3)
        restored = size("RESTORED")
        assert restored == initial, (initial, restored)
        print(f"ok: stty size tracks shrink and restore: {initial} -> {smaller} -> {restored}")

        command("printf 'CHES_%s\\n' BEFORE_EXIT; exit 7")
        wait(lambda: "Exited:" in screen() and "Ctrl-\\ Ctrl-r restarts" in screen(),
             "retained exit status")
        assert "CHES_BEFORE_EXIT" in screen(), screen()
        assert "7" in next(line for line in screen().splitlines() if "Exited:" in line), screen()
        capture("exited")
        hide()
        send(" tt")
        wait(lambda: "Exited:" in screen() and "CHES_BEFORE_EXIT" in screen(),
             "reopening retains exited snapshot")
        prefix("C-r")
        wait(lambda: "Ctrl-\\ Ctrl-n hides" in screen() and "Exited:" not in screen(),
             "explicit restart")
        command("printf 'CHES_%s=%s\\n' RESTART \"${CHES_SMOKE_VALUE-unset}\"; "
                f"printf '%s' \"$$\" > {shlex.quote(str(root / 'restart.pid'))}")
        wait(lambda: "CHES_RESTART=unset" in screen() and (root / "restart.pid").exists(),
             "fresh shell after restart")
        restart_pid = int((root / "restart.pid").read_text())
        assert restart_pid != shell_pid
        assert not alive(shell_pid), "exited child shell was not reaped"
        capture("restarted")
        print("ok: exit 7 retains output/status across hide/reopen; Ctrl-backslash Ctrl-r starts a fresh shell")

        hide()
        assert fixture.read_bytes() == original, "terminal input modified the editor file"
        # Saving also catches accidental in-memory edits that did not reach disk yet.
        send(" w")
        wait(lambda: "Wrote" in screen(), "save unchanged editor buffer")
        assert fixture.read_bytes() == original, "terminal input modified the editor buffer"
        send(" q")
        wait(lambda: (root / "after").exists() and (root / "exit-code").exists()
             and t("display-message", "-p", "-t", target, "#{alternate_on}").strip() == "0",
             "normal editor quit")
        assert (root / "exit-code").read_text() == "0"
        assert (root / "before").read_bytes() == (root / "after").read_bytes(), "outer tty modes changed"
        assert t("display-message", "-p", "-t", target, "#{cursor_flag}").strip() == "1"
        wait(lambda: not alive(restart_pid), "running shell reaped after editor quit")
        capture("quit")
        print("ok: unchanged saved editor bytes, clean quit, child reaped, outer tty modes/cursor restored")
    finally:
        subprocess.run(tmux + ["kill-server"], check=False, capture_output=True)
        shutil.rmtree(socket_dir, ignore_errors=True)
        print(f"Terminal smoke captures/results: {root}")


if __name__ == "__main__":
    main()
