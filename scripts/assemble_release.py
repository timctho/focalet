#!/usr/bin/env python3
"""Assemble one native Flutter + Rust Focalet release directory and archive."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform as host_platform
import shutil
import subprocess
import tarfile
import tempfile
import time
import uuid
import zipfile

from release_version import read_version

REPOSITORY = Path(__file__).resolve().parents[1]
LICENSE_FILES = {
    "LICENSE": "LICENSE",
    "THIRD_PARTY_NOTICES.md": "THIRD_PARTY_NOTICES.md",
    "third_party/hotkey_manager_linux/LICENSE": "licenses/hotkey_manager_linux-LICENSE.txt",
    "src/Focalet.Flutter/assets/runtime_icons/SOURCES.md": "licenses/runtime-icons-NOTICES.md",
    "design/focalet-logo/Manrope-OFL.txt": "licenses/Manrope-OFL.txt",
}


def _copy_licenses(destination: Path) -> None:
    for source, relative in LICENSE_FILES.items():
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(REPOSITORY / source, target)


def _copy_contents(source: Path, destination: Path) -> None:
    if not source.is_dir():
        raise ValueError(f"Flutter output directory does not exist: {source}")
    for child in source.iterdir():
        target = destination / child.name
        if child.is_dir() and not child.is_symlink():
            shutil.copytree(child, target, symlinks=True)
        elif child.is_symlink():
            target.symlink_to(os.readlink(child), target_is_directory=child.is_dir())
        else:
            shutil.copy2(child, target)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _regular_files(root: Path) -> list[Path]:
    return sorted(
        (
            path
            for path in root.rglob("*")
            if path.is_file() and not path.is_symlink()
        ),
        key=lambda path: path.relative_to(root).as_posix(),
    )


def _write_checksums(root: Path) -> None:
    checksum_path = root / "SHA256SUMS.txt"
    lines = [
        f"{_sha256(path)}  {path.relative_to(root).as_posix()}"
        for path in _regular_files(root)
        if path != checksum_path
    ]
    checksum_path.write_text("\n".join(lines) + "\n", encoding="ascii")


def _sign_macos(application: Path, identity: str | None) -> dict[str, str]:
    selected = identity or "-"
    identity_signed = selected != "-"
    browser_directory = application / "Contents/MacOS/browser-capture"
    browser = browser_directory / "focalet-browser-capture"
    if browser.is_file():
        # Sign the .NET libraries before their host. Only that host needs JIT;
        # do not grant executable-memory entitlements to the Flutter app.
        options = ["--options", "runtime", "--timestamp"] if identity_signed else []
        for library in sorted(browser_directory.rglob("*.dylib")):
            subprocess.run(["codesign", "--force", "--sign", selected, *options, str(library)], check=True)
        subprocess.run(["codesign", "--force", "--sign", selected, *options,
                        "--entitlements", str(REPOSITORY / "scripts/macos-browser-entitlements.plist"),
                        str(browser)], check=True)
    command = ["codesign", "--force", "--deep", "--sign", selected]
    if identity_signed:
        command.append("--preserve-metadata=entitlements")
        command.extend(["--options", "runtime", "--timestamp"])
    command.append(str(application))
    subprocess.run(command, check=True)
    subprocess.run(
        ["codesign", "--verify", "--deep", "--strict", str(application)],
        check=True,
    )
    signing = {"status": "ad-hoc", "mechanism": "codesign"}
    if identity_signed:
        details = subprocess.run(
            ["codesign", "--display", "--verbose=4", str(application)],
            check=True,
            capture_output=True,
            text=True,
        ).stderr
        fields = dict(
            line.split("=", 1) for line in details.splitlines() if "=" in line
        )
        authorities = [
            line.removeprefix("Authority=")
            for line in details.splitlines()
            if line.startswith("Authority=")
        ]
        authority = authorities[0] if authorities else ""
        if authority.startswith("Developer ID Application:"):
            signing["status"] = "distribution-signed"
        elif authority.startswith(("Apple Development:", "Mac Developer:")):
            signing["status"] = "development-signed"
        else:
            signing["status"] = "identity-signed"
        if team := fields.get("TeamIdentifier"):
            signing["teamIdentifier"] = team
        if authority:
            signing["authority"] = authority
    return signing


def _write_manifest(
    root: Path,
    *,
    target_platform: str,
    architecture: str,
    commit: str,
    entrypoint: str,
    core_host: str,
    capture_host: str | None,
    signing: dict[str, str],
    browser_capture_host: str | None = None,
) -> None:
    identity = read_version(REPOSITORY / "src/Focalet.Flutter/pubspec.yaml")
    manifest = {
        "schemaVersion": 1,
        "product": "Focalet",
        "version": identity["version"],
        "releaseTag": identity["tag"],
        "license": "Apache-2.0",
        "gitCommit": commit,
        "platform": target_platform,
        "architecture": architecture,
        "entrypoint": entrypoint,
        "coreHost": core_host,
        "components": {
            "desktopUi": "flutter",
            "runtimeCore": "rust",
            "captureProvider": {"windows": "dotnet-uia", "linux": "gnome-wayland-atspi", "macos": "screen-capture-ax"}[target_platform],
            **({"browserProvider": "shared-dom"} if browser_capture_host else {}),
            **(
                {"wslTransport": "persistent-authenticated-relay", "windowsReset": "owned-profile-reset"}
                if target_platform == "windows"
                else {}
            ),
        },
        "signing": signing,
    }
    if capture_host:
        manifest["captureHost"] = capture_host
    if browser_capture_host:
        manifest["browserCaptureHost"] = browser_capture_host
    if target_platform == "windows":
        icon = root / "data/flutter_assets/windows/runner/resources/app_icon.ico"
        if icon.is_file():
            icon_name = f"focalet-icon-{_sha256(icon)[:16]}.ico"
            shutil.copy2(icon, root / icon_name)
            manifest["icon"] = icon_name
    (root / "release-manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def _zip_directory(root: Path, archive: Path) -> None:
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as output:
        for path in sorted(root.rglob("*")):
            relative = Path(root.name) / path.relative_to(root)
            if path.is_symlink():
                info = zipfile.ZipInfo(relative.as_posix())
                info.create_system = 3
                info.external_attr = 0o120777 << 16
                output.writestr(info, os.readlink(path))
            elif path.is_file():
                output.write(path, relative.as_posix())


def _archive(root: Path, target_platform: str) -> Path:
    if target_platform == "linux":
        pending = root.with_name(f"{root.name}.pending.tar.gz")
        final = root.with_name(f"{root.name}.tar.gz")
        with tarfile.open(pending, "w:gz") as output:
            output.add(root, arcname=root.name, recursive=True)
    else:
        pending = root.with_name(f"{root.name}.pending.zip")
        final = root.with_name(f"{root.name}.zip")
        if target_platform == "macos" and shutil.which("ditto"):
            subprocess.run(
                [
                    "ditto",
                    "-c",
                    "-k",
                    "--sequesterRsrc",
                    "--keepParent",
                    str(root),
                    str(pending),
                ],
                check=True,
            )
        else:
            _zip_directory(root, pending)
    if final.exists():
        final.unlink()
    pending.replace(final)
    Path(f"{final}.sha256").write_text(
        f"{_sha256(final)}  {final.name}\n",
        encoding="ascii",
    )
    return final


def _replace_path(source: Path, destination: Path) -> None:
    attempts = 6 if os.name == "nt" else 1
    for attempt in range(attempts):
        try:
            source.replace(destination)
            return
        except PermissionError:
            if attempt + 1 == attempts:
                raise
            time.sleep(0.05 * (2**attempt))


def _replace_directory(pending: Path, destination: Path) -> None:
    """Atomically install pending without leaving a partially deleted package."""
    if not destination.exists():
        _replace_path(pending, destination)
        return

    previous = destination.with_name(
        f".{destination.name}-previous-{uuid.uuid4().hex}"
    )
    try:
        _replace_path(destination, previous)
    except OSError as error:
        raise RuntimeError(
            "The existing package is in use and was left unchanged. "
            "Stop processes launched from the package and retry."
        ) from error
    try:
        _replace_path(pending, destination)
    except BaseException:
        _replace_path(previous, destination)
        raise

    try:
        shutil.rmtree(previous)
    except OSError as error:
        failed_new = destination.with_name(
            f".{destination.name}-failed-{uuid.uuid4().hex}"
        )
        try:
            _replace_path(destination, failed_new)
            _replace_path(previous, destination)
        finally:
            shutil.rmtree(failed_new, ignore_errors=True)
        raise RuntimeError(
            "The existing package is in use; the original package was restored. "
            "Stop processes launched from the package and retry."
        ) from error


def assemble(args: argparse.Namespace) -> tuple[Path, Path]:
    output_root = args.output_root.resolve()
    output_root.mkdir(parents=True, exist_ok=True)
    package_name = f"focalet-{args.platform}-{args.architecture}"
    destination = output_root / package_name
    pending = Path(tempfile.mkdtemp(prefix=f".{package_name}-", dir=output_root))
    try:
        signing = {
            "status": args.signing_status,
            "mechanism": args.signing_mechanism,
        }
        capture_relative: str | None = None
        browser_relative: str | None = None
        if args.platform != "windows":
            browser_source = getattr(args, "browser_capture_host", None)
            if browser_source is None or not (browser_source / "focalet-browser-capture").is_file():
                raise ValueError("Unix releases require --browser-capture-host with a published native helper.")
        if args.platform == "macos":
            application = pending / "Focalet.app"
            shutil.copytree(args.flutter_output, application, symlinks=True)
            core_relative = "Focalet.app/Contents/MacOS/focalet-core-host"
            entrypoint = "Focalet.app/Contents/MacOS/Focalet"
            core_destination = pending / core_relative
            shutil.copy2(args.core_host, core_destination)
            core_destination.chmod(core_destination.stat().st_mode | 0o111)
            browser_relative = "Focalet.app/Contents/MacOS/browser-capture/focalet-browser-capture"
            shutil.copytree(browser_source, (pending / browser_relative).parent)
            (pending / browser_relative).chmod(0o755)
            # Keep notices with the installed app and include them in its signature.
            _copy_licenses(application / "Contents/Resources")
            signing = _sign_macos(application, args.macos_signing_identity)
        else:
            _copy_contents(args.flutter_output, pending)
            if args.platform == "windows":
                entrypoint = "Focalet.exe"
                core_relative = "focalet-core-host.exe"
                capture_relative = "native/Focalet.CaptureHost.exe"
                if args.capture_host is None:
                    raise ValueError("Windows releases require --capture-host.")
                shutil.copytree(args.capture_host, pending / "native", symlinks=True)
                support = pending / "support"
                support.mkdir()
                for name in ("stop-focalet-relays.ps1", "stop-focalet-relay.sh"):
                    shutil.copy2(Path(__file__).parent / name, support / name)
            else:
                entrypoint = "focalet"
                browser_relative = "browser-capture/focalet-browser-capture"
                shutil.copytree(browser_source, (pending / browser_relative).parent)
                (pending / browser_relative).chmod(0o755)
                core_relative = "focalet-core-host"
                capture_relative = "focalet-linux-capture"
                if args.linux_capture_host is None:
                    raise ValueError("Linux releases require --linux-capture-host.")
                capture_destination = pending / capture_relative
                shutil.copy2(args.linux_capture_host, capture_destination)
                capture_destination.chmod(capture_destination.stat().st_mode | 0o111)
                extension = pending / "gnome-extension/focalet@focalet"
                shutil.copytree(REPOSITORY / "src/Focalet.Gnome", extension)
                subprocess.run(["glib-compile-schemas", str(extension / "schemas")], check=True)
                flutter_binary = pending / "focalet"
                packaged_binary = pending / "focalet-bin"
                flutter_binary.replace(packaged_binary)
                flutter_binary.write_text(
                    "#!/usr/bin/env sh\n"
                    "set -eu\n"
                    'app_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)\n'
                    'export LD_LIBRARY_PATH="$app_dir/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"\n'
                    'exec "$app_dir/focalet-bin" "$@"\n',
                    encoding="utf-8",
                )
                flutter_binary.chmod(0o755)
            core_destination = pending / core_relative
            shutil.copy2(args.core_host, core_destination)
            if args.platform == "linux":
                core_destination.chmod(core_destination.stat().st_mode | 0o111)
            _copy_licenses(pending)

        for document in args.document:
            document = document.resolve()
            if not document.is_file():
                raise ValueError(f"Release document does not exist: {document}")
            docs = pending / "docs"
            docs.mkdir(exist_ok=True)
            shutil.copy2(document, docs / document.name)

        _write_manifest(
            pending,
            target_platform=args.platform,
            architecture=args.architecture,
            commit=args.git_commit,
            entrypoint=entrypoint,
            core_host=core_relative,
            capture_host=capture_relative,
            browser_capture_host=browser_relative,
            signing=signing,
        )
        _write_checksums(pending)
        _replace_directory(pending, destination)
        archive = _archive(destination, args.platform)
        return destination, archive
    except BaseException:
        shutil.rmtree(pending, ignore_errors=True)
        raise


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    parser.add_argument("--platform", choices=("windows", "linux", "macos"), required=True)
    parser.add_argument("--architecture", choices=("x64", "arm64"), required=True)
    parser.add_argument("--flutter-output", type=Path, required=True)
    parser.add_argument("--core-host", type=Path, required=True)
    parser.add_argument("--linux-capture-host", type=Path)
    parser.add_argument("--browser-capture-host", type=Path)
    parser.add_argument("--capture-host", type=Path)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--git-commit", required=True)
    parser.add_argument("--document", type=Path, action="append", default=[])
    parser.add_argument("--macos-signing-identity")
    parser.add_argument(
        "--signing-status",
        choices=("unsigned", "checksum-only", "distribution-signed"),
        default="unsigned",
    )
    parser.add_argument("--signing-mechanism", default="none")
    return parser


def main() -> int:
    args = _parser().parse_args()
    destination, archive = assemble(args)
    print(
        json.dumps(
            {
                "package": str(destination),
                "archive": str(archive),
                "host": host_platform.platform(),
            }
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
