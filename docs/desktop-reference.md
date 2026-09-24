# Desktop reference

Start with [installation](install.md) to use Zommi or
[contributing](../CONTRIBUTING.md) to build it.

## Components

| Location | Responsibility |
| --- | --- |
| `src/Zommi.Flutter` | Desktop UI, sessions, composer, attachment previews, hotkeys and tray |
| `crates/zommi-core` | Agent discovery, runtime adapters and context handoff |
| `crates/zommi-core-host` | JSONL broker between Flutter and the runtime adapters |
| `src/Zommi.Windows` and `src/Zommi.Capture.Core` | Windows selection, annotations, accessibility and browser capture |
| `crates/zommi-linux-capture` | GNOME Wayland ScreenCast and AT-SPI capture |
| `src/Zommi.Gnome` | GNOME window geometry, identity and Alt+A integration |
| `src/Zommi.Flutter/macos/Runner` | macOS selection and platform integration |

The selected agent owns authentication, tools, permissions and canonical chat
history. Zommi binds each chat to an exact runtime target and session; runtime
targets distinguish native hosts, WSL distributions and connection modes.
Adapters normalize streaming replies, approvals, questions and artifacts.
See [runtime commands](runtime-commands.md) and [capture context](browser-context.md).

## Local state and recovery

Zommi stores preferences and a rebuildable session metadata cache in:

| Platform | State directory |
| --- | --- |
| Windows | `%APPDATA%\Zommi` |
| Linux | `$XDG_STATE_HOME/zommi` or `~/.local/state/zommi` |
| macOS | `~/Library/Application Support/Zommi` |

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

## Native packages

| Platform | Archive | Entrypoint |
| --- | --- | --- |
| Windows x64 | `zommi-windows-x64.zip` | `Zommi.exe` |
| Ubuntu 24.04 LTS x64 | `Zommi-Ubuntu-amd64.deb` / `zommi-linux-x64.tar.gz` | `zommi` |
| macOS x64/arm64 | `zommi-macos-<arch>.zip` | `Zommi.app` |

Packages include the Rust host, platform capture helper, licenses,
`release-manifest.json` and `SHA256SUMS.txt`. macOS embeds the host in
`Contents/MacOS` and licenses in `Contents/Resources`. The verifier checks file
inventory, checksums and a broker initialize/shutdown exchange. Native capture
acceptance is separate from headless contract tests.

See [release preparation](public-releases.md), [Windows acceptance](windows-acceptance.md)
and [macOS testing](macos-testing.md) for packaging and platform checks.
