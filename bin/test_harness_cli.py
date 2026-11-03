"""Stdlib PTY vertical slice. Optional second argument uses a real qh/toolchain.

    python3 bin/test_harness_cli.py _build/default/bin/ches.exe /path/to/qh

The default fixture exercises argv paths, failed runs and an x/z waveform without
requiring HDL tools. The real mode creates/runs all three installed starters.
"""
import errno
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import struct
import subprocess
import sys
import tempfile
import termios
import time


FIXTURE = r'''#!/usr/bin/env python3
import json, pathlib, sys
args = sys.argv[1:]
assert args[-2:] == ['--format', 'json'], args
if args[0] == 'new':
    language, root = args[1], pathlib.Path(args[2])
    root.mkdir()
    entry = 'counter.sv' if language == 'sv' else 'design.ml'
    (root / entry).write_text('STARTER_' + language + '\n')
    (root / 'quick-harness.json').write_text('{}')
    print(json.dumps(dict(root=str(root), entry_file=entry, actions=['run'], language=language)))
else:
    root = pathlib.Path(args[args.index('--project') + 1])
    latest = root / '.quick-harness/latest.json'
    if args[0] == 'run':
        assert args[args.index('--jobs') + 1] == '6', args
        latest.parent.mkdir(exist_ok=True)
        log = latest.parent / 'run.log'
        log.write_text('HARNESS_LOG_CONTENT\n')
        vcd = latest.parent / 'wave.vcd'
        vcd.write_text('$timescale 1 ns $end\n$scope module demo $end\n'
            '$var wire 1 ! clock $end\n$var wire 4 # data $end\n'
            '$upscope $end\n$enddefinitions $end\n'
            '$dumpvars\n0!\nbx #\n$end\n#5\n1!\nb10xz #\n#10\n0!\nbz #\n#30\n')
        # A failed simulation may still produce a valid waveform; keep its status.
        result = dict(run_id='PTY-CURRENT-RUN', status='failed', exit_code=3,
            project_root=str(root), log_path=str(log),
            artifacts=[dict(kind='waveform', path=str(vcd))])
        latest.write_text(json.dumps(result))
    else:
        result = json.loads(latest.read_text())
    print(json.dumps(result))
    sys.exit(result['exit_code'] if args[0] == 'run' else 0)
'''


def main():
    binary = str(Path(sys.argv[1]).resolve())
    real_qh = str(Path(sys.argv[2]).resolve()) if len(sys.argv) > 2 else None
    with tempfile.TemporaryDirectory(prefix="ches-harness-pty-") as temp:
        root = Path(temp)
        scratch = root / "scratch root ;$"
        document = root / "original.txt"
        document.write_text("ORIGINAL_PTY_BUFFER\n")
        qh = root / "qh fixture"
        if not real_qh:
            qh.write_text(FIXTURE)
            qh.chmod(0o700)
        env = dict(os.environ, QH_BIN=real_qh or str(qh), QH_SCRATCH_ROOT=str(scratch),
                   XDG_CONFIG_HOME=str(root / "config"), TERM="xterm-256color",
                   COLORTERM="truecolor", LC_ALL="C.UTF-8")
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 32, 160, 0, 0))
        process = subprocess.Popen([binary, "--no-lsp", "--workspace", str(document)],
                                   stdin=slave, stdout=slave, stderr=slave, env=env)
        os.close(slave)
        output = bytearray()

        def wait(predicate, timeout=30):
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                readable, _, _ = select.select([master], [], [], 0.03)
                if readable:
                    try:
                        chunk = os.read(master, 65536)
                    except OSError as exc:
                        if exc.errno != errno.EIO:
                            raise
                        chunk = b""
                    output.extend(chunk)
                if predicate():
                    return
                if process.poll() is not None:
                    break
            raise AssertionError(bytes(output[:24000]).decode(errors="replace"))

        def send(text):
            os.write(master, text.encode())

        def palette(title):
            output.clear()
            send(" ccQuick-Harness: " + title + "\r")

        def waveform():
            wait(lambda: b"Quick-Harness waveform" in output, timeout=120)
            assert b"run " in output, bytes(output)
            assert b"/tick)" in output, bytes(output)

        try:
            wait(lambda: b"ORIGINAL_PTY_BUFFER" in output)
            send("iUNSAVED_\x1b")
            wait(lambda: b"UNSAVED_" in output)
            projects = []
            for language, title in [("sv", "SV"), ("hardcaml", "Hardcaml"), ("ocaml", "OCaml")]:
                previous = set(scratch.glob("*/project"))
                palette("New " + title + " scratch")
                wait(lambda: bool(set(scratch.glob("*/project")) - previous))
                project = (set(scratch.glob("*/project")) - previous).pop()
                projects.append(project)
                entry = project / ("counter.sv" if language == "sv" else "design.ml")
                # Let the async new response finish opening the entry buffer.
                wait(lambda: entry.name.encode() in output)
                if language == "sv":
                    # A dirty file in this project must not run an older disk copy.
                    send("iDIRTY_\x1b")
                    wait(lambda: b"DIRTY_" in output)
                    palette("Run harness")
                    wait(lambda: b"Save modified project" in output)
                    assert not (project / ".quick-harness/latest.json").exists()
                    # Undo just the test edit; leave the real starter valid.
                    send("u")
                palette("Run harness")
                latest = project / ".quick-harness/latest.json"
                wait(latest.exists, timeout=120)
                result = json.loads(latest.read_text())
                assert result["project_root"] == str(project)
                if real_qh:
                    assert result["status"] == "success", Path(result["log_path"]).read_text()
                else:
                    assert result["status"] == "failed" and result["exit_code"] == 3
                if result["artifacts"]:
                    waveform()
                    assert result["run_id"].encode() in output
                    send("lllll-]0+jkq")
                    # Reopen persisted result: it must not run the harness again.
                    palette("Open latest waveform")
                    waveform()
                    assert json.loads(latest.read_text())["run_id"] == result["run_id"]
                    send("q")
                palette("Open latest run log")
                wait(lambda: b"run.log" in output)
            assert len(set(projects)) == 3
            # Original retained buffer still exists, unchanged on disk.
            palette("New SV scratch")
            wait(lambda: len(list(scratch.glob("*/project"))) == 4)
            wait(lambda: b"counter.sv" in output)
            output.clear()
            # Next wraps to the original, whose unsaved contents survived all work.
            send(" bn")
            wait(lambda: b"UNSAVED_ORIGINAL_PTY_BUFFER" in output)
            assert document.read_text() == "ORIGINAL_PTY_BUFFER\n"
            send(" Q")
            wait(lambda: process.poll() is not None)
            assert process.wait(timeout=5) == 0
            print("PTY: three scratch languages, unique paths with spaces, run/status/log, native waves, navigation/close, persisted latest, clean exit")
        finally:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=5)
            os.close(master)


if __name__ == "__main__":
    main()
