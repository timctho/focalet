# macOS test package

Source builds need Xcode and CocoaPods **1.17.0** (`gem install cocoapods --version
1.17.0 --no-document`) in addition to the toolchains in [Contributing](../CONTRIBUTING.md).
Use `scripts/package-unix.sh macos`: it applies the macOS 12 deployment target
to Swift packages and CocoaPods dependencies as well as the app. The committed
Podfile, lockfile and Xcode integration include plugins that still require CocoaPods.

CI builds Apple Silicon (`arm64`, `macos-15`) by default. Dispatch CI with
`macos_arch: x64` for Intel (`macos-15-intel`). A dispatch with `macos_only: true`
and `macos_draft_release: true` provides the ZIP and probe evidence through a
private draft release, independent of Actions artifact quota. Alternatively use
`upload_packages: true` for seven-day Actions artifacts. Download the matching
architecture's ZIP, then check it with
`shasum -a 256 -c zommi-macos-<arch>.zip.sha256` before extracting it.
The ZIP includes the app, release identity and checksums. Move `Zommi.app` to
Applications before granting permissions so the app keeps a stable location.

The default package is ad-hoc signed and is not notarized. For a trusted test
build, use Finder's Open action and, if macOS blocks it, System Settings >
Privacy & Security > Open Anyway. Developer ID signing can be supplied through
`ZOMMI_MACOS_SIGNING_IDENTITY`; it does not itself notarize the app. For repeated
local builds, select an existing Apple Development or Developer ID certificate
from `security find-identity -v -p codesigning`, then save its name or fingerprint:

```bash
git config --local zommi.macosSigningIdentity '<chosen signing identity>'
bash scripts/package-unix.sh macos
```

The environment variable overrides this checkout-local setting. The package
manifest records the actual signing authority and team. Keep the same identity
and `/Applications/Zommi.app` path across updates. Ad-hoc signatures identify the
binary by its hash, so every rebuild can invalidate Screen Recording and
Accessibility grants even while System Settings still displays Zommi as enabled.
Switching from an ad-hoc build to a certificate-signed build needs a one-time
grant for the new identity. If the old entry remains enabled but access is
denied after reopening, remove that stale Zommi entry and add the installed app
again using **+**. Subsequent builds must keep the saved signing identity.

## First launch

The default window is 900×760 points; the large setting is 1100×860. Both fit to
the display's available work area. A fresh install opens a small welcome flow:

1. Detect local agent runtimes and select the one to use.
2. Sign in through that runtime's terminal command if needed. Scan again after
   installing an agent, or use Configure runtime to choose its executable.
3. Connect and continue, or explicitly choose Set up later. Existing settings
   skip the welcome flow. A failed connection or settings save leaves it open.

Finder launches also search Homebrew and the common user-local executable
folders, passing that PATH to both the broker and its runtime children. Unusual
locations can be added through Configure runtime.

Zommi keeps authentication, models and history owned by the selected runtime.
The welcome flow also checks Accessibility (application context and AX element capture) and
Screen Recording (images). If screenshot access is missing, Select and Option+A
show an explanation before capture. Click **Open System Settings**, then turn on
**Zommi** under **Privacy & Security > Screen & System Audio Recording** (called
**Screen Recording** on older macOS versions). If Zommi is missing, use **+** to
add it from Applications. Choose **Quit & Reopen** if macOS asks. The dialog
rechecks permission when you return, also offers **Check again**, and starts the
picker only when you click **Start selecting**. **Not now** cancels without a
permission request or capture. The Screen Recording Allow button in setup and
App settings opens the same guide. Browser URLs may additionally trigger macOS
Automation consent for System Events and the selected browser. Enable denied
permissions under Privacy & Security, then restart Zommi when macOS requires it.
Permission checks and capture failures never open Settings themselves. Only
the guide's explicit button requests Screen Recording, at most once per launch;
later clicks can reopen the pane without repeating the system request.

## Native build and automated evidence

The Mac runner uses Flutter's Skia Metal backend. Flutter 3.47's default
wide-gamut Impeller path produced invalid pixel-format blits and a black window
on the native Apple Silicon runner. GPU rendering remains enabled. Acceptance
also checks the restored app's visible pixels and retains its screenshot.

