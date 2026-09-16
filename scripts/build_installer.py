#!/usr/bin/env python3
"""Build an installer from an already verified native package."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tempfile

from verify_release import _sha256, verify_package


def inventory(root: Path) -> dict[str, str]:
    return {
        path.relative_to(root).as_posix(): _sha256(path)
        for path in sorted(root.rglob("*"))
        if path.is_file() and not path.is_symlink()
    }


def nsis_string(value: str) -> str:
    if "\n" in value or "\r" in value:
        raise ValueError("Installer paths cannot contain newlines.")
    return value.replace("$", "$$").replace('"', '$\\"')


def windows_installer(package: Path, output: Path, manifest: dict, compiler: str) -> Path:
    if manifest["architecture"] != "x64":
        raise ValueError("The Windows installer currently supports x64 packages.")
    version = manifest["version"]
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("Installer version must have three numeric components.")
    asset = output / "Zommi-Setup-x64.exe"
    with tempfile.TemporaryDirectory(prefix="zommi-nsis-") as temporary:
        temp = Path(temporary)
        install, uninstall, directories = [], [], set()
        for relative in inventory(package):
            path = Path(relative)
            windows_name = nsis_string(relative.replace("/", "\\"))
            parent = str(path.parent).replace("/", "\\")
            destination = "$INSTDIR" if parent == "." else "$INSTDIR\\" + nsis_string(parent)
            install += [f'SetOutPath "{destination}"', f'File "{nsis_string((package / path).as_posix())}"']
            uninstall.append(f'Delete "$INSTDIR\\{windows_name}"')
            directories.update(parent.as_posix() for parent in path.parents if parent != Path("."))
        for directory in sorted(directories, key=lambda name: (name.count("/"), name), reverse=True):
            uninstall.append('RMDir "$INSTDIR\\' + nsis_string(directory.replace("/", "\\")) + '"')
        (temp / "install.nsh").write_text("\n".join(install) + "\n", encoding="utf-8")
        (temp / "uninstall.nsh").write_text("\n".join(uninstall) + "\n", encoding="utf-8")
        definitions = {
            "OUTPUT_FILE": asset.as_posix(),
            "APP_VERSION": version,
            "APP_ICON": (package / "data/flutter_assets/windows/runner/resources/app_icon.ico").as_posix(),
            "INSTALL_FILES": (temp / "install.nsh").as_posix(),
            "UNINSTALL_FILES": (temp / "uninstall.nsh").as_posix(),
        }
        prefix = "/" if platform.system() == "Windows" else "-"
        subprocess.run(
            [compiler, prefix + "WX", prefix + "V2", *[f"{prefix}D{key}={nsis_string(value)}" for key, value in definitions.items()],
             str(Path(__file__).parent / "installer/windows.nsi")], check=True,
        )
    return asset


def macos_installer(package: Path, output: Path, manifest: dict) -> Path:
    if platform.system() != "Darwin":
        raise ValueError("DMG creation and verification must run on macOS.")
    asset = output / f"Zommi-macOS-{manifest['architecture']}.dmg"
    application = package / "Zommi.app"
    before = inventory(application)
    with tempfile.TemporaryDirectory(prefix="zommi-dmg-") as temporary:
        temp = Path(temporary)
        layout, mounted = temp / "layout", temp / "mounted"
        layout.mkdir()
        subprocess.run(["ditto", str(application), str(layout / "Zommi.app")], check=True)
        (layout / "Applications").symlink_to("/Applications")
        shutil.copy2(Path(__file__).parents[1] / "docs/install.md", layout / "Install.txt")
        subprocess.run(["hdiutil", "create", "-volname", "Zommi", "-srcfolder", str(layout),
                        "-format", "UDZO", "-ov", str(asset)], check=True)
        subprocess.run(["hdiutil", "verify", str(asset)], check=True)
        mounted.mkdir()
        subprocess.run(["hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", str(mounted), str(asset)], check=True)
        try:
            if inventory(mounted / "Zommi.app") != before:
                raise ValueError("Mounted DMG app differs from the verified package.")
            if os.readlink(mounted / "Applications") != "/Applications":
                raise ValueError("The DMG Applications shortcut is invalid.")
            subprocess.run(["codesign", "--verify", "--deep", "--strict", str(mounted / "Zommi.app")], check=True)
        finally:
            subprocess.run(["hdiutil", "detach", str(mounted)], check=True)
    return asset


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path)
    parser.add_argument("--expected-commit", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--makensis", default="makensis")
    args = parser.parse_args()
    package, output = args.package.resolve(), args.output.resolve()
    # A Linux machine may wrap a Windows package with NSIS, but cannot execute it.
    manifest = json.loads((package / "release-manifest.json").read_text(encoding="utf-8"))
    if manifest.get("architecture") not in {"arm64", "x64"}:
        raise ValueError("Unsupported installer architecture.")
    native_host = {"Windows": "windows", "Darwin": "macos", "Linux": "linux"}[platform.system()]
    verify_package(package, expected_commit=args.expected_commit, smoke_processes=manifest["platform"] == native_host)
    before = inventory(package)
    output.mkdir(parents=True, exist_ok=True)
    if manifest["platform"] == "windows":
        asset = windows_installer(package, output, manifest, args.makensis)
    elif manifest["platform"] == "macos":
        asset = macos_installer(package, output, manifest)
    else:
        raise ValueError("Only Windows and macOS installers are supported.")
    if inventory(package) != before:
        raise ValueError("The source package changed while creating the installer.")
    result = {
        "product": "Zommi", "version": manifest["version"], "gitCommit": args.expected_commit,
        "platform": manifest["platform"], "architecture": manifest["architecture"],
        "file": asset.name, "sha256": _sha256(asset), "packageFiles": before,
        "applicationSigning": manifest["signing"],
        "installerSigning": "unsigned" if manifest["platform"] == "windows" else "not-notarized",
    }
    asset.with_name(asset.name + ".release.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    asset.with_name(asset.name + ".sha256").write_text(f"{result['sha256']}  {asset.name}\n", encoding="ascii")
    print(json.dumps({key: value for key, value in result.items() if key != "packageFiles"}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
