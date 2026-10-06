#!/usr/bin/env python3
"""Build standalone native Capture from committed source, without Desktop."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import tempfile
import zipfile
from release_version import read_version
from ubuntu_compatibility import verify_build_host, verify_ubuntu_abi

ROOT = Path(__file__).resolve().parents[1]


def run(*args, **kwargs):
    subprocess.run(list(map(str, args)), check=True, **kwargs)


def package(target: str, output: Path):
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    run('git', 'diff', '--exit-code', 'HEAD', cwd=ROOT)
    if target == "linux": verify_build_host()
    machine = platform.machine().lower()
    arch = 'arm64' if machine in ('arm64', 'aarch64') else 'x64'
    expected = {'macos': 'Darwin', 'linux': 'Linux', 'windows': 'Windows'}[target]
    if platform.system() != expected:
        raise ValueError(f'Build {target} on its native runner.')
    runtime = f"{dict(macos='osx', linux='linux', windows='win')[target]}-{arch}"
    output.mkdir(parents=True, exist_ok=True)
    destination = output / f'focalet-capture-{runtime}'
    if destination.exists(): shutil.rmtree(destination)
    destination.mkdir()
    with tempfile.TemporaryDirectory(prefix='focalet-capture-build-') as temporary:
        temp = Path(temporary); archive = temp/'source.zip'
        run('git', 'archive', '--format=zip', f'--output={archive}', commit, cwd=ROOT)
        source = temp/'source'
        with zipfile.ZipFile(archive) as zipped: zipped.extractall(source)
        version = read_version(source/'src/Focalet.Flutter/pubspec.yaml')
        resources = destination
        if target == 'macos':
            app = destination/'Focalet Capture.app'; contents = app/'Contents'
            resources = contents/'Resources'; resources.mkdir(parents=True)
            binary = contents/'MacOS/Focalet Capture'; binary.parent.mkdir()
            shutil.copytree(source/'src/Focalet.Capture.Mac/Resources', resources, dirs_exist_ok=True)
            run('iconutil', '-c', 'icns', resources/'AppIcon.iconset', '-o', resources/'AppIcon.icns')
            shutil.rmtree(resources/'AppIcon.iconset')
            with (contents/'Info.plist').open('wb') as file:
                plistlib.dump({'CFBundleIdentifier': 'com.focalet.capture', 'CFBundleName': 'Focalet Capture',
                    'CFBundleDisplayName': 'Focalet Capture', 'CFBundleExecutable': 'Focalet Capture',
                    'CFBundlePackageType': 'APPL', 'CFBundleIconFile': 'AppIcon',
                    'CFBundleShortVersionString': version['version'], 'CFBundleVersion': version['buildNumber'],
                    'LSMinimumSystemVersion': '12.0', 'LSUIElement': True, 'NSHighResolutionCapable': True,
                    'NSHumanReadableCopyright': 'Focalet contributors',
                    'NSScreenCaptureUsageDescription': 'Capture the screen regions you select.',
                    'NSAccessibilityUsageDescription': 'Attach selected context and paste into your chosen input.'}, file)
            swift_arch = 'arm64' if arch == 'arm64' else 'x86_64'
            run('xcrun', 'swiftc', '-swift-version', '5', '-O', '-parse-as-library', '-target', f'{swift_arch}-apple-macos12.0',
                source/'src/Focalet.Capture.Mac/MacRegionSelector.swift', source/'src/Focalet.Capture.Mac/CaptureApp.swift', '-o', binary)
            entry = binary.relative_to(destination).as_posix()
        elif target == 'linux':
            for pattern in ('src/Focalet.Capture.Linux/*.py', 'src/Focalet.Capture.Unix/*.py'):
                for file in source.glob(pattern): shutil.copy2(file, destination)
            shutil.copy2(source/'src/Focalet.Capture.Linux/Resources/app-icon.png', destination)
            # Cache compiled native dependencies, but select only the capture helper.
            env = {**os.environ, 'CARGO_TARGET_DIR': str(ROOT/'target')}
            run('cargo', 'build', '--locked', '--release', '--manifest-path', source/'Cargo.toml', '-p', 'focalet-linux-capture', env=env)
            (destination/'native').mkdir()
            shutil.copy2(ROOT/'target/release/focalet-linux-capture', destination/'native')
            extension = destination/'gnome-extension/focalet@focalet'
            shutil.copytree(source/'src/Focalet.Gnome', extension)
            run('glib-compile-schemas', extension/'schemas')
            native = extension/'native'; native.mkdir()
            flags = subprocess.check_output(['pkg-config', '--cflags', '--libs', 'libmutter-14'], text=True).split()
            run('cc', '-shared', '-fPIC', '-O2', '-Wall', '-Wextra', '-Werror', source/'src/Focalet.Capture.Linux/clipboard.c',
                '-o', native/'libfocalet-clipboard.so', *flags)
            gir = subprocess.check_output(['pkg-config', '--variable=girdir', 'libmutter-14'], text=True).strip()
            gi_env = {**os.environ, 'LD_LIBRARY_PATH': ':'.join([str(native), gir, os.environ.get('LD_LIBRARY_PATH', '')])}
            run('g-ir-scanner', f'--add-include-path={gir}', '--quiet', '--warn-all', '--namespace=FocaletClipboard', '--nsversion=1.0',
                '--identifier-prefix=FocaletClipboard', '--symbol-prefix=focalet_clipboard', '--include=Meta-14',
                '--library=focalet-clipboard', f'--library-path={native}', '--pkg=libmutter-14',
                source/'src/Focalet.Capture.Linux/clipboard.h', source/'src/Focalet.Capture.Linux/clipboard.c',
                '-o', native/'FocaletClipboard-1.0.gir', env=gi_env)
            run('g-ir-compiler', f'--includedir={gir}', native/'FocaletClipboard-1.0.gir', '-o', native/'FocaletClipboard-1.0.typelib')
            launcher = destination/'focalet-capture'
            launcher.write_text('#!/bin/sh\nexport PYTHONDONTWRITEBYTECODE=1\nexec /usr/bin/python3 "$(dirname "$(readlink -f "$0")")/capture.py" "$@"\n')
            launcher.chmod(0o755); entry = launcher.name
        else:
            run('dotnet', 'publish', source/'src/Focalet.CaptureTool/Focalet.CaptureTool.csproj', '--configuration', 'Release',
                '--runtime', runtime, '--self-contained', 'true', '-p:PublishSingleFile=true', '-p:DebugType=None',
                f"-p:Version={version['version']}", '--output', destination, cwd=source)
            shutil.copy2(source/'src/Focalet.CaptureTool/app.ico', destination)
            entry = 'Focalet.Capture.exe'
        if target != 'windows':
            run('dotnet', 'publish', source/'src/Focalet.BrowserCapture/Focalet.BrowserCapture.csproj', '--configuration', 'Release',
                '--runtime', runtime, '--self-contained', 'true', '-p:PublishSingleFile=true', '-p:DebugType=None',
                '--output', resources/'native', cwd=source)
        for name in ('LICENSE', 'THIRD_PARTY_NOTICES.md'):
            shutil.copy2(source/name, resources)
        shutil.copy2(source/'docs/capture-tool.md', resources/'README.md')
        (resources/'VERSION').write_text(version['releaseVersion']+'\n')
        signing = 'unsigned'
        if target == 'macos':
            identity = os.environ.get('FOCALET_MACOS_SIGNING_IDENTITY', '-')
            for file in resources.rglob('*'):
                if file.is_file() and file.read_bytes()[:4] in (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe'):
                    options = ['--options', 'runtime', '--timestamp'] if identity != '-' else []
                    if file.name == 'focalet-browser-capture':
                        options += ['--entitlements', str(source/'scripts/macos-browser-entitlements.plist')]
                    run('codesign', '--force', '--sign', identity, *options, file)
            run('codesign', '--force', '--sign', identity, app)
            run('codesign', '--verify', '--deep', '--strict', app)
            signing = 'ad-hoc' if identity == '-' else 'identity-signed'
        if target == 'linux': verify_ubuntu_abi(destination)
        if target != 'windows':
            probe = subprocess.run([str(resources/'native/focalet-browser-capture')], input='\n'.join([json.dumps({'id': 'ping', 'method': 'ping'}), json.dumps({'id': 'shutdown', 'method': 'shutdown'})])+'\n', text=True, capture_output=True, check=True, timeout=30)
            replies = [json.loads(line) for line in probe.stdout.splitlines()]
            if not replies or replies[0].get('result', {}).get('ready') is not True:
                raise ValueError('Packaged browser helper did not complete its startup handshake.')
        manifest = {'product': 'Focalet Capture', 'version': version['version'], 'releaseTag': version['tag'],
                    'gitCommit': commit, 'runtime': runtime, 'platform': target, 'architecture': arch,
                    'entryPoint': entry, 'signing': signing}
        (destination/'capture-tool-manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
        files = sorted(p for p in destination.rglob('*') if p.is_file())
        (destination/'SHA256SUMS.txt').write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.relative_to(destination).as_posix()}\n' for p in files))
    print(destination)
    return destination


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('platform', choices=['windows', 'macos', 'linux'])
    parser.add_argument('--output', type=Path, default=ROOT/'artifacts')
    args = parser.parse_args(); package(args.platform, args.output.resolve())
