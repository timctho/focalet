#!/usr/bin/env python3
"""Install, capture, and uninstall a Windows setup package in a disposable folder."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import time

from build_installer import inventory
from verify_release import _sha256


def main() -> int:
    import winreg

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("installer", type=Path)
    parser.add_argument("--expected-commit", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    installer, output = args.installer.resolve(), args.output.resolve()
    metadata = json.loads(installer.with_name(installer.name + ".release.json").read_text())
    if metadata["gitCommit"] != args.expected_commit or metadata["sha256"] != _sha256(installer):
        raise ValueError("Installer identity or checksum does not match.")
    keys = [r"Software\Focalet", r"Software\Microsoft\Windows\CurrentVersion\Uninstall\Focalet"]
    for key in keys:
        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, key):
                raise RuntimeError("An existing Focalet installation is registered; do not overwrite it during acceptance.")
        except FileNotFoundError:
            pass
    shortcut = Path(os.environ["APPDATA"]) / "Microsoft/Windows/Start Menu/Programs/Focalet/Focalet.lnk"
    if shortcut.exists():
        raise RuntimeError("An existing Focalet shortcut must not be overwritten during acceptance.")
    output.mkdir(parents=True, exist_ok=True)
    target = output / "installed"
    if target.exists():
        raise RuntimeError("Acceptance needs a fresh install directory.")
    uninstaller = target / "Uninstall.exe"
    result = {"gitCommit": args.expected_commit, "installerSha256": metadata["sha256"], "status": "running"}
    try:
        print("Installing into the disposable acceptance directory", flush=True)
        # NSIS requires /D to be last, without quotes around its directory.
        command = subprocess.list2cmdline([str(installer), "/S"]) + " /D=" + str(target)
        subprocess.run(command, check=True, timeout=90)
        installed = inventory(target)
        if set(installed) != set(metadata["packageFiles"]) | {"Uninstall.exe"}:
            raise ValueError("Installed file inventory differs from the accepted package.")
        if any(installed[name] != digest for name, digest in metadata["packageFiles"].items()):
            raise ValueError("Installed payload checksums differ.")
        if not shortcut.is_file():
            raise ValueError("The Start menu shortcut was not created.")
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, keys[1]) as key:
            if winreg.QueryValueEx(key, "DisplayName")[0] != "Focalet":
                raise ValueError("Installed Apps registration is missing.")
            if winreg.QueryValueEx(key, "UninstallString")[0] != f'"{uninstaller}"':
                raise ValueError("Installed Apps uninstall command is invalid.")
            if winreg.QueryValueEx(key, "QuietUninstallString")[0] != f'"{uninstaller}" /S':
                raise ValueError("Silent uninstall command is invalid.")
        result["installedPayloadVerified"] = True
        (target / "keep-me.txt").write_text("User-created files must survive uninstall.")
        print("Checking capture from the installed executable", flush=True)
        subprocess.run([
            "pwsh", "-NoProfile", "-File", str(Path(__file__).parent / "accept-windows-capture.ps1"),
            "-PackageDirectory", str(target), "-ResultPath", str(output / "capture.json"),
        ], check=True, timeout=600)
        result["captureVerified"] = True
    finally:
        if uninstaller.is_file():
            print("Uninstalling the acceptance copy", flush=True)
            subprocess.run([str(uninstaller), "/S"], check=True, timeout=60)
            deadline = time.monotonic() + 30
            while uninstaller.exists() and time.monotonic() < deadline:
                time.sleep(.2)
    if set(inventory(target)) != {"keep-me.txt"}:
        raise ValueError("Uninstall did not remove exactly the installed app files.")
    if shortcut.exists():
        raise ValueError("Uninstall left the Start menu shortcut.")
    for key in keys:
        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, key):
                raise ValueError("Uninstall left its registry entry.")
        except FileNotFoundError:
            pass
    result.update(status="passed", uninstallVerified=True, unrelatedFilePreserved=True)
    (output / "installer-acceptance.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
