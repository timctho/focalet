# Build and test on Ubuntu

The primary Linux target is **Ubuntu 24.04 LTS x64** with its default **Wayland**
desktop. Use a desktop installation or a VM with a graphical session. Confirm
the session with:

```sh
echo "$XDG_SESSION_TYPE"
```

Use `wayland` for primary desktop acceptance. If a machine starts an X11 session,
choose a Wayland session at the login screen on a supported graphics setup.
**Ubuntu on Xorg** remains a compatibility test configuration. A headless server
or WSL terminal can run automated checks, but does not verify Ubuntu's tray,
permissions or desktop capture. Other Linux distributions are outside the
supported scope.

Wayland and X11 are desktop display systems: they coordinate windows, screen
content and input. Wayland restricts direct access to other apps, so Zommi uses
desktop portals for screenshots and global shortcuts. Portal support varies by
desktop version. Ubuntu 24.04 uses GNOME 46, while GNOME's global-shortcut portal
backend was [introduced in GNOME 48](https://gitlab.gnome.org/GNOME/xdg-desktop-portal-gnome/-/blob/48.0/NEWS).
Zommi currently relies on that portal for Wayland Alt+A, so use **Select** in the
app on stock Ubuntu 24.04. Shortcut integration for GNOME 46 and aligned
DOM/accessibility capture remain gaps in the primary target.

## Install a release

When an Ubuntu asset is listed in [Releases](https://github.com/timctho/zommi/releases),
download `Zommi-Ubuntu-amd64.deb` and check it against `SHA256SUMS.txt`, then run:

```sh
sudo apt install ./Zommi-Ubuntu-amd64.deb
zommi
```

`sudo dpkg -i Zommi-Ubuntu-amd64.deb` also works, but does not fetch dependencies;
follow it with `sudo apt-get -f install` if needed. The package installs under
`/opt/zommi` with an app-menu entry. You do not need Flutter, Rust or .NET to run
it. The [release workflow](public-releases.md#run-a-release-from-github-actions)
can build and publish this asset. Existing previews without a `.deb` still
require a source build.

## Build and launch from source

Clone the repository, then install Rust **1.93.0** and Flutter **3.47.2** with
their commands on `PATH` (see [toolchain setup](../CONTRIBUTING.md#set-up)).
Install the Ubuntu build dependencies:

```sh
sudo apt-get update
sudo apt-get install -y binutils clang cmake ninja-build pkg-config libgtk-3-dev libwebkit2gtk-4.1-dev libepoxy-dev \
  libayatana-appindicator3-dev libx11-dev libsqlite3-dev python3 python3-venv
flutter config --enable-linux-desktop
flutter doctor -v
```

From the repository root:

```sh
bash scripts/package-unix.sh linux
./artifacts/zommi-linux-x64/zommi
```

The output includes `artifacts/zommi-linux-x64.tar.gz` and its SHA-256 sidecar.
Keep the extracted directory together: the app needs its adjacent libraries,
Rust broker and capture helper. To create the Debian installer locally, install
`dpkg-dev` and run:

```sh
python3 scripts/build_installer.py artifacts/zommi-linux-x64 \
  --expected-commit "$(git rev-parse HEAD)" \
  --output artifacts/installers
```

The package retains the release version from `src/Zommi.Flutter/pubspec.yaml`;
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
from the same terminal before launching Zommi. For a first-run test without
changing existing Zommi settings, launch with separate data directories:

```sh
zommi_test_profile=$(mktemp -d /tmp/zommi-ubuntu-test.XXXXXX)
XDG_CONFIG_HOME="$zommi_test_profile/config" \
XDG_STATE_HOME="$zommi_test_profile/state" \
XDG_CACHE_HOME="$zommi_test_profile/cache" \
  ./artifacts/zommi-linux-x64/zommi
```

For a `.deb` installation, replace the last line with `zommi`.

This isolates Zommi preferences, detection and local history metadata. Agent CLIs
inherit these XDG directories too, so agents that use them may need sign-in or
configuration in the test profile. Sending a message creates a real agent
conversation; the automated checks below use fake agents instead.

1. In **Welcome to Zommi**, confirm the installed agent appears, connect, and
   send a message. After signing in or changing providers, use **Refresh agents**
   and check the model list.
2. Open another app, including a native Wayland app. In Zommi, choose **Select**
   and complete the desktop screenshot prompt. Confirm the captured pixels match
   the source, then select several regions, draw with pen/arrow/shape/highlighter,
   undo and redo, and press **Enter** to attach the batch. Press **Escape** to
   cancel the editor. These portal captures should be **Image only**: the portal
   does not provide the screen origin needed for aligned DOM/accessibility.
   Test with display scaling and multiple monitors when available.
   Cancel the desktop screenshot prompt too, then retry **Select**; the app and
   draft must remain usable. Check permission-denial recovery where the desktop
   offers that choice. A test using only XWayland apps does not cover native
   Wayland sources.

3. Type an unsent draft, close with **X**, and reopen from the tray. Check that
   the chat and draft remain. Choose **Quit** to exit. Ubuntu's AppIndicator
   extension must be enabled to show the tray icon.
4. Restart with the same test directories and check the saved session. Then
   test an unavailable agent: connection failure should release the controls and
   offer recovery without losing the draft.

### X11 compatibility checks

At the login screen, choose **Ubuntu on Xorg** and confirm `XDG_SESSION_TYPE=x11`.
Test agent connection, region selection/drawing, tray behavior and recovery;
use **Alt+A** to start selection. Accessible apps can supply AT-SPI
text, roles, values, states and bounds; supported Chromium browsers can also
supply DOM through an authorized CDP connection (see
[browser context](browser-context.md)). UIA is Windows-specific; AT-SPI is the
Ubuntu equivalent. Change the source content while the editor is open: the
original image and drawings should remain, with **Image only** instead of newer
context when alignment is no longer reliable.

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

To exercise the built package's X11 shortcuts, region selection and cancellation
in an isolated virtual display:

```sh
sudo apt-get install -y xvfb xauth libxtst6 dbus-x11 libgl1-mesa-dri
xvfb-run -a -s "-screen 0 1280x960x24 +extension GLX +render -noreset" \
  dbus-run-session -- env ZOMMI_RUNTIME_DISCOVERY_MODE=configured-only \
  python3 scripts/accept-linux-x11.py artifacts/zommi-linux-x64
```

The script creates temporary Zommi configuration and state. These Xvfb checks
exercise the X11 compatibility path. Primary Wayland acceptance still requires
the GNOME desktop steps above, including portal prompts, native Wayland source
apps and cancellation/retry. When reporting a problem, include the source
revision, Ubuntu version, X11/Wayland session and the failing step.

The native AT-SPI regression uses only a synthetic GTK window on a private X11
and D-Bus session. Install `xvfb dbus-x11 at-spi2-core openbox`, then run:

```bash
cargo build --locked --bin zommi-x11-capture
xvfb-run -a -s '-screen 0 1100x800x24' env GSETTINGS_BACKEND=memory \
  dbus-run-session -- python3 scripts/accept-linux-context.py
```
