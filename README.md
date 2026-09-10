# Zommi

[![CI](https://github.com/timctho/zommi/actions/workflows/ci.yml/badge.svg)](https://github.com/timctho/zommi/actions/workflows/ci.yml)

Zommi is a local floating context companion for existing agent runtimes. Its
Flutter desktop shell rests as a small orb above the work area, expands into
chat on hover, and talks to a separate Rust runtime core over versioned JSONL.
Windows uses one capture-only .NET helper for UI Automation and explicit region
selection; it does not own sessions, runtimes, or model credentials.

Zommi does not host a model, require model API keys, or replace Codex, Pi,
Hermes, OpenClaw, or another agent runtime. Authentication, tools, permissions,
models, and canonical history remain owned by the selected runtime.

The product intent is in [docs/product-intent.md](docs/product-intent.md), and
project terminology is defined in [CONTEXT.md](CONTEXT.md).

## Current architecture

```text
Flutter desktop app
  ├── orb, composer, history, approvals, previews, tray, and hotkeys
  ├── macOS platform capture
  ├── Linux Rust X11 and Wayland-portal capture helper
  └── Windows Zommi.Capture helper (UIA and explicit region selection only)
          ↕
Rust zommi-core-host
  ├── runtime discovery and exact Session Binding
  ├── Codex, Pi, ACP, Hermes, OpenClaw, and PTY adapters
  └── normalized stream, approval, question, and artifact events
```

The Electron/JavaScript broker and the old hook/state relay are removed from the
authoritative source and release inventory. Release verification rejects any
Electron, Node module, or `.mjs` payload.

## User experience

- bottom-center quiet orb with a visible working state and 500 ms delayed
  collapse;
- `Alt+A` or **Select content** opens the same content picker; click an object,
  drag a region, or use Ctrl to accumulate selections on Windows;
- a sliding chat sidebar with mixed-runtime sessions, runtime logos, and a runtime
  picker for new chats;
- chats ordered by latest response across runtimes, with the runtime bound when
  creating each chat;
- compact workspace and model menus anchored below their controls, with settings,
  minimize, and close at the right;
- readable A/B attachments, bounded previews and in-place selection adjustment;
- exact runtime, model, reasoning, and provider-owned session selection;
- paged history, concurrent background turns, running/unread state, and exact
  interruption;
- streamed thinking, plans, tools, approvals, structured questions, Markdown,
  image/HTML artifact previews, and clipboard actions; and
- accessible names, keyboard actions, reduced motion, and visible degraded
  states.

Windows selection uses UIA and enriches connected Chromium pages with DOM
content. Selected image regions use native desktop capture; GPU-composited
pixels can differ or be blank on that path.
macOS uses its platform selector. Linux packages one Rust helper: X11 provides
active-window metadata and direct region capture, while Wayland uses the global-
shortcuts and area-screenshot portals. Standard Wayland portals do not expose
active-window metadata, so that context is visibly degraded. See
[docs/flutter-rust-migration.md](docs/flutter-rust-migration.md).

Browser connection, selection gestures and alignment limits are described in
[docs/browser-context.md](docs/browser-context.md).

## Native packages

| Platform | Package | Entrypoint | Core |
| --- | --- | --- | --- |
| Windows x64 | `zommi-windows-x64.zip` | `Zommi.exe` | `zommi-core-host.exe` |
| Linux x64/arm64 | `zommi-linux-<arch>.tar.gz` | `zommi` | `zommi-core-host` |
| macOS x64/arm64 | `zommi-macos-<arch>.zip` | `Zommi.app` | inside `Contents/MacOS` |

Each archive contains `release-manifest.json` and `SHA256SUMS.txt`; the archive
also has a sibling `.sha256`. The verifier checks complete file inventory,
component identity, checksums, absence of legacy payloads, and a real Rust-core
initialize/shutdown exchange. Windows pings the packaged capture helper, and
Linux probes both compiled capture providers without requiring a live display.

Signing is reported, not inferred. Windows is `distribution-signed` only when a
valid Authenticode certificate thumbprint is supplied. macOS uses the supplied
Developer ID identity or records `ad-hoc`. Linux records `checksum-only` unless
a later distribution-signing stage is configured.

The Linux archive includes its non-baseline Ayatana tray libraries and launches
through a relocatable `zommi` wrapper; users do not need the build sysroot. It
also carries `zommi-x11-capture`, so neither `xdotool` nor `gnome-screenshot` is
required. X11 supports global shortcuts, active-window metadata, and region
capture directly. Wayland sessions request global shortcuts and area screenshots
through `xdg-desktop-portal`; missing portal interfaces are shown as degraded.
Wayland active-window metadata remains unavailable by standard portal design.

## Build and test

Required toolchains are Rust 1.93, Flutter 3.47.2, Python 3, and .NET 8 for the
Windows capture helper. Native Flutter packaging must run on its target OS.

```sh
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace --all-targets
cargo build --workspace --bins

cd src/Zommi.Flutter
flutter pub get
dart format --output=none --set-exit-if-changed lib test
flutter analyze --no-pub
flutter test --no-pub
cd ../..

python3 tests/test_release_package.py -v
dotnet run --project tests/Zommi.Capture.Tests/Zommi.Capture.Tests.csproj --configuration Release
dotnet build src/Zommi.Windows/Zommi.Windows.csproj --configuration Release
```

Build and verify a native release on Linux or macOS:

```sh
bash scripts/package-unix.sh linux
# or, on macOS:
bash scripts/package-unix.sh macos
```

On Windows PowerShell:

```powershell
.\scripts\package-windows.ps1 -Runtime win-x64
```

To require real signing, set `ZOMMI_WINDOWS_SIGNING_THUMBPRINT` or
`ZOMMI_MACOS_SIGNING_IDENTITY` in the native build environment. CI builds and
verifies native Windows and Linux releases on separate local runners and
uploads only each archive plus checksum. The native macOS job is explicitly
skipped until a local macOS builder is available.

## Launch

- Windows: extract the full ZIP and run `Zommi.exe`.
- Linux: extract the tarball and run `./zommi` from the extracted directory.
- macOS: extract the ZIP and open `Zommi.app`.

At least one supported agent CLI must already be installed and authenticated in
its own environment. Zommi discovers native and WSL targets, or accepts an
explicit credential-free path/endpoint override. It never copies runtime
credentials into its own settings.

Windows build and manual native acceptance details are in
[docs/windows-prototype.md](docs/windows-prototype.md) and
[docs/windows-acceptance.md](docs/windows-acceptance.md). Native hotkey, z-order,
drag, permission, capture, and signed-distribution acceptance remains separate
from unit tests and package assembly.
