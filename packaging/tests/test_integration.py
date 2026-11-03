"""Opt-in real ELF/inventory packaging twice, with no executable rebuild."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("package_release_integration", ROOT / "scripts/package_release.py")
pack = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pack)


@unittest.skipUnless(os.environ.get("CHES_PACKAGE_INTEGRATION") == "1",
                     "set CHES_PACKAGE_INTEGRATION=1 for real two-pass packaging")
class RealPackagingTests(unittest.TestCase):
    def test_repeat_without_rebuild_and_no_overwrite(self):
        sizes = {stripped: self.check_package(stripped) for stripped in (False, True)}
        print(f"\nSize comparison (bytes): unstripped={sizes[False]}, stripped={sizes[True]}")

    def check_package(self, stripped):
        binary = ROOT / "_build/default/bin/ches.exe"
        before = (pack.digest(binary), binary.stat().st_mtime_ns, binary.stat().st_mode)
        with tempfile.TemporaryDirectory(prefix="ches-repro-", dir="/tmp") as temp:
            root = Path(temp)
            command = ["python3", str(ROOT / "scripts/package_release.py"),
                       "--version", "0.1.0-test+repro", "--no-build"]
            if stripped:
                command.append("--strip")
            for directory in (root / "first", root / "second"):
                subprocess.run(command + ["--output", str(directory)], check=True,
                               cwd=root, stdout=subprocess.PIPE, text=True)
            first, second = root / "first", root / "second"
            self.assertEqual(sorted(p.name for p in first.iterdir()), sorted(p.name for p in second.iterdir()))
            for p in first.iterdir():
                self.assertEqual(pack.digest(p), pack.digest(second / p.name), p.name)
            # Failure is non-destructive, even if unrelated data already exists.
            sentinel = first / "unrelated-cache"
            sentinel.write_bytes(b"preserve me")
            sums = {p.name: pack.digest(p) for p in first.iterdir()}
            failed = subprocess.run(command + ["--output", str(first)], capture_output=True, text=True)
            self.assertNotEqual(failed.returncode, 0)
            self.assertIn("never overwritten", failed.stderr)
            self.assertEqual(sums, {p.name: pack.digest(p) for p in first.iterdir()})
            self.assertFalse(any(p.name.startswith(".ches-package-") for p in first.iterdir()))
            manifest_file = next(first.glob("*.manifest.json"))
            manifest = json.loads(manifest_file.read_text())
            self.assertFalse(manifest["build"]["performed"])
            self.assertFalse(manifest["source"]["complete_corresponding_source_verified"])
            self.assertEqual(manifest["input_binary_sha256"], before[0])
            self.assertEqual(manifest["strip"]["enabled"], stripped)
            if stripped:
                self.assertNotEqual(manifest["binary_sha256"], before[0])
                self.assertLess(manifest["binary_size"], manifest["input_binary_size"])
                self.assertIn("GNU strip", manifest["strip"]["version"])
                self.assertIn("--enable-deterministic-archives", manifest["strip"]["flags"])
            else:
                self.assertEqual(manifest["binary_sha256"], before[0])
                self.assertIsNone(manifest["strip"]["version"])
                self.assertEqual(manifest["strip"]["flags"], [])
            binary_archive = first / (manifest_file.name.removesuffix(".manifest.json") + ".tar.gz")
            stem = manifest_file.name.removesuffix(".manifest.json")
            with tarfile.open(binary_archive) as tar:
                names = tar.getnames()
                for required in ("bin/ches", "SHA256SUMS", "README.md", "NOTICES.md",
                                 "metadata/manifest.json", "metadata/opam-inventory.json",
                                 "licenses/repository/highlight_tree_sitter/gas_grammar/LICENSE"):
                    self.assertIn(stem + "/" + required, names)
                self.assertEqual(hashlib.sha256(tar.extractfile(stem + "/bin/ches").read()).hexdigest(),
                                 manifest["binary_sha256"])
                self.assertEqual(tar.getmember(stem + "/bin/ches").size, manifest["binary_size"])
                self.assertEqual(json.load(tar.extractfile(stem + "/metadata/manifest.json")), manifest)
                for line in tar.extractfile(stem + "/SHA256SUMS").read().decode().splitlines():
                    checksum, name = line.split("  ", 1)
                    self.assertEqual(hashlib.sha256(tar.extractfile(stem + "/" + name).read()).hexdigest(), checksum)
            with tarfile.open(first / manifest["source"]["archive"]) as tar:
                prefix = f"ches-{manifest['version']}-source/"
                names = tar.getnames()
                for required in ("highlight_tree_sitter/gas_grammar/grammar.js",
                                 "highlight_tree_sitter/gas_grammar/parser.c.gz",
                                 "highlight_tree_sitter/gas_grammar/ASSETS.md", "dune-project",
                                 "scripts/package_release.py", "packaging/README.md"):
                    self.assertIn(prefix + required, names)
                    self.assertEqual(tar.extractfile(prefix + required).read(), (ROOT / required).read_bytes())
                self.assertFalse(any(set(Path(n).parts) & pack.EXCLUDED for n in names))
            if stripped:
                # Real extracted ELF validation and PTY smoke exercise shipped bytes.
                extracted = root / "shipped-ches"
                with tarfile.open(binary_archive) as tar:
                    extracted.write_bytes(tar.extractfile(stem + "/bin/ches").read())
                self.assertEqual(pack.elf_info(extracted), manifest["elf"])
                self.assertEqual(pack.elf_info(binary), manifest["elf"])
                subprocess.run(["python3", str(ROOT / "packaging/smoke.py"), str(binary_archive)],
                               cwd=root, check=True)
            sizes = {"executable": manifest["binary_size"], "tar_gz": binary_archive.stat().st_size}
        self.assertEqual(before, (pack.digest(binary), binary.stat().st_mtime_ns, binary.stat().st_mode))
        return sizes


if __name__ == "__main__":
    unittest.main()
