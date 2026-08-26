# Zommi

Zommi is a local floating context companion for Codex. Its cross-platform
Electron shell stays in the tray, opens beside the pointer on a global
shortcut, and uses Codex app-server for the conversation. Windows delegates
UI Automation capture and WSL transport to a packaged native host.

Its goal is to let someone browse, point, and ask naturally while their chosen
agent receives a compact description of what they are seeing. Zommi does not
host a model, require model API keys, or replace Codex, Hermes, or another agent
runtime.

The product intent and initial success boundary are documented in
[docs/product-intent.md](docs/product-intent.md). Project-specific language is
defined in [CONTEXT.md](CONTEXT.md).

## Status

The Electron rewrite is implemented for Windows, macOS, and Linux. The current
Windows package has controlled native acceptance; the macOS and Linux packages
have assembly/unit evidence but still need real native-desktop acceptance. The
product provides:

- a tray-resident, rounded dark-glass floating chat modeled on Pickle Glass;
- `Alt+A` invocation that captures and moves the existing window beside the
  pointer instead of toggling it away;
- cumulative URL-abbreviated context tokens directly in the composer;
- an in-window raw-context preview that stays open while the pointer enters it
  and supports scrolling without visible scrollbars;
- `Alt+Shift+A` drag selection for image context;
- selected text as the primary context when the accessibility provider exposes
  it;
- browser URL, post-render accessibility hierarchy, Explorer path/selection,
  bounded accessibility text, and pointer target capture;
- a fresh WSL Codex app-server thread with streamed thinking/commentary, plans,
  tool lifecycle/output, and final replies;
- the user's existing Codex permissions and configured tools, plus a required
  bundled Chrome DevTools MCP backed by an isolated headless browser; and
- conversation continuity across invocations.

The Electron candidate has passing JS/.NET contracts, a native seeded UI
contract, an explicit Alt+Shift+A image-selection contract, and a controlled
real-Edge Alt+A-to-Codex streaming run. The earlier WinForms candidate's live
Amazon walkthrough is historical and has not been rerun on Electron. Evidence
boundaries are tracked in
[docs/acceptance-report.md](docs/acceptance-report.md).

Build and walkthrough instructions are in
[docs/windows-prototype.md](docs/windows-prototype.md).

## Launch

1. Extract the entire `zommi-win-x64.zip` archive to a local Windows folder.
2. Double-click `Zommi.exe`.

That is the complete setup. Zommi starts Codex app-server inside the default WSL
distribution and remains in the tray. Hover over a browser page, folder, or
window and press **Alt+A**. Zommi captures the underlying structured context
before taking focus and inserts a token such as `[amazon.com]` into the
composer. It opens beside the pointer and focuses the composer. Switch pages
and press Alt+A again to accumulate more tokens. Hover a token to inspect the
captured text. Press **Alt+Shift+A** only when you want to attach image context.
Type the question and press Enter; Codex thinking, tool activity, and the answer
stream into the same surface.

The bundled Chrome tool uses a separate ephemeral browser profile. It can
navigate and interact with pages the agent opens there, but it does not inherit
the user's browser login or silently control the tab under the pointer.

Codex CLI must already be installed, signed in, and available on the WSL shell
`PATH`. The prototype is unsigned, so Windows SmartScreen may require **More
info → Run anyway** on first launch.

Run the Electron and managed contract checks with:

```sh
npm --prefix src/Zommi.Electron test
dotnet run --project tests/Zommi.Tests/Zommi.Tests.csproj
```

The Windows runtime suite is `scripts/test-windows-runtime.ps1`; package first,
then run it from Windows PowerShell as described in the acceptance report.

## Core boundary

- Local and account-free by default.
- Floating desktop UX rather than a browser-only chat surface.
- Structured URL, path, selected text, window, and pointer context; pixels are
  attached only through the explicit Alt+Shift+A region-selection path.
- Ephemeral by default; observation does not imply recording or persistence.
- Attached to the exact app-server thread Zommi starts; it never guesses from
  recent or foreground sessions.
- No bundled chatbot, inference provider, or credential store.
- Runtime integration fails open and never restricts the agent's native tools.
