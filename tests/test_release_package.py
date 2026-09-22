from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import tarfile
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

    def test_windows_icon_path_changes_when_icon_bytes_change(self) -> None:
        icon = self.root / "data/flutter_assets/windows/runner/resources/app_icon.ico"
        icon.parent.mkdir(parents=True)
        names = []
        for content in (b"previous-icon", b"ocean-icon"):
            icon.write_bytes(content)
            assemble_release._write_manifest(
                self.root, target_platform="windows", architecture="x64",
                commit="a" * 40, entrypoint="Zommi.exe", core_host="zommi-core-host.exe",
                capture_host="native/Zommi.Capture.exe", signing={"status": "unsigned"},
            )
            name = json.loads((self.root / "release-manifest.json").read_text())["icon"]
            self.assertEqual((self.root / name).read_bytes(), content)
            names.append(name)
        self.assertNotEqual(*names)

    def test_licensed_package_cannot_omit_notices_even_with_valid_checksums(self) -> None:
        manifest_path = self.root / "release-manifest.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["license"] = "Apache-2.0"
        manifest_path.write_text(json.dumps(manifest))
        assemble_release._copy_licenses(self.root)
        for relative in verify_release.LICENSE_DOCUMENTS:
            with self.subTest(document=relative):
                path = self.root / relative
                content = path.read_bytes()
                path.unlink()
                self._write_checksums()
                with self.assertRaisesRegex(
                    verify_release.ReleaseValidationError, "License document is missing"
                ):
                    verify_release.verify_package(self.root, smoke_processes=False)
                path.write_bytes(content)

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
        with self.assertRaisesRegex(
            verify_release.ReleaseValidationError, "Bundled Windows runtime library is missing"
        ):
            verify_release.verify_package(self.root, smoke_processes=False)
        for name in verify_release.WINDOWS_RUNTIME_LIBRARIES:
            (self.root / name).write_text("redistributable", encoding="utf-8")
        self._write_checksums()
        with self.assertRaisesRegex(verify_release.ReleaseValidationError, "vcruntime140_1"):
            verify_release.verify_package(self.root, smoke_processes=False)
        (self.root / "vcruntime140_1.dll").write_text("redistributable", encoding="utf-8")
        self._write_checksums()
        result = verify_release.verify_package(self.root, smoke_processes=False)
        self.assertEqual(result["platform"], "windows")

        manifest["components"]["windowsReset"] = "owned-profile-reset"
        manifest_path.write_text(json.dumps(manifest))
        self._write_checksums()
        with self.assertRaisesRegex(verify_release.ReleaseValidationError, "Windows reset helper is missing"):
            verify_release.verify_package(self.root, smoke_processes=False)
        for name in ("stop-zommi-relays.ps1", "stop-zommi-relay.sh"):
            helper = self.root / "support" / name
            helper.parent.mkdir(exist_ok=True)
            helper.write_text("reset helper")
        self._write_checksums()
        verify_release.verify_package(self.root, smoke_processes=False)

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

    def test_windows_acceptance_requires_stable_taskbar_lifecycle(self) -> None:
        script = (SCRIPTS / "accept-windows-capture.ps1").read_text(encoding="utf-8")
        for contract in (
            "TaskbarEligible",
            "const int toolWindow = 0x00000080",
            "const int appWindow = 0x00040000",
            "GetWindow(window, owner)",
            "PhysicalBounds",
            "SetThreadDpiAwarenessContext(new IntPtr(-4))",
            "SetPhysicalCursorPos",
            "Start-Sleep -Milliseconds 750",
            "Packaged application did not start as a complete taskbar chat window",
            "Taskbar window resized on hover",
            "Taskbar window resized after pointer exit",
            "Rapid Max/Restore lost the last requested normal placement",
            "native-max-restore: ok (rapid commands retain the last requested placement)",
            "Packaged taskbar window did not minimize",
            "Packaged taskbar window did not restore",
            "Could not minimize Zommi before the Alt+A restore gate",
            "Cancelled Alt+A did not restore, show, and focus the minimized packaged taskbar window",
            "minimizedImageShortcutRestored = $true",
            "Packaged taskbar window unexpectedly remained always-on-top",
        ):
            self.assertIn(contract, script)

    def test_windows_capture_acceptance_isolates_saved_window_preferences(self) -> None:
        script = (SCRIPTS / "accept-windows-capture.ps1").read_text(encoding="utf-8")
        application_gate = script.split(
            "function Invoke-PackagedApplicationAcceptance {", 1
        )[1].split("function Read-PngDimension {", 1)[0]
        for contract in (
            "$acceptanceProfile = Join-Path $env:TEMP",
            "[IO.Directory]::CreateDirectory((Join-Path $acceptanceProfile 'Zommi'))",
            "'Zommi\\settings.json'",
            '\"runtimeSetupCompleted\":true',
            "$start.EnvironmentVariables['APPDATA'] = $acceptanceProfile",
            "Packaged application did not start in the isolated normal window mode",
        ):
            self.assertIn(contract, application_gate)
        self.assertLess(
            application_gate.index("$start.EnvironmentVariables['APPDATA']"),
            application_gate.index("$application.Start()"),
        )

    def test_windows_maximize_respects_the_active_monitor_work_area(self) -> None:
        source = (
            SCRIPTS.parent
            / "src/Zommi.Flutter/windows/runner/flutter_window.cpp"
        ).read_text(encoding="utf-8")
        for contract in (
            "WM_GETMINMAXINFO",
            "MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST)",
            "monitor_info.rcWork",
            "work_area.left - monitor_area.left",
            "work_area.top - monitor_area.top",
            "limits->ptMaxSize",
        ):
            self.assertIn(contract, source)
        self.assertLess(
            source.index("HandleTopLevelWindowProc("),
            source.index("message == WM_GETMINMAXINFO"),
        )
        script = (SCRIPTS / "accept-windows-capture.ps1").read_text(encoding="utf-8")
        for contract in (
            "Maximize did not respect the active monitor work area",
            "Restoring Maximize did not retain the previous normal window size",
            "maximizedToWorkArea = $true",
        ):
            self.assertIn(contract, script)

    def test_windows_size_acceptance_tracks_rendered_control_pixels(self) -> None:
        script = (SCRIPTS / "accept-windows-window-size.ps1").read_text(encoding="utf-8")
        for contract in (
            "-HelpersOnly",
            "Assert-DesktopCaptureSurface",
            "[ZommiWindowsAcceptanceNative]::SendAltA($false)",
            "IsOwnedWindowAtPoint($window, $left, $top)",
            "ZommiWindowSizeAccess]::Sample($window, 3000)",
            "retained-frame-without-animation",
            "Partial resized frame appeared",
            "$atOldFrame -and -not $atNewFrame",
            "NativeAnimationsEnabled()",
            "[ZommiRenderedSizeProbe]::Area = $workArea",
            "PhysicalClientBounds($window)",
            "ZommiRenderedSizeProbe.CaptureDeferred()",
            "ZommiRenderedSizeProbe.AnalyzeDeferred(pending[index], frames[index].elapsedMs)",
            "foreach (var captured in pending) captured.Dispose()",
            "Rendered control disappeared",
            "Rendered control duplicated",
            "duplicate-frame fixture",
            "Rendered control jumped outside its endpoints",
            "Rendered control reversed direction",
            "windows-desktop-frame.cs",
            "dxgi-desktop-duplication",
            "[ZommiRenderedSizeProbe]::Dispose()",
            "did not settle within the sampled interval",
            "jumped outside its endpoints",
            "reversed direction",
            "native Restore retains pre-Max placement",
            "native Restore redraws the previous panel",
            "Measure-SizeTransition 'Restore' 'standard' -NativeRestore",
            "lost foreground ownership",
            "Restore-SuspendedZommiApplications",
        ):
            self.assertIn(contract, script)
        visual_probe = (SCRIPTS / "windows-size-visual-probe.cs").read_text(encoding="utf-8")
        for contract in ("desktop.Capture()", "LockBits", "FindMarker", "bitmap.Dispose()"):
            self.assertIn(contract, visual_probe)
        self.assertNotIn("BitBlt", visual_probe)
        desktop_capture = (SCRIPTS / "windows-desktop-frame.cs").read_text(encoding="utf-8")
        for contract in ("DuplicateOutput", "AcquireFrame", "CopyRegion", "MapTexture", "ReleaseFrame", "SetThreadDpiAwarenessContext", "Dispose()"):
            self.assertIn(contract, desktop_capture)
        workflow = (SCRIPTS.parent / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        self.assertIn("shell: pwsh", workflow)
        self.assertIn("#requires -Version 7.0", script)
        self.assertIn("accept-windows-window-size.ps1", workflow)
        self.assertIn("-CaptureBackend Gdi", workflow)

    def test_windows_size_cpu_observer_does_not_claim_presentation_time(self) -> None:
        script = (SCRIPTS / "accept-windows-window-size.ps1").read_text(encoding="utf-8")
        for contract in (
            "windows-desktop-frame-gdi.cs",
            "gdi-copy-completion-qpc-from-input-release",
            "$firstMotionMs = $frame.captureCompletedMs",
            "captureStartedMs",
            "captureCompletedMs",
        ):
            self.assertIn(contract, script)
        capture = (SCRIPTS / "windows-desktop-frame-gdi.cs").read_text(encoding="utf-8")
        self.assertIn("PresentationTimestamp { get { return 0; } }", capture)
        self.assertIn("BitBlt(target", capture)
        self.assertIn("SetThreadDpiAwarenessContext", capture)
        self.assertIn("frame.Bitmap = null", capture)
        self.assertNotIn("D3D11", capture)
        self.assertNotIn("dxgi", capture)

    def test_windows_size_acceptance_checks_background_and_response_latency(self) -> None:
        script = (SCRIPTS / "accept-windows-window-size.ps1").read_text(encoding="utf-8")
        for contract in (
            "windows-size-background.cs",
            "[ZommiSizeBackground]::new",
            "background = ZommiRenderedSizeProbe.LastBackground",
            "$maximumBackgroundChange -gt 3",
            "$firstMotionMs -gt 250",
            "$settledMs -gt 800",
            "interactionClock = Stopwatch.StartNew()",
            "interactionStarted = Stopwatch.GetTimestamp()",
            "$firstMotionMs = $frame.presentedMs",
            "$firstObservedMotionMs = $frame.elapsedMs",
            "$firstMotionMs -lt 0",
            "Panel background flashed",
            "$background.Dispose()",
        ):
            self.assertIn(contract, script)
        visual_probe = (SCRIPTS / "windows-size-visual-probe.cs").read_text(encoding="utf-8")
        self.assertIn("Background(bitmap, marker)", visual_probe)
        self.assertNotIn("elapsed < 1200", visual_probe)

    def test_windows_acceptance_allows_only_already_exited_processes(self) -> None:
        script = (SCRIPTS / "accept-windows-capture.ps1").read_text(encoding="utf-8")
        self.assertIn("Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop", script)
        self.assertIn(
            "if (Get-Process -Id $process.ProcessId -ErrorAction SilentlyContinue) { throw }",
            script,
        )

    def test_windows_size_capture_defers_readback_without_dropping_frames(self) -> None:
        script = (SCRIPTS / "accept-windows-window-size.ps1").read_text(encoding="utf-8")
        self.assertLess(script.index("while (clock.ElapsedMilliseconds < duration)"), script.index("ZommiRenderedSizeProbe.AnalyzeDeferred"))
        self.assertIn("for (var index = 0; index < pending.Count; index++)", script)
        self.assertIn("frames[index].processedMs = clock.ElapsedMilliseconds", script)
        capture = (SCRIPTS / "windows-desktop-frame.cs").read_text(encoding="utf-8")
        deferred = capture.split("public DeferredFrame CaptureDeferred()", 1)[1].split("public System.Drawing.Bitmap ReadFrame", 1)[0]
        self.assertIn("CopyRegion", deferred)
        self.assertIn("FlushContext", deferred)
        self.assertNotIn("MapTexture", deferred)
        self.assertNotIn("readbackTexture", deferred)
        self.assertIn("Usage = 0, CpuAccessFlags = 0", capture)
        self.assertIn("Method<CopyTexture>(context, 47)(context, readbackTexture, frame.Texture)", capture)
        self.assertIn("Release(ref readbackTexture)", capture)
        self.assertIn("Marshal.AddRef(lastTexture)", capture)

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

    def test_windows_size_background_pumps_messages_on_its_own_thread(self) -> None:
        background = (SCRIPTS / "windows-size-background.cs").read_text(encoding="utf-8")
        for contract in (
            "new System.Threading.Thread",
            "GetMessage(out message",
            "DispatchMessage(ref message)",
            "ready.WaitOne(10000)",
            "PostThreadMessage(threadId",
            "thread.Join(5000)",
        ):
            self.assertIn(contract, background)

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
        native = SCRIPTS.parent / "src/Zommi.Windows"
        region = (native / "RegionSelectionForm.cs").read_text(encoding="utf-8")
        content = (native / "ContentSelectionForm.cs").read_text(encoding="utf-8")
        self.assertIn(": ContentSelectionForm(returnProcessId, capturedDesktop, 1, theme)", region)
        self.assertIn("base.OnShown(e);", region)
        self.assertIn("ContentSelectionForm : PointSelectionForm", content)
        # Both selectors inherit foreground ownership from the shared form.
        source = (native / "PointSelectionForm.cs").read_text(encoding="utf-8")
        for contract in (
            "flags |= NoActivate",
            "ForceForeground();",
            "AttachThreadInput(currentThread, foregroundThread, true)",
            "BringWindowToTop(Handle)",
            "SetForegroundWindow(Handle)",
            "topMostGuard.Start()",
        ):
            self.assertIn(contract, source)

    def test_windows_point_context_uses_a_crosshair_and_clicked_target(self) -> None:
        source = (SCRIPTS.parent / "src/Zommi.Windows/PointSelectionForm.cs").read_text(
            encoding="utf-8"
        )
        host = (SCRIPTS.parent / "src/Zommi.Windows/CaptureNativeHost.cs").read_text(
            encoding="utf-8"
        )
        acceptance = (SCRIPTS / "accept-windows-capture.ps1").read_text(
            encoding="utf-8"
        )
        for contract in (
            "Cursor = Cursors.Cross",
            "Result = Cursor.Position",
            "Click the content to select",
            "Zommi context scope",
            "AttachThreadInput(currentThread, foregroundThread, true)",
            "ForceForeground();",
        ):
            self.assertIn(contract, source)
        self.assertIn('case "selectContext"', host)
        self.assertIn("CrosshairCursorActive", acceptance)
        self.assertIn("Opacity = 0.28", source)
        self.assertNotIn("TransparencyKey", source)
        self.assertIn(
            "Context point selector lost pointer ownership after painting.",
            acceptance,
        )
        click = acceptance.split("public static bool ClickSelection(", 1)[1].split(
            "public static uint WindowDpi", 1
        )[0]
        self.assertIn("IsOwnedWindowAtPoint", click)
        self.assertIn("mouse_event(leftDown", click)
        self.assertNotIn("SendMessage", click)
        self.assertIn("$cursorClock.ElapsedMilliseconds -lt 5000", acceptance)
        self.assertIn("Context point selector did not expose its crosshair cursor.", acceptance)
        self.assertIn("point-context: ok (crosshair, click, parent and smaller scope)", acceptance)

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

    def assert_license_payload(self, directory: Path) -> None:
        for source, relative in assemble_release.LICENSE_FILES.items():
            self.assertEqual(
                (directory / relative).read_bytes(),
                (SCRIPTS.parent / source).read_bytes(),
                relative,
            )

    def test_windows_and_linux_archives_include_project_and_third_party_licenses(self) -> None:
        for platform in ("windows", "linux"):
            with self.subTest(platform=platform):
                inputs = self.root / platform
                flutter = inputs / "flutter"
                flutter.mkdir(parents=True)
                entrypoint = "Zommi.exe" if platform == "windows" else "zommi"
                (flutter / entrypoint).write_text("flutter")
                libraries = (
                    (*verify_release.WINDOWS_RUNTIME_LIBRARIES, "vcruntime140_1.dll")
                    if platform == "windows" else verify_release.LINUX_RUNTIME_LIBRARIES
                )
                for relative in libraries:
                    library = flutter / relative
                    library.parent.mkdir(parents=True, exist_ok=True)
                    library.write_text("runtime")
                core = inputs / "core"
                core.write_text("rust")
                capture = inputs / "capture"
                capture.mkdir()
                capture_binary = capture / "Zommi.Capture.exe"
                capture_binary.write_text("capture")
                package, archive = assemble_release.assemble(SimpleNamespace(
                    platform=platform, architecture="x64", flutter_output=flutter,
                    core_host=core, capture_host=capture, linux_capture_host=capture_binary,
                    output_root=inputs / "output", git_commit="license-contract-sha",
                    document=[], signing_status="unsigned", signing_mechanism="none",
                ))
                self.assert_license_payload(package)
                self.assertEqual(
                    json.loads((package / "release-manifest.json").read_text())["license"],
                    "Apache-2.0",
                )
                verify_release.verify_package(package, smoke_processes=False)
                if platform == "windows":
                    with zipfile.ZipFile(archive) as bundle:
                        names = bundle.namelist()
                else:
                    with tarfile.open(archive) as bundle:
                        names = bundle.getnames()
                for relative in verify_release.LICENSE_DOCUMENTS:
                    self.assertIn(f"{package.name}/{relative}", names)

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

        def sign_with_notices(application, identity):
            self.assert_license_payload(application / "Contents/Resources")
            return {"status": "ad-hoc", "mechanism": "codesign"}

        with mock.patch.object(
            assemble_release,
            "_sign_macos",
            side_effect=sign_with_notices,
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
        self.assert_license_payload(package / "Zommi.app/Contents/Resources")

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
        for relative in verify_release.LICENSE_DOCUMENTS:
            self.assertIn(
                f"zommi-macos-x64/Zommi.app/Contents/Resources/{relative}", names
            )

    def test_macos_distribution_signing_requests_hardened_runtime(self) -> None:
        application = self.root / "Zommi.app"
        identity = "Developer ID Application: Zommi Test"
        with mock.patch.object(assemble_release.subprocess, "run") as run:
            run.return_value.stderr = f"Authority={identity}\nTeamIdentifier=TESTTEAM\n"
            result = assemble_release._sign_macos(application, identity)

        self.assertEqual(
            result,
            {"status": "distribution-signed", "mechanism": "codesign",
             "teamIdentifier": "TESTTEAM", "authority": identity},
        )
        self.assertEqual(run.call_count, 3)
        self.assertEqual(
            run.call_args_list[0].args[0],
            [
                "codesign",
                "--force",
                "--deep",
                "--sign",
                identity,
                "--preserve-metadata=entitlements",
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

    def test_macos_development_certificate_is_not_reported_as_distribution(self) -> None:
        with mock.patch.object(assemble_release.subprocess, "run") as run:
            run.return_value.stderr = (
                "Authority=Apple Development: Test (TESTTEAM)\n"
                "Authority=Apple Worldwide Developer Relations Certification Authority\n"
                "TeamIdentifier=TESTTEAM\n"
            )
            result = assemble_release._sign_macos(self.root / "Zommi.app", "certificate-hash")
        self.assertEqual(result["status"], "development-signed")
        self.assertEqual(result["teamIdentifier"], "TESTTEAM")
        self.assertEqual(result["authority"], "Apple Development: Test (TESTTEAM)")

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
