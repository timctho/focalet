# Capture and Desktop

Focalet has two independently built apps in one repository. Choose by where you
want to work; installing both is optional.

## Focalet Capture: bring context to your existing tool

Use Capture when you already have a preferred editor, terminal or chat app and
only need to give it what you see on screen. Examples:

- Select a UI defect and an error message, annotate them, and paste into your
  coding agent's existing input.
- Select several product details or document fragments and ask your existing
  chat app to compare them.
- Capture a chart and its labels, then paste into the conversation where you are
  already investigating the issue.

**Shift+Alt+A** (**Shift+Option+A** on Mac) opens selection and annotation. Select up to eight
regions, finish, then click the destination input and press **Alt+A**. Each image
is followed by that region's text and available DOM/accessibility metadata. The images
remain separate, and unsupported image inputs still receive the text. The batch
can be pasted again; successful pastes finish silently.

Capture does not connect to agent runtimes, choose models, manage chats or send
a message. It needs no agent sign-in and does not require Desktop. The receiving
app controls image support, attachment placement and upload completion.
See [Capture setup, controls and limitations](capture-tool.md).

Capture has independent installers for Windows x64, macOS Apple Silicon/Intel
and Ubuntu 24.04 GNOME Wayland x64. Both products use the same Focalet icon.
Capture lives in the system tray, menu bar or GNOME panel. Desktop installers
do not install it. On Windows and Mac, quit Desktop or change its capture shortcut
before starting Capture. Ubuntu routes Alt+A to Capture while it is running.

## Focalet Desktop: a dedicated workspace for agent chats

Use Desktop when you want the conversation itself in Focalet. Examples:

- Keep separate agent sessions for different projects and switch between their
  drafts and attachments.
- Choose among installed agents and the models each runtime advertises.
- Capture and annotate material, review attachments in the composer, then send
  a question and respond to the agent's approvals in the same window.

Desktop supports Windows, macOS and Ubuntu GNOME Wayland. It uses an existing
supported agent runtime and account. The selected agent owns authentication,
canonical history, tools and permissions. Desktop does not require the Capture
tray app; its capture UI is included in its own package.
See [Desktop installation](install.md) and [runtime support](runtime-commands.md).

## Shared code, separate products

The apps share selected pixels, annotations, browser/accessibility extraction and
context models where their platforms overlap. On Windows they both depend on
`Focalet.Capture.Windows`, a library with no tray, paste loop or agent broker.

Capture owns its hotkeys, clipboard output and ordered paste flow. Desktop owns
chat/session UI and uses the Rust broker for agent connections. The Rust
`focalet-core` is the **agent runtime core**; it is not a dependency of Capture.

Each app has a separate entrypoint, build and package. Capture-only changes run
native Capture CI without building Flutter. Shared or unknown source changes
run both products' applicable native checks. One release publishes separate
installers for both products, built from the same version and source revision. See the
[component map](desktop-reference.md) and [contributor checks](../CONTRIBUTING.md).

## Naming and upgrades

Both apps, source packages, environment variables and OS identities use Focalet.
Capture launches `Focalet.Capture.exe` on Windows, `focalet-capture` on Ubuntu
and `Focalet Capture.app` on Mac; Desktop launches `Focalet.exe` on Windows,
`focalet` on Linux and `Focalet.app` on macOS. Desktop's Windows capture helper is
`Focalet.CaptureHost.exe`, distinct from the standalone app.

See [upgrade notes](migration.md) for prior installations. Recorded demos and
Git tags retain source provenance. Obsolete release downloads may be removed
after their replacement is published and verified.
