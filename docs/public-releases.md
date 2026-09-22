# Releases in the Zommi repository

Publish installers in [timctho/zommi Releases](https://github.com/timctho/zommi/releases),
alongside the source. Release tags point to the exact accepted source revision.
Releases inherit repository visibility; publishing does not change it. Downloads
from a private repository require GitHub access. Actions artifacts expire and
are not the release distribution channel.

Each release lists only the platforms actually accepted for that revision,
with checksums and a manifest recording the source SHA. Windows previews can
contain only the per-user Windows installer. Mac disk images are included when
built and accepted on that same revision. Raw desktop acceptance evidence stays
private and is not uploaded by the publisher.

## Build and accept one revision

Run the checks required by [CONTRIBUTING.md](../CONTRIBUTING.md) for the revision
and inspect hosted PR checks. Record unavailable CI separately from local results;
never describe jobs that did not start as passed.
Keep persistent runners reserved for operator-invoked native acceptance. Build Windows locally with
`scripts/package-windows.ps1 -Runtime win-x64`, then run the packaged Windows
acceptance scripts. The package bundles MSVC and .NET runtime libraries.
All platforms include the Apache 2.0 license and retained third-party notices.
On macOS these are copied inside the app before code signing, so they survive
installation from the DMG.

With NSIS 3 installed, create the Windows installer:

```sh
python scripts/build_installer.py artifacts/zommi-windows-x64 \
  --expected-commit <main-sha> --output artifacts/installers
```

NSIS can also wrap the Windows package on Linux (`--makensis /path/to/makensis`).
The installed payload must then be verified on Windows: install, compare every
packaged file, launch and capture from the installed location, uninstall, and
confirm that unrelated files and user settings remain.

```powershell
python scripts/accept_windows_installer.py artifacts/installers/Zommi-Setup-x64.exe `
  --expected-commit <main-sha> --output artifacts/installer-acceptance
```

This requires an interactive Windows desktop and PowerShell 7, and refuses to
overwrite an already registered Zommi installation. Existing portable Zommi
processes must be closed before the installer runs. The capture acceptance
helper suspends and restores conflicting app processes during its own checks.

For each Mac architecture, dispatch the manual Native acceptance workflow on the same
main revision:

```sh
gh workflow run ci.yml --ref main -f macos_only=true -f macos_arch=arm64 \
  -f macos_draft_release=true -f run_shared_runners=false
gh workflow run ci.yml --ref main -f macos_only=true -f macos_arch=x64 \
  -f macos_draft_release=true -f run_shared_runners=false
```

Architecture-specific concurrency allows both Mac builds to complete. CI builds
the app, checks interactive capture, creates the DMG, mounts it, compares the app
payload with the accepted package, and verifies its code signature. The private
draft releases `macos-test-<sha12>-<architecture>` retain the DMGs and their
`.release.json` metadata without consuming Actions artifact storage.

## Prepare and publish

Collect the accepted installer and its `.release.json` sidecar. With an
authenticated local `gh` session, prepare a Windows preview:

```sh
python scripts/publish_release.py --repository timctho/zommi \
  --tag v0.1.0-preview.6 --expected-commit <main-sha> \
  --windows-only \
  --metadata installers/Zommi-Setup-x64.exe.release.json \
  --output artifacts/release
```

This prepares the manifest, checksum list and release notes without changing
GitHub. Add `--publish` to verify that the source commit exists in the destination,
upload to a draft, check GitHub's asset digests and publish the preview. The tag
must match the installer version and source revision. Published tags cannot be
overwritten; choose a new version for each release. Existing draft assets must
belong to the same release asset set.

For a release with Windows and Mac, omit `--windows-only` and add the accepted
Mac Apple Silicon `.release.json` metadata; Mac Intel is optional. A partial
platform set is rejected unless the Windows-only preview is explicitly selected.

After publication, download the actual installer and checksum files from
`timctho/zommi` and compare them with the accepted local bytes. Use authenticated
downloads for a private repository; also verify anonymous downloads if it is
public. Keep the repository's visibility unchanged.

GitHub does not select prereleases for `/releases/latest`. Point the README's
Windows buttons and installation guide at
`/releases/download/<tag>/Zommi-Setup-x64.exe` for the current accepted preview.
General release links point to this repository's `/releases` page.

## Signing

The current installer builder produces an unsigned Windows setup executable and
a non-notarized Mac DMG. Operating systems may require
explicit opening confirmation; document that in preview release notes.

For a normal distribution release, sign the Windows application and installer
with Authenticode, and sign the Mac app with an Apple Developer ID, notarize and
staple the distribution. Recompute installer hashes after signing. The existing
package builders accept `ZOMMI_WINDOWS_SIGNING_THUMBPRINT` and
`ZOMMI_MACOS_SIGNING_IDENTITY`; signing only the app does not sign the installer
or notarize the Mac distribution.

Local publication needs no additional Actions secret. A workflow publishing in
this source repository can use its `GITHUB_TOKEN` with `contents: write`; no
separate downloads repository or cross-repository token is needed.
