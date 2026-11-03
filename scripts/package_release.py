#!/usr/bin/env python3
"""Offline Linux snapshot packaging. See packaging/README.md; Python stdlib only."""
from __future__ import annotations

import argparse
import datetime
import gzip
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SYSTEM_LIBS = re.compile(
    r"^(lib(c|m|pthread|dl|rt|resolv|util|anl)\.so\.[0-9]+|ld-linux[^/]*\.so\.[0-9]+)$")
EXCLUDED = {".git", "_build", "dist", "__pycache__", ".cache", ".opam",
            "node_modules", ".vibe-wise", ".pytest_cache"}


def run(args, cwd=ROOT):
    return subprocess.check_output(args, cwd=cwd, text=True,
                                   env={**os.environ, "LC_ALL": "C"}).strip()


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def safe_relative(value):
    p = PurePosixPath(value)
    if (not value or p.is_absolute() or any(x in {"", ".", ".."} for x in value.split("/"))
            or any(x in EXCLUDED for x in p.parts) or "\\" in value
            or any(ord(c) < 32 for c in value)):
        raise ValueError(f"unsafe source/archive path: {value!r}")
    return p


def version_string(value, commit, dirty, epoch):
    if value == "snapshot":
        date = datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).strftime("%Y%m%d")
        value = f"0.1.0-dev+{date}.{commit[:12]}" + (".dirty" if dirty else "")
    if not re.fullmatch(r"[0-9][A-Za-z0-9.+~-]{0,95}", value):
        raise ValueError("version must start with a digit and contain only letters, digits, . + ~ - (max 96)")
    return value


def checked_source_path(root, name):
    """Reject symlinks in every component before traversing a source path."""
    relative = safe_relative(name)
    p = root
    for component in relative.parts:
        p = p / component
        if p.is_symlink():
            raise ValueError(f"source symlink requires explicit review: {name}")
    if not p.resolve().is_relative_to(root.resolve()):
        raise ValueError(f"source escapes repository: {name}")
    return p


def walk_source(root, name):
    """Do not follow symlinks or even descend into excluded cache directories."""
    p = checked_source_path(root, name)
    if p.is_dir():
        for child in sorted(p.iterdir()):
            if child.name not in EXCLUDED:
                yield from walk_source(root, str(child.relative_to(root)))
    elif p.is_file():
        yield name
    else:
        raise ValueError(f"not a regular source file/directory: {name}")


def source_paths(root, includes=()):
    # Read working-tree bytes, never git archive (which would omit local edits).
    names = set(subprocess.check_output(["git", "ls-files", "-z", "--cached"], cwd=root)
                .decode().split("\0")) - {""}
    # Include this new tooling before its first commit, but no arbitrary personal files.
    scripts = checked_source_path(root, "scripts")
    if scripts.is_dir():
        for p in scripts.glob("package_release*"):
            names.update(walk_source(root, str(p.relative_to(root))))
    packaging = checked_source_path(root, "packaging")
    if packaging.exists():
        names.update(walk_source(root, "packaging"))
    for item in includes:
        names.update(walk_source(root, item))
    result = []
    for name in sorted(names):
        if any(part in EXCLUDED for part in PurePosixPath(name).parts):
            continue
        p = checked_source_path(root, name)
        if p.exists():
            if not p.is_file():
                raise ValueError(f"not a regular source file (submodule?): {name}")
            result.append(p)
    return result


