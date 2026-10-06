# Focalet Capture

Share selected screen regions with the editor, terminal or chat app you already
use. Capture runs independently of Desktop and needs no agent sign-in.

## Download and open

Choose **Capture** for your platform in the [download table](https://github.com/timctho/focalet#download):

| Platform | Install | Where to find Capture |
| --- | --- | --- |
| Windows 10/11 x64 | Run the Capture setup executable | Start menu and system tray |
| macOS 12+ Apple Silicon or Intel | Open the matching DMG and drag **Focalet Capture** into Applications | Applications and menu bar |
| Ubuntu 24.04 x64, GNOME Wayland | Install the Capture `.deb` with `sudo apt install ./Focalet-Capture-Ubuntu-amd64.deb` | Applications and GNOME panel |

Windows packages include .NET. Mac packages include the browser context helper.
Ubuntu's package manager installs the native dependencies. Flutter and agent
runtimes are not required. Windows installers are unsigned; Mac apps are ad-hoc
signed and DMGs are not notarized.

On Mac, allow **Screen Recording** to select pixels and **Accessibility** to
include context and paste. The menu's **Permissions** item opens these settings.
On Ubuntu, choose **Enable desktop integration** on first launch. If GNOME has
not loaded the extension, sign out and back in, then reopen Capture. Capture
reuses a current Focalet extension; its independent installer does not overwrite
files owned by Desktop. Screen sharing is authorized when you invoke capture.

Both apps can be installed together. On Windows and Mac, quit Desktop or change
its capture shortcut before opening Capture. On Ubuntu, Alt+A routes to Capture
while it is running, and returns to Desktop when Capture quits.

## Capture, then choose where to paste

1. In the source window, press **Shift+Alt+A** (**Shift+Option+A** on Mac).
2. Drag up to eight regions. **Ctrl** enters continuous selection; choose a
   drawing tool to annotate. Pen, arrow, rectangle, ellipse, colors and undo are
   available. Choose **Done** or press Enter.
3. Switch to your destination and click its input at the intended caret.
4. Press **Alt+A** (**Option+A** on Mac).

Paste follows **image A → context A → image B → context B**. Images remain
separate at their selected dimensions. Capture never submits the message.
Successful pastes finish silently. Press the paste shortcut again to reuse the
batch, including in a different app. Cancelling a new capture preserves the
previous batch.

Capture does not guess a previous destination. Paste uses the currently focused
window, stops on focus or clipboard changes, and never retries interrupted steps
automatically. Known protected fields are excluded. Destination accessibility
checks inspect identity and state, not input text. The receiving app controls
whether it accepts images and where attachments appear.

## Menu and clipboard

The system tray, menu bar or GNOME panel provides **Capture**, **Copy last batch**,
**Copy text**, preferences, and **Quit**. Text-only and slower-image preferences
are in the menu on Windows/Mac and **Preferences** on Ubuntu.

Each automatic image step offers only image formats: PNG/DIB/RTF on Windows,
PNG/TIFF on Mac, and PNG on Ubuntu. Its following text step contains the region
label, readable context and complete bounded snapshot JSON. Inputs that ignore
images still receive the text. DOM, accessibility IDs, hierarchy, geometry,
state, source and alignment remain available when captured reliably.

Default minimum waits are **0.5 seconds per image** and **0.15 seconds per text
step**, plus a brief period after clipboard reads. **Slower image paste** allows
at least three seconds for apps that read a preview and fetch the image again
later. A clipboard read cannot prove that the receiving app finished uploading
an attachment. Use **Text only** to skip images entirely.

**Copy last batch** offers a rich HTML document with separate images and complete
plain-text fallback (also RTF on Windows). Manual paste depends on the receiving
app's format support. No combined image is created.

Capture retains batches in memory. Each region is limited to 32 megapixels and
the images together to 32 MiB. **Quit** releases shortcuts, capture helpers and
the batch. The app captures only after invocation. Frozen selected pixels are
preserved; changed or unaligned source structure is reported as image-only.

## Build and verify

From a committed checkout on the target OS:

```sh
python3 scripts/package_capture.py linux
# macOS: python3 scripts/package_capture.py macos
# Windows: python scripts/package_capture.py windows
```

Build prerequisites and regression suites are in [CONTRIBUTING.md](../CONTRIBUTING.md).
Capture's native CI is independent of Flutter and the Rust agent broker. It
checks image/context order, Unicode metadata, alignment, package inventories and
installers. Windows tests include native editors, Chromium and an isolated
Electron receiver. Ubuntu tests run real capture and ordered paste in a private
GNOME Wayland desktop. Mac checks compile both architectures, verify native
clipboard formats, selection geometry and the mounted DMG; OS permission and
actual destination-app acceptance remain separate from these checks.

See [product use cases](products.md) and the [component map](desktop-reference.md).
