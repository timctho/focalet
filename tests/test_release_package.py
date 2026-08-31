from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock


SCRIPTS = Path(__file__).parents[1] / "scripts"


def _load_script(name: str):
    script = SCRIPTS / f"{name}.py"
    spec = importlib.util.spec_from_file_location(name, script)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


verify_release = _load_script("verify_release")
assemble_release = _load_script("assemble_release")


class ReleasePackageTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="zommi-release-test-")
        self.root = Path(self.temporary.name)
        (self.root / "zommi").write_text(
            "#!/bin/sh\nLD_LIBRARY_PATH=lib exec ./zommi-bin\n", encoding="utf-8"
        )
        (self.root / "zommi-bin").write_text("flutter", encoding="utf-8")
        (self.root / "zommi-core-host").write_text("rust", encoding="utf-8")
        (self.root / "zommi-x11-capture").write_text("x11", encoding="utf-8")
        for relative in verify_release.LINUX_RUNTIME_LIBRARIES:
            library = self.root / relative
            library.parent.mkdir(parents=True, exist_ok=True)
            library.write_text("runtime", encoding="utf-8")
        manifest = {
            "schemaVersion": 1,
            "product": "Zommi",
            "gitCommit": "abc123",
            "platform": "linux",
            "architecture": "x64",
            "entrypoint": "zommi",
            "coreHost": "zommi-core-host",
            "captureHost": "zommi-x11-capture",
            "components": {
                "desktopUi": "flutter",
                "runtimeCore": "rust",
                "captureProvider": "platform-native",
            },
            "signing": {"status": "unsigned", "mechanism": "none"},
        }
        (self.root / "release-manifest.json").write_text(
            json.dumps(manifest), encoding="utf-8"
        )
        self._write_checksums()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _write_checksums(self) -> None:
        lines = []
        for path in sorted(self.root.rglob("*")):
            if not path.is_file() or path.name == "SHA256SUMS.txt":
                continue
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            lines.append(f"{digest}  {path.relative_to(self.root).as_posix()}")
        (self.root / "SHA256SUMS.txt").write_text(
            "\n".join(lines) + "\n", encoding="ascii"
        )

    def test_valid_flutter_rust_inventory_passes(self) -> None:
        result = verify_release.verify_package(
            self.root,
            expected_platform="linux",
            expected_commit="abc123",
            smoke_processes=False,
        )
        self.assertEqual(result["entrypoint"], "zommi")
        self.assertEqual(result["captureHost"], "zommi-x11-capture")
        self.assertEqual(result["files"], 5 + len(verify_release.LINUX_RUNTIME_LIBRARIES))

    def test_missing_linux_runtime_library_is_rejected(self) -> None:
        (self.root / verify_release.LINUX_RUNTIME_LIBRARIES[0]).unlink()
        self._write_checksums()
        with self.assertRaisesRegex(
            verify_release.ReleaseValidationError,
            "Bundled Linux runtime library is missing",
        ):
            verify_release.verify_package(self.root, smoke_processes=False)

    def test_missing_linux_capture_host_is_rejected(self) -> None:
        (self.root / "zommi-x11-capture").unlink()
        self._write_checksums()
        with self.assertRaisesRegex(
            verify_release.ReleaseValidationError,
            "Linux capture host is missing",
        ):
            verify_release.verify_package(self.root, smoke_processes=False)

    def test_linux_capture_smoke_uses_display_independent_probe(self) -> None:
        completed = mock.Mock(
            returncode=0,
            stdout='{"ok":true,"providers":["x11","wayland-portal"]}\n',
            stderr="",
        )
        with mock.patch.object(verify_release.subprocess, "run", return_value=completed) as run:
            verify_release._smoke_linux_capture(self.root / "zommi-x11-capture")
        run.assert_called_once_with(
            [str(self.root / "zommi-x11-capture"), "probe"],
            text=True,
            capture_output=True,
            timeout=15,
            check=False,
        )

    def test_linux_launcher_must_load_bundled_libraries(self) -> None:
        (self.root / "zommi").write_text("#!/bin/sh\nexec ./zommi-bin\n", encoding="utf-8")
        self._write_checksums()
        with self.assertRaisesRegex(
            verify_release.ReleaseValidationError,
            "does not load bundled runtime libraries",
        ):
            verify_release.verify_package(self.root, smoke_processes=False)

    def test_tampered_file_fails_checksum_validation(self) -> None:
        (self.root / "zommi-core-host").write_text("tampered", encoding="utf-8")
        with self.assertRaisesRegex(verify_release.ReleaseValidationError, "Checksum mismatch"):
            verify_release.verify_package(self.root, smoke_processes=False)

    def test_electron_payload_is_rejected_even_when_checksummed(self) -> None:
        legacy = self.root / "resources" / "app" / "main.mjs"
        legacy.parent.mkdir(parents=True)
        legacy.write_text("electron", encoding="utf-8")
        self._write_checksums()
        with self.assertRaisesRegex(verify_release.ReleaseValidationError, "Legacy Electron"):
            verify_release.verify_package(self.root, smoke_processes=False)

    def test_manifest_component_cannot_escape_package_root(self) -> None:
        manifest_path = self.root / "release-manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["coreHost"] = "../outside-core"
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        self._write_checksums()
        with self.assertRaisesRegex(verify_release.ReleaseValidationError, "escapes"):
            verify_release.verify_package(self.root, smoke_processes=False)


class ReleaseAssemblyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="zommi-assembly-test-")
        self.root = Path(self.temporary.name)
        self.pending = self.root / "pending"
        self.destination = self.root / "zommi-windows-x64"
        self.pending.mkdir()
        self.destination.mkdir()
        (self.pending / "identity.txt").write_text("new", encoding="utf-8")
        (self.destination / "identity.txt").write_text("old", encoding="utf-8")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_directory_replacement_is_complete(self) -> None:
        assemble_release._replace_directory(self.pending, self.destination)
        self.assertEqual(
            (self.destination / "identity.txt").read_text(encoding="utf-8"),
            "new",
        )
        self.assertFalse(self.pending.exists())
        self.assertEqual(list(self.root.glob(".*-previous-*")), [])

    def test_transient_windows_rename_is_retried(self) -> None:
        source = self.root / "rename-source"
        destination = self.root / "rename-destination"
        source.write_text("complete", encoding="utf-8")
        real_replace = type(source).replace
        calls = 0

        def fail_once(path, target):
            nonlocal calls
            calls += 1
            if calls == 1:
                raise PermissionError("transient scanner lock")
            return real_replace(path, target)

        with (
            mock.patch.object(assemble_release.os, "name", "nt"),
            mock.patch.object(
                type(source),
                "replace",
                autospec=True,
                side_effect=fail_once,
            ),
            mock.patch.object(assemble_release.time, "sleep") as sleep,
        ):
            assemble_release._replace_path(source, destination)

        self.assertEqual(destination.read_text(encoding="utf-8"), "complete")
        self.assertEqual(calls, 2)
        sleep.assert_called_once_with(0.05)

    def test_locked_destination_is_left_unchanged(self) -> None:
        real_replace = type(self.destination).replace

        def fail_destination(path, target):
            if path == self.destination:
                raise PermissionError("locked working directory")
            return real_replace(path, target)

        with mock.patch.object(
            type(self.destination),
            "replace",
            autospec=True,
            side_effect=fail_destination,
        ):
            with self.assertRaisesRegex(RuntimeError, "was left unchanged"):
                assemble_release._replace_directory(self.pending, self.destination)

        self.assertEqual(
            (self.destination / "identity.txt").read_text(encoding="utf-8"),
            "old",
        )
        self.assertEqual(
            (self.pending / "identity.txt").read_text(encoding="utf-8"),
            "new",
        )
        self.assertEqual(list(self.root.glob(".*-previous-*")), [])

    def test_locked_previous_package_is_restored(self) -> None:
        real_rmtree = assemble_release.shutil.rmtree

        def fail_previous(path, *args, **kwargs):
            if "-previous-" in Path(path).name:
                raise PermissionError("locked executable")
            return real_rmtree(path, *args, **kwargs)

        with mock.patch.object(
            assemble_release.shutil,
            "rmtree",
            side_effect=fail_previous,
        ):
            with self.assertRaisesRegex(RuntimeError, "original package was restored"):
                assemble_release._replace_directory(self.pending, self.destination)

        self.assertEqual(
            (self.destination / "identity.txt").read_text(encoding="utf-8"),
            "old",
        )
        self.assertEqual(list(self.root.glob(".*-previous-*")), [])
        self.assertEqual(list(self.root.glob(".*-failed-*")), [])


if __name__ == "__main__":
    unittest.main()
