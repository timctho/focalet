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

On Windows, **Shift+Alt+A** opens selection and annotation. Select up to eight
regions, finish, then click the destination input and press **Alt+A**. Each image
is followed by that region's text and available DOM/UIA metadata. The images
remain separate, and unsupported image inputs still receive the text. The batch
can be pasted again; successful pastes finish silently.

Capture does not connect to agent runtimes, choose models, manage chats or send
a message. It needs no agent sign-in and does not require Desktop. The receiving
app controls image support, attachment placement and upload completion.
See [Capture setup, controls and limitations](capture-tool.md).

Capture is currently a **Windows prototype** with its own portable package.
The Desktop installers do not install it. Do not run both apps with Alt+A
registered: quit one, or change Desktop's capture shortcut before starting Capture.

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
Windows Capture CI without building Flutter. Shared or unknown source changes
run both products' applicable native checks. Desktop's existing release pipeline
and Capture's prototype artifact remain separate. See the
[component map](desktop-reference.md) and [contributor checks](../CONTRIBUTING.md).

## Naming and upgrades

Both apps, source packages, environment variables and OS identities use Focalet.
Capture launches `Focalet.Capture.exe`; Desktop launches `Focalet.exe` on Windows,
`focalet` on Linux and `Focalet.app` on macOS. Desktop's Windows capture helper is
`Focalet.CaptureHost.exe`, distinct from the standalone app.

See [upgrade notes](migration.md) for prior installations. Recorded demos and
already published releases retain their original bytes and source provenance.
