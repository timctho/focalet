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

## When builds run

| Trigger | Workflow / machine | Result |
| --- | --- | --- |
| Every PR, including forks; every push to `main`; manual dispatch | [PR checks](../.github/workflows/checks.yml), GitHub-hosted `ubuntu-24.04`, `windows-2025`, `macos-15` | Tests and a native release-mode package on each platform; no installer upload or published Release |
| Manual dispatch of Build and publish release | [Release workflow](../.github/workflows/release.yml), GitHub-hosted Ubuntu, Windows and selected Mac architectures | Builds installers and optionally publishes a GitHub Release after every selected build passes |
| Manual dispatch of Native acceptance | [Native acceptance](../.github/workflows/ci.yml); Ubuntu/Windows on opted-in self-hosted runners, Mac on GitHub-hosted runners | Native acceptance and optional package artifacts; Mac can create an installer in a draft release |
| Maintainer runs `publish_release.py --publish` with accepted installer metadata | Maintainer's build/publication environment | Publishes the verified installers, checksums and source manifest to GitHub Releases |

There are no path filters: a documentation-only PR also runs PR checks. Uploading
an Actions artifact and publishing a GitHub Release are separate operations.
The release workflow is **manual only**. Pushing a version tag or changing the
repository to public does not trigger it.

Making the repository public preserves these triggers and runner choices.
[Standard GitHub-hosted runners are free for public repositories](https://docs.github.com/en/billing/concepts/product-billing/github-actions);
larger runners are billed separately. Actions still has to be enabled, and fork
contributions can require approval before their workflow runs. Public visibility
does not move self-hosted jobs to GitHub's machines or make manual releases automatic.

## Run a release from GitHub Actions

Open **Actions → Build and publish release → Run workflow** and select `main`.

| Input | Meaning |
| --- | --- |
| `tag` | A new tag matching the app version, such as `v0.1.0-preview.8` |
| `platforms` | `windows-ubuntu` (default), `all`, `windows`, `ubuntu`, or `macos` (both Mac architectures) |
| `publish` | Off: retain installers as Actions artifacts. On: publish them to this repository's Releases after all selected builds pass |
| `prerelease` | On by default. Off requires the exact stable app tag, such as `v0.1.0`, and marks it as the latest release |

For example, build a Windows/Ubuntu preview without publishing:

```sh
gh workflow run release.yml --ref main \
  -f tag=v0.1.0-preview.8 -f platforms=windows-ubuntu \
  -f publish=false -f prerelease=true
```

Set `publish=true` to build and publish in one run. All jobs use the dispatch's
exact source SHA even if `main` advances. The workflow requires `main`, pins its
actions, gives build jobs read-only access, and grants `contents: write` only to
the final publication job. It needs no personal access token or self-hosted
runner; `GITHUB_TOKEN` publishes into this repository.

Ubuntu produces `Zommi-Ubuntu-amd64.deb`, Windows produces `Zommi-Setup-x64.exe`,
and Mac produces architecture-specific DMGs. Installers are unsigned by this
workflow; Mac apps use ad-hoc signing and DMGs are not notarized. Ubuntu runs an
installed-package X11 check in a virtual display and removes the package;
Windows runs packaged non-visual capture checks; Mac verifies selection geometry
and the mounted DMG. These checks do not replace real desktop acceptance of tray
menus, OS permissions, or agent sign-in.

Each selected platform must succeed. Missing platforms, mixed source revisions,
incorrect Ubuntu package versions and changed installer hashes stop publication.
The publisher checks uploaded digests before making the draft public, and refuses
to overwrite a published release. Build-only runs retain artifacts for seven
days and create no release or tag. Actions must be available for the account;
jobs blocked by billing or runner availability have not built anything.

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
