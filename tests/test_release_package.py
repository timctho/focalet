from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
import zipfile


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

    def test_windows_manifest_requires_persistent_wsl_transport(self) -> None:
        manifest_path = self.root / "release-manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["platform"] = "windows"
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        self._write_checksums()
        with self.assertRaisesRegex(
            verify_release.ReleaseValidationError,
            "persistent WSL relay",
        ):
            verify_release.verify_package(self.root, smoke_processes=False)

        manifest["components"]["wslTransport"] = "persistent-authenticated-relay"
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        self._write_checksums()
        result = verify_release.verify_package(self.root, smoke_processes=False)
        self.assertEqual(result["platform"], "windows")

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

    def test_windows_interactive_acceptance_restores_the_deployed_app(self) -> None:
        script = (SCRIPTS / "accept-windows-capture.ps1").read_text(encoding="utf-8")
        for contract in (
            "Suspend-ConflictingZommiApplications",
            "Restore-SuspendedZommiApplications",
            "Remove-Item Env:RUNNER_TRACKING_ID",
            "Restore-SuspendedZommiApplications -ExecutablePaths $suspendedApplications",
        ):
            self.assertIn(contract, script)

    def test_windows_hover_acceptance_rejects_synthetic_resize_exit(self) -> None:
        script = (SCRIPTS / "accept-windows-capture.ps1").read_text(encoding="utf-8")
        for contract in (
            "IsOwnedWindowAtPoint",
            "GetAncestor(hit, root) == window",
            "PhysicalBounds",
            "SetThreadDpiAwarenessContext(new IntPtr(-4))",
            "SetPhysicalCursorPos",
            "WindowFromPhysicalPoint",
            "PostMouseLeaveAtPoint",
            "PostMessage(hit, mouseLeave",
            "Start-Sleep -Milliseconds 750",
            "Packaged hover expansion collapsed under a stationary pointer",
            "Could not re-arm the packaged surface hover state",
            "Packaged hover surface did not collapse after the pointer left",
        ):
            self.assertIn(contract, script)

    def test_windows_desktop_preflight_reports_runner_session_without_blame(self) -> None:
        script = (SCRIPTS / "accept-windows-capture.ps1").read_text(encoding="utf-8")
        for contract in (
            "Get-DesktopCaptureDiagnostics",
            "sessionId=$($process.SessionId)",
            "sessionName=$sessionName",
            "clientName=$clientName",
            "userInteractive=$([Environment]::UserInteractive)",
            "virtualScreen=$virtualScreen",
            "foreach ($attempt in 1..20)",
            "TryCopyDesktopPixel",
            "desktop-surface: recovered on attempt $attempt",
            "Start-Sleep -Milliseconds 250",
            "it does not prove Windows was locked",
        ):
            self.assertIn(contract, script)
        self.assertNotIn("Keep the RDP client visible and the session unlocked", script)

    def test_windows_pixel_capture_uses_the_verified_direct_gdi_path(self) -> None:
        source = (SCRIPTS.parent / "src/Zommi.Windows/ScreenCapture.cs").read_text(
            encoding="utf-8"
        )
        for contract in (
            'DllImport("user32.dll", SetLastError = true)',
            'DllImport("gdi32.dll", SetLastError = true)',
            "GetDC(nint.Zero)",
            "BitBlt(",
            "ReleaseDC(nint.Zero, desktopDc)",
            "SourceCopy",
        ):
            self.assertIn(contract, source)
        self.assertNotIn("graphics.CopyFromScreen", source)

    def test_windows_selector_forces_initial_foreground_and_stays_topmost(self) -> None:
        source = (SCRIPTS.parent / "src/Zommi.Windows/RegionSelectionForm.cs").read_text(
            encoding="utf-8"
        )
        for contract in (
            "flags |= NoActivate",
            "ForceForeground();",
            "AttachThreadInput(currentThread, foregroundThread, true)",
            "BringWindowToTop(Handle)",
            "SetForegroundWindow(Handle)",
            "topMostGuard.Start()",
        ):
            self.assertIn(contract, source)

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

    def test_macos_bundle_contains_flutter_core_manifest_and_archive(self) -> None:
        flutter_app = self.root / "input" / "Zommi.app"
        flutter_binary = flutter_app / "Contents" / "MacOS" / "Zommi"
        flutter_binary.parent.mkdir(parents=True)
        flutter_binary.write_text("flutter", encoding="utf-8")
        flutter_binary.chmod(0o755)
        framework = (
            flutter_app
            / "Contents"
            / "Frameworks"
            / "FlutterMacOS.framework"
            / "Versions"
            / "A"
            / "FlutterMacOS"
        )
        framework.parent.mkdir(parents=True)
        framework.write_text("framework", encoding="utf-8")
        core_host = self.root / "zommi-core-host"
        core_host.write_text("rust", encoding="utf-8")
        document = self.root / "README.md"
        document.write_text("release", encoding="utf-8")
        output_root = self.root / "artifacts"
        arguments = SimpleNamespace(
            platform="macos",
            architecture="x64",
            flutter_output=flutter_app,
            core_host=core_host,
            output_root=output_root,
            git_commit="macos-contract-sha",
            document=[document],
            macos_signing_identity=None,
            signing_status="unsigned",
            signing_mechanism="none",
            capture_host=None,
            linux_capture_host=None,
        )

        with mock.patch.object(
            assemble_release,
            "_sign_macos",
            return_value={"status": "ad-hoc", "mechanism": "codesign"},
        ) as sign:
            package, archive = assemble_release.assemble(arguments)

        result = verify_release.verify_package(
            package,
            expected_platform="macos",
            expected_commit="macos-contract-sha",
            smoke_processes=False,
        )
        self.assertEqual(result["entrypoint"], "Zommi.app/Contents/MacOS/Zommi")
        self.assertEqual(
            result["coreHost"],
            "Zommi.app/Contents/MacOS/zommi-core-host",
        )
        self.assertIsNone(result["captureHost"])
        self.assertEqual(result["signing"], {"status": "ad-hoc", "mechanism": "codesign"})
        manifest = json.loads((package / "release-manifest.json").read_text())
        self.assertEqual(manifest["components"]["captureProvider"], "platform-native")
        self.assertTrue((package / result["coreHost"]).stat().st_mode & 0o111)
        self.assertEqual((package / "docs" / "README.md").read_text(), "release")
        sign.assert_called_once()
        self.assertEqual(sign.call_args.args[0].name, "Zommi.app")
        self.assertIsNone(sign.call_args.args[1])

        self.assertTrue(archive.is_file())
        self.assertTrue(Path(f"{archive}.sha256").is_file())
        with zipfile.ZipFile(archive) as zipped:
            names = set(zipped.namelist())
        self.assertIn(
            "zommi-macos-x64/Zommi.app/Contents/MacOS/Zommi",
            names,
        )
        self.assertIn(
            "zommi-macos-x64/Zommi.app/Contents/MacOS/zommi-core-host",
            names,
        )

    def test_macos_distribution_signing_requests_hardened_runtime(self) -> None:
        application = self.root / "Zommi.app"
        identity = "Developer ID Application: Zommi Test"
        with mock.patch.object(assemble_release.subprocess, "run") as run:
            result = assemble_release._sign_macos(application, identity)

        self.assertEqual(
            result,
            {"status": "distribution-signed", "mechanism": "codesign"},
        )
        self.assertEqual(run.call_count, 2)
        self.assertEqual(
            run.call_args_list[0].args[0],
            [
                "codesign",
                "--force",
                "--deep",
                "--sign",
                identity,
                "--options",
                "runtime",
                "--timestamp",
                str(application),
            ],
        )
        self.assertEqual(
            run.call_args_list[1].args[0],
            ["codesign", "--verify", "--deep", "--strict", str(application)],
        )

    def test_macos_without_identity_is_ad_hoc_signed_and_verified(self) -> None:
        application = self.root / "Zommi.app"
        with mock.patch.object(assemble_release.subprocess, "run") as run:
            result = assemble_release._sign_macos(application, None)

        self.assertEqual(result, {"status": "ad-hoc", "mechanism": "codesign"})
        self.assertEqual(
            run.call_args_list[0].args[0],
            [
                "codesign",
                "--force",
                "--deep",
                "--sign",
                "-",
                str(application),
            ],
        )
        self.assertEqual(
            run.call_args_list[1].args[0],
            ["codesign", "--verify", "--deep", "--strict", str(application)],
        )

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
