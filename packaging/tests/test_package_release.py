import importlib.util
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("package_release", ROOT / "scripts/package_release.py")
pack = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pack)


class PackagingTests(unittest.TestCase):
    def test_versions_and_paths(self):
        self.assertEqual(pack.version_string("snapshot", "abc123", True, 0),
                         "0.1.0-dev+19700101.abc123.dirty")
        for version in ("../bad", "-1", "a", "1\n", "1/x", "1;rm", "1" * 97):
            with self.subTest(version=version), self.assertRaises(ValueError):
                pack.version_string(version, "abc", False, 0)
        for path in ("../x", "/x", "a/../x", "a//x", "a/./x", "x\ny", "dist/x", "a\\x"):
            with self.subTest(path=path), self.assertRaises(ValueError):
                pack.safe_relative(path)

    def test_deterministic_archive_and_metadata(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            entries = [("pkg/z", b"payload", False), ("pkg/bin/ches", b"executable", True)]
            pack.archive(root / "a.gz", entries, 1234)
            pack.archive(root / "b.gz", reversed(entries), 1234)
            self.assertEqual((root / "a.gz").read_bytes(), (root / "b.gz").read_bytes())
            self.assertEqual((root / "a.gz").read_bytes()[4:8], b"\0" * 4)
            with tarfile.open(root / "a.gz") as tar:
                self.assertEqual(tar.getnames(), ["pkg/bin/ches", "pkg/z"])
                for member in tar.getmembers():
                    self.assertEqual((member.uid, member.gid, member.uname, member.gname, member.mtime),
                                     (0, 0, "", "", 1234))
                    self.assertEqual(member.mode, 0o755 if "bin/" in member.name else 0o644)
            before = (root / "a.gz").read_bytes()
            with self.assertRaises(FileExistsError):
                pack.archive(root / "a.gz", [], 0)
            self.assertEqual((root / "a.gz").read_bytes(), before)

    def test_source_selection_working_tree_and_personal_files(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / "code.ml").write_text("edited, not committed\n")
            (root / "personal.txt").write_text("private\n")
            (root / "new.ml").write_text("explicit\n")
            (root / "_build").mkdir()
            (root / "_build/cache").write_text("cache\n")
            (root / "deleted.ml").unlink(missing_ok=True)
            with patch.object(subprocess, "check_output", return_value=b"code.ml\0deleted.ml\0_build/cache\0"):
                paths = pack.source_paths(root)
                self.assertEqual([p.name for p in paths], ["code.ml"])
                self.assertEqual(paths[0].read_text(), "edited, not committed\n")
                self.assertEqual([p.name for p in pack.source_paths(root, ["new.ml"])], ["code.ml", "new.ml"])
                (root / "link").symlink_to(root / "personal.txt")
                with self.assertRaises(ValueError):
                    pack.source_paths(root, ["link"])
                with self.assertRaises(ValueError):
                    pack.source_paths(root, ["nonexistent.ml"])
            self.assertEqual((root / "_build/cache").read_text(), "cache\n")

    def test_output_validation_preserves_existing_data(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            repo = root / "repo"
            repo.mkdir()
            sentinel = repo / "keep"
            sentinel.write_bytes(b"keep")
            for bad in (repo, root, repo / "_build", root / "missing" / "out"):
                with self.subTest(path=bad), self.assertRaises(ValueError):
                    pack.output_directory(bad, repo)
            link = root / "linked"
            link.symlink_to(repo, target_is_directory=True)
            with self.assertRaises(ValueError):
                pack.output_directory(link, repo)
            self.assertEqual(pack.output_directory(repo / "dist", repo), repo / "dist")
            self.assertEqual(sentinel.read_bytes(), b"keep")

    def test_recursive_includes_reject_symlinks_before_traversal(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "repo"
            images = root / "docs/images"
            images.mkdir(parents=True)
            (images / "new.png").write_bytes(b"untracked screenshot")
            outside = Path(temp) / "outside"
            outside.mkdir()
            (outside / "private").write_text("never include")
            (images / "_build").mkdir()
            (images / "_build/ignored-link").symlink_to(outside, target_is_directory=True)
            with patch.object(subprocess, "check_output", return_value=b""):
                self.assertEqual(pack.source_paths(root, ["docs/images"]), [images / "new.png"])
                for target in (outside, images / "new.png", outside / "missing"):
                    link = images / "link"
                    link.symlink_to(target)
                    with self.subTest(target=target), self.assertRaisesRegex(ValueError, "source symlink"):
                        pack.source_paths(root, ["docs/images"])
                    link.unlink()
                (root / "linked-docs").symlink_to(root / "docs", target_is_directory=True)
                with self.assertRaisesRegex(ValueError, "source symlink"):
                    pack.source_paths(root, ["linked-docs/images/new.png"])

    def test_strip_failure_touches_only_private_copy(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            binary = root / "input"
            binary.write_bytes(b"original")
            before = (binary.read_bytes(), binary.stat().st_mtime_ns, binary.stat().st_mode)
            with tempfile.TemporaryDirectory(dir=root) as staging:
                stage = Path(staging)

                def fail_strip(command, **kwargs):
                    self.assertEqual(Path(command[-1]), stage / "ches")
                    (stage / "ches").write_bytes(b"damaged copy")
                    raise subprocess.CalledProcessError(1, command)

                with patch.object(pack.shutil, "which", return_value="/usr/bin/strip"), \
                     patch.object(pack, "run", return_value="GNU strip test"), \
                     patch.object(subprocess, "run", side_effect=fail_strip):
                    with self.assertRaises(subprocess.CalledProcessError):
                        pack.staged_binary(binary, stage, True)
            self.assertFalse(stage.exists())
            self.assertEqual(before, (binary.read_bytes(), binary.stat().st_mtime_ns, binary.stat().st_mode))

    def test_explicit_bundle_allowlist(self):
        with tempfile.TemporaryDirectory() as temp:
            p = Path(temp) / "libexample.so.1"
            p.write_bytes(b"library")
            ldd = f"libexample.so.1 => {p} (0x123)\nlibc.so.6 => /lib/libc.so.6 (0x456)"
            with patch.object(pack, "run", return_value=ldd):
                with self.assertRaises(ValueError):
                    pack.runtime_libraries(p, [])
                _, bundled = pack.runtime_libraries(p, [f"libexample.so.1={p}"])
                self.assertEqual(bundled, {"libexample.so.1": p})
                with self.assertRaises(ValueError):
                    pack.runtime_libraries(p, [f"libc.so.6={p}"])
                with self.assertRaises(ValueError):
                    pack.runtime_libraries(p, [f"unneeded.so.1={p}"])
            with patch.object(pack, "run", return_value="libfoo.so.1 => not found"):
                with self.assertRaises(ValueError):
                    pack.runtime_libraries(p, [])

    def test_jobs_hard_cap_without_build_or_output(self):
        result = subprocess.run(["python3", str(ROOT / "scripts/package_release.py"),
                                 "--version", "1.0", "--jobs", "21"], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--jobs must be in 1..20", result.stderr)


if __name__ == "__main__":
    unittest.main()
