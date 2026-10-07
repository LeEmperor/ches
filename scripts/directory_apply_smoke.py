#!/usr/bin/env python3
"""Phase-7 terminal save/reassociation checks in an isolated /tmp/opencode fixture."""
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
    root = Path(tempfile.mkdtemp(prefix="directory-phase7-pty-", dir="/tmp/opencode"))
    (root / "a.txt").write_text("original\n")
    (root / "dir").mkdir()
    (root / "dir/nested.ml").write_text("let x = 1\n")
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
        send(b" vt vb")
        send(b"\riEDIT\x1b oA.renamed\x1bofresh\rnewdir/\x1b")
        assert (root / "a.txt").read_text() == "original\n"
        assert not (root / "a.txt.renamed").exists()
        assert not (root / "fresh").exists()
        send(b" w")
        assert b"Rename a.txt -> a.txt.renamed" in capture
        assert not (root / "a.txt").exists()
        assert (root / "a.txt.renamed").read_text() == "original\n"
        assert (root / "fresh").read_text() == ""
        assert (root / "newdir").is_dir()
        send(b"u o w")
        assert (root / "a.txt.renamed").read_text() == "EDIToriginal\n"
        assert not (root / "a.txt").exists()  # Text undo did not undo filesystem apply.
        send(b" oj\r\riNESTED\x1b o-")
        send(b"$i.moved\x1b")
        assert (root / "dir/nested.ml").read_text() == "let x = 1\n"
        send(b" w")
        assert not (root / "dir").exists()
        assert (root / "dir.moved/nested.ml").read_text() == "let x = 1\n"
        send(b" o w")
        assert (root / "dir.moved/nested.ml").read_text() == "NESTEDlet x = 1\n"
        send(b" o-gg0i@\x1b w")  # Noncanonical name: protected IDs cannot be edited.
        assert b"Invalid directory plan" in capture
        assert sorted(p.name for p in root.iterdir()) == ["a.txt.renamed", "dir.moved", "fresh", "newdir"]
        send(b"u q")
        assert proc.wait(timeout=5) == 0
        assert not any(root.rglob(".ches-stage-*"))
        print("PASS: explicit rename/create saves, dirty file and descendant reassociation,")
        print("      fresh undo boundary, invalid-plan zero mutation, clean quit (0)")
        print("Fixture:", root)
    finally:
        Path("/tmp/opencode/directory-phase7-pty.log").write_bytes(capture)
        if proc.poll() is None:
            proc.terminate()
            proc.wait(timeout=5)
        os.close(master)


if __name__ == "__main__":
    main()
