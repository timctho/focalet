"""Verify the standalone Capture package without Flutter or an agent runtime."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import time


def verify(root: Path, commit: str) -> dict:
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("Expected a full source commit SHA.")
    manifest = json.loads((root / "capture-tool-manifest.json").read_text(encoding="utf-8-sig"))
    if (manifest.get("product") != "Focalet Capture" or manifest.get("gitCommit") != commit
            or manifest.get("runtime") not in {"win-x64", "win-arm64"}
            or manifest.get("entryPoint") != "Focalet.Capture.exe"):
        raise ValueError("Capture product, source revision, runtime or entrypoint mismatch.")
    checksums = {}
    for line in (root / "SHA256SUMS.txt").read_text().splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
        if not match:
            raise ValueError("Invalid checksum entry.")
        digest, name = match.groups()
        path = PurePosixPath(name)
        if path.is_absolute() or ".." in path.parts or "\\" in name or ":" in name or name in checksums:
            raise ValueError("Invalid or duplicate package path.")
        checksums[name] = digest
    inventory = set()
    for path in root.rglob("*"):
        if path.is_symlink():
            raise ValueError("Package contains a symbolic link.")
        if path.is_file() and path != root / "SHA256SUMS.txt":
            inventory.add(path.relative_to(root).as_posix())
    if inventory != set(checksums):
        raise ValueError("Package file inventory does not match its checksums.")
    for name, digest in checksums.items():
        if hashlib.sha256((root / name).read_bytes()).hexdigest() != digest:
            raise ValueError(f"Checksum mismatch: {name}")
    required = {"Focalet.Capture.exe", "capture-tool-manifest.json", "LICENSE", "THIRD_PARTY_NOTICES.md", "README.md"}
    if not required.issubset(inventory):
        raise ValueError("Capture package is missing required files.")
    forbidden = {"zommi.exe", "zommi.capture.exe", "zommi.capture.dll", "zommi-core-host.exe", "flutter_windows.dll"}
    if any(PurePosixPath(name).name.lower() in forbidden for name in inventory):
        raise ValueError("Capture package unexpectedly contains a Desktop component.")
    with (root / manifest["entryPoint"]).open("rb") as executable:
        if executable.read(2) != b"MZ":
            raise ValueError("Capture entrypoint is not a Windows executable.")
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path)
    parser.add_argument("--expected-commit", required=True)
    parser.add_argument("--smoke", action="store_true", help="Launch the packaged tray app on a disposable Windows runner.")
    args = parser.parse_args()
    root = args.package.resolve()
    manifest = verify(root, args.expected_commit)
    if args.smoke:
        if os.name != "nt":
            raise SystemExit("The tray startup check requires Windows.")
        process = subprocess.Popen([str(root / manifest["entryPoint"])], cwd=root)
        try:
            time.sleep(2)
            if process.poll() is not None:
                raise SystemExit(f"Packaged Capture exited during startup: {process.returncode}")
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=10)
    print(f"Verified Focalet Capture package from {manifest['gitCommit']}.")


if __name__ == "__main__":
    main()
