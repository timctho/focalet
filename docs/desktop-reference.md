# Components and local state

Start with [Capture or Desktop](products.md) to choose an app, or
[contributing](../CONTRIBUTING.md) to build it.

## Components

| Product / layer | Location | Responsibility |
| --- | --- | --- |
| Mac Capture | `src/Focalet.Capture.Mac` | Swift/AppKit app, menu bar, hotkeys, AX and ordered native paste |
| Ubuntu Capture | `src/Focalet.Capture.Linux`, `src/Focalet.Capture.Unix` | GTK selector, clipboard, context helpers and GNOME panel integration |
| Windows Capture | `src/Focalet.CaptureTool` | Windows tray app, capture/paste hotkeys, clipboard image/context sequence; builds `Focalet.Capture.exe` |
| Focalet Desktop | `src/Focalet.Flutter` | Desktop UI, sessions, composer, attachment previews, hotkeys and tray |
| Desktop runtime | `crates/focalet-core` | Agent discovery, runtime adapters and context handoff |
| Desktop runtime | `crates/focalet-core-host` | JSONL broker between Flutter and the runtime adapters |
| Desktop Windows adapter | `src/Focalet.Windows` | JSONL capture host and acceptance probes; builds `Focalet.CaptureHost.exe` |
| Shared capture | `src/Focalet.Capture.Windows` | Windows selection, annotations, screen pixels, accessibility, browser capture and invocation-time window identity |
| Shared capture | `src/Focalet.Capture.Core` | Context models, extraction, alignment and clipboard representations without an app dependency |
| Desktop Linux capture | `crates/focalet-linux-capture`, `src/Focalet.Gnome` | GNOME Wayland ScreenCast, AT-SPI, geometry, identity and shortcut integration |
| Desktop macOS capture | `src/Focalet.Flutter/macos/Runner` | macOS selection and platform integration |

Capture and the Windows Desktop adapter both reference the shared capture
library. Neither references the other's executable. Clipboard injection and
capture-tool hotkeys belong only to Capture; JSONL request handling belongs only
to the Desktop adapter. Platform capture implementations on Linux and macOS
are shared by Desktop and the independent native Capture apps. Capture builds
without Flutter or the agent broker.

`focalet-core` is an agent runtime library, not the shared capture library. Capture
runs without Flutter, a broker or an installed agent. Ubuntu builds use Rust
only for the native capture helper. Build
Capture with `scripts/package-capture-tool.ps1`; build Desktop with
`scripts/package-windows.ps1` or `scripts/package-unix.sh`. The two packages do
not bundle each other's app.

## Desktop agent boundary

The selected agent owns authentication, tools, permissions and canonical chat
history. Focalet binds each chat to an exact runtime target and session; runtime
targets distinguish native hosts, WSL distributions and connection modes.
Adapters normalize streaming replies, approvals, questions and artifacts.
See [runtime commands](runtime-commands.md) and [capture context](browser-context.md).

## Local state and recovery

Focalet stores preferences and a rebuildable session metadata cache in:

| Platform | State directory |
| --- | --- |
| Windows | `%APPDATA%\Focalet` |
| Linux | `$XDG_STATE_HOME/focalet` or `~/.local/state/focalet` |
| macOS | `~/Library/Application Support/Focalet` |

`session-catalog.sqlite` holds session IDs, titles, workspaces, runtime labels and
activity timestamps. Transcripts and credentials stay with the agent. Inactive
metadata expires after seven days; current and running chats are retained.
Removing cached metadata does not delete provider history. **Refresh agents**
refreshes runtime discovery, session catalogs and available models.

Switching chats retains each draft and its attachments. Recovery reconnects
the same runtime and saved session without replaying accepted or uncertain
requests. A Codex thread held by another writer opens read-only and retries
ownership while preserving its draft. For missing Codex history, check the
[runtime home and history lookup](codex-history-repair.md).

## Desktop native packages

| Platform | Archive | Entrypoint |
| --- | --- | --- |
| Windows x64 | `focalet-windows-x64.zip` | `Focalet.exe` |
| Ubuntu 24.04 LTS x64 | `Focalet-Ubuntu-amd64.deb` / `focalet-linux-x64.tar.gz` | `focalet` |
| macOS x64/arm64 | `focalet-macos-<arch>.zip` | `Focalet.app` |

Packages include the Rust host, platform capture helper, licenses,
`release-manifest.json` and `SHA256SUMS.txt`. macOS embeds the host in
`Contents/MacOS` and licenses in `Contents/Resources`. The verifier checks file
inventory, checksums and a broker initialize/shutdown exchange. Native capture
acceptance is separate from headless contract tests.

See [release preparation](public-releases.md), [Windows acceptance](windows-acceptance.md)
and [macOS testing](macos-testing.md) for packaging and platform checks.

## Capture package and state

Capture builds `artifacts/focalet-capture-win-x64.zip` independently. It includes
`Focalet.Capture.exe`, its .NET runtime, licenses, usage notes,
`capture-tool-manifest.json` and `SHA256SUMS.txt`. It contains no Flutter UI or
Rust agent broker. `scripts/verify_capture_package.py` checks the exact source
revision, file inventory and hashes; Windows CI also launches the packaged app.

The tray app keeps its current batch and paste-mode choices in memory until it
exits. It has no session catalog or agent credentials. See [Capture use](capture-tool.md).
