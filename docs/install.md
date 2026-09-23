# Install Zommi and connect your agent

Zommi is a desktop companion for an agent you already use. If Codex, Pi, Hermes
or another supported runtime already works in its own terminal, keep that
installation and account. You do not need a separate model API key in Zommi.

## 1. Install the app

Download the newest published version from [Zommi Releases](https://github.com/timctho/zommi/releases).
Choose the installer for your computer from that release's assets; older previews
may only include Windows. Do not use GitHub's “Source code” archive as an installer.

| Computer | Download | Install |
| --- | --- | --- |
| Windows 10/11, x64 | `Zommi-Setup-x64.exe` | Run the installer, then launch Zommi from Start |
| Mac with Apple Silicon | `Zommi-macOS-arm64.dmg`, when available | Open the DMG; drag Zommi into Applications |
| Mac with Intel | `Zommi-macOS-x64.dmg`, when available | Open the DMG; drag Zommi into Applications |
| Ubuntu 24.04 LTS, x64 | `Zommi-Ubuntu-amd64.deb`, when listed in the release | `sudo apt install ./Zommi-Ubuntu-amd64.deb` |

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

On Linux, Zommi targets **Ubuntu 24.04 LTS x64** with **Ubuntu on Xorg**.
Install the `.deb` when it is listed in the selected release; `apt` also installs
its dependencies. You can use `sudo dpkg -i Zommi-Ubuntu-amd64.deb`, then
`sudo apt-get -f install` if dependencies are missing. Open **Zommi** from the app
menu or run `zommi`. Follow the [Ubuntu testing guide](ubuntu-testing.md) to test
the installer or build it from source.
Wayland is experimental: capture needs a screenshot portal and Alt+A also
needs a compatible global-shortcut portal. Other distributions are outside
the supported scope.

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
[OpenCode](https://opencode.ai/docs/),
[Hermes](https://github.com/NousResearch/hermes-agent), or
[OpenClaw](https://github.com/openclaw/openclaw).

Zommi uses the runtime's existing account, models, tools and permissions. It does
not merge histories across agents or move credentials into its settings. Native
commands and session actions depend on the protocol your runtime exposes.
Claude CLI uses limited terminal compatibility rather than full structured
session support; on Windows it currently requires WSL. Codex, Pi, Grok via Pi
and OpenCode can use native Windows installations. See [runtime commands](runtime-commands.md).

For **Grok (via Pi)**, install Pi, run `pi --provider xai --models 'xai/*'`, and use `/login` to
configure your xAI API key in Pi (or supply `XAI_API_KEY` to the runtime).
Then choose **Grok (via Pi)** in Zommi. Its model picker shows the xAI models
available to Pi; **Refresh agents** reloads that list. This uses Pi as the agent
runtime, with credentials, tools and saved conversations kept in Pi.

OpenCode connects through [`opencode acp`](https://opencode.ai/docs/acp/).
Install a version with ACP support and run `opencode auth login` to connect your
provider, then select **OpenCode** in Zommi. After signing in or changing providers,
choose **New agent → Refresh agents** to reload the model lists without restarting
Zommi. Refresh is available when agents are idle and preserves your current chat and
model selection. Its models, tools, permissions and
saved sessions remain in OpenCode. Images, saved-chat loading and commands use
the capabilities advertised by that version; built-in `/undo` and `/redo` are
currently unavailable through OpenCode ACP.

### An installed agent is missing

Use **Configure runtime** in setup, or **Advanced agent runtime** from the agent
menu. Select the correct host and provide the executable's path. Use the path
returned by `command -v codex` / `command -v pi` on Unix, or
`Get-Command codex` / `Get-Command pi` in Windows PowerShell.

Choose **Add runtime** to detect and add that CLI. On success, Advanced closes
and setup selects the new runtime. To add another CLI, open **Configure runtime**
again and repeat. If detection fails, the path stays in place so you can correct
it and retry.

For a native Windows CLI, choose **Windows** and browse to its `.exe` or npm
`.cmd` launcher. The Windows host remains available even if only WSL agents
were detected. Discovery also checks common npm, Bun, Scoop and WinGet locations.

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
app already uses it. [Examples](../README.md#see-it-in-action).

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
| Connecting or creating a chat times out | Use **Cancel** to keep navigating, then **Retry**. If it still fails, use **Restart agent connections**; confirm that the CLI works in the selected host |
| Codex times out during `initialize` | Read the host and startup diagnostic in the error. Run `codex app-server` in that same host to check for startup/configuration errors; update the CLI if needed, then Retry. A WSL launch failure and a silent app-server are different failures |
| An agent disconnects during a reply | Zommi keeps the chat and draft and attempts to reconnect. The unfinished request is not resent, and queued messages stay paused until you resume them |
| Alt+A does nothing | Try **Select**; check the configured shortcut and OS permissions |
| Capture says **Image only** | The source did not expose reliable text/structure; the selected image is still attached |
| Mac capture is blocked | Check Accessibility and Screen Recording for the app in Applications, then restart it |
| A saved Codex chat cannot be opened | Confirm the selected runtime/home; see [history lookup](codex-history-repair.md) before changing any files |
| A Pi chat cannot resume | Pi requires the exact session file it returned; do not substitute a session ID or guess a file path |

## Update, uninstall and verify

Choose **Quit** from Zommi's tray menu before installing an update; the window's
**X** only hides it. On Windows, remove it through
**Settings → Apps → Installed apps → Zommi**. On Mac, remove the app from
Applications. The Windows installer asks you to close Zommi, including its tray
icon, before replacing files. **App settings** shows the installed build revision.
Existing Zommi desktop and Start menu shortcuts are updated to the installed
copy and its current icon, including shortcuts from earlier desktop versions.

For a fresh Windows setup, select **Remove all Zommi settings, cached agent
detection and local session metadata** in the uninstaller, then reinstall.
This removes `%APPDATA%\Zommi` and `%LOCALAPPDATA%\Zommi`; the next launch
shows **Welcome to Zommi** and detects agents again. Leave it unchecked to keep
your settings. Automated uninstall can request the same reset with
`Uninstall.exe /S /PURGE=1`. Agent-owned accounts and conversations are retained.
Reset also stops Zommi's background WSL connections so they cannot recreate
the deleted cache. Other WSL processes and distributions are left running.

If a pinned Windows shortcut still shows the previous logo after updating,
unpin it and pin Zommi again from the refreshed Start menu shortcut.

On Ubuntu, choose **Quit**, then install the newer `.deb` with the same `apt`
command. Use `sudo apt remove zommi` to uninstall. Removing or purging the package
retains your Zommi settings and agent-owned accounts/history in your home directory.

Each public release includes `SHA256SUMS.txt` and `zommi-release.json` with its
source revision and installer hashes. Compare your download before opening:

```powershell
Get-FileHash .\Zommi-Setup-x64.exe -Algorithm SHA256
```

```sh
shasum -a 256 Zommi-macOS-arm64.dmg
```

The result must match that filename's entry in the release's `SHA256SUMS.txt`.
