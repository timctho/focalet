#!/usr/bin/env python3
"""Create and verify an independent Capture installer from an accepted package."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from build_installer import windows_installer, macos_installer, inventory
from verify_capture_package import verify
from verify_release import _sha256
from ubuntu_installer import debian_version, payload_identity


def ubuntu(package, output, manifest):
    if manifest['architecture'] != 'x64': raise ValueError('Ubuntu Capture requires x64.')
    version = debian_version(manifest['version'], manifest['releaseTag'], manifest['gitCommit'])
    asset = output/'Focalet-Capture-Ubuntu-amd64.deb'
    with tempfile.TemporaryDirectory(prefix='focalet-capture-deb-') as temporary:
        root = Path(temporary)/'root'
        shutil.copytree(package, root/'opt/focalet-capture')
        for name in ('DEBIAN', 'usr/bin', 'usr/share/applications', 'usr/share/icons/hicolor/256x256/apps', 'usr/share/doc/focalet-capture'):
            (root/name).mkdir(parents=True, exist_ok=True)
        launcher = root/'usr/bin/focalet-capture'
        launcher.write_text('#!/bin/sh\nexec /opt/focalet-capture/focalet-capture "$@"\n'); launcher.chmod(0o755)
        (root/'usr/share/applications/com.focalet.capture.desktop').write_text(
            '[Desktop Entry]\nType=Application\nName=Focalet Capture\nComment=Paste selected screen context into your existing app\n'
            'Exec=/usr/bin/focalet-capture\nIcon=focalet-capture\nTerminal=false\nCategories=Utility;Graphics;\nStartupWMClass=com.focalet.capture\n')
        shutil.copy2(package/'app-icon.png', root/'usr/share/icons/hicolor/256x256/apps/focalet-capture.png')
        shutil.copy2(package/'LICENSE', root/'usr/share/doc/focalet-capture/copyright')
        (root/'DEBIAN/control').write_text(
            f'Package: focalet-capture\nVersion: {version}\nArchitecture: amd64\nSection: utils\nPriority: optional\n'
            'Maintainer: Focalet contributors <noreply@github.com>\n'
            'Depends: libc6 (>= 2.39), libgcc-s1, libstdc++6 (>= 13.2), python3, python3-gi, python3-gi-cairo, '
            'gir1.2-gtk-3.0, gir1.2-atspi-2.0, librsvg2-common, at-spi2-core, libgtk-3-0t64, libicu74, libssl3t64, libgssapi-krb5-2, zlib1g, '
            'gnome-shell (>= 46), gnome-shell (<< 47), xdg-desktop-portal, xdg-desktop-portal-gnome, '
            'pipewire, wireplumber, gstreamer1.0-pipewire, gstreamer1.0-plugins-base, libgstreamer1.0-0 (>= 1.24), libgstreamer-plugins-base1.0-0 (>= 1.24)\n'
            'Homepage: https://github.com/timctho/focalet\n'
            'Description: Selected pixels and context for your existing app\n'
            ' Capture multiple screen regions and paste images with their text context.\n')
        for file in [root, *root.rglob('*')]:
            file.chmod(0o755 if file.is_dir() or file.stat().st_mode & 0o111 else 0o644)
        subprocess.run(['dpkg-deb', '--root-owner-group', '--build', str(root), str(asset)], check=True)
        extracted = Path(temporary)/'extracted'
        subprocess.run(['dpkg-deb', '--extract', str(asset), str(extracted)], check=True)
        expected = {k: v for k, v in payload_identity(root).items() if not k.startswith('DEBIAN/')}
        if payload_identity(extracted) != expected: raise ValueError('Capture installer payload changed.')
        subprocess.run(['desktop-file-validate', str(extracted/'usr/share/applications/com.focalet.capture.desktop')], check=True)
    return asset


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('package', type=Path)
    parser.add_argument('--expected-commit', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--makensis', default='makensis')
    args = parser.parse_args(); package = args.package.resolve(); output = args.output.resolve()
    manifest = verify(package, args.expected_commit)
    before = inventory(package); output.mkdir(parents=True, exist_ok=True)
    if manifest['platform'] == 'windows': asset = windows_installer(package, output, manifest, args.makensis, capture=True)
    elif manifest['platform'] == 'macos': asset = macos_installer(package, output, manifest, capture=True)
    else: asset = ubuntu(package, output, manifest)
    if inventory(package) != before: raise ValueError('Capture package changed while building installer.')
    record = {key: manifest[key] for key in ('product', 'version', 'releaseTag', 'gitCommit', 'platform', 'architecture')}
    record.update(file=asset.name, sha256=_sha256(asset), packageFiles=before, applicationSigning=manifest['signing'],
                  installerSigning='not-notarized' if manifest['platform'] == 'macos' else 'unsigned')
    asset.with_name(asset.name+'.release.json').write_text(json.dumps(record, indent=2)+'\n')
    asset.with_name(asset.name+'.sha256').write_text(f"{record['sha256']}  {asset.name}\n")
    print(asset)


if __name__ == '__main__': main()
