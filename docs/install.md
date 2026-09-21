# Install Zommi and connect your agent

Zommi is a desktop companion for an agent you already use. If Codex, Pi, Hermes
or another supported runtime already works in its own terminal, keep that
installation and account. You do not need a separate model API key in Zommi.

## 1. Install the app

Download from [Zommi Releases](https://github.com/timctho/zommi-releases/releases).
Choose a platform actually listed in that release; preview releases may only
include Windows. Do not use GitHub's “Source code” archive as an installer.

| Computer | Download | Install |
| --- | --- | --- |
| Windows 10/11, x64 | `Zommi-Setup-x64.exe` | Run the installer, then launch Zommi from Start |
| Mac with Apple Silicon | `Zommi-macOS-arm64.dmg`, when available | Open the DMG; drag Zommi into Applications |
| Mac with Intel | `Zommi-macOS-x64.dmg`, when available | Open the DMG; drag Zommi into Applications |

Windows installs for your account without administrator access and includes
runtime libraries. You do not need Rust, Flutter, Visual Studio or .NET to use
it. A portable Windows ZIP, when supplied, must be fully extracted before
running `Zommi.exe`; keep its adjacent files together.

On macOS 12 or later, launch the app from **Applications**, then grant
**Accessibility** and **Screen Recording** when requested. Restart Zommi after
changing permissions if capture remains unavailable.

Current preview installers are unsigned on Windows and not notarized on Mac.
After checking the release source and checksum, Windows may require
**More info → Run anyway**. On Mac, use
**System Settings → Privacy & Security → Open Anyway** for a trusted download.

Linux native archives can be [built from source](../CONTRIBUTING.md). Extract
`zommi-linux-<arch>.tar.gz` and run `./zommi`. X11 supports direct region capture;
Wayland needs working screenshot/global-shortcut portals and provides less
window context. Linux download availability is listed on each release.

## 2. Choose the agent you already have

1. Confirm your agent works in its usual terminal, including sign-in.
2. Open Zommi. In **Welcome to Zommi**, choose a detected agent and connect.
   Windows detects native Windows installations and agents inside WSL.
3. If prompted to sign in, finish that in the runtime's own flow and retry.
   **Scan again** refreshes discovery; **Set up later** leaves setup available
   without creating a chat.

No agent installed yet? Follow your preferred runtime's installation guide,
sign in there, and return to Zommi:
[Codex](https://github.com/openai/codex),
[Pi](https://github.com/badlogic/pi-mono/tree/main/packages/coding-agent),
[Hermes](https://github.com/NousResearch/hermes-agent), or
[OpenClaw](https://github.com/openclaw/openclaw).

Zommi uses the runtime's existing account, models, tools and permissions. It does
not merge histories across agents or move credentials into its settings. Native
commands and session actions depend on the protocol your runtime exposes.
Claude CLI uses limited terminal compatibility rather than full structured
session support. See [runtime commands](runtime-commands.md).

### An installed agent is missing

Use **Configure runtime** in setup, or **Advanced agent runtime** from the agent
menu. Select the correct host and provide the executable's path. Use the path
returned by `command -v codex` / `command -v pi` on Unix, or
`Get-Command codex` / `Get-Command pi` in Windows PowerShell.

For a WSL agent, choose that distribution and enter its **Linux** path, such as
`~/.local/bin/codex` or `/home/you/.local/bin/codex`. The tilde is resolved inside
the selected distribution. A Windows `C:\...` path is not a WSL executable.
Refresh agents after installing or moving a CLI. Finder-launched Mac apps also
search common Homebrew and per-user CLI locations.

## 3. Point to what you mean

1. Bring the source app into view.
2. Press **Alt+A** (or click **Select** in Zommi).
3. Drag around a chart, error, paragraph, card or table cell.
4. On Windows, optionally draw on the selection, then press **Enter** or
   **Attach**. Use the toolbar's pen, arrows, shapes, highlighter and undo/redo.
5. Check the attachment and ask a short question, then send.

For example: select an error dialog and ask “What should I do next?” rather
than transcribing the error and explaining where it appeared.

On Windows, hold **Ctrl** on the first drag to collect several regions, then
use **Attach** or **Enter**. Refer to the attachments as **A**, **B**, etc.
You can also use **Add region** in the drawing toolbar. Each region keeps its
own annotations and undo history.
**Escape** cancels without attaching. Change Alt+A in **App settings** if another
app already uses it. [Recorded examples](demos/README.md).

A browser connection is optional. Without it, images and available accessibility
context still work. On Windows, **Full webpage details** can enrich a selection
with DOM text and links when a compatible browser authorizes the connection.
Zommi does not restart or reconfigure your browser.
[Browser setup and capture limitations](browser-context.md#connecting-a-browser).

## Troubleshooting

| Symptom | Next step |
| --- | --- |
| No agents found | Verify the CLI works in the same Windows/WSL/Mac environment; scan again or configure its executable |
| Agent needs authentication | Sign in through that agent, then retry in Zommi |
| Alt+A does nothing | Try **Select**; check the configured shortcut and OS permissions |
| Capture says **Image only** | The source did not expose reliable text/structure; the selected image is still attached |
| Mac capture is blocked | Check Accessibility and Screen Recording for the app in Applications, then restart it |
| A saved Codex chat cannot be opened | Confirm the selected runtime/home; see [history lookup](codex-history-repair.md) before changing any files |
| A Pi chat cannot resume | Pi requires the exact session file it returned; do not substitute a session ID or guess a file path |

## Update, uninstall and verify

Close Zommi before installing an update. On Windows, remove it through
**Settings → Apps → Installed apps → Zommi**. On Mac, remove the app from
Applications. Agent-owned accounts and history remain with the agent;
Zommi's local settings are retained by the Windows uninstaller.

Each public release includes `SHA256SUMS.txt` and `zommi-release.json` with its
source revision and installer hashes. Compare your download before opening:

```powershell
Get-FileHash .\Zommi-Setup-x64.exe -Algorithm SHA256
```

```sh
shasum -a 256 Zommi-macOS-arm64.dmg
```

The result must match that filename's entry in the release's `SHA256SUMS.txt`.
