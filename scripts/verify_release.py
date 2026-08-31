#!/usr/bin/env python3
"""Validate and smoke-test an assembled Zommi native release directory."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
from typing import Any


class ReleaseValidationError(RuntimeError):
    pass


LINUX_RUNTIME_LIBRARIES = (
    "lib/libayatana-appindicator3.so.1",
    "lib/libayatana-indicator3.so.7",
    "lib/libdbusmenu-glib.so.4",
    "lib/libdbusmenu-gtk3.so.4",
)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _inside(root: Path, relative: str, label: str) -> Path:
    candidate = (root / relative).resolve()
    try:
        candidate.relative_to(root.resolve())
    except ValueError as error:
        raise ReleaseValidationError(f"{label} escapes the package root.") from error
    if not candidate.is_file():
        raise ReleaseValidationError(f"{label} is missing: {relative}")
    return candidate


def _read_manifest(root: Path) -> dict[str, Any]:
    path = root / "release-manifest.json"
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ReleaseValidationError(f"Release manifest is invalid: {error}") from error
    if not isinstance(value, dict):
        raise ReleaseValidationError("Release manifest must be an object.")
    return value


def _verify_checksums(root: Path) -> int:
    path = root / "SHA256SUMS.txt"
    try:
        lines = path.read_text(encoding="ascii").splitlines()
    except OSError as error:
        raise ReleaseValidationError(f"Checksum manifest is missing: {error}") from error
    expected: dict[str, str] = {}
    for line in lines:
        digest, separator, relative = line.partition("  ")
        if not separator or len(digest) != 64 or relative in expected:
            raise ReleaseValidationError("Checksum manifest contains an invalid entry.")
        expected[relative] = digest
    actual = {
        file.relative_to(root).as_posix()
        for file in root.rglob("*")
        if file.is_file() and not file.is_symlink() and file != path
    }
    if set(expected) != actual:
        missing = sorted(actual - set(expected))
        stale = sorted(set(expected) - actual)
        raise ReleaseValidationError(
            f"Checksum inventory mismatch; missing={missing}, stale={stale}"
        )
    for relative, expected_digest in expected.items():
        candidate = _inside(root, relative, "Checksummed file")
        if _sha256(candidate) != expected_digest:
            raise ReleaseValidationError(f"Checksum mismatch: {relative}")
    return len(expected)


def _request_process(executable: Path, requests: list[dict[str, Any]]) -> list[dict[str, Any]]:
    payload = "".join(json.dumps(request) + "\n" for request in requests)
    try:
        completed = subprocess.run(
            [str(executable), *( ["--capture-host"] if "capture" in executable.name.lower() else [])],
            input=payload,
            text=True,
            capture_output=True,
            timeout=15,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ReleaseValidationError(f"Process smoke failed for {executable.name}: {error}") from error
    if completed.returncode != 0:
        raise ReleaseValidationError(
            f"Process smoke exited {completed.returncode} for {executable.name}: "
            f"{completed.stderr[-1000:]}"
        )
    values: list[dict[str, Any]] = []
    for line in completed.stdout.splitlines():
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            values.append(value)
    return values


def _smoke_core(core_host: Path) -> None:
    values = _request_process(
        core_host,
        [
            {"id": "initialize", "protocolVersion": 1, "operation": "core.initialize", "payload": {}},
            {"id": "shutdown", "protocolVersion": 1, "operation": "core.shutdown", "payload": {}},
        ],
    )
    initialize = next((value for value in values if value.get("id") == "initialize"), None)
    shutdown = next((value for value in values if value.get("id") == "shutdown"), None)
    if initialize is None or initialize.get("ok") is not True:
        raise ReleaseValidationError("Rust core initialize smoke did not succeed.")
    if initialize.get("protocolVersion") != 1:
        raise ReleaseValidationError("Rust core smoke returned the wrong protocol version.")
    if shutdown is None or shutdown.get("ok") is not True:
        raise ReleaseValidationError("Rust core shutdown smoke did not succeed.")


def _smoke_windows_capture(capture_host: Path) -> None:
    values = _request_process(
        capture_host,
        [
            {"id": "ping", "method": "ping", "params": {}},
            {"id": "shutdown", "method": "shutdown", "params": {}},
        ],
    )
    for identifier in ("ping", "shutdown"):
        response = next((value for value in values if value.get("id") == identifier), None)
        if response is None or response.get("ok") is not True:
            raise ReleaseValidationError(f"Windows capture {identifier} smoke did not succeed.")


def _smoke_linux_capture(capture_host: Path) -> None:
    try:
        completed = subprocess.run(
            [str(capture_host), "probe"],
            text=True,
            capture_output=True,
            timeout=15,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ReleaseValidationError(
            f"Process smoke failed for {capture_host.name}: {error}"
        ) from error
    if completed.returncode != 0:
        raise ReleaseValidationError(
            f"Process smoke exited {completed.returncode} for {capture_host.name}: "
            f"{completed.stderr[-1000:]}"
        )
    try:
        value = json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise ReleaseValidationError("Linux X11 capture smoke returned invalid JSON.") from error
    if value != {"ok": True, "provider": "x11"}:
        raise ReleaseValidationError("Linux X11 capture smoke did not succeed.")


def verify_package(
    root: Path,
    *,
    expected_platform: str | None = None,
    expected_commit: str | None = None,
    smoke_processes: bool = True,
) -> dict[str, Any]:
    root = root.resolve()
    manifest = _read_manifest(root)
    required = {
        "schemaVersion": 1,
        "product": "Zommi",
        "components": {
            "desktopUi": "flutter",
            "runtimeCore": "rust",
        },
    }
    if manifest.get("schemaVersion") != required["schemaVersion"] or manifest.get("product") != "Zommi":
        raise ReleaseValidationError("Release manifest identity is invalid.")
    components = manifest.get("components")
    if not isinstance(components, dict) or any(
        components.get(key) != value for key, value in required["components"].items()
    ):
        raise ReleaseValidationError("Release manifest does not identify Flutter + Rust.")
    if expected_platform and manifest.get("platform") != expected_platform:
        raise ReleaseValidationError("Release platform does not match the requested target.")
    if expected_commit and manifest.get("gitCommit") != expected_commit:
        raise ReleaseValidationError("Release commit does not match the requested revision.")

    names = [path.relative_to(root).as_posix().lower() for path in root.rglob("*")]
    forbidden = [name for name in names if "electron" in name or "node_modules" in name or name.endswith(".mjs")]
    if forbidden:
        raise ReleaseValidationError(f"Legacy Electron/Node payload found: {forbidden[:3]}")

    entrypoint = _inside(root, str(manifest.get("entrypoint", "")), "Flutter entrypoint")
    core_host = _inside(root, str(manifest.get("coreHost", "")), "Rust core host")
    capture_host = None
    if manifest.get("platform") == "windows":
        capture_host = _inside(root, str(manifest.get("captureHost", "")), "Windows capture host")
    if manifest.get("platform") == "linux":
        _inside(root, "zommi-bin", "Packaged Linux Flutter binary")
        capture_host = _inside(
            root,
            str(manifest.get("captureHost", "")),
            "Linux X11 capture host",
        )
        try:
            launcher = entrypoint.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as error:
            raise ReleaseValidationError(f"Linux launcher is invalid: {error}") from error
        if "LD_LIBRARY_PATH" not in launcher or "zommi-bin" not in launcher:
            raise ReleaseValidationError("Linux launcher does not load bundled runtime libraries.")
        for relative in LINUX_RUNTIME_LIBRARIES:
            _inside(root, relative, "Bundled Linux runtime library")
    file_count = _verify_checksums(root)
    if smoke_processes:
        _smoke_core(core_host)
        if capture_host:
            if manifest.get("platform") == "windows":
                _smoke_windows_capture(capture_host)
            else:
                _smoke_linux_capture(capture_host)
    return {
        "platform": manifest.get("platform"),
        "architecture": manifest.get("architecture"),
        "gitCommit": manifest.get("gitCommit"),
        "entrypoint": entrypoint.relative_to(root).as_posix(),
        "coreHost": core_host.relative_to(root).as_posix(),
        "captureHost": capture_host.relative_to(root).as_posix() if capture_host else None,
        "files": file_count,
        "signing": manifest.get("signing"),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("package", type=Path)
    parser.add_argument("--expected-platform", choices=("windows", "linux", "macos"))
    parser.add_argument("--expected-commit")
    parser.add_argument("--skip-process-smoke", action="store_true")
    args = parser.parse_args()
    result = verify_package(
        args.package,
        expected_platform=args.expected_platform,
        expected_commit=args.expected_commit,
        smoke_processes=not args.skip_process_smoke,
    )
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
