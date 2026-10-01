#!/usr/bin/env python3
"""Run the same credential-free checks locally and on disposable PR runners."""

import argparse
import contextlib
import ctypes.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FLUTTER = ROOT / "src/Zommi.Flutter"
SUITES = ("rust", "flutter", "contracts", "capture", "browser", "windows")
_check_environment = None


def isolated_runtime_environment(directory, inherited):
    # Retain toolchain/OS variables while removing runtime overrides inherited
    # from the developer's interactive Zommi session. Each fixture opts in its
    # own command/endpoint; automatic PATH and WSL discovery are disabled.
    environment = {
        key: value
        for key, value in inherited.items()
        if not key.startswith(
            (
                "ZOMMI_CODEX_",
                "ZOMMI_PI_",
                "ZOMMI_HERMES_",
                "ZOMMI_OPENCLAW_",
                "ZOMMI_OPENCODE_",
                "ZOMMI_GEMINI_",
                "ZOMMI_CLAUDE_",
                "ZOMMI_FAKE_",
            )
        )
    }
    environment.update(
        {
            "ZOMMI_RUNTIME_DISCOVERY_MODE": "configured-only",
            "ZOMMI_CORE_STATE_PATH": str(Path(directory, "binding.json")),
            "ZOMMI_RUNTIME_OVERRIDES_PATH": str(Path(directory, "overrides.json")),
            "ZOMMI_RUNTIME_DISCOVERY_CACHE_PATH": str(Path(directory, "targets.json")),
            "ZOMMI_OPENCLAW_DEVICE_IDENTITY_PATH": str(Path(directory, "device.json")),
        }
    )
    return environment


def run(*command, cwd=ROOT, env=None):
    executable = shutil.which(str(command[0]))
    if not executable:
        raise RuntimeError(
            f"Missing {command[0]}; see CONTRIBUTING.md for prerequisites."
        )
    print("+ " + " ".join(map(str, command)), flush=True)
    subprocess.run(
        [executable, *map(str, command[1:])],
        cwd=cwd,
        env=env if env is not None else _check_environment,
        check=True,
    )


@contextlib.contextmanager
def flutter_environment():
    """Resolve SQLite for Dart FFI without changing a contributor's system."""
    environment = dict(_check_environment or os.environ)
    if not sys.platform.startswith("linux"):
        yield environment
        return
    library = ctypes.util.find_library("sqlite3")
    if not library:
        raise RuntimeError(
            "SQLite is missing. Install libsqlite3-dev (see CONTRIBUTING.md)."
        )
    # Minimal distributions may have libsqlite3.so.0 but no linker alias.
    with tempfile.TemporaryDirectory(prefix="zommi-test-sqlite-") as directory:
        Path(directory, "libsqlite3.so").symlink_to(library)
        # A relative symlink to a soname is not resolvable by the loader: use its
        # actual location from ldconfig when only the versioned library exists.
        alias = Path(directory, "libsqlite3.so")
        if not alias.exists():
            ldconfig = shutil.which("ldconfig") or "/sbin/ldconfig"
            inventory = subprocess.check_output([ldconfig, "-p"], text=True)
            matches = [
                line.split("=>", 1)[1].strip()
                for line in inventory.splitlines()
                if line.strip().split(" ", 1)[0] == library and "=>" in line
            ]
            if not matches:
                raise RuntimeError("Cannot locate SQLite; install libsqlite3-dev.")
            alias.unlink()
            alias.symlink_to(matches[0])
        environment["LD_LIBRARY_PATH"] = os.pathsep.join(
            filter(
                None,
                [
                    directory,
                    environment.get("LD_LIBRARY_PATH"),
                ],
            )
        )
        yield environment


def check_rust():
    packages = (
        ["-p", "zommi-core", "-p", "zommi-core-host"]
        if sys.platform != "linux"
        else ["--workspace"]
    )
    run("cargo", "fmt", "--all", "--", "--check")
    run(
        "cargo",
        "clippy",
        "--locked",
        *packages,
        "--all-targets",
        "--",
        "-D",
        "warnings",
    )
    run("cargo", "test", "--locked", *packages, "--all-targets")
    # Dart/Python integration tests launch the real broker with fake runtimes.
    run(
        "cargo",
        "build",
        "--locked",
        "-p",
        "zommi-core-host",
        "--bin",
        "zommi-core-host",
    )


