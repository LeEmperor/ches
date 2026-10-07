#!/usr/bin/env python3
"""PTY smoke for directory phase 5; edits only an isolated /tmp/opencode fixture."""
import fcntl
import os
import pty
import select
import signal
import struct
import subprocess
import tempfile
import termios
import time
from pathlib import Path


def main():
    executable = Path(__file__).resolve().parents[1] / "_build/default/bin/ches.exe"
    root = Path(tempfile.mkdtemp(prefix="directory-phase5-pty-", dir="/tmp/opencode"))
    for name in ("a.txt", "b.txt", "c.txt"):
        (root / name).write_text(name + "\n")
    (root / "bad.txt").write_bytes(b"\0")
    (root / "child").mkdir()
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 100, 0, 0))
    proc = subprocess.Popen([str(executable), "--no-lsp", "."], cwd=root,
                            env=dict(os.environ, TERM="xterm-256color"),
                            stdin=slave, stdout=slave, stderr=slave)
    os.close(slave)
    capture = bytearray()

    def pump(seconds=0.4):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            if select.select([master], [], [], 0.05)[0]:
                try:
                    capture.extend(os.read(master, 65536))
                except OSError:
                    break

    def send(keys):
        start = len(capture)
        os.write(master, keys)
        pump()
        return bytes(capture[start:])

    def resize(columns, rows):
        fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))
        proc.send_signal(signal.SIGWINCH)
        pump()

    try:
        pump(1)
        assert b"Directory" in capture
        send(b" ds\r")  # Side requested before any files; first open creates editor.
        send(b"iX\x1b w")
        assert (root / "a.txt").read_text() == "Xa.txt\n"
        send(b" df mmVj\r")  # Same adapter: mark a, Visual-open a and b.
        send(b"iY\x1b w")  # First successful target remains a, not b.
        assert (root / "a.txt").read_text() == "YXa.txt\n"
        send(b" df dm ds")  # Move the marked browser to major and back.
        assert b"1 marked" in capture
        send(b" dh ds mo")  # Hide/restore mark, open clears it, focus file.
        send(b" vt vb")  # Wider history feedback: hide status and problems.
        send(b" dfggV4j ms\x1b mo")
        assert b"bad.txt: Cannot open" in capture
        assert b"Batch skipped: child" in capture
        send(b" df")
        assert b"2 marked" in capture  # Failed/skipped marks survive in side buffer.
        send(b" d+ d+ vz")
        send(b"iZ\x1b w")  # Zen suppresses browser and returns input to editor.
        assert (root / "a.txt").read_text() == "ZYXa.txt\n"
        send(b" vz df")
        resize(8, 2)  # Hidden directory must not retain input on tiny resize.
        send(b"iT\x1b w")
        assert (root / "a.txt").read_text() == "TZYXa.txt\n"
        resize(100, 24)
        send(b" dfgg4j\r")  # Directory Enter navigates rather than opening a tab.
        send(b"- o")  # Parent + return target; side remains requested.
        send(b" cchide directory browser\r")  # Discoverable placement command.
        send(b" ds\t")  # Restore then explicit focus return.
        send(b" bniB\x1b bp bn")  # Tab switch preserves an independent dirty edit.
        send(b"u bc bc bc")  # Undo B, close b/c/a, return to zero-file directory.
        send(b" q")
        assert proc.wait(timeout=5) == 0
        assert (root / "b.txt").read_text() == "b.txt\n"
        assert (root / "c.txt").read_text() == "c.txt\n"
        assert (root / "bad.txt").read_bytes() == b"\0"
        print("PASS: side/major/hide, visual+marked opens, editor focus/save, partial failures,")
        print("      zen/tiny focus return, tabs/undo/last-close fallback, clean quit")
        print("Fixture:", root)
    finally:
        Path("/tmp/opencode/directory-phase5-pty.log").write_bytes(capture)
        if proc.poll() is None:
            proc.terminate()
            proc.wait(timeout=5)
        os.close(master)


if __name__ == "__main__":
    main()
