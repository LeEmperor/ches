#!/usr/bin/env python3
"""Pending directory edits, backing paths and undo/save boundaries in an isolated PTY."""
import fcntl
import os
import pty
import select
import struct
import subprocess
import tempfile
import termios
import time
from pathlib import Path


def main():
    executable = Path(__file__).resolve().parents[1] / "_build/default/bin/ches.exe"
    root = Path(tempfile.mkdtemp(prefix="directory-phase6-pty-", dir="/tmp/opencode"))
    (root / "a.txt").write_text("original\n")
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 120, 0, 0))
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
        os.write(master, keys)
        pump()

    try:
        pump(1)
        send(b" vt vb")  # Leave history wide enough for actionable feedback.
        send(b" mmA.renamed\x1b")
        assert b"1 pending" in capture
        assert not (root / "a.txt.renamed").exists()
        send(b" r")
        assert b"unsaved edits" in capture
        send(b"\r")  # Pending rename opens its backing file, not a new destination.
        send(b"iEDIT\x1b w")
        assert (root / "a.txt").read_text() == "EDIToriginal\n"
        send(b" q")
        assert proc.poll() is None
        assert b"Unsaved changes:" in capture
        send(b" ouofresh/\x1b")
        send(b"\r")
        assert b"requires save" in capture
        assert not (root / "fresh").exists()
        send(b" w")
        assert b"Create directory fresh/" in capture
        assert (root / "fresh").is_dir()
        send(b"u q")  # Text undo cannot undo the committed directory creation.
        assert proc.wait(timeout=5) == 0
        assert sorted(p.name for p in root.iterdir()) == ["a.txt", "fresh"]
        print("PASS: pending edits/undo, dirty refresh refusal, backing-path open,")
        print("      hidden dirty quit guard, fresh-row refusal, apply/undo boundary")
        print("Fixture:", root)
    finally:
        Path("/tmp/opencode/directory-phase6-pty.log").write_bytes(capture)
        if proc.poll() is None:
            proc.terminate()
            proc.wait(timeout=5)
        os.close(master)


if __name__ == "__main__":
    main()
