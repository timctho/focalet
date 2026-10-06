# Build and test on Ubuntu

The primary Linux target is **Ubuntu 24.04 LTS x64** with its default **Wayland**
desktop. Use a desktop installation or a VM with a graphical session. Confirm
the session with:

```sh
echo "$XDG_SESSION_TYPE"
```

Use `wayland` for desktop acceptance. Focalet targets GNOME 46 on Ubuntu 24.04;
X11 sessions and other desktop environments are outside the supported scope.
A headless server or WSL terminal can run the isolated GNOME checks below, but
real monitor scaling, tray behavior and permissions should also be tested on a
desktop installation.

Focalet uses ScreenCast/PipeWire for monitor pixels, the bundled GNOME extension
for window identity, geometry and Alt+A, and AT-SPI for accessibility. Authorized
browser connections add DOM details. The extension supports GNOME 46; new GNOME
major versions need explicit compatibility testing.

## Install a release

When an Ubuntu asset is listed in [Releases](https://github.com/timctho/focalet/releases),
download `Focalet-Ubuntu-amd64.deb` and check it against `SHA256SUMS.txt`, then run:

```sh
sudo apt install ./Focalet-Ubuntu-amd64.deb
focalet
```

`sudo dpkg -i Focalet-Ubuntu-amd64.deb` also works, but does not fetch dependencies;
follow it with `sudo apt-get -f install` if needed. The package installs under
`/opt/focalet` with an app-menu entry. You do not need Flutter, Rust or .NET to run
it. Enable **Focalet Desktop Integration** in first-run setup or App settings.
If GNOME has not loaded a newly installed extension, sign out and sign in, then
retry Enable. The app remains available while desktop integration is disabled.
The [release workflow](public-releases.md#run-a-release-from-github-actions)
can build and publish this asset. Existing previews without a `.deb` still
require a source build.

## If desktop integration fails

Open **App settings → Ubuntu desktop integration** and recheck. Focalet queries
the running GNOME compositor; an inherited `XDG_SESSION_TYPE` value alone does
not decide whether capture is supported. **Copy desktop diagnostics** includes
the detected session, GNOME version, loaded extension path and failure reason.

- **Xorg / X11:** at the login screen, select your user and choose **Ubuntu**
  from the gear menu, rather than **Ubuntu on Xorg**. If Wayland is unavailable,
  logging out again will not enable it; check your system's Wayland configuration.
- **WSLg without GNOME:** WSL app windows do not provide a GNOME desktop.
  Use the Windows build to capture Windows, or use an Ubuntu 24.04 desktop/VM.
- **Extensions disabled globally:** turn on extensions in Ubuntu's **Extensions**
  app. If only Focalet is disabled, choose **Enable desktop integration** in Focalet.
- **Disconnected integration:** choose **Repair desktop integration**. This
  disables and re-enables the integration without losing your chat.
- **Extension load error:** inspect the reported error and installation path.
  Fix the reported problem or reinstall the Ubuntu package before starting a new
  desktop session. GNOME cannot retry an extension in its error state by toggling it.
- **Missing or older extension:** reinstall the Ubuntu `.deb`, then sign out
  of the desktop once to load it. GNOME cannot replace already imported extension
  code until a new desktop session. If this persists, inspect `extensionPath` in
  the copied diagnostics: a copy under your user data directory can override the
  system extension. Back up that older copy outside `gnome-shell/extensions`,
  then sign out once and recheck.
- **Session bus unavailable:** launch Focalet from Ubuntu's app menu as your normal
  user, without `sudo` or SSH.

If it still fails, include the copied diagnostics in your report. They are not
uploaded automatically. Repeatedly restarting Focalet or signing out without
addressing the reported condition will not repair it.

## Build and launch from source

Clone the repository, then install Rust **1.93.0** and Flutter **3.47.2** with
their commands on `PATH` (see [toolchain setup](../CONTRIBUTING.md#set-up)).
Install the Ubuntu build dependencies:

```sh
sudo apt-get update
sudo apt-get install -y binutils clang cmake ninja-build pkg-config libgtk-3-dev libwebkit2gtk-4.1-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev gstreamer1.0-pipewire libepoxy-dev \
  libayatana-appindicator3-dev libx11-dev libsqlite3-dev python3 python3-venv
flutter config --enable-linux-desktop
flutter doctor -v
```

From the repository root:

```sh
bash scripts/package-unix.sh linux
bash scripts/install-gnome-extension.sh artifacts/focalet-linux-x64
./artifacts/focalet-linux-x64/focalet
```

The output includes `artifacts/focalet-linux-x64.tar.gz` and its SHA-256 sidecar.
Keep the extracted directory together: the app needs its adjacent libraries,
Rust broker and capture helper. To create the Debian installer locally, install
`dpkg-dev` and run:

```sh
python3 scripts/build_installer.py artifacts/focalet-linux-x64 \
  --expected-commit "$(git rev-parse HEAD)" \
  --output artifacts/installers
```

The package retains the release version from `src/Focalet.Flutter/pubspec.yaml`;
no manual tag is needed. Windows release assets cannot run as the Ubuntu app.

## Package compatibility

Release builds require Ubuntu **24.04**, including for local packaging. A newer
host can use a 24.04 VM or container. Keep the Linux release runner on
`ubuntu-24.04` while this version is supported.

Package verification uses `readelf` from `binutils` to check every bundled ELF
binary and shared library. It rejects requirements above `GLIBC_2.39`,
`GLIBCXX_3.4.32` or `CXXABI_1.3.14`, matching the installer's `libc6 >= 2.39` and
`libstdc++6 >= 13.2` dependency floors. This catches incompatible prebuilt
components even on the correct build OS, and still runs with
`--skip-process-smoke`. It does not replace installed-package startup tests or
detect every dynamically loaded dependency.

Ubuntu 22.04 and newer Ubuntu releases are not release targets. Before adding a
future release, check its available package names (especially `libicu74` and
the `t64` libraries), install and launch the `.deb` in a clean environment, and
run the desktop checks below. Keep building on 24.04 while supporting it; review
ABI limits and Debian dependencies together when changing the baseline.

## Try the desktop flow

Install and sign in to a supported agent CLI in Ubuntu, and verify that it works
from the same terminal before launching Focalet. For a first-run test without
changing existing Focalet settings, launch with separate data directories:

```sh
focalet_test_profile=$(mktemp -d /tmp/focalet-ubuntu-test.XXXXXX)
XDG_CONFIG_HOME="$focalet_test_profile/config" \
XDG_STATE_HOME="$focalet_test_profile/state" \
XDG_CACHE_HOME="$focalet_test_profile/cache" \
  ./artifacts/focalet-linux-x64/focalet
```

For a `.deb` installation, replace the last line with `focalet`.

This isolates Focalet preferences, detection and local history metadata. Agent CLIs
inherit these XDG directories too, so agents that use them may need sign-in or
configuration in the test profile. Sending a message creates a real agent
conversation; the automated checks below use fake agents instead.

1. In **Welcome to Focalet**, confirm the installed agent appears, connect, and
   send a message. After signing in or changing providers, use **Refresh agents**
   and check the model list.
2. Open a native Wayland app. Press **Alt+A** or choose **Select** in Focalet,
   then authorize the monitors to share with **Remember this selection** enabled.
   Confirm later captures and a restarted app reuse the grant without another
   Share prompt. Select several regions, draw, undo/redo
   and press **Enter**. Verify original pixels, text, values and checkbox states
   match the selected source; password, hidden and outside-region content must
   not be included. Supported Chromium browsers can add DOM through an authorized
   connection (see [browser context](browser-context.md)). Apps that expose no
   accessibility retain images with an explanation.
   Cancel both the portal prompt and editor with **Escape**, then retry. Change
   the source while the editor is open: retain the original image and drawings,
   and downgrade to **Image only** when the source no longer matches. Test
   fractional scaling, multiple monitors, negative monitor origins and rotation.
   Disable/re-enable the GNOME extension and stop screen sharing during selection;
   recovery must not lose the chat or draft.
   Check all four window corners, and verify capture/Cancel returns to a painted
   chat at the original size, without a white or black surface.

3. Type an unsent draft, close with **X**, and reopen from the tray. Check that
   the chat and draft remain. Choose **Quit** to exit. Ubuntu's AppIndicator
   extension must be enabled to show the tray icon.
4. Restart with the same test directories and check the saved session. Then
   test an unavailable agent: connection failure should release the controls and
   offer recovery without losing the draft.

## Automated checks

Install the remaining contributor tools and Python dependencies from
[CONTRIBUTING.md](../CONTRIBUTING.md#set-up). On Ubuntu 24.04, use a Python virtual
environment rather than installing packages into the OS-managed Python:

```sh
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r tests/requirements.txt
python scripts/check.py --suite rust --suite flutter
```

These tests use local fake agents and need no account. `python scripts/check.py`
runs all suites, including browser and managed capture contracts.

The native acceptance test starts a private GNOME Wayland compositor, D-Bus,
PipeWire, desktop portals and synthetic apps. It does not use the logged-in
user's session or settings:

```sh
sudo apt-get install -y gnome-shell xdg-desktop-portal-gnome pipewire wireplumber \
  dbus-x11 python3-pyatspi python3-gi gir1.2-gtk-3.0 gir1.2-gtk-4.0 python3-pil
cargo build --locked --bin focalet-linux-capture
/usr/bin/python3 scripts/accept-linux-wayland.py
/usr/bin/python3 scripts/accept-linux-wayland.py --package artifacts/focalet-linux-x64 \
  --browser /usr/bin/google-chrome
```

The tests cover compositor detection with stale or missing session variables,
unavailable desktops, extension recovery, GTK 3/4 pixels and accessibility
geometry, password filtering, portal cancellation, packaged selection/drawing, and floating
HTML previews. `--browser` adds native Wayland Chromium DOM alignment. GTK 4 text
input values are intentionally omitted when masked fields cannot be distinguished.
For an installed `.deb`, use `--package /opt/focalet --system-extension` to also
verify that GNOME discovers the extension from its system installation path.

Evidence goes to `artifacts/wayland-acceptance`. CI uses the same test. Real GNOME
tray integration and physical display configurations still need the desktop
steps above. Include the source revision, Ubuntu/GNOME version, monitor scaling
and failing step when reporting a problem.
