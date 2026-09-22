# Build and test on Ubuntu

The Linux target is **Ubuntu 24.04 LTS x64**. Use a desktop installation or a VM
with a graphical session. At the login screen, select your user, open the gear
menu and choose **Ubuntu on Xorg**. Confirm the session with:

```sh
echo "$XDG_SESSION_TYPE"
```

Start with `x11`. Wayland is experimental and depends on the desktop's screenshot
and global-shortcut portals. A headless server or WSL terminal can run automated
checks, but does not verify Ubuntu's tray, permissions or desktop capture.
Other Linux distributions are outside the supported scope.

## Build and launch

Clone the repository, then install Rust **1.93.0** and Flutter **3.47.2** with
their commands on `PATH` (see [toolchain setup](../CONTRIBUTING.md#set-up)).
Install the Ubuntu build dependencies:

```sh
sudo apt-get update
sudo apt-get install -y clang cmake ninja-build pkg-config libgtk-3-dev \
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
Rust broker and capture helper. There is no Ubuntu installer in the current
preview; Windows release assets cannot run as the Ubuntu app.

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

This isolates Zommi preferences, detection and local history metadata. Agent CLIs
inherit these XDG directories too, so agents that use them may need sign-in or
configuration in the test profile. Sending a message creates a real agent
conversation; the automated checks below use fake agents instead.

1. In **Welcome to Zommi**, confirm the installed agent appears, connect, and
   send a message. After signing in or changing providers, use **Refresh agents**
   and check the model list.
2. Open another app. Press **Alt+A**, drag a region, and confirm the attachment
   matches it. Repeat and press **Escape** to check cancellation. Ubuntu capture
   currently supplies images; Windows drawing and browser enrichment are not
   part of this test.
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

To exercise the built package's X11 shortcuts, region selection and cancellation
in an isolated virtual display:

```sh
sudo apt-get install -y xvfb xauth libxtst6 dbus-x11 libgl1-mesa-dri
xvfb-run -a -s "-screen 0 1280x960x24 +extension GLX +render -noreset" \
  dbus-run-session -- env ZOMMI_RUNTIME_DISCOVERY_MODE=configured-only \
  python3 scripts/accept-linux-x11.py artifacts/zommi-linux-x64
```

The script creates temporary Zommi configuration and state. Passing this check
does not verify the real GNOME tray or Wayland portal prompts; use the desktop
steps above for those. When reporting a problem, include the source revision,
Ubuntu version, X11/Wayland session and the failing step.
