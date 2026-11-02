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
    ("escape", [b"\x1b"]),
    ("ctrl-backslash", [b"\x1c"]),
    ("ctrl-n-after-backslash", [b"\x0e"]),
    ("ctrl-backslash-again", [b"\x1c"]),
    ("ctrl-r-after-backslash", [b"\x12"]),
    ("alt-x", [b"\x1bx"]),
    ("f5", [b"\x1b[15~"]),
    ("rapid-jk", [b"Q"]),
    ("standalone-j", [b"j"]),
    ("slow-jk", [b"jk"]),
    ("mismatch-jx", [b"jx"]),
    ("lone-space", [b" "]),
    ("lone-digits", [b"23"]),
    ("slow-space-slash", [b" /"]),
    ("slow-count-space", [b"2 /"]),
    ("quick-mismatch", [b"23 x"]),
    ("unicode-prefix", ["2 λ 中".encode()]),
    ("paste", [b"\x1b[200~paste jk 2 / \xe4\xb8\xad\tline\nnext\x1b[201~"]),
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
        received_at = time.monotonic()
        results.append({"key": name, "hex": data.hex(),
                        "received_at": received_at, "ok": data in expected})
        (root / "input-results.tmp").write_text(json.dumps(results, indent=2))
        (root / "input-results.tmp").replace(root / "input-results.json")
        if data not in expected:
            raise AssertionError((name, data, expected))
finally:
    os.write(1, b"\x1b[?2004l")
    termios.tcsetattr(fd, termios.TCSANOW, saved)
print("CHES_PROBE_DONE", flush=True)
'''


# Keep both readers alive across a direct switch, including the delayed-j timer.
# Files provide bounded synchronization without sending control bytes to a shell.
ISOLATION_PROBE = r'''
import os, select, sys, termios, time, tty
from pathlib import Path
root, label = Path(sys.argv[1]), sys.argv[2]
fd = sys.stdin.fileno()
saved = termios.tcgetattr(fd)
data = b""
try:
    tty.setraw(fd)
    os.write(1, b"\x1b[?2004h")
    os.write(1, ("\r\nCHES_RAW_READY=" + label + "\r\n").encode())
    (root / (label + ".ready")).touch()
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        if select.select([fd], [], [], .05)[0]:
            data += os.read(fd, 4096)
        elif (root / (label + ".stop")).exists():
            break
finally:
    os.write(1, b"\x1b[?2004l")
    termios.tcsetattr(fd, termios.TCSANOW, saved)
