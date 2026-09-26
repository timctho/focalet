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
| Every PR, including forks; every push to `main`; manual dispatch | [PR checks](../.github/workflows/checks.yml), GitHub-hosted `ubuntu-24.04`, `windows-2025`, `macos-15`, `macos-15-intel` | Tests and a native release-mode package on each platform and Mac architecture; no installer upload or published Release |
| A release version change pushed to `main` | [Release workflow](../.github/workflows/release.yml), GitHub-hosted Windows, Ubuntu and both Mac architectures | Builds, checks and automatically publishes all four installers |
| Manual dispatch of Build and publish release | Same release workflow, GitHub-hosted runners for the selected platforms | Builds installers and optionally publishes after every selected build passes |
| Manual dispatch of Native acceptance | [Native acceptance](../.github/workflows/ci.yml); Ubuntu/Windows on opted-in self-hosted runners, Mac on GitHub-hosted runners | Native acceptance and optional package artifacts; Mac can create an installer in a draft release |
| Maintainer runs `publish_release.py --publish` with accepted installer metadata | Maintainer's build/publication environment | Publishes the verified installers, checksums and source manifest to GitHub Releases |

PR checks have no path filters: a documentation-only PR also runs those checks.
Automatic releases watch `src/Zommi.Flutter/pubspec.yaml` on `main` and compare
its release version before and after the whole push. An unchanged release
version, a dependency/description edit or a build-number-only change skips
installer builds and publication. Pushing a Git tag does not trigger a release.

Making the repository public preserves these triggers and runner choices.
[Standard GitHub-hosted runners are free for public repositories](https://docs.github.com/en/billing/concepts/product-billing/github-actions);
larger runners are billed separately. Actions still has to be enabled, and fork
contributions can require approval before their workflow runs. Public visibility
does not move self-hosted jobs to GitHub's machines or change release triggers.

## Run a release from GitHub Actions

Change the app version in a PR, review the changes and merge it into `main`.
That version change starts the release automatically; no extra button or manual
Git tag is needed. The committed `version` in
[`src/Zommi.Flutter/pubspec.yaml`](../src/Zommi.Flutter/pubspec.yaml) is the source:

```yaml
version: 0.1.0-preview.8+1
```

This produces tag `v0.1.0-preview.8` and a prerelease. A version such as
`0.1.0+2` produces the stable tag `v0.1.0` and marks the release as latest.
The `+N` is Flutter's build number; it is not part of the Git tag. The workflow
creates the tag at the exact built commit when publishing. Before a subsequent
release, bump the version in a PR (for example to `0.1.0-preview.9+2`); changing
only `+N` does not create a new release version. Published tags are never overwritten.

GitHub sorts releases from the same day by their numeric version, then compares
prerelease suffixes alphabetically. That puts `preview.9` above `preview.10`.
Before crossing that boundary, increase the patch version and restart the preview
counter: for example, use `0.1.1-preview.1+5` after `0.1.0-preview.11+4`.
The publisher rejects tags that could sort below an existing version. Leave old
tags and installers unchanged; their manifests identify their original versions.

Automatic releases use the `all` platform set: Windows x64, Ubuntu x64, macOS
Apple Silicon and macOS Intel. The workflow builds the installers once, runs
the release checks below and publishes those same files only if every selected
platform succeeds. A failed or cancelled check
prevents publication. Adding this workflow without a version change does not
retroactively publish the version already in the file.

### Manual builds and retries

The manual entry remains available for build-only checks, other platform sets
and recovery. Open **Actions → Build and publish release → Run workflow**, select
`main` and choose:

| Input | Meaning |
| --- | --- |
| `platforms` | `all` (default), `windows-ubuntu`, `windows`, `ubuntu`, `macos` (both Mac architectures), `macos-arm64`, or `macos-x64` |
| `publish` | Off: retain installers as Actions artifacts. On: publish them to this repository's Releases after all selected builds pass |

For example, build all four installers without publishing:

```sh
gh workflow run release.yml --ref main \
  -f platforms=all -f publish=false
```

Set `publish=true` to build and publish in one run. For an infrastructure failure,
rerun the original failed workflow to keep its exact source SHA. If a code fix is
needed, merge it and manually build/publish the corrected `main`, or bump the
release version in that PR. An already published version always needs a new tag.
A new manual dispatch rebuilds from the selected `main`; it does not promote
artifacts from an earlier build-only run.

All jobs use the triggering push or dispatch's exact source SHA even if `main`
advances. Runs for different commits do not cancel each other; publication for
the same tag is serialized. The workflow requires `main`, pins its
actions, gives build jobs read-only access, and grants `contents: write` only to
the final publication job. It needs no personal access token or self-hosted
runner; `GITHUB_TOKEN` publishes into this repository.

Ubuntu produces `Zommi-Ubuntu-amd64.deb`, Windows produces `Zommi-Setup-x64.exe`,
and Mac produces architecture-specific DMGs. Ubuntu builds require 24.04 and
validate bundled ELF runtime requirements against the
[package compatibility baseline](ubuntu-testing.md#package-compatibility) before
creating an installer. Installers are unsigned by this
workflow; Mac apps use ad-hoc signing and DMGs are not notarized. Ubuntu runs an
installed-package GNOME Wayland check in a private virtual desktop and removes the package;
Windows runs packaged non-visual capture checks; Mac verifies selection geometry
and the mounted DMG. Ubuntu's automated checks use real GNOME, portals and synthetic apps;
physical display and tray acceptance also needs the
[GNOME desktop checks](ubuntu-testing.md#try-the-desktop-flow). These checks do
not replace real desktop acceptance of tray menus, OS permissions, or agent sign-in.

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

On a local Mac, build the native architecture and create the same verified DMG:

```sh
bash scripts/package-unix.sh macos
python3 scripts/build_installer.py artifacts/zommi-macos-arm64 \
  --expected-commit "$(git rev-parse HEAD)" --output artifacts/installers
```

Use `zommi-macos-x64` on Intel. The installer builder smoke-tests the bundled
helpers, verifies the DMG, mounts it, compares the app payload and checks its
signature. Run the [Mac acceptance checks](macos-testing.md) for capture and
permissions as well. These local builds remain available when hosted Actions
cannot start.

## Prepare and publish

Collect the accepted installer and its `.release.json` sidecar. With an
authenticated local `gh` session, prepare a Windows preview:

```sh
python scripts/publish_release.py --repository timctho/zommi \
  --tag "$(python scripts/release_version.py)" --expected-commit <main-sha> \
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
Mac Apple Silicon `.release.json` metadata; Mac Intel is optional. For a Mac-only
preview, use `--platforms macos` with both DMGs, or explicitly select
`--platforms macos-arm64` or `--platforms macos-x64` with the corresponding
`.release.json`. Every selected installer must be present; choosing `macos`
still requires both architectures. Automatic version releases still require all
four installers.

After publication, download the actual installer and checksum files from
`timctho/zommi` and compare them with the accepted local bytes. Use authenticated
downloads for a private repository; also verify anonymous downloads if it is
public. Keep the repository's visibility unchanged.

The README download table lists each platform and Mac architecture separately.
Update a row's versioned installer link only after that asset is published and
its download has been verified. Until then, label the planned installer and link
to the `/releases` page; do not advertise an unavailable download. Different
platforms can link to different accepted releases. Keep the installation guide
and the table's all-releases link on `/releases`, which includes previews.
GitHub's `/releases/latest` excludes prereleases and returns 404 while only
previews exist.

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
