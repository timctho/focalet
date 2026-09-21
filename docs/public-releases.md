# Public Windows and Mac downloads

Use a public downloads repository, `timctho/zommi-releases`, for GitHub Releases.
The source repository can remain private: releases in a private repository
cannot be downloaded anonymously. Actions artifacts also require authentication
and expire; they are not the public distribution channel.

The download repository contains an installation README and release assets.
Each release provides a per-user Windows installer, Mac disk images with an
Applications shortcut, checksums, and a manifest recording the exact source SHA.
The publisher never uploads the source checkout or desktop acceptance evidence.

## Build and accept one revision

Run `python3 scripts/check.py` and require the PR checks for the revision first.
Keep persistent runners reserved for operator-invoked native acceptance. Build Windows locally with
`scripts/package-windows.ps1 -Runtime win-x64`, then run the packaged Windows
acceptance scripts. The package bundles MSVC and .NET runtime libraries.

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
processes are suspended and restored by the capture acceptance helper.

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

Collect each installer and its `.release.json` sidecar into a local directory.
Create the public downloads repository with only the installation README; do
not copy the source checkout into it. Using an authenticated local `gh` session:

```sh
python scripts/publish_release.py --repository timctho/zommi-releases \
  --tag v0.1.0-preview.1 --expected-commit <main-sha> \
  --metadata installers/Zommi-Setup-x64.exe.release.json \
  --metadata installers/Zommi-macOS-arm64.dmg.release.json \
  --metadata installers/Zommi-macOS-x64.dmg.release.json \
  --output artifacts/public-release
```

This only prepares the manifest, checksum list, and release notes for review.
Add `--publish` to upload to a draft, verify GitHub's asset digests, and publish
the preview. Re-running against an already published tag is rejected. Use a new
tag for each version. Verify the final download URLs without GitHub credentials.

Preview releases are not selected by GitHub's `/releases/latest` URL. Link users
to the version's release page or `/releases/download/<tag>/<asset>` URLs from the
public README. A future stable release can use `/releases/latest/download/<asset>`.

## Signing

The current installer builder produces an unsigned Windows setup executable and
a non-notarized Mac DMG. Public downloads work, but operating systems may require
explicit opening confirmation; document that in preview release notes.

For a normal distribution release, sign the Windows application and installer
with Authenticode, and sign the Mac app with an Apple Developer ID, notarize and
staple the distribution. Recompute installer hashes after signing. The existing
package builders accept `ZOMMI_WINDOWS_SIGNING_THUMBPRINT` and
`ZOMMI_MACOS_SIGNING_IDENTITY`; signing only the app does not sign the installer
or notarize the Mac distribution.

Local publication needs no additional Actions secret. If publication later runs
inside the private source workflow, its default `GITHUB_TOKEN` cannot write to a
different repository; use a narrowly scoped GitHub App or token with Contents
write permission on the downloads repository.
