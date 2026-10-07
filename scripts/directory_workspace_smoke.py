#!/usr/bin/env python3
"""Run current directory-workspace terminal checks after dune build.

Each child owns its PTY and isolated /tmp/opencode fixture, and verifies disk
outcomes as well as terminal feedback. No Git operations or repository writes.
"""
import subprocess
import sys
from pathlib import Path


def main():
    scripts = Path(__file__).resolve().parent
    binary = scripts.parent / "_build/default/bin/ches.exe"
    if not binary.is_file():
        raise SystemExit("Build first: opam exec --switch=5.2.0+ox -- dune build")
    Path("/tmp/opencode").mkdir(exist_ok=True)
    for name in ("directory_side_smoke.py", "directory_editing_smoke.py",
                 "directory_apply_smoke.py", "directory_operations_smoke.py"):
        print(f"Running {name}", flush=True)
        subprocess.run([sys.executable, str(scripts / name)], check=True, timeout=90)
    print("PASS: integrated directory-workspace terminal checks")


if __name__ == "__main__":
    main()
