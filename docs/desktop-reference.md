# Desktop reference

Implementation details for contributors. Start with the [installation guide](install.md) to use Zommi.

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
[docs/flutter-rust-migration.md](flutter-rust-migration.md).

Browser connection, selection gestures and alignment limits are described in
[docs/browser-context.md](browser-context.md).

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
selected or running. Scrolling down in Chats reveals 20 more sessions at a time
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
[Repairing Codex history lookup](codex-history-repair.md) for diagnosing
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

