"""Private-environment PTY checks for production startup and explicit CLI theme."""
import errno
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import select
import struct
import subprocess
import sys
import tempfile
import termios
import time


binary = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix="ches-config-cli-") as directory:
    root = Path(directory)
    config_dir = root / "ches"
    config_dir.mkdir()
    config = config_dir / "config.ml"
    marker = root / "loaded"
    document = root / "document.txt"
    original = b"CONFIGURATION_DOCUMENT\nsecond line\n"
    document.write_bytes(original)
    env = dict(os.environ, XDG_CONFIG_HOME=str(root), HOME=str(root),
               TERM="xterm-256color", COLORTERM="truecolor", LC_ALL="C.UTF-8")
    source = ("open Ches_config\nlet () =\n"
              f"  let out = open_out {json.dumps(str(marker))} in\n"
              "  output_string out \"loaded\"; close_out out;\n"
              '  Theme.set "glacier"\n')
    config.write_text(source)
    listing = subprocess.run([binary, "--list-themes"], env=env,
                             capture_output=True, timeout=10, check=True)
    assert b"vim-classic" in listing.stdout and b"glacier" in listing.stdout
    assert not marker.exists(), "--list-themes executed configuration"
    invalid = subprocess.run([binary, "--theme", "not-a-theme"], env=env,
                             capture_output=True, timeout=10)
    assert invalid.returncode and b"--list-themes" in invalid.stderr
    assert not marker.exists()

    def launch(options=(), expected_error=None):
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 160, 0, 0))
        process = subprocess.Popen([binary, "--no-lsp", "--bare", *options, str(document)],
                                   stdin=slave, stdout=slave, stderr=slave, env=env)
        os.close(slave)
        output = bytearray()

        def drain_until(predicate):
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                if predicate(bytes(output)):
                    return
                readable, _, _ = select.select([master], [], [], .05)
                if readable:
                    try:
                        chunk = os.read(master, 65536)
                    except OSError as error:
                        if error.errno != errno.EIO:
                            raise
                        break
                    if not chunk:
                        break
                    output.extend(chunk)
            if predicate(bytes(output)):
                return
            raise AssertionError(bytes(output).decode(errors="replace"))

        try:
            drain_until(lambda data: b"CONFIGURATION_DOCUMENT" in data and
                        (expected_error is None or expected_error in data))
            # The first document draw must already use the configured/overridden
            # theme; a later asynchronous recolor would fail this assertion.
            prefix = bytes(output).split(b"CONFIGURATION_DOCUMENT", 1)[0]
            colors = tuple(re.findall(rb"(?:38|48);2;\d+;\d+;\d+", prefix))
            assert colors, prefix
            os.write(master, b" Q")
            drain_until(lambda _: process.poll() is not None)
            assert process.wait(timeout=5) == 0
            assert document.read_bytes() == original
            return colors
        finally:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=5)
            os.close(master)

    configured = launch()
    assert marker.read_text() == "loaded", "startup did not execute configuration"
    assert config.read_text() == source
    explicit = launch(("--theme", "vim-classic"))
    assert explicit != configured, "omitted --theme incorrectly overrides config"
    config.unlink()
    missing = launch()
    assert missing == explicit, "missing configuration did not use defaults"
    config.write_text('let () = failwith "CLI_CONFIG_FAILURE"\n')
    failed = launch(expected_error=b"Configuration startup failed; using defaults")
    assert failed == explicit, "startup failure did not use default theme"
    assert config.read_text() == 'let () = failwith "CLI_CONFIG_FAILURE"\n'
    print("CLI: list skips config; startup precedes first draw; explicit theme wins; missing/error defaults; no writes")
