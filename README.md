# Zommi

[![CI](https://github.com/timctho/zommi/actions/workflows/ci.yml/badge.svg)](https://github.com/timctho/zommi/actions/workflows/ci.yml)

Download Windows and Mac installers from [Zommi Releases](https://github.com/timctho/zommi-releases/releases).
See [installation instructions](docs/install.md) and [release publishing](docs/public-releases.md).

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
- `Alt+A` or **Select** opens a rectangle picker; drag to attach an image with
  available context, or use Ctrl to collect up to eight rectangles on Windows;
- a sliding chat sidebar with mixed-runtime sessions, runtime logos, and a runtime
  picker for new chats;
- chats ordered by latest response across runtimes, with the runtime bound when
  creating each chat;
- cached chat metadata appears before runtime initialization; missing or stale
  catalogs sync in the background without creating or switching chats;
- compact workspace and model menus anchored below their controls, with settings,
  minimize, and close at the right;
- readable A/B attachments, clickable bounded previews and restored message contexts;
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

In a Codex chat, type `/` to open command suggestions. Keep typing to filter
them (for example `/cl` or `/goal`), use Up/Down to choose, and Tab or a click
to complete the command. Recognized command names appear in bold without
changing the text. Press Enter to run a completed command, or `/help` to see
the reference:

- `/clear` (or `/new`) opens a fresh chat and retains the old chat in history.
- `/goal <objective>` sets a persistent goal and starts Codex's goal work.
- `/goal` shows the objective, status, and usage; `/goal edit` loads the objective
  into the composer. `/goal pause`, `/goal resume`, and `/goal clear` control it.

Goal controls use the selected Codex runtime's native goal and thread-settings
APIs (verified with Codex 0.151). Codex owns continuation, completion, usage,
and persistence. Its goals feature must be enabled in the runtime configuration.
An unavailable API is reported in the chat. Commands are handled before sending
model input; unknown Codex commands show help instead of becoming prompts.
Goal objectives accept up to 4,000 Unicode characters. Send attached context as
a normal message first, then set the goal. `/clear` pauses the old goal and waits
for the current response to stop before opening the new chat; it preserves the
previous transcript and goal for later resumption.

The sidebar keeps a rebuildable `session-catalog.sqlite` in Zommi's application
state directory (`%APPDATA%\Zommi` on Windows, `$XDG_STATE_HOME/zommi` or
`~/.local/state/zommi` on Linux, `~/Library/Application Support/Zommi` on macOS).
It stores runtime labels, session IDs, titles, workspaces, profiles, last activity,
and sync/use timestamps; transcripts and credentials remain with the runtimes.
The primary key is `(runtime_target_id, id)`. Coalesced writes run in a background
isolate and transactionally update changed rows. Failed or partial listings retain
known metadata within the retention window.

Session metadata is retained for seven days since last activity, with exceptions
for the currently selected or running chats. Expiry runs on load, save, and hourly
while the app is open; refresh does not re-cache expired rows. Provider rows with
no valid timestamp can appear during the current run, but are only persisted when
selected or running. Scrolling down in Chats reveals 12 more sessions at a time
and reads older provider listings on demand; selecting an old chat keeps it
available while open. No provider history is deleted. Runtime labels and sync
timestamps remain independent of session
expiry, so eviction does not trigger unnecessary runtime launches.

Each chat keeps its own in-memory composer draft, cursor position, and attachments
when switching chats. Leaving a newly created chat with no draft, attachments, or
conversation removes it from the sidebar. Its scoped ID is recorded locally so
provider refreshes and restarts do not restore that empty entry. Provider history
is not deleted.

The first SQLite open imports a valid legacy `session-catalog.json` or its backup,
applies the retention window, and removes the JSON files after committing. A
corrupt SQLite cache can be rebuilt; a database with a newer schema is left alone.
Windows and macOS use OS SQLite. Linux packages include the build host's SQLite
library to preserve the supported glibc baseline.
For direct `flutter test` on Linux, install `libsqlite3-dev` (CI supplies the
equivalent linker alias without requiring a system installation).

The app restores its selected runtime as before, while other catalogs start
refreshing five seconds after initialization (or when Chats is opened). A shared
queue allows at most two reads, prioritizing recently used runtimes. Runtimes
used in the past seven days refresh after 15 minutes; others after six hours.
Failures have a persisted two-minute cooldown. Opening Chats checks freshness;
**Refresh agents** bypasses it. Catalog failures do not add error rows to Chats.
Opening a cached chat connects its exact runtime/session and reads canonical
history on demand.

If opening a saved Codex chat reports `no rollout found for thread id`, see
[Repairing Codex history lookup](docs/codex-history-repair.md) for diagnosing
different Codex homes and previewing a repair that preserves the original files.

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
`ZOMMI_MACOS_SIGNING_IDENTITY` in the native build environment. Shared Linux and
Windows CI runners are disabled by default. Run the checks and native package
commands above locally; skipped CI jobs do not establish validation. An operator
can explicitly resume shared jobs for one dispatch with `run_shared_runners: true`.
To publish
the archives and checksums to GitHub Actions storage, dispatch CI with
`upload_packages: true`; those artifacts are retained for three days. Ordinary
Windows/Linux push and pull-request jobs stay skipped. Manual uploads still require available quota.
macOS CI uses a native Apple Silicon hosted runner by default; dispatch with
`macos_arch: x64` for Intel. Manual `upload_packages` uploads retain Mac packages
and evidence for seven days. With `macos_draft_release: true`, a dispatch stores
them in a draft release instead; `macos_only: true` runs only the Mac job. See [Mac testing](docs/macos-testing.md) for
installation, signing, permissions and interactive capture checks.

## Launch

- Windows: extract the full ZIP and run `Zommi.exe`.
- Linux: extract the tarball and run `./zommi` from the extracted directory.
- macOS: extract the ZIP and open `Zommi.app`.

A fresh install opens runtime setup before connecting: select a detected agent,
sign in, scan again, configure its executable, or choose Set up later. Existing
settings skip this flow. The standard window is 900×760 and large is 1100×860,
clamped to the display work area.

To chat, install and authenticate a supported agent CLI in its own environment. Zommi discovers native and WSL targets, or accepts an
explicit credential-free path/endpoint override. It never copies runtime
credentials into its own settings.

Windows build and manual native acceptance details are in
[docs/windows-prototype.md](docs/windows-prototype.md) and
[docs/windows-acceptance.md](docs/windows-acceptance.md). Native hotkey, z-order,
drag, permission, capture, and signed-distribution acceptance remains separate
from unit tests and package assembly.
