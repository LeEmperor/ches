#!/usr/bin/env python3
"""Verify/extract one binary archive, then exercise it outside source/opam in a PTY."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time


def extract(archive, destination):
    with tarfile.open(archive, "r:gz") as tar:
        members = tar.getmembers()
        names = set()
        for member in members:
            p = PurePosixPath(member.name)
            if (not member.isfile() or p.is_absolute() or ".." in p.parts
                    or member.name in names or len(p.parts) < 2):
                raise ValueError(f"unsafe archive entry: {member.name}")
            names.add(member.name)
        roots = {PurePosixPath(m.name).parts[0] for m in members}
        if len(roots) != 1:
            raise ValueError("expected exactly one package root")
        # Copy ourselves: no tar symlink/device/permission extraction semantics.
        for member in members:
            target = destination / member.name
            target.parent.mkdir(parents=True, exist_ok=True)
            with tar.extractfile(member) as source, target.open("xb") as out:
                shutil.copyfileobj(source, out)
            target.chmod(0o755 if member.mode & 0o111 else 0o644)
    return destination / roots.pop()


def verify(package):
    expected = set()
    for line in (package / "SHA256SUMS").read_text().splitlines():
        checksum, name = line.split("  ", 1)
        p = PurePosixPath(name)
        if p.is_absolute() or ".." in p.parts or name in expected:
            raise ValueError("unsafe/duplicate checksum path")
        expected.add(name)
        h = hashlib.sha256()
        with (package / name).open("rb") as f:
            for block in iter(lambda: f.read(1024 * 1024), b""):
                h.update(block)
        assert h.hexdigest() == checksum, name
    actual = {str(p.relative_to(package)) for p in package.rglob("*") if p.is_file()}
    assert actual == expected | {"SHA256SUMS"}, (actual - expected)


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: python3 packaging/smoke.py path/to/binary.tar.gz")
    if not shutil.which("tmux"):
        raise SystemExit("tmux is required for the extracted-package PTY smoke")
    with tempfile.TemporaryDirectory(prefix="ches-package-smoke-", dir="/tmp") as temp:
        root = Path(temp)
        package = extract(Path(sys.argv[1]).resolve(), root)
        verify(package)
        manifest = json.loads((package / "metadata/manifest.json").read_text())
        binary = package / "bin/ches"
        home = root / "empty-home"
        home.mkdir()
        path = root / "minimal-path"
        path.mkdir()
        # Shell support only; no compiler, opam, LSP, git or user PATH.
        for name, target in {"sh": "/bin/sh", "dirname": "/usr/bin/dirname"}.items():
            (path / name).symlink_to(target)
        env = {"HOME": str(home), "XDG_CONFIG_HOME": str(home / "config"),
               "XDG_CACHE_HOME": str(home / "cache"), "PATH": str(path),
               "SHELL": "/bin/sh", "TERM": "xterm-256color", "LC_ALL": "C.UTF-8"}
        listing = subprocess.check_output([binary, "--list-themes"], cwd=root, env=env, text=True)
        assert "vim-classic\t" in listing and len(listing.splitlines()) >= 40
        fixture = root / "fixture.ml"
        fixture.write_text('let package_probe = "CHES_PACKAGE_HIGHLIGHT"\n')
        socket = root / "tmux.sock"
        tmux = [shutil.which("tmux"), "-S", str(socket), "-f", "/dev/null"]

        def t(*args):
            return subprocess.check_output(tmux + list(args), env=env, cwd=root,
                                           text=True, stderr=subprocess.STDOUT)

        def screen(ansi=False):
            return t("capture-pane", "-p", *(["-e"] if ansi else []), "-t", "package")

        def wait(predicate, label):
            deadline = time.monotonic() + 12
            while time.monotonic() < deadline:
                if predicate():
                    return
                time.sleep(.08)
            raise AssertionError(f"{label}:\n{screen(True)}")

        def send(text):
            t("send-keys", "-t", "package", "-l", "--", text)

        def key(name):
            t("send-keys", "-t", "package", name)
            time.sleep(.15)

        # env -i also scrubs tmux-added variables from the actual program environment.
        launch = shlex.join(["/usr/bin/env", "-i", *(f"{k}={v}" for k, v in env.items()),
                             str(binary), "--theme", "crimson", str(fixture)])
        # First run exercises an absent automatic language server.
        command = f"{launch}; printf '%s' $? > exit-code; /bin/sleep 60"
        try:
            t("new-session", "-d", "-s", "package", "-x", "140", "-y", "44", "-c", str(root),
              "/bin/sh -c " + shlex.quote(command))
            t("set-option", "-t", "package", "status", "off")
            wait(lambda: "CHES_PACKAGE_HIGHLIGHT" in screen(), "startup without LSP/compiler")
            ansi = screen(True)
            # Verify multiple foreground colors on the code line, not just UI chrome.
            code = next(line for line in ansi.splitlines() if "CHES_PACKAGE_HIGHLIGHT" in line)
            assert len(set(re.findall(r"38;2;\d+;\d+;\d+", code))) >= 2, code
            send("i(* packaged edit *) ")
            key("Escape")
            send(" w")
            wait(lambda: fixture.read_text().startswith("(* packaged edit *) "), "edit/save")
            send(" /")
            wait(lambda: "Tile Term" in screen(), "embedded terminal")
            send("printf 'CHES_%s\\n' PACKAGE_SHELL_OK\n")
            wait(lambda: "CHES_PACKAGE_SHELL_OK" in screen(), "embedded shell output")
            key("C-Space")
            send(" /")
            wait(lambda: "Tile Term" not in screen(), "hide terminal")
            send(" q")
            wait(lambda: (root / "exit-code").exists(), "clean quit")
            assert (root / "exit-code").read_text() == "0"
            # A user config without a compiler must degrade to defaults, not prevent editing.
            configuration = home / "config/ches/config.ml"
            configuration.parent.mkdir(parents=True, exist_ok=True)
            configuration.write_text('let () = failwith "must not run without compiler"\n')
            second = shlex.join(["/usr/bin/env", "-i", *(f"{k}={v}" for k, v in env.items()),
                                 str(binary), "--no-lsp", str(fixture)])
            startup_log = root / "config-startup.ansi"
            t("pipe-pane", "-t", "package", "/bin/cat > " + shlex.quote(str(startup_log)))
            t("respawn-pane", "-k", "-t", "package", "-c", str(root),
              "/bin/sh -c " + shlex.quote(f"{second}; printf '%s' $? > config-exit-code; /bin/sleep 60"))
            wait(lambda: "CHES_PACKAGE_HIGHLIGHT" in screen()
                 and startup_log.exists()
                 and b"Configuration startup failed; using defaults" in startup_log.read_bytes(),
                 "configuration fallback without compiler")
            send(" q")
            wait(lambda: (root / "config-exit-code").exists(), "configuration fallback quit")
            assert (root / "config-exit-code").read_text() == "0"
            assert configuration.read_text() == 'let () = failwith "must not run without compiler"\n'
        finally:
            subprocess.run(tmux + ["kill-server"], env=env, cwd=root,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        print(f"PASS {manifest['version']}: checksums, isolated --list-themes, PTY highlighting, edit/save, missing LSP, config fallback without compiler, embedded shell, clean quit")


if __name__ == "__main__":
    main()