def check_flutter(*tests):
    suffix = ".exe" if os.name == "nt" else ""
    if not (ROOT / f"target/debug/zommi-core-host{suffix}").is_file():
        raise RuntimeError(
            "Build the broker first: python scripts/check.py --suite rust"
        )
    run("flutter", "pub", "get", "--enforce-lockfile", cwd=FLUTTER)
    run(
        "dart",
        "format",
        "--output=none",
        "--set-exit-if-changed",
        "lib",
        "test",
        cwd=FLUTTER,
    )
    run("flutter", "analyze", "--no-pub", cwd=FLUTTER)
    with flutter_environment() as environment:
        run(
            "flutter",
            "test",
            "--no-pub",
            "--concurrency=4",
            "--reporter=expanded",
            *tests,
            cwd=FLUTTER,
            env=environment,
        )


def check_contracts():
    run(sys.executable, "scripts/verify_demo_assets.py")
    run(
        sys.executable,
        "-m",
        "unittest",
        "discover",
        "-s",
        "tests",
        "-p",
        "test_*.py",
        "-v",
    )
    run("node", "--check", "scripts/zommi-wsl-relay.js")
    run("node", "--test", "tests/wsl_relay.test.mjs")
    check_shell_scripts()


def check_shell_scripts(directory=ROOT):
    # bash accepts one script; further paths are arguments to that script.
    for path in sorted((directory / "scripts").glob("*.sh")):
        run("bash", "-n", path.relative_to(directory), cwd=directory)


def check_capture():
    run(
        "dotnet",
        "run",
        "--project",
        "tests/Zommi.Capture.Tests",
        "--configuration",
        "Release",
    )
    run(
        "dotnet",
        "build",
        "src/Zommi.Windows/Zommi.Windows.csproj",
        "--configuration",
        "Release",
    )
    run(
        "dotnet",
        "run" if os.name == "nt" else "build",
        *(["--project"] if os.name == "nt" else []),
        "tests/Zommi.Windows.Tests/Zommi.Windows.Tests.csproj",
        "--configuration",
        "Release",
    )


def check_windows():
    if os.name != "nt":
        raise RuntimeError("The windows suite requires Windows.")
    check_rust()
    # Linux runs every widget/golden test. Windows additionally exercises native
    # process launching, paths, SQLite, capture channels and notification logic.
    tests = sorted(
        str(path.relative_to(FLUTTER))
        for path in (FLUTTER / "test").glob("*process_test.dart")
    )
    tests += [
        f"test/{name}_test.dart"
        for name in (
            "desktop_bridge",
            "core_host_resolution",
            "sqlite_session_catalog",
            "session_catalog_cache",
            "response_notifications",
            "document_preview",
            "document_preview_thumbnail",
            "runtime_environment",
            "runtime_order",
            "capture_shortcut",
            "first_run_setup",
        )
    ]
    check_flutter(*tests)
    run(sys.executable, "-m", "unittest", "discover", "-s", "tests", "-p", "test_claude_runtime.py", "-v")
    run(sys.executable, "-m", "unittest", "discover", "-s", "tests", "-p", "test_acp_startup.py", "-v")
    run(sys.executable, "-m", "unittest", "discover", "-s", "tests", "-p", "test_windows_relay_reset.py", "-v")
    check_capture()
    run("pwsh", "-NoProfile", "-File", "scripts/test-windows-deployment-helpers.ps1")


def main():
    global _check_environment
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--suite",
        choices=SUITES,
        action="append",
        help="May repeat; default: rust, flutter, contracts, capture, browser",
    )
    args = parser.parse_args()
    suites = args.suite or list(SUITES[:-1])
    checks = {
        "rust": check_rust,
        "flutter": check_flutter,
        "contracts": check_contracts,
        "capture": check_capture,
        "browser": lambda: run("bash", "scripts/test-browser-capture.sh"),
        "windows": check_windows,
    }
    try:
        with tempfile.TemporaryDirectory(prefix="zommi-checks-") as directory:
            _check_environment = isolated_runtime_environment(directory, os.environ)
            for suite in suites:
                print(f"\nChecking {suite}", flush=True)
                checks[suite]()
    except (RuntimeError, subprocess.CalledProcessError, OSError) as error:
        print(f"Check failed: {error}", file=sys.stderr)
        return 1
    print("\nAll requested checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