The macOS CI job compiles Flutter and Rust on the selected Mac architecture,
assembles and verifies the signed app/checksums, and runs the Rust core's actual
initialize/shutdown exchange. It then launches the packaged Zommi to probe its
native permission channel, window size, external TextEdit context and screen
pixels when permission permits. It also verifies the app survives hiding its
window for capture, then restores it. Evidence includes JSON, startup logs and a desktop screenshot if the runner
allows one. Every run also prints the probe and startup log; manual dispatch can
retain the evidence in a draft release or Actions artifact.

A successful startup probe with `captureVerified: false` is **not** capture
acceptance. Hosted runners may have no TCC grants. From the extracted package
folder on your Mac, close Zommi, enable its permissions, then run:

```bash
python3 docs/accept-macos.py . --output macos-acceptance --require-capture
```

The script opens a disposable TextEdit fixture and uses LaunchServices to start
the app with its own macOS permission identity. Directly executing the binary
can inherit the terminal or automation host's TCC identity instead. To test the
copy already granted permission in Applications, add `--app /Applications/Zommi.app`.
The report identifies the process and executable. It requires the fixture's
actual text in a region attachment, aligned Accessibility elements and captured
pixels. This backend check does not inject mouse gestures. It closes only the Zommi process it started;
it never changes permissions automatically. Temporary captured pixels are
removed; the output desktop screenshot remains in your local evidence folder.

For a separately launched local Chromium fixture, pass `--window-title`,
`--expected-text`, `--browser-endpoint` and `--require-dom`. This exercises the
installed app's native AX viewport and the packaged DOM helper together. A
normal browser without an authorized CDP connection can provide AX context but
does not count as a DOM pass. The probe never enables CDP in the user's browser.

Native window binding ignores the omitted cursor and uses the Dock's actual AX
list bounds instead of macOS 26's full-display transparent backing window.
Recording indicators outside the crop no longer erase unrelated window data;
changed or overlapping windows still block that region. Kernel process start
times identify CLI-launched browsers, and Chromium's lazy AX tree is requested
for the selected app, with a bounded wait for its first web subtree. Repeated AX observations compare nested values rather
than dictionary insertion order; changed text, bounds or element order still
discard semantic metadata.

## Interactive capture acceptance

The interactive probe drives the shared capture editor with CGEvents, verifies
the PNG matches its region mapping, and cancels a second selection with Escape. This
requires input permission for the driver as well as Zommi capture permissions.
Run the same path with `--interactive` on an authorized test desktop. Use
`--manual-interactive` to drive the two gestures yourself or through Computer
Use without launching the CGEvent driver. Otherwise manually
verify these gestures:

1. With TextEdit or Safari in front, press Option+A or click Select, then drag a
   rectangle. Continue dragging to add up to eight boxes, with no modifier key
   required. Press Enter or click Attach to add the batch in selection order.
   **Delete** removes the selected box; Escape or Cancel discards the batch.
   Select a display from the menu to add regions from another monitor. Choose
   pen, arrow, shape or highlighter; **Cmd+Z** undoes and **Cmd+Shift+Z** redoes
   drawings independently for each region.
2. Check each image preview against the selected pixels. The overlay freezes
   the displays before selection, and crops the original pixels without its
   dimming, borders, labels or toolbar. Screen coordinates and Retina image
   dimensions are retained. Stable accessible apps include AX text, roles, states
   and image-coordinate bounds. Change the source while selecting: the image and
   drawings stay, and stale AX/DOM context must be discarded.
3. Repeat and press Escape: cancellation must add no image.
4. Deny Screen Recording and retry: Zommi should explain how to enable it.
   Grant it, restart if requested, and repeat selection successfully.
5. Quit/reopen: the welcome flow should stay completed, and Zommi should discover
   and reconnect to the runtime normally.

Record the commit from `release-manifest.json`, macOS version, architecture and
these results when reporting an issue. A mock test or Linux build cannot replace
this native evidence.