def archive(destination, entries, epoch):
    """entries: iterable of (POSIX archive name, Path or bytes, executable)."""
    with destination.open("xb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0, compresslevel=9) as gz:
            with tarfile.open(fileobj=gz, mode="w", format=tarfile.PAX_FORMAT) as tar:
                for name, content, executable in sorted(entries, key=lambda e: e[0]):
                    safe_relative(name)
                    info = tarfile.TarInfo(name)
                    info.uid = info.gid = 0
                    info.uname = info.gname = ""
                    info.mtime = epoch
                    info.mode = 0o755 if executable else 0o644
                    if isinstance(content, Path):
                        info.size = content.stat().st_size
                        with content.open("rb") as stream:
                            tar.addfile(info, stream)
                    else:
                        info.size = len(content)
                        tar.addfile(info, io.BytesIO(content))


def json_bytes(value):
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()


def elf_info(binary):
    header = run(["readelf", "-hW", str(binary)])
    dynamic = run(["readelf", "-dW", str(binary)])
    program = run(["readelf", "-lW", str(binary)])
    versions = run(["readelf", "--version-info", "-W", str(binary)])
    glibc = sorted(set(re.findall(r"\bGLIBC_(\d+(?:\.\d+)+)", versions)),
                   key=lambda v: tuple(map(int, v.split("."))))
    interpreter = re.search(r"Requesting program interpreter: ([^\]]+)", program)
    machine = re.search(r"Machine:\s*(.+)", header).group(1)
    arch = {"Advanced Micro Devices X86-64": "x86_64", "AArch64": "aarch64"}.get(machine)
    if arch is None or arch != platform.machine():
        raise ValueError(f"unsupported/cross-architecture ELF: {machine}; package on target Linux")
    paths = re.findall(r"\((?:RPATH|RUNPATH)\).*?\[([^\]]*)\]", dynamic)
    # Absolute development paths must not silently survive in a distributed binary.
    if any(p and not p.startswith("$ORIGIN") for value in paths for p in value.split(":")):
        raise ValueError("ELF contains a non-relative RPATH/RUNPATH; rebuild without it")
    return {"architecture": arch, "machine": machine,
            "needed": re.findall(r"\(NEEDED\).*?\[([^\]]+)\]", dynamic),
            "interpreter": interpreter.group(1) if interpreter else None,
            "glibc_versions": glibc, "minimum_glibc": glibc[-1] if glibc else None,
            "rpaths": paths}


def runtime_libraries(binary, requested):
    output = run(["ldd", str(binary)])
    if "not found" in output:
        raise ValueError(f"unresolved runtime dependency:\n{output}")
    resolved = {}
    for line in output.splitlines():
        match = re.match(r"\s*(\S+) => (/\S+) \(", line)
        if match:
            resolved[match.group(1)] = Path(match.group(2)).resolve()
        else:
            match = re.match(r"\s*(/\S+) \(", line)
            if match:
                p = Path(match.group(1))
                resolved[p.name] = p.resolve()
    bundles = {}
    for spec in requested:
        name, sep, path = spec.partition("=")
        if not sep or not re.fullmatch(r"[A-Za-z0-9_+.-]+\.so(?:\.[0-9]+)*", name):
            raise ValueError("--bundle-library must be SONAME=/absolute/path")
        p = Path(path)
        if not p.is_absolute() or not p.is_file() or name in bundles:
            raise ValueError(f"invalid/duplicate bundle path: {spec}")
        if SYSTEM_LIBS.fullmatch(name):
            raise ValueError(f"system glibc libraries must not be bundled: {name}")
        if name not in resolved or resolved[name] != p.resolve():
            raise ValueError(f"bundle must match actual ldd resolution: {name}")
        bundles[name] = p.resolve()
    for name in resolved:
        if not SYSTEM_LIBS.fullmatch(name) and name not in bundles:
            raise ValueError(f"non-system dependency {name}: explicitly supply --bundle-library and its notices/source")
    return resolved, bundles


def inventory(prefix):
    columns = "name,version,license:,homepage:,dev-repo:"
    text = run(["opam", "list", "--installed", "--columns=" + columns,
                "--separator=|", "--color=never"])
    packages = []
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        fields = line.split("|", 4)
        if len(fields) < 2:
            raise ValueError(f"cannot parse opam inventory: {line}")
        fields += [""] * (5 - len(fields))  # virtual base packages have no metadata
        packages.append(dict(zip(("name", "version", "declared_license", "homepage", "source_repository"),
                                 (f.strip() for f in fields))))
    return {"scope": "all installed opam packages: build-environment superset, not a linked-library audit",
            "packages": sorted(packages, key=lambda p: p["name"])}


def notices(root, prefix, packages, extra):
    entries = []
    for p in source_paths(root):
        if p.name.lower().startswith(("license", "copying", "notice", "copyright")) or p.name == "ASSETS.md":
            entries.append(("licenses/repository/" + str(p.relative_to(root)), p, False))
    for package in packages["packages"]:
        doc = prefix / "doc" / package["name"]
        if not doc.is_dir():
            continue
        for p in sorted(doc.rglob("*")):
            if p.is_file() and p.name.lower().startswith(("license", "copying", "notice", "copyright")):
                if not p.resolve().is_relative_to(prefix):
                    raise ValueError(f"notice escapes opam prefix: {p}")
                entries.append(("licenses/opam/" + package["name"] + "/" + str(p.relative_to(doc)), p, False))
    if extra:
        for p in sorted(extra.rglob("*")):
            if p.is_symlink():
                raise ValueError(f"symlink in extra notices: {p}")
            if p.is_file():
                entries.append(("licenses/audit/" + str(p.relative_to(extra)), p, False))
    return entries


def checksums(entries):
    return "".join(f"{digest(content) if isinstance(content, Path) else hashlib.sha256(content).hexdigest()}  {name}\n"
                   for name, content, _ in sorted(entries)).encode()


def output_directory(path, root):
    # Only create one explicitly named leaf; never recursively create/delete paths.
    path = path.absolute()
    if path.is_symlink() or not path.parent.is_dir():
        raise ValueError("output must have an existing parent and must not be a symlink")
    resolved = path.resolve()
    if resolved == root or root.is_relative_to(resolved):
        raise ValueError("output must not be the repository or an ancestor")
    if resolved.is_relative_to(root) and resolved != root / "dist":
        raise ValueError("inside the repository, output must be dist/")
    if path.exists() and not path.is_dir():
        raise ValueError("output is not a directory")
    return path


def staged_binary(binary, stage, strip_enabled):
    """Always copy, never hard-link: strip may rewrite or replace its input."""
    shipped = stage / "ches"
    input_hash = digest(binary)
    shutil.copyfile(binary, shipped)
    shipped.chmod(0o755)
    if digest(shipped) != input_hash:
        raise ValueError("input binary changed while copying")
    strip_metadata = {"enabled": strip_enabled, "version": None, "flags": []}
    if strip_enabled:
        tool = shutil.which("strip")
        if tool is None:
            raise ValueError("--strip requires GNU strip (binutils) on PATH")
        strip_metadata["version"] = run([tool, "--version"]).splitlines()[0]
        strip_metadata["flags"] = ["--strip-all", "--enable-deterministic-archives"]
        subprocess.run([tool, *strip_metadata["flags"], str(shipped)], check=True,
                       env={**os.environ, "LC_ALL": "C"})
    if digest(binary) != input_hash:
        raise ValueError("input binary changed during staging")
    return shipped, input_hash, strip_metadata


def package(args):
    if sys.platform != "linux":
        raise ValueError("Linux packaging requires Linux")
    root = ROOT
    out = output_directory(args.output, root)
    commit = run(["git", "rev-parse", "HEAD"])
    dirty = bool(run(["git", "status", "--porcelain", "--untracked-files=normal"]))
    epoch = int(os.environ.get("SOURCE_DATE_EPOCH", run(["git", "show", "-s", "--format=%ct", "HEAD"])))
    if not 0 <= epoch <= 0xFFFFFFFF:
        raise ValueError("SOURCE_DATE_EPOCH must be between 0 and 4294967295")
    version = version_string(args.version, commit, dirty, epoch)
    if not 1 <= args.jobs <= 20:
        raise ValueError("--jobs must be in 1..20 (default 6)")
    if not args.no_build and args.binary.resolve() != root / "_build/default/bin/ches.exe":
        raise ValueError("a custom --binary requires --no-build")
    if not args.no_build:
        subprocess.run(["opam", "exec", "--", "dune", "build", "-j", str(args.jobs), "bin/ches.exe"],
                       cwd=root, check=True)
    binary = args.binary.resolve()
    if not binary.is_file():
        raise ValueError(f"executable not found: {binary}")
    elf = elf_info(binary)
    prefix = Path(run(["opam", "var", "prefix"])).resolve()
    packages = inventory(prefix)
    stem = f"ches-{version}-linux-{elf['architecture']}"
    source_name = f"ches-{version}-source.tar.gz"
    artifact_names = [stem + ".tar.gz", source_name, stem + ".manifest.json", stem + ".sha256"]
    if out.exists() and any((out / n).exists() or (out / n).is_symlink() for n in artifact_names):
        raise ValueError("artifacts already exist; choose a fresh output directory/version (never overwritten)")
    sources = source_paths(root, args.include_source)
    source_entries = [(f"ches-{version}-source/" + str(p.relative_to(root)), p,
                       bool(p.stat().st_mode & stat.S_IXUSR)) for p in sources]
    source_inventory = checksums([(str(p.relative_to(root)), p, False) for p in sources])
    dependency_sources = []
    extras = []
    for p in args.dependency_source:
        if not p.is_file() or p.is_symlink():
            raise ValueError(f"dependency source must be a regular local archive: {p}")
        safe_relative(p.name)
        extras.append(("sources/dependencies/" + p.name, p, False))
        dependency_sources.append({"file": p.name, "sha256": digest(p)})
    if len({e[0] for e in extras}) != len(extras):
        raise ValueError("duplicate dependency-source basenames")
    license_entries = notices(root, prefix, packages, args.extra_notices)
    manifest = {
        "schema_version": 1, "name": "ches", "version": version,
        "git_commit": commit, "working_tree_dirty": dirty, "source_date_epoch": epoch,
        "build": {"performed": not args.no_build, "jobs": args.jobs,
                  "binary_source_association": "not attested" if args.no_build else "built from this working tree",
                  "ocaml": run(["opam", "exec", "--", "ocamlc", "-version"]),
                  "dune": run(["opam", "exec", "--", "dune", "--version"])},
        "host": {"os_release": Path("/etc/os-release").read_text(),
                 "kernel": platform.release(), "libc": list(platform.libc_ver())},
        "source": {"archive": source_name, "file_count": len(sources),
                   "selection": "tracked working-tree files plus packaging tooling and explicit --include-source; ignored/cache files excluded",
                   "inventory_sha256": hashlib.sha256(source_inventory).hexdigest(),
                   "dependency_sources": dependency_sources,
                   "complete_corresponding_source_verified": False},
        "licensing": {"project_declared": "MIT (metadata only; no root license grant synthesized)",
                      "embedded_gas_grammar": "GPL-3.0; combined binary obligations apply",
                      "release_audit_status": "unverified; see NOTICES.md and supplied audit notices"},
        "portability": "Native Linux/glibc snapshot; minimum symbol version is necessary, not a portability guarantee. No musl/macOS/Windows support claimed.",
    }
    # Verify the parent before creation, then stage privately on the same filesystem.
    out.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".ches-package-", dir=out) as temp:
        stage = Path(temp)
        shipped, input_hash, strip_metadata = staged_binary(binary, stage, args.strip)
        shipped_elf = elf_info(shipped)
        if shipped_elf != elf:
            raise ValueError("shipped ELF runtime metadata differs from input binary")
        elf = shipped_elf
        resolved, bundles = runtime_libraries(shipped, args.bundle_library)
        if bundles and not args.extra_notices:
            raise ValueError("bundled libraries require --extra-notices with applicable license texts/provenance")
        manifest.update({"input_binary_sha256": input_hash, "binary_sha256": digest(shipped),
                         "input_binary_size": binary.stat().st_size,
                         "binary_size": shipped.stat().st_size, "strip": strip_metadata, "elf": elf,
                         "runtime_libraries": [{"soname": name, "bundled": name in bundles,
                                                "sha256": digest(p)} for name, p in sorted(resolved.items())]})
        archive(stage / source_name, source_entries, epoch)
        manifest["source"]["sha256"] = digest(stage / source_name)
        entries = [("bin/ches", shipped, True)]
        if bundles:
            entries = [("libexec/ches", shipped, True)]
            launcher = ("#!/bin/sh\nset -eu\n"
                        'base=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)\n'
                        'export LD_LIBRARY_PATH="$base/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"\n'
                        'exec "$base/libexec/ches" "$@"\n').encode()
            entries.append(("bin/ches", launcher, True))
            entries.extend(("lib/" + name, p, False) for name, p in bundles.items())
            # Include transitive bundled objects' glibc requirements, too.
            for p in bundles.values():
                required = elf_info(p)["minimum_glibc"]
                if required and (not elf["minimum_glibc"] or
                                 tuple(map(int, required.split("."))) > tuple(map(int, elf["minimum_glibc"].split(".")))):
                    elf["minimum_glibc"] = required
        entries += license_entries + extras
        entries += [("sources/" + source_name, stage / source_name, False),
                    ("metadata/source-files.sha256", source_inventory, False),
                    ("metadata/opam-inventory.json", json_bytes(packages), False),
                    ("metadata/manifest.json", json_bytes(manifest), False),
                    ("README.md", (root / "packaging/BINARY_README.md").read_bytes(), False),
                    ("NOTICES.md", (root / "packaging/NOTICES.md").read_bytes(), False)]
        names = [e[0] for e in entries]
        if len(set(names)) != len(names):
            raise ValueError("duplicate package paths")
        entries.append(("SHA256SUMS", checksums(entries), False))
        archive(stage / artifact_names[0], [(stem + "/" + n, c, x) for n, c, x in entries], epoch)
        (stage / artifact_names[2]).write_bytes(json_bytes(manifest))
        sums = [(n, stage / n, False) for n in artifact_names[:-1]]
        (stage / artifact_names[3]).write_bytes(checksums(sums))
        # Hard links provide no-clobber publication even with concurrent invocations.
        published = []
        try:
            for name in artifact_names:
                os.link(stage / name, out / name)
                published.append(out / name)
        except BaseException:
            for p in published:
                p.unlink()
            raise
    for name in artifact_names:
        p = out / name
        print(f"{p}: {p.stat().st_size:,} bytes")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True, help="release version, or 'snapshot' for date+commit[.dirty]")
    parser.add_argument("--output", type=Path, default=ROOT / "dist")
    parser.add_argument("--jobs", "-j", type=int, default=6, help="Dune workers, 1..20 (default 6)")
    parser.add_argument("--no-build", action="store_true", help="package existing executable; source association is not attested")
    parser.add_argument("--binary", type=Path, default=ROOT / "_build/default/bin/ches.exe")
    parser.add_argument("--strip", action="store_true", help="GNU strip symbols from a private copy only; preserve the build executable")
    parser.add_argument("--include-source", action="append", default=[], metavar="RELATIVE_PATH")
    parser.add_argument("--bundle-library", action="append", default=[], metavar="SONAME=PATH")
    parser.add_argument("--extra-notices", type=Path, help="local audit notices directory (copied verbatim)")
    parser.add_argument("--dependency-source", action="append", type=Path, default=[], help="local dependency source archive to accompany binary")
    args = parser.parse_args()
    try:
        if args.extra_notices and not args.extra_notices.is_dir():
            raise ValueError("--extra-notices must be an existing directory")
        package(args)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"package_release: {error}\n")


if __name__ == "__main__":
    main()