(root / (label + ".bytes")).write_bytes(data)
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
    (root / "isolation_probe.py").write_text(ISOLATION_PROBE)
    (root / "numbered_background.py").write_text(
        "import os, sys, time\nfrom pathlib import Path\n"
        "root = Path(sys.argv[1])\n"
        "deadline = time.monotonic() + 8\n"
        "while not (root / 'numbered-background.go').exists():\n"
        "    if time.monotonic() >= deadline: raise SystemExit(1)\n"
        "    time.sleep(.05)\n"
        "for _ in range(128): os.write(1, b'3' * 1023 + b'\\r\\n')\n"
        "os.write(1, b'CHES_BACKGROUND_THREE\\r\\n')\n"
        "(root / 'numbered-background.done').touch()\n")
    (root / "inspection.py").write_text(
        "import os, sys, time\nfrom pathlib import Path\n"
        "os.write(1, b'\\x1b[2J\\x1b[HCHES_SELECTION_ALPHA\\r\\nCHES_SELECTION_BETA\\x1b[H')\n"
        "time.sleep(1)\n"
        "os.write(1, b'\\x1b[4;1HCHES_UNFROZEN\\x1b[H')\n"
        "Path(sys.argv[1]).touch()\n"
        "sys.stdin.readline()\n")
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

    def clipboard_text():
        result = subprocess.run(tmux + ["save-buffer", "-"], capture_output=True, text=True)
        return result.stdout if result.returncode == 0 else None

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

    def command(text, paste=True):
        # Paths/commands may contain the reserved Insert chord. Real paste is
        # deliberately distinct from typing, including when shell paste mode is off.
        send("\x1b[200~" + text + "\x1b[201~"
             if paste and ("jk" in text or " /" in text) else text)
        key("Enter")

    def marker(name):
        # The complete marker never appears in the echoed command itself.
        command(f"printf 'CHES_%s\\n' {shlex.quote(name)}")
        wait(lambda: f"CHES_{name}" in screen(), name)

    def normal():
        key("C-Space")
        wait(lambda: terminal_mode("NORMAL"),
             "Ctrl-Space enters terminal Normal")

    def terminal_visible():
        return "╭─ Tile Term " in screen()

    def terminal_mode(mode):
        # Inspect the framed footer, never shell output or optional shortcut hints.
        return any("╰─ " in line and mode in line for line in screen().splitlines())

    def hide(from_insert=True):
        if from_insert:
            normal()
        send(" /")
        wait(lambda: not terminal_visible()
             and "TERMINAL_SMOKE_DOCUMENT" in screen(), "hide terminal")

    def reopen():
        send(" /")
        wait(lambda: terminal_mode("INSERT"), "open terminal Insert")

    def editor_normal():
        # Terminal hide restores the editor's original mode, including Insert.
        key("Escape")
        # --bare intentionally omits the editor mode/status line. Subsequent
        # saved-byte assertions verify the mode rather than relying on chrome.
        time.sleep(.05)

    def insert_chord(text):
        # Every gap is below 200ms, but total elapsed can exceed 200ms. This
        # distinguishes a per-key deadline from one timer for the whole chord.
        for char in text:
            send(char)
            time.sleep(.12)

    def selected(number, from_insert=True):
        if from_insert:
            normal()
        send(f"{number} /")
        wait(lambda: f"Tile Term {number}" in screen() and terminal_mode("INSERT"),
             f"select terminal {number} in Insert")

    def persistent(number, pid, value):
        command(f"printf 'CHES_%s=%s:%s:%s\\n' SESSION_{number} "
                '"$CHES_SMOKE_VALUE" "$$" "$PWD"')
        wait(lambda: f"CHES_SESSION_{number}={value}:{pid}:{project}" in screen(),
             f"terminal {number} retains its environment, PID and cwd")

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
        t("new-session", "-d", "-s", "terminal", "-x", "180", "-y", "60",
          "-c", str(root),
          "env LC_ALL=C.UTF-8 TERM=tmux-256color SHELL=/bin/sh ENV= PS1='OUTER> ' /bin/sh")
        t("set-option", "-t", "terminal", "status", "off")
        # tmux stores OSC 52 writes in its paste buffer even without an attached
        # client, giving us an observable frontend clipboard destination.
        t("set-option", "-s", "set-clipboard", "on")
        command(f"stty -g > before; {shlex.quote(str(binary))} --no-lsp --bare "
                "project/document.txt; result=$?; stty -g > after; "
                "printf '%s' \"$result\" > exit-code", paste=False)
        wait(lambda: t("display-message", "-p", "-t", target, "#{alternate_on}").strip() == "1"
              and "TERMINAL_SMOKE_DOCUMENT" in screen(), "editor startup")

        # No terminal process/output or animation can wake the idle editor here.
        # Inspect the actual rendered buffer before sending the next input.
        send("ggi")
        send(" ")
        time.sleep(.35)
        assert any(line.startswith(" TERMINAL_SMOKE_DOCUMENT") for line in screen().splitlines()), \
            "idle editor space did not flush without another key"
        send("23")
        time.sleep(.35)
        send(" ")
        time.sleep(.35)
        send("/")
        send("23 x")
        send("2 λ 中")
        send("\x1b[200~2 / jk\x1b[201~")
        time.sleep(.35)
        editor_normal()
        send(" w")
        expected_insert = " 23 /23 x2 λ 中2 / jk".encode() + original
        wait(lambda: fixture.read_bytes() == expected_insert,
             "editor exact timeout/mismatch/Unicode/paste literal bytes")
        send("u w")
        wait(lambda: fixture.read_bytes() == original, "undo editor Insert probes")

        send("ggi")
        insert_chord(" /")
        wait(lambda: terminal_mode("INSERT"),
             "editor Insert Space / opens terminal")
        assert "Tile Term 1" in screen(), "uncounted first open must select terminal 1"
        command("PS1='CHILD> '; CHES_SMOKE_VALUE=persist-token; "
                "printf 'CHES_%s=%s\\n' CWD \"$PWD\"; "
                f"printf '%s' \"$$\" > {shlex.quote(str(root / 'shell.pid'))}")
        wait(lambda: f"CHES_CWD={project}" in screen() and (root / "shell.pid").exists(),
             "shell cwd and marker")
        shell_pid = int((root / "shell.pid").read_text())
        capture("startup")
        print("ok: Space / opens a real shell in Insert in the editor file's directory")

        # Hide directly in terminal Insert and verify the original editor Insert
        # cursor/mode survived. Successful prefixes must not touch the document.
        insert_chord(" /")
        wait(lambda: not terminal_visible() and "TERMINAL_SMOKE_DOCUMENT" in screen(),
             "terminal Insert hide restores editor Insert")
        send("MODE_SENTINEL")
        editor_normal()
        send(" w")
        wait(lambda: fixture.read_bytes() == b"MODE_SENTINEL" + original,
             "Insert restored with no leaked successful leader")
        send("u w")
        wait(lambda: fixture.read_bytes() == original, "undo mode sentinel")
        send("ggi")
        insert_chord("3 /")
        wait(lambda: "Tile Term 3" in screen() and terminal_mode("INSERT"),
             "counted editor Insert opens terminal 3")
        insert_chord("1 /")
        wait(lambda: "Tile Term 1" in screen() and terminal_mode("INSERT"),
             "counted terminal Insert switches directly to terminal 1")
        insert_chord(" /")
        wait(lambda: not terminal_visible() and "TERMINAL_SMOKE_DOCUMENT" in screen(),
             "counted open retains original editor Insert")
        editor_normal()
        send(" w")
        wait(lambda: fixture.read_bytes() == original, "counted leaders leave editor unchanged")
        send("v1")
        time.sleep(.3)
        send(" ")
        time.sleep(.3)
        send("/")
        wait(lambda: "Tile Term 1" in screen() and terminal_mode("INSERT"),
             "Visual counted leader remains untimed")
        hide()
        editor_normal()
        send(" ")
        time.sleep(.3)
        send("/")
        wait(lambda: "Tile Term 1" in screen() and terminal_mode("INSERT"),
             "Normal leader remains untimed")
        marker("NO_LEAK_AFTER_INSERT_TOGGLES")
        def assert_quiet_footer(mode):
            footer = next(line for line in screen().splitlines() if "╰─ " in line and mode in line)
            assert not any(hint in footer for hint in
                           ("Ctrl-Space", "Space /", "restart", "i/a:", "y/yy:", "+/-:")), footer

        assert_quiet_footer("INSERT")
        normal()
        assert_quiet_footer("NORMAL")
        hide(from_insert=False)
        editor_normal()
        send(" v?")
        reopen()
        wait(lambda: "Ctrl-Space" in screen(), "global hints shown in terminal Insert")
        normal()
        wait(lambda: "Space /: hide" in screen(), "global hints shown in terminal Normal")
        capture("hints-enabled")
        hide(from_insert=False)
        send(" v?")
        reopen()
        assert_quiet_footer("INSERT")
        capture("hints-disabled")
        hide()
        send(" ccToggle Tile Term")
        wait(lambda: "> Toggle Tile Term" in screen(), "renamed terminal palette toggle")
        key("Enter")
        wait(lambda: terminal_mode("INSERT"), "palette toggle opens Tile Term")
        assert_quiet_footer("INSERT")
        print("ok: Tile Term title/palette toggle; quiet mode footer by default; global Space v ? enables Insert/Normal hints and toggles back to quiet")
        print("ok: editor Insert timeout/mismatch/Unicode/paste bytes; plain/count Insert toggles consume leaders and restore original Insert; explicit Escape resumes editor controls")

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
        print("ok: Ctrl-Space enters Normal, Space / hides; reopen retains PID, variables and hidden output")

        command(f"{shlex.quote(sys.executable)} {shlex.quote(str(root / 'input_probe.py'))} "
                f"{shlex.quote(str(root))}")
        keys = ["Up", "Down", "Left", "Right", "Home", "End", "DC", "BSpace",
                 "Tab", "BTab", "C-a", "C-_", "Escape", "C-\\", "C-n", "C-\\", "C-r", "M-x", "F5"]
        names = ["up", "down", "left", "right", "home", "end", "delete", "backspace",
                  "tab", "shift-tab", "ctrl-a", "ctrl-underscore", "escape", "ctrl-backslash",
                  "ctrl-n-after-backslash", "ctrl-backslash-again", "ctrl-r-after-backslash",
                  "alt-x", "f5", "rapid-jk", "standalone-j", "slow-jk", "mismatch-jx",
                  "lone-space", "lone-digits", "slow-space-slash", "slow-count-space",
                  "quick-mismatch", "unicode-prefix", "paste"]
        for name, input_key in zip(names, keys + [None] * (len(names) - len(keys))):
            wait(lambda name=name: f"CHES_PROBE_READY={name}" in screen(), f"input probe {name}")
            if input_key is not None:
                key(input_key)
            elif name == "rapid-jk":
                send("jk")
                wait(lambda: terminal_mode("NORMAL"),
                     "rapid jk enters Normal")
                send("i")
                wait(lambda: terminal_mode("INSERT"),
                     "resume after rapid jk")
                send("Q")
            elif name == "standalone-j":
                sent_at = time.monotonic()
                send("j")
            elif name == "slow-jk":
                send("j")
                time.sleep(.3)
                send("k")
            elif name == "mismatch-jx":
                send("jx")
            elif name in ("lone-space", "lone-digits"):
                sent_at = time.monotonic()
                send(" " if name == "lone-space" else "23")
            elif name == "slow-space-slash":
                send(" ")
                time.sleep(.35)
                send("/")
            elif name == "slow-count-space":
                send("2")
                time.sleep(.35)
                send(" ")
                time.sleep(.35)
                send("/")
            elif name == "quick-mismatch":
                send("23 x")
            elif name == "unicode-prefix":
                send("2 λ 中")
            else:
                # Inject real outer bracket markers, not an ordinary paste of ESC
                # text. The child explicitly enabled its own bracketed-paste mode.
                send("\x1b[200~paste jk 2 / 中\tline\nnext\x1b[201~")
            wait(lambda name=name: (root / "input-results.json").exists()
                 and any(item["key"] == name for item in
                         json.loads((root / "input-results.json").read_text())), f"received {name}")
            results = json.loads((root / "input-results.json").read_text())
            assert results[-1]["ok"], results[-1]
            if name == "standalone-j":
                elapsed = results[-1]["received_at"] - sent_at
                assert .12 <= elapsed < 1., ("standalone j timeout", elapsed)
            elif name in ("lone-space", "lone-digits"):
                elapsed = results[-1]["received_at"] - sent_at
                assert .16 <= elapsed < 1., (name, "200ms idle flush", elapsed)
        wait(lambda: "CHES_PROBE_DONE" in screen(), "input probe completion")
        capture("input")
        print("ok: arrows, Home/End, Delete/Backspace, Tab/Shift-Tab, Ctrl, Alt, F5 and UTF-8 bracketed paste; Escape and Ctrl-backslash sequences reach child raw")
        print("ok: rapid jk is consumed and enters Normal; idle j flushes after 150ms; slow jk, mismatch jx and pasted jk reach child in order")
        print("ok: terminal raw bytes: idle space/digits flush at 200ms without output/animation; slow leaders, quick mismatch and Unicode preserve order; pasted literal 2 / bypasses shortcuts")

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

        # Paint a deterministic current screen, then produce more output while
        # inspecting it. The PTY must keep draining without changing the inspected
        # frame; returning to Insert must reveal the newest screen.
        inspection_cols = size("INSPECTION")[1]
        inspection_done = root / "inspection.done"
        command(f"{shlex.quote(sys.executable)} {shlex.quote(str(root / 'inspection.py'))} "
                f"{shlex.quote(str(inspection_done))}")
        wait(lambda: any(line.strip().startswith("│CHES_SELECTION_ALPHA")
                         or "CHES_SELECTION_ALPHA" in line and "printf" not in line
                         for line in screen().splitlines()), "selection fixture")
        normal()
        frozen = screen()
        wait(inspection_done.exists, "output produced during inspection")
        time.sleep(.2)
        assert "CHES_UNFROZEN" not in screen(), "inspection did not freeze terminal output"
        assert screen() == frozen, "inspected frame changed while output arrived"
        capture("frozen")

        def yank_into_editor(selection, expected, clipboard, label, block=False):
            send("gg0")
            if block:
                key("C-v")
                send(selection)
            else:
                send(selection)
            send("y")
            wait(lambda: clipboard_text() == clipboard, f"{label} OSC 52 clipboard")
            hide(from_insert=False)
            editor_normal()
            send("ggP w")
            wait(lambda: fixture.read_bytes() == expected, f"{label} pasted and saved")
            assert fixture.read_bytes() == expected, (label, fixture.read_bytes(), expected)
            capture(label)
            send("u w")
            wait(lambda: fixture.read_bytes() == original, f"undo {label} paste")
            reopen()
            normal()

        yank_into_editor("vlll", b"CHES" + original, "CHES", "character-yank")
        # A terminal line is the entire current-screen row, including blank cells.
        selected_line = b"CHES_SELECTION_ALPHA".ljust(inspection_cols) + b"\n"
        yank_into_editor("V", selected_line + original, selected_line.decode(), "line-yank")
        yank_into_editor("y", selected_line + original, selected_line.decode(), "yy-yank")
        yank_into_editor("lj", b"CHTERMINAL_SMOKE_DOCUMENT\nCHunchanged editor contents\n",
                         "CH\nCH", "block-yank", block=True)
        send("a")
        wait(lambda: "INSERT" in screen() and "CHES_UNFROZEN" in screen(),
             "a resumes Insert with latest output")
        normal()
        send("i")
        wait(lambda: terminal_mode("INSERT"), "i resumes Insert")
        key("Enter")
        marker("AFTER_INSPECTION")
        print("ok: inspection freezes while PTY drains; v/V/Ctrl-v movement+y and yy copy exact character/line/block text to editor register and OSC 52 clipboard; i/a resume Insert")

        initial = size("INITIAL")
        assert initial == (38, 128), ("default content size", initial)

        def delta(value, count):
            return value[0] + 2 * count, value[1] + 10 * count

        def adjust(keys, label, expected):
            normal()
            send(keys)
            send("i")
            wait(lambda: terminal_mode("INSERT"), label)
            actual = size(label)
            assert actual == expected, (label, actual, expected)

        adjust("+", "GROW", delta(initial, 1))
        adjust("2+", "COUNT_GROW", delta(initial, 3))
        adjust("3-", "COUNT_SHRINK", initial)
        adjust("-", "SHRINK", delta(initial, -1))
        adjust(" tr", "RESET", initial)
        adjust("2+", "PREFERRED", delta(initial, 2))
        hide()
        reopen()
        assert size("REOPEN_SIZE") == delta(initial, 2)

        def viewport(width, height, label):
            t("resize-window", "-t", "terminal:0", "-x", str(width), "-y", str(height))
            # PTY ioctl and child processing follow the asynchronous resize event.
            time.sleep(.3)
            return size(label)

        narrow = viewport(76, 60, "WIDTH_CLAMP")
        assert narrow == (42, 70), ("width-clamped content size", narrow)
        short = viewport(180, 24, "HEIGHT_CLAMP")
        assert short == (20, 148), ("height-clamped content size", short)
        smaller = viewport(76, 24, "BOTH_CLAMP")
        assert smaller == (20, 70), ("both-clamped content size", smaller)
        restored = viewport(180, 60, "RESTORED")
        assert restored == delta(initial, 2), (initial, restored)

        def editor_adjust(keys, label, expected):
            hide()
            editor_normal()
            send(keys)
            reopen()
            actual = size(label)
            assert actual == expected, (label, actual, expected)

        editor_adjust(" t+", "EDITOR_GROW", delta(initial, 3))
        editor_adjust(" t-", "EDITOR_SHRINK", delta(initial, 2))
        editor_adjust(" tr", "EDITOR_RESET", initial)

        def palette_adjust(title, label, expected):
            hide()
            editor_normal()
            send(" cc")
            send(title)
            wait(lambda: title in screen(), f"palette {title}")
            key("Enter")
            reopen()
            actual = size(label)
            assert actual == expected, (label, actual, expected)

        palette_adjust("Grow Tile Term", "PALETTE_GROW", delta(initial, 1))
        palette_adjust("Shrink Tile Term", "PALETTE_SHRINK", initial)
        editor_adjust(" t+", "BEFORE_PALETTE_RESET", delta(initial, 1))
        palette_adjust("Reset Tile Term size", "PALETTE_RESET", initial)
        print(f"ok: live stty sizing {initial}; +/- steps (2 rows, 10 cols), counts, reset, hidden preference, independent viewport clamps, editor Space t +/-/r and palette size commands")

        # Start nonconsecutive IDs lazily, directly from terminal Normal. Each
        # shell must start fresh rather than inheriting another shell's variables.
        numbered_pids = {}
        for number in (3, 4):
            selected(number)
            command(f"printf 'CHES_%s=%s\\n' FRESH_{number} "
                    '"${CHES_SMOKE_VALUE-unset}"; '
                    f"CHES_SMOKE_VALUE=token-{number}; "
                    f"printf '%s' \"$$\" > {shlex.quote(str(root / f'shell-{number}.pid'))}")
            path = root / f"shell-{number}.pid"
            wait(lambda: path.exists() and f"CHES_FRESH_{number}=unset" in screen(),
                 f"fresh shell {number}")
            numbered_pids[number] = int(path.read_text())
            persistent(number, numbered_pids[number], f"token-{number}")
            # 132x40 is the preferred float size; stty reports its content area.
            assert size(f"INITIAL_{number}") == initial, "new terminal preferred size"
        assert len({shell_pid, *numbered_pids.values()}) == 3, "sessions shared a shell PID"

        # Same visible numbered ID hides; uncounted toggle must remember that ID.
        normal()
        send("4 /")
        wait(lambda: not terminal_visible() and "TERMINAL_SMOKE_DOCUMENT" in screen(),
             "same visible ID hides")
        reopen()
        assert "Tile Term 4" in screen(), "uncounted toggle forgot selected terminal 4"
        persistent(4, numbered_pids[4], "token-4")
        selected(3)
        persistent(3, numbered_pids[3], "token-3")
        adjust("2+", "THREE_GROW", delta(initial, 2))
        command(f"{shlex.quote(sys.executable)} "
                f"{shlex.quote(str(root / 'numbered_background.py'))} {shlex.quote(str(root))} &")
        selected(4)
        (root / "numbered-background.go").touch()
        wait(lambda: (root / "numbered-background.done").exists(),
             "terminal 3 drains more than a PTY buffer while terminal 4 is active")
        assert "Tile Term 4" in screen() and "CHES_BACKGROUND_THREE" not in screen(), screen()
        assert size("FOUR_UNCHANGED") == initial
        marker("ONLY_FOUR")
        selected(3)
        wait(lambda: "CHES_BACKGROUND_THREE" in screen(), "terminal 3 retained background output")
        assert "CHES_ONLY_FOUR" not in screen(), "terminal 4 output leaked into terminal 3"
        assert size("THREE_REOPEN") == delta(initial, 2)
        persistent(3, numbered_pids[3], "token-3")
        print("ok: numbered 3/4 have independent PID/env/cwd/output and default 132x40 sizes; direct switches, same-ID hide, latest-ID toggle, per-session sizing and background PTY draining")

        # Compare actual child bytes, not screen echo. Deferred prefixes belong
        # to the originating owner across mode changes and direct switches.
        def isolation_start(number):
            label = f"isolation-{number}"
            command(f"{shlex.quote(sys.executable)} "
                    f"{shlex.quote(str(root / 'isolation_probe.py'))} "
                    f"{shlex.quote(str(root))} {label}")
            wait(lambda: (root / f"{label}.ready").exists()
                 and f"CHES_RAW_READY={label}" in screen(), f"raw reader {number}")
            return label

        label3 = isolation_start(3)
        paste3 = "three jk 2 / 中\tbytes"
        send("\x1b[200~" + paste3 + "\x1b[201~")
        send("j")
        selected(4)
        label4 = isolation_start(4)
        paste4 = "four jk 2 / λ\tbytes"
        send("\x1b[200~" + paste4 + "\x1b[201~")
        send("4 ")
        selected(3)
        send("23")
        selected(4)
        # Successful direct Insert switches and hide/reopen must contribute zero
        # bytes to either reader, even with bracketed-paste enabled in both.
        insert_chord("3 /")
        wait(lambda: "Tile Term 3" in screen(), "raw Insert switch to 3")
        insert_chord(" /")
        wait(lambda: not terminal_visible(), "raw Insert hide")
        reopen()
        assert "Tile Term 3" in screen(), "Insert hide forgot last selected shell"
        insert_chord("4 /")
        wait(lambda: "Tile Term 4" in screen(), "raw Insert switch to 4")
        insert_chord("4 /")
        wait(lambda: not terminal_visible(), "same-ID counted Insert hide")
        reopen()
        assert "Tile Term 4" in screen(), "counted Insert hide forgot last selected shell"
        time.sleep(.3)
        for label, expected in ((label3, ("\x1b[200~" + paste3 + "\x1b[201~j23").encode()),
                                (label4, ("\x1b[200~" + paste4 + "\x1b[201~4 ").encode())):
            (root / f"{label}.stop").touch()
            path = root / f"{label}.bytes"
            wait(path.exists, f"finish {label}")
            assert path.read_bytes() == expected, (label, path.read_bytes(), expected)
        marker("FOUR_AFTER_ISOLATION")
        selected(1)
        persistent(1, shell_pid, "persist-token")
        assert size("ONE_UNCHANGED") == initial
        print("ok: exact per-session raw bytes preserve pasted jk/2 / /Unicode, route deferred j/digits/space to their original shells and consume Insert toggles without leaks; terminal 1 retains PID/env/size")

        command("printf 'CHES_%s\\n' BEFORE_EXIT; exit 7")
        wait(lambda: "Exited:" in screen() and terminal_mode("NORMAL"),
             "retained exit status")
        assert "CHES_BEFORE_EXIT" in screen(), screen()
        assert "7" in next(line for line in screen().splitlines() if "Exited:" in line), screen()
        assert_quiet_footer("NORMAL")
        capture("exited")
        hide()
        editor_normal()
        send(" /")
        wait(lambda: "Exited:" in screen() and "CHES_BEFORE_EXIT" in screen(),
             "reopening retains exited snapshot")
        normal()
        send("r")
        wait(lambda: terminal_mode("INSERT") and "Exited:" not in screen(),
             "explicit restart")
        command("printf 'CHES_%s=%s\\n' RESTART \"${CHES_SMOKE_VALUE-unset}\"; "
                f"printf '%s' \"$$\" > {shlex.quote(str(root / 'restart.pid'))}")
        wait(lambda: "CHES_RESTART=unset" in screen() and (root / "restart.pid").exists(),
             "fresh shell after restart")
        restart_pid = int((root / "restart.pid").read_text())
        assert restart_pid != shell_pid
        assert not alive(shell_pid), "exited child shell was not reaped"
        capture("restarted")
        print("ok: exit 7 retains output/status across hide/reopen; Normal r starts a fresh shell")

        for number in (3, 4):
            assert alive(numbered_pids[number]), f"restart of 1 killed terminal {number}"
            selected(number)
            persistent(number, numbered_pids[number], f"token-{number}")
            assert size(f"AFTER_RESTART_{number}") == (delta(initial, 2) if number == 3 else initial)
        print("ok: exiting/restarting terminal 1 leaves terminals 3/4 running with their original PIDs, variables and sizes")

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
        wait(lambda: all(not alive(pid) for pid in numbered_pids.values()),
             "all numbered shell PIDs reaped after editor quit")
        capture("quit")
        print("ok: unchanged saved editor bytes, clean quit, ALL numbered shells reaped, outer tty modes/cursor restored")
    finally:
        subprocess.run(tmux + ["kill-server"], check=False, capture_output=True)
        shutil.rmtree(socket_dir, ignore_errors=True)
        print(f"Terminal smoke captures/results: {root}")


if __name__ == "__main__":
    main()
