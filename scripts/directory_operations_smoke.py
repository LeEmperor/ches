#!/usr/bin/env python3
"""Phase-8 terminal copy/delete/recover/move checks, isolated fixture only."""
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
    root = Path(tempfile.mkdtemp(prefix="directory-phase8-pty-", dir="/tmp/opencode"))
    (root / "a").write_text("original\n")
    (root / "zdir").mkdir()
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
        send(b" vt vb\riEDIT\x1b o")
        send(b"ggyypVc@copy copy\x1b")  # Protected copied row; no ID needs exposing.
        assert not (root / "copy").exists()
        send(b" w")
        assert (root / "copy").read_text() == "original\n"  # Backing text, not dirty tab.
        send(b"ggdd w")
        assert not (root / "a").exists()
        send(b" o w")
        assert not (root / "a").exists()
        assert b"Missing backing file" in capture and b"[missing]" in capture
        send(b" ccrecreate missing\r")
        assert (root / "a").read_text() == "EDIToriginal\n"
        send(b" ogg$i./zdir/\x1b")
        assert (root / "a").exists() and not (root / "zdir/a").exists()
        send(b" w")
        assert not (root / "a").exists()
        assert (root / "zdir/a").read_text() == "EDIToriginal\n"
        send(b" ogg0iNEXT\x1b w")
        assert (root / "zdir/a").read_text() == "NEXTEDIToriginal\n"
        assert (root / "copy").read_text() == "original\n"
        send(b" q")
        assert proc.wait(timeout=5) == 0
        assert not list(root.rglob(".ches-*"))
        print("PASS: explicit copy/delete, missing-save refusal, palette recovery, cross-directory move and next-save")
        print("Fixture:", root)
    finally:
        Path("/tmp/opencode/directory-phase8-pty.log").write_bytes(capture)
        if proc.poll() is None:
            proc.terminate()
            proc.wait(timeout=5)
        os.close(master)


if __name__ == "__main__":
    main()
