# macOS test package

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
`ZOMMI_MACOS_SIGNING_IDENTITY`; it does not itself notarize the app.

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
The welcome flow also checks Accessibility (application/title context) and
Screen Recording (images). Permission requests happen only when you press
Allow or invoke image capture. Browser URLs may additionally trigger macOS
Automation consent for System Events and the selected browser. Enable denied
permissions under Privacy & Security, then restart Zommi when macOS requires it.

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

The script opens a disposable TextEdit fixture and starts only this package.
The report identifies the process and executable. It requires the fixture's
real title and a decodable screen image. It closes the Zommi process it started;
it never changes permissions automatically. Temporary captured pixels are
removed; the output desktop screenshot remains in your local evidence folder.

## Interactive capture acceptance

CI also drives the real native rectangle selector with CGEvents, checks the PNG
matches a 120×80-point drag (allowing the native selector's inclusive edge
pixel), and cancels a second selection with Escape. This
requires input permission for the driver as well as Zommi capture permissions.
Run the same path with `--interactive` on an authorized test desktop, or manually
verify these gestures:

1. With TextEdit or Safari in front, press Option+A or click Select, then drag a
   rectangle. Check the image and available foreground application/title context;
   Safari context should include its URL after granting Automation consent.
2. Check the image preview against the selected pixels. Foreground metadata is
   best-effort context, not element-level hit testing of the selected rectangle.
3. Repeat and press Escape: cancellation must add no image.
4. Deny Screen Recording and retry: Zommi should explain how to enable it.
   Grant it, restart if requested, and repeat selection successfully.
5. Quit/reopen: the welcome flow should stay completed, and Zommi should discover
   and reconnect to the runtime normally.

Record the commit from `release-manifest.json`, macOS version, architecture and
these results when reporting an issue. A mock test or Linux build cannot replace
this native evidence.
