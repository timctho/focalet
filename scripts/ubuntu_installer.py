"""Wrap the verified x64 desktop bundle in an Ubuntu 24.04 Debian package."""
from __future__ import annotations

import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def debian_version(version: str, tag: str | None, commit: str) -> str:
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("Invalid package version.")
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("A full source commit is required.")
    if tag is None:
        return f"{version}~dev+{commit[:12]}"
    if tag == f"v{version}":
        return version
    prefix = f"v{version}-"
    if not tag.startswith(prefix) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]*", tag[len(prefix):]):
        raise ValueError("The release tag must match the package version.")
    # Debian sorts '~preview.8' before the eventual stable version.
    return f"{version}~{tag[len(prefix):]}"


def payload_identity(root: Path) -> dict[str, tuple]:
    import hashlib
    result = {}
    for path in sorted(root.rglob("*")):
        name = path.relative_to(root).as_posix()
        if path.is_symlink():
            result[name] = ("link", os.readlink(path))
        elif path.is_file():
            result[name] = ("file", path.stat().st_mode & 0o777,
                            hashlib.sha256(path.read_bytes()).hexdigest())
    return result


def ubuntu_installer(package: Path, output: Path, manifest: dict, tag: str | None) -> Path:
    if manifest["platform"] != "linux" or manifest["architecture"] != "x64":
        raise ValueError("The Ubuntu installer supports Linux x64 packages only.")
    version = debian_version(manifest["version"], tag, manifest["gitCommit"])
    # Avoid packaging a symlink that reads data outside the accepted bundle.
    for path in package.rglob("*"):
        if path.is_symlink() and (
            os.path.isabs(os.readlink(path)) or not path.resolve().is_relative_to(package.resolve())
        ):
            raise ValueError("Ubuntu payload symlinks must stay inside the package.")
    icon = package / "data/flutter_assets/assets/branding/app-icon.png"
    if not icon.is_file():
        raise ValueError("The Ubuntu launcher icon is missing from the package.")
    asset = output / "Zommi-Ubuntu-amd64.deb"
    with tempfile.TemporaryDirectory(prefix="zommi-deb-") as temporary:
        root = Path(temporary) / "root"
        destination = root / "opt/zommi"
        shutil.copytree(package, destination, symlinks=True)
        for directory in ("DEBIAN", "usr/bin", "usr/share/applications",
                          "usr/share/icons/hicolor/256x256/apps", "usr/share/doc/zommi"):
            (root / directory).mkdir(parents=True, exist_ok=True)
        # A symlink in /usr/bin would make the bundle's dirname($0) resolve there.
        launcher = root / "usr/bin/zommi"
        launcher.write_text('#!/bin/sh\nexec /opt/zommi/zommi "$@"\n', encoding="utf-8")
        launcher.chmod(0o755)
        (root / "usr/share/applications/com.zommi.desktop.desktop").write_text(
            "[Desktop Entry]\nType=Application\nName=Zommi\n"
            "Comment=Show your agent what you mean\nExec=/usr/bin/zommi\n"
            "Icon=zommi\nTerminal=false\nCategories=Utility;Development;\n"
            "StartupWMClass=com.zommi.desktop\n", encoding="utf-8")
        shutil.copy2(icon, root / "usr/share/icons/hicolor/256x256/apps/zommi.png")
        shutil.copy2(package / "LICENSE", root / "usr/share/doc/zommi/copyright")
        size = sum(p.stat().st_size for p in root.rglob("*") if p.is_file())
        (root / "DEBIAN/control").write_text(
            f"Package: zommi\nVersion: {version}\nArchitecture: amd64\n"
            "Maintainer: Zommi contributors <noreply@github.com>\n"
            "Section: utils\nPriority: optional\n"
            f"Installed-Size: {(size + 1023) // 1024}\n"
            "Depends: libc6 (>= 2.39), libgcc-s1, libstdc++6 (>= 13.2), "
            "libgtk-3-0t64, libglib2.0-0t64, libayatana-appindicator3-1, "
            "libx11-6, libxext6, libxfixes3, libxrandr2, libxi6, libxtst6, "
            "libegl1, libgl1, libepoxy0, libnotify4, libwebkit2gtk-4.1-0, libsoup-3.0-0\n"
            "Recommends: gnome-shell-extension-appindicator\n"
            "Homepage: https://github.com/timctho/zommi\n"
            "Description: Desktop companion for your existing agent\n"
            " Select screen context and send it to an agent. Ubuntu 24.04 LTS x64.\n",
            encoding="utf-8")
        # The portable bundle is staged with mkdtemp (0700). A system package
        # must be readable/traversable by normal users after root installs it.
        for path in [root, *root.rglob("*")]:
            if not path.is_symlink():
                path.chmod(0o755 if path.is_dir() or path.stat().st_mode & 0o111 else 0o644)
        subprocess.run(["dpkg-deb", "--root-owner-group", "--build", str(root), str(asset)], check=True)
        extracted = Path(temporary) / "extracted"
        subprocess.run(["dpkg-deb", "--extract", str(asset), str(extracted)], check=True)
        # DEBIAN control files are in the control archive, not the payload.
        expected = {k: v for k, v in payload_identity(root).items() if not k.startswith("DEBIAN/")}
        if payload_identity(extracted) != expected:
            raise ValueError("The Debian archive changed the accepted payload.")
    return asset
