#!/usr/bin/env python3
"""Capture real repository buffers in private tmux; rasterize ANSI with Pillow.

Run after dune build -j6 bin/ches.exe. Requires tmux, rg, ocamllsp, Pillow and DejaVu Sans Mono.
Only docs/images PNGs are written in the checkout. Raw evidence stays in /tmp.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import time
import unicodedata

from PIL import Image, ImageDraw, ImageFont, PngImagePlugin

COLS, ROWS = 144, 44
CELL = (12, 24)
DEFAULT_FG, DEFAULT_BG = (211, 211, 211), (0, 0, 0)


def indexed(n):
    basic = [(0, 0, 0), (128, 0, 0), (0, 128, 0), (128, 128, 0),
             (0, 0, 128), (128, 0, 128), (0, 128, 128), (192, 192, 192),
             (128, 128, 128), (255, 0, 0), (0, 255, 0), (255, 255, 0),
             (0, 0, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255)]
    if n < 16:
        return basic[n]
    if n >= 232:
        return (8 + (n - 232) * 10,) * 3
    n -= 16
    levels = [0, 95, 135, 175, 215, 255]
    return levels[n // 36], levels[n // 6 % 6], levels[n % 6]


def render(ansi, destination, description, font_dir):
    fonts = [ImageFont.truetype(str(font_dir / name), 20) for name in
             ("DejaVuSansMono.ttf", "DejaVuSansMono-Bold.ttf")]
    image = Image.new("RGB", (COLS * CELL[0], ROWS * CELL[1]), DEFAULT_BG)
    draw = ImageDraw.Draw(image)
    fg, bg, bold, underline, reverse = DEFAULT_FG, DEFAULT_BG, False, False, False
    # tmux elides unchanged SGR across rows: deliberately retain state here.
    for y, line in enumerate(ansi.splitlines()[:ROWS]):
        x = 0
        for token in re.split(r"(\x1b\[[0-9;:]*m)", line):
            if token.startswith("\x1b["):
                values = [int(v or 0) for v in token[2:-1].replace(":", ";").split(";")]
                i = 0
                while i < len(values):
                    v = values[i]
                    if v == 0:
                        fg, bg, bold, underline, reverse = DEFAULT_FG, DEFAULT_BG, False, False, False
                    elif v in (1, 22): bold = v == 1
                    elif v in (4, 24): underline = v == 4
                    elif v in (7, 27): reverse = v == 7
                    elif v == 39: fg = DEFAULT_FG
                    elif v == 49: bg = DEFAULT_BG
                    elif 30 <= v <= 37: fg = indexed(v - 30)
                    elif 40 <= v <= 47: bg = indexed(v - 40)
                    elif 90 <= v <= 97: fg = indexed(v - 90 + 8)
                    elif 100 <= v <= 107: bg = indexed(v - 100 + 8)
                    elif v in (38, 48):
                        mode = values[i + 1]
                        color = tuple(values[i + 2:i + 5]) if mode == 2 else indexed(values[i + 2])
                        if v == 38: fg = color
                        else: bg = color
                        i += 4 if mode == 2 else 2
                    i += 1
                continue
            for char in token:
                width = 0 if unicodedata.combining(char) else (2 if unicodedata.east_asian_width(char) in "WF" else 1)
                if width == 0:
                    continue
                ink, paper = (bg, fg) if reverse else (fg, bg)
                left, top = x * CELL[0], y * CELL[1]
                draw.rectangle((left, top, left + width * CELL[0] - 1, top + CELL[1] - 1), fill=paper)
                draw.text((left, top + 1), char, font=fonts[int(bold)], fill=ink)
                if underline:
                    draw.line((left, top + 22, left + width * CELL[0] - 1, top + 22), fill=ink)
                x += width
    metadata = PngImagePlugin.PngInfo()
    metadata.add_text("Description", description)
    metadata.add_text("Capture", "Real Ches tmux ANSI frame; Pillow rasterization; no added overlays")
    image.save(destination, pnginfo=metadata)


def main():
    repo = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=repo / "_build/default/bin/ches.exe")
    parser.add_argument("--font-dir", type=Path, default=Path("/usr/share/fonts/truetype/dejavu"))
    args = parser.parse_args()
    missing = [name for name in ("tmux", "ocamllsp", "rg", "git", "wc", "clear", "dune")
               if not shutil.which(name)]
    if not args.binary.is_file() or not os.access(args.binary, os.X_OK):
        parser.error("requires an executable built Ches binary")
    if missing:
        parser.error("missing capture tools on PATH: " + ", ".join(missing))
    for name in ("DejaVuSansMono.ttf", "DejaVuSansMono-Bold.ttf"):
        if not (args.font_dir / name).is_file():
            parser.error("missing font: " + str(args.font_dir / name))
    root = Path(tempfile.mkdtemp(prefix="ches-readme-", dir="/tmp/opencode"))
    for name in ("home", "config", "cache", "data", "state", "runtime"):
        (root / name).mkdir(mode=0o700)
    env = dict(os.environ)
    env.update(HOME=str(root / "home"), XDG_CONFIG_HOME=str(root / "config"),
               XDG_CACHE_HOME=str(root / "cache"), XDG_DATA_HOME=str(root / "data"),
               XDG_STATE_HOME=str(root / "state"), XDG_RUNTIME_DIR=str(root / "runtime"),
               SHELL="/bin/sh", ENV="", BASH_ENV="", PS1="ches $ ",
                LC_ALL="C.UTF-8", TERM="tmux-256color", GIT_OPTIONAL_LOCKS="0")
    env.pop("TMUX", None)
    tmux = ["tmux", "-S", str(root / "sock"), "-f", "/dev/null"]
    def t(*items):
        return subprocess.check_output(tmux + list(items), env=env, text=True)
    def screen(ansi=False):
        return t("capture-pane", "-p", *(["-e"] if ansi else []), "-t", "capture")
    def send(text):
        t("send-keys", "-t", "capture", "-l", "--", text)
        time.sleep(.18)
    def key(name):
        t("send-keys", "-t", "capture", name)
        time.sleep(.18)
    def wait(text, absent=(), timeout=30):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            frame = screen()
            if text in frame and all(item not in frame for item in absent):
                return
            time.sleep(.1)
        (root / "failure.txt").write_text(screen())
        raise RuntimeError(f"Waiting for {text!r}:\n{screen()}")
    def git(*items):
        return subprocess.check_output(["git", *items], cwd=repo,
                                       env={**os.environ, "GIT_OPTIONAL_LOCKS": "0"})
    sources = [repo / "completion/snippet.ml", repo / "source/lsp_client.ml"]
    original = {str(p.relative_to(repo)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    before = git("status", "--porcelain=v1")
    index_before = git("diff", "--cached", "--binary")
    (root / "git-before.txt").write_bytes(before)
    captures = []
    def save(name, description, keys):
        time.sleep(.4)
        ansi = screen(True)
        (root / (name + ".ansi")).write_text(ansi)
        (root / (name + ".txt")).write_text(screen())
        render(ansi, repo / "docs/images" / (name + ".png"), description, args.font_dir)
        captures.append(dict(path=f"docs/images/{name}.png", dimensions=[1728, 1056],
                             description=description, keys=keys))
    try:
        t("new-session", "-d", "-s", "capture", "-x", str(COLS), "-y", str(ROWS),
          "-c", str(repo), "/bin/sh")
        t("set-option", "-t", "capture", "status", "off")
        send(shlex.join([str(args.binary.resolve()), "completion/snippet.ml"]))
        key("Enter")
        wait("let grouped")
        send(" ccToggle absolute line numbers")
        key("Enter")
        send("22G")
        save("editor", "Vim Classic Zen editor on real completion/snippet.ml, absolute line numbers enabled.",
             "Space c c; Toggle absolute line numbers; Enter; 22G")
        send(" vz ds")
        wait("Directory")
        key("Tab")
        save("workspace", "Non-Zen workspace with repository directory browser, source, status and support tiles.",
             "Space v z; Space d s; Tab")
        send(" vz")
        wait("let grouped", ("╭─ Status",))
        send(" /")
        wait("Tile Term 1")
        key("C-Space")
        send("5-i")
        # The shell starts in the source file's directory. Commands operate on
        # this real checkout, and neither build nor modify source.
        send("cd ..")
        key("Enter")
        send("clear")
        key("Enter")
        send("git ls-files 'completion/*.ml'")
        key("Enter")
        send("wc -l completion/snippet.ml source/lsp_client.ml")
        key("Enter")
        send("dune --version")
        key("Enter")
        save("tile-terms", "Floating Tile Term running real read-only project commands over the Zen source editor.",
             "Space /; Ctrl-Space; 5-; i; cd ..; clear; git ls-files 'completion/*.ml'; wc -l completion/snippet.ml source/lsp_client.ml; dune --version")
        key("C-Space")
        send(" /")
        send(" ffsource/lsp_client.ml")
        wait("Preview | source/lsp_client.ml", ("Filtering", "Loading"))
        save("navigation", "Project file picker filtered to source/lsp_client.ml, with actual source preview.",
             "Ctrl-Space; Space /; Space f f; source/lsp_client.ml")
        key("Escape")
        # Real ocamllsp references on the definition of grouped, no fake server.
        send("22G0wgr")
        wait("Find references (")
        wait("Source preview (buffer")
        save("references", "Real ocamllsp references for grouped in completion/snippet.ml with source preview.",
             "Escape; 22G0w; g r")
        key("Escape")
        send(" q")
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if t("display-message", "-p", "-t", "capture", "#{alternate_on}").strip() == "0":
                break
            time.sleep(.1)
        else:
            raise RuntimeError("Ches did not exit cleanly")
    finally:
        subprocess.run(tmux + ["kill-server"], env=env, capture_output=True)
        after = git("status", "--porcelain=v1")
        (root / "git-after.txt").write_bytes(after)
        assert git("diff", "--cached", "--binary") == index_before, "staged work changed"
        assert all(hashlib.sha256((repo / p).read_bytes()).hexdigest() == digest
                   for p, digest in original.items()), "source bytes changed"
        evidence = dict(captures=captures, source_sha256=original,
                        git_before=before.decode(), git_after=after.decode(),
                        staged_diff_unchanged=True, real_ocamllsp=shutil.which("ocamllsp"))
        (root / "metadata.json").write_text(json.dumps(evidence, indent=2) + "\n")
        print(f"Capture evidence: {root}")
        for item in captures:
            print(f"{item['path']}: 1728 × 1056 — {item['description']}")


if __name__ == "__main__":
    main()
