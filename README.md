# Zommi

[![CI](https://github.com/timctho/zommi/actions/workflows/ci.yml/badge.svg)](https://github.com/timctho/zommi/actions/workflows/ci.yml)

Zommi is a local floating context companion for existing agent runtimes. Its cross-platform
Electron shell rests as a small orb above the taskbar, expands into chat on
hover, and connects through a protocol-first runtime broker. Windows delegates
only UI Automation capture and explicit image selection to a packaged native host.

Its goal is to let someone browse, point, and ask naturally while their chosen
agent receives a compact description of what they are seeing. Zommi does not
host a model, require model API keys, or replace Codex, Hermes, or another agent
runtime.

The product intent and initial success boundary are documented in
[docs/product-intent.md](docs/product-intent.md). Project-specific language is
defined in [CONTEXT.md](CONTEXT.md).

## Status

The Electron client is implemented for Windows, macOS, and Linux. The final
Windows package is cross-built and awaits native execution after Windows interop
is restored; an earlier package in the same tranche has controlled native
acceptance. Linux has packaged UI and real Codex transport evidence. macOS has
assembly/unit evidence and still needs real native-desktop acceptance. The
product provides:

- a tray-resident, Siri-like orb centered above the taskbar that smoothly
  expands into a rounded translucent chat on hover;
- constant panel translucency on hover and an automatic return to the orb
  0.5 seconds after the pointer leaves;
- `Alt+A` capture that opens the anchored chat without moving it to the
  pointer;
- cumulative URL-abbreviated context tokens directly in the composer;
- an in-window raw-context preview that stays open while the pointer enters it
  and supports scrolling without visible scrollbars;
- `Alt+Shift+A` drag selection for image context;
- selection-first context: selected text/files, UIA selected items and grid
  coordinates, Google Sheets range boxes, and native PowerPoint
  slide/shape/text selections when their providers expose them;
- browser URL, nearby post-render accessibility hierarchy, Explorer
  path/selection, bounded accessibility text, and pointer target fallback;
- zero-config discovery on native Windows and installed WSL distributions,
  deterministic default selection, and a visible Runtime Target picker;
- first-class adapters for Codex app-server, Pi RPC, ACP/Hermes, Hermes Gateway,
  OpenClaw's runtime-owned Gateway/ACP bridge, and Advanced direct OpenClaw
  Gateway endpoints, plus a visibly degraded PTY compatibility path;
- streamed thinking/commentary, plans, tool lifecycle/output, final replies,
  exact interruption, and session history when the selected protocol supports them;
- user-resolved runtimes without Zommi-owned model, provider, authentication,
  permission, plugin, MCP, or tool configuration; and
- conversation continuity across invocations.

The current source and packages have passing JS/.NET contracts, packaged Linux
Codex transport and seeded UI evidence, and real Codex and Hermes turns. The
fresh-profile Windows discovery, capture, send, stream, session-switch, and
interrupt run belongs to the preceding package revision. Final native Windows,
locked-RDP hover, pointer immobility, physical drag, and synthetic global-hotkey
claims remain unaccepted. Real Pi and OpenClaw runs require those CLIs to be
installed. Evidence boundaries are tracked in
[docs/acceptance-report.md](docs/acceptance-report.md).

Build and walkthrough instructions are in
[docs/windows-prototype.md](docs/windows-prototype.md).

## Launch

1. Extract the entire `zommi-win-x64.zip` archive to a local Windows folder.
2. Double-click `Zommi.exe`.

That is the complete Zommi setup. It searches native Windows and WSL for
supported CLIs, reuses their existing login/configuration, selects a deterministic
protocol target, and remains in the tray. Select a range, shape, text box, text, or
file when that is what you mean; otherwise hover a browser page, control, or
window and press **Alt+A**. Zommi captures the selection first, then the
underlying pointer and surrounding structured context
before taking focus and inserts a token such as `[amazon.com]` into the
composer. It expands at its fixed bottom-center position and focuses the
composer. Switch pages and press Alt+A again to accumulate more tokens. Hover a token to inspect the
captured text. Press **Alt+Shift+A** only when you want to attach image context.
Type the question and press Enter; agent thinking, tool activity, and the answer
stream into the same surface.

A supported CLI must already be installed and authenticated in its own native or
WSL environment. No path entry or credential copy is required. The prototype is
unsigned, so Windows SmartScreen may require **More info → Run anyway** on first
launch.

Browser-control tools remain owned by Codex. A browser tool injected by the
ChatGPT desktop host is scoped to that host's Agent Session and is not inherited
by Zommi's separately launched app-server. To use Chrome from Zommi, configure a
user-owned Chrome MCP server in the default WSL Codex runtime; see
[the Windows browser-tool setup](docs/windows-prototype.md#optional-user-owned-chrome-tool).

Run the Rust, Flutter, Electron, and managed contract checks with:

```sh
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace --all-targets
cargo build --workspace --bins
(cd src/Zommi.Flutter && dart format --output=none --set-exit-if-changed lib test && flutter analyze && flutter test)
npm --prefix src/Zommi.Electron test
dotnet run --project tests/Zommi.Tests/Zommi.Tests.csproj
```

The Flutter tests include a real process-level handshake with
`zommi-core-host`, interaction coverage for the floating surface and composer,
and a checked visual baseline. Every pull request and push to `main` runs these
checks, performs a Release .NET build, and assembles the current self-contained
`zommi-win-x64.zip` package. The workflow uploads the portable package and its
SHA-256 checksum as a 14-day `zommi-win-x64-<commit>` artifact.

Run an authenticated, model-backed latency walkthrough with simple,
selection-rich, and multi-context-plus-image turns using
`node scripts/test-user-response-latency.mjs`. Its expected values live only in
the selected context and image fixtures, so it verifies attachment use as well
as the response budgets documented in the Windows acceptance guide.

The Windows runtime suite is `scripts/test-windows-runtime.ps1`; package first,
then run it from Windows PowerShell as described in the acceptance report.

## Core boundary

- Local and account-free by default.
- Floating desktop UX rather than a browser-only chat surface.
- Structured Surface Selection, URL, path, window, nearby accessibility, and
  pointer fallback; pixels are attached only through the explicit
  Alt+Shift+A region-selection path.
- Ephemeral by default; observation does not imply recording or persistence.
- Attached to an exact Runtime Target and provider-owned Agent Session; it never
  guesses from recent or foreground sessions.
- No bundled chatbot, inference provider, or credential store.
- Zommi neither adds nor restricts agent tools. Capabilities come from the
  selected runtime and its user-owned configuration; tools injected into a
  different host or session do not transfer automatically.

The architecture and rollout gates are in
[docs/multi-runtime-broker-plan.md](docs/multi-runtime-broker-plan.md), with the
protocol-first decision in
[docs/adr/0003-use-protocol-first-runtime-adapters.md](docs/adr/0003-use-protocol-first-runtime-adapters.md).
