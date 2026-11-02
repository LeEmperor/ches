#!/usr/bin/env python3
"""Rendered mixed-LSP inspection smoke in a private tmux PTY.

Default: deterministic existing fake_lsp for both language clients (CI-friendly).
--real: installed ocamllsp and Slang, using ches's normal server discovery.
Needs only Python's standard library, tmux, and the built binaries. Fixtures and
screen captures are retained under /tmp for diagnosis; no checkout files change.
"""
import argparse
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import time


def main():
    checkout = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", nargs="?", default=checkout / "_build/default/bin/ches.exe")
    parser.add_argument("--real", action="store_true")
    parser.add_argument("--fake-lsp", default=os.environ.get(
        "CHES_FAKE_LSP", checkout / "_build/default/source/test/fake_lsp/fake_lsp.exe"))
    args = parser.parse_args()
    binary = Path(args.binary).resolve()
    if not shutil.which("tmux") or not binary.is_file():
        parser.error("requires tmux and a built ches binary")
    fake = Path(args.fake_lsp).resolve()
    if not args.real and not fake.is_file():
        parser.error("build source/test/fake_lsp/fake_lsp.exe or pass --fake-lsp")
    if args.real:
        slang = (os.environ.get("SLANG_SERVER") or shutil.which("slang-server")
                 or str(Path.home() / "slang-server/build/bin/slang-server"))
        if not shutil.which("ocamllsp") or not os.access(slang, os.X_OK):
            parser.error("--real requires ocamllsp and Slang (SLANG_SERVER, PATH, or HOME fallback)")

    root = Path(tempfile.mkdtemp(prefix="ches-lsp-", dir="/tmp"))
    captures = root / ".captures"
    captures.mkdir()
    ml, rtl = root, root / "rtl"
    rtl.mkdir()
    (ml / "dune-project").write_text("(lang dune 3.0)\n")
    (rtl / ".slang").write_text("")
    original = {ml / "a.ml": "let value = 1\n",
                rtl / "b.sv": "module b; endmodule\n",
                rtl / "c.sv": "module c; endmodule\n"}
    for path, content in original.items():
        path.write_text(content)
    env = {"LC_ALL": "C.UTF-8", "TERM": "tmux-256color"}
    if not args.real:
        fakebin = root / ".fakebin"
        fakebin.mkdir()
        (fakebin / "ocamllsp").symlink_to(fake)
        env.update(PATH=str(fakebin) + os.pathsep + os.environ["PATH"], SLANG_SERVER=str(fake))
    socket = root / "tmux.sock"
    tmux = ["tmux", "-S", str(socket), "-f", "/dev/null"]

    def t(*arguments):
        return subprocess.check_output(tmux + list(arguments), text=True)

    def screen(ansi=False):
        return t("capture-pane", "-p", *(["-e"] if ansi else []), "-t", "lsp")

    def save(label):
        (captures / (label + ".txt")).write_text(screen())
        (captures / (label + ".ansi")).write_text(screen(True))

    def wait(predicate, label):
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            output = screen()
            if predicate(output):
                return output
            time.sleep(.05)
        save("failure")
        raise AssertionError(f"{label}:\n{screen()}")

    def send(text):
        t("send-keys", "-t", "lsp", "-l", "--", text)

    def key(name):
        t("send-keys", "-t", "lsp", name)

    def blocks(output):
        return dict(re.findall(r'Server: "([^"]+)"(.*?)(?=Server:|╰)', output, re.S))

    def inventory(current, documents, label):
        def matches(output):
            servers = blocks(output)
            if len(servers) != len(documents):
                return False
            for prefix, (project, names) in documents.items():
                matched = [(name, block) for name, block in servers.items() if name.startswith(prefix + "#")]
                if len(matched) != 1:
                    return False
                name, block = matched[0]
                if not all(text in block for text in (
                        "Status: Running", f'Root: "{project}"',
                        f"Attached documents: {len(names)}", *(f'"{project / file}"' for file in names))):
                    return False
                if project / current.name == current and current.name in names:
                    if f'Current file attached to: "{name}"' not in output or "[current file attached]" not in block:
                        return False
            return f'Current file: "{current}"' in output
        output = wait(matches, label)
        save(label)
        print("ok:", label, ", ".join(blocks(output)), flush=True)
        return blocks(output)

    def open_file(relative):
        send(" ff" + Path(relative).name)
        wait(lambda s: "Files |" in s and
             re.search(r"Preview \| [^\n]*" + re.escape(Path(relative).name), s) is not None
             and "Filtering" not in s, "file picker " + relative)
        key("Enter")
        wait(lambda s: "Files |" not in s and Path(relative).name in s, "open " + relative)

    both = {"ocamllsp": (ml, ["a.ml"]), "slang-server": (rtl, ["b.sv"])}
    all_files = {**both, "slang-server": (rtl, ["b.sv", "c.sv"])}
    try:
        command = shlex.join(["env", *(f"{k}={v}" for k, v in env.items()),
                              "bash", "--norc", "--noprofile"])
        t("new-session", "-d", "-s", "lsp", "-x", "220", "-y", "55", "-c", str(root), command)
        t("set-option", "-t", "lsp", "status", "off")
        send("stty -g > before; " + shlex.join([str(binary), "a.ml"]) +
             "; printf '%s' $? > exit-code; stty -g > after\n")
        wait(lambda s: "let value = 1" in s and "NORMAL" in s, "startup")
        open_file("rtl/b.sv")
        send(" cclsp")
        wait(lambda s: "> Language servers" in s and "Space l i" in s, "palette discovery")
        key("Enter")
        first = inventory(rtl / "b.sv", both, "01-real-mixed" if args.real else "01-fake-mixed")
        slang_id = next(name for name in first if name.startswith("slang-server#"))
        # Report tab -> a.ml -> report. Association follows the active file, not
        # the report's focused read-only buffer.
        send(" bn li")
        inventory(ml / "a.ml", both, "02-current-ocaml")
        open_file("rtl/c.sv")
        send(" li")
        inventory(rtl / "c.sv", all_files, "03-shared-slang-two-documents")
        # Reveal workspace, hide its default companions, and keep the report in a
        # split while changing the file pane. No inspection command after closes:
        # these assertions require automatic inventory updates.
        send(" vz vt vb vm ss sf")
        wait(lambda s: "module c; endmodule" in s and "Language servers (live)" in s, "split inspection")
        send(" bc")
        inventory(rtl / "b.sv", both, "04-live-close-one-attachment")
        send(" bc")
        inventory(ml / "a.ml", {"ocamllsp": (ml, ["a.ml"])}, "05-live-remove-last-slang-attachment")
        open_file("rtl/b.sv")
        reopened = inventory(rtl / "b.sv", both, "06-live-reopen-new-slang-process")
        assert slang_id not in reopened, (slang_id, reopened)
        if not args.real:
            # Controlled process failure while the report stays visible. Fake
            # diagnostics alone cannot satisfy its authoritative status checks.
            send("oCRASH")
            key("Escape")
            wait(lambda s: "Status: Stopped:" in s and "exited with code 3" in s, "live fake crash")
            save("07-live-stopped")
            send("u vR")
            inventory(rtl / "b.sv", both, "08-live-restart-running")
        send(" li")
        inventory(rtl / "b.sv", both, "09-explicit-inspect-refresh")
        send("ggVGy")
        wait(lambda s: "Copied" in s, "report copy")
        send("ixdp")
        wait(lambda s: "read-only" in s.lower(), "read-only edit rejection")
        send(" bc q")
        wait(lambda s: (root / "after").exists(), "clean exit")
        assert (root / "exit-code").read_text() == "0"
        assert (root / "before").read_bytes() == (root / "after").read_bytes()
        assert all(path.read_text() == content for path, content in original.items())
        print("PASS: mixed LSP frontend, current-file association, live close/remove/reopen, refresh, copy/read-only, clean exit", flush=True)
    finally:
        subprocess.run(tmux + ["kill-server"], capture_output=True, check=False)
        print("LSP terminal fixtures/captures:", root, flush=True)


if __name__ == "__main__":
    main()
