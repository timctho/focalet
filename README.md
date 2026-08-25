# Zommi

Zommi is a local floating context companion for Codex. On Windows it stays in
the tray, opens beside the pointer on a global shortcut, and uses Codex
app-server in the default WSL distribution for the conversation.

Its goal is to let someone browse, point, and ask naturally while their chosen
agent receives a compact description of what they are seeing. Zommi does not
host a model, require model API keys, or replace Codex, Hermes, or another agent
runtime.

The product intent and initial success boundary are documented in
[docs/product-intent.md](docs/product-intent.md). Project-specific language is
defined in [CONTEXT.md](CONTEXT.md).

## Status

Windows shortcut-to-answer prototype implemented. It provides:

- a tray-resident, translucent floating WinForms chat;
- `Ctrl+Enter` invocation without moving or covering the pointer;
- one deliberate snapshot of the actual top-level window under the pointer;
- browser URL, Explorer path/selection, bounded accessibility text, and pointer
  target capture;
- a compact `[context]` attachment instead of rendering raw captured text; and
- a fresh WSL Codex app-server thread with streamed replies and conversation
  continuity across invocations.

The exact candidate passed native Windows 11 regression checks and a live
Chrome Amazon-product walkthrough with a correct real Codex answer. The exact
revision, executable hash, and evidence boundary are in
[docs/acceptance-report.md](docs/acceptance-report.md).

Build and walkthrough instructions are in
[docs/windows-prototype.md](docs/windows-prototype.md).

## Launch

1. Extract the entire `zommi-win-x64.zip` archive to a local Windows folder.
2. Double-click `Zommi.exe`.

That is the complete setup. Zommi starts Codex app-server inside the default WSL
distribution and remains in the tray. Hover over a browser page, folder, or
window and press **Ctrl+Enter**. Zommi captures the underlying context before
taking focus, opens beside the pointer, and focuses the composer. Type the
question and press Enter; the answer streams into the same floating surface.

Codex CLI must already be installed, signed in, and available on the WSL shell
`PATH`. The prototype is unsigned, so Windows SmartScreen may require **More
info → Run anyway** on first launch.

Run the cross-platform contract checks with:

```sh
dotnet run --project tests/Zommi.Tests/Zommi.Tests.csproj
```

The Windows runtime suite is `scripts/test-windows-runtime.ps1`; package first,
then run it from Windows PowerShell as described in the acceptance report.

## Core boundary

- Local and account-free by default.
- Floating desktop UX rather than a browser-only chat surface.
- Structured URL, path, selection, window, and pointer context before images.
- Ephemeral by default; observation does not imply recording or persistence.
- Attached to the exact app-server thread Zommi starts; it never guesses from
  recent or foreground sessions.
- No bundled chatbot, inference provider, or credential store.
- Runtime integration fails open and never restricts the agent's native tools.
