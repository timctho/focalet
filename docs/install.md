# Install Focalet Desktop and connect your agent

This guide covers **Focalet Desktop**, the dedicated chat app. To paste screen context into an app you already
use, see [Focalet Capture](capture-tool.md); it needs no agent setup in Focalet.

Focalet is a desktop companion for an agent you already use. If Codex, Pi, Hermes
or another supported runtime already works in its own terminal, keep that
installation and account. You do not need a separate model API key in Focalet.

## 1. Install the app

For an earlier installation, follow the [upgrade notes](migration.md). Download
Desktop directly from the [README download table](https://github.com/timctho/focalet#download).
Choose your platform in the **Focalet Desktop** column.
Do not use GitHub's “Source code” archive as an installer.

| Computer | Download | Install |
| --- | --- | --- |
| Windows 10/11, x64 | `Focalet-Setup-x64.exe` | Run the installer, then launch Focalet from Start |
| Mac with Apple Silicon | `Focalet-macOS-arm64.dmg` | Open the DMG; drag Focalet into Applications |
| Mac with Intel | `Focalet-macOS-x64.dmg` | Open the DMG; drag Focalet into Applications |
| Ubuntu 24.04 LTS, x64 | `Focalet-Ubuntu-amd64.deb` | `sudo apt install ./Focalet-Ubuntu-amd64.deb` |

Windows installs for your account without administrator access and includes
runtime libraries. You do not need Rust, Flutter, Visual Studio or .NET to use
it. A portable Windows ZIP, when supplied, must be fully extracted before
running `Focalet.exe`; keep its adjacent files together.

On macOS 12 or later, launch the app from **Applications**, then grant
**Accessibility** and **Screen Recording** when requested. Restart Focalet after
changing permissions if capture remains unavailable.

Windows installers are currently unsigned; Mac installers are not notarized.
After checking the release source and checksum, Windows may require
**More info → Run anyway**. On Mac, use
**System Settings → Privacy & Security → Open Anyway** for a trusted download.

On Linux, Focalet's primary target is **Ubuntu 24.04 LTS x64** with its default
**Wayland** desktop session.
Install the `.deb` when it is listed in the selected release; `apt` also installs
its dependencies. You can use `sudo dpkg -i Focalet-Ubuntu-amd64.deb`, then
`sudo apt-get -f install` if dependencies are missing. Open **Focalet** from the app
menu or run `focalet`. Follow the [Ubuntu testing guide](ubuntu-testing.md) to test
the installer or build it from source.
The package includes the GNOME desktop extension. After installation, sign out
and sign in if GNOME has not loaded it, then choose **Enable desktop integration**
in Focalet's first-run setup or App settings. This enables Alt+A and window/context
alignment. Use **Select** or **Alt+A**, authorize the monitors to share, and keep
**Remember this selection** checked to reuse that permission on later captures
and app launches. Then select regions and draw. Sharing stops when that selection
completes or is cancelled. A dismissed prompt can be retried without restarting
the chat.
Ubuntu on Xorg and other desktop environments are outside the supported scope.

## 2. Choose the agent you already have

1. Confirm your agent works in its usual terminal, including sign-in.
2. Open Focalet. In **Welcome to Focalet**, choose a detected agent and connect.
   Windows detects native Windows installations and agents inside WSL.
   WSL, Ubuntu and macOS also check your terminal shell with `command -v`,
   including PATH settings from shell startup files. CLIs installed through
   nvm, fnm or Hermes's bundled Node keep that PATH when launched.
3. If prompted to sign in, finish that in the runtime's own flow and retry.
   **Scan again** refreshes discovery; **Set up later** leaves setup available
   without creating a chat.

No agent installed yet? Follow your preferred runtime's installation guide,
sign in there, and return to Focalet:
[Codex](https://github.com/openai/codex),
[Pi](https://github.com/badlogic/pi-mono/tree/main/packages/coding-agent),
[OpenCode](https://opencode.ai/docs/),
[Gemini CLI](https://geminicli.com/docs/get-started/installation/),
[Hermes](https://github.com/NousResearch/hermes-agent), or
[OpenClaw](https://github.com/openclaw/openclaw).

First launch and **App settings → Full access (YOLO)** control permissions for
new chats. Full access is on by default. When turned off, Focalet uses the agent's own policy
and displays approval requests with **Allow once**, **Deny**, and session scope
when supported. Requests include the source chat and queue across chats.
Unanswered local CLI approvals expire after five minutes and are denied.

Full access lets agents change files and run commands without asking. Codex
uses `approvalPolicy: never` with `danger-full-access`; Claude Code uses
`bypassPermissions`; Gemini uses `--approval-mode yolo`; OpenCode gets an
allow-all permission override; Hermes gets its YOLO launch setting. ACP runtimes
also receive automatic grants for requested tools, preferring a one-time grant.
Hermes and OpenClaw gateways receive automatic approval responses for Full access
chats; questions and credential requests still need an answer. Pi already runs
its built-in tools without approval. Gateway server policies remain in force.
Runtime or administrator restrictions can still reject an operation.

The setting is saved in Focalet without rewriting CLI configuration. It applies
when creating each chat, including on a runtime already connected. Existing
chats keep their permissions when switching, reconnecting or reopening Focalet.

Focalet uses the runtime's existing account, models and tools. It does
not merge histories across agents or move credentials into its settings. Native
commands and session actions depend on the protocol your runtime exposes.
Codex, Pi, OpenCode, Gemini CLI and Claude Code can use native Windows
installations. See [runtime commands](runtime-commands.md).

Claude Code connects through its [bidirectional stream-json interface](https://code.claude.com/docs/en/headless).
Install Claude Code and run `claude` in the same host to finish its setup and
authentication, then choose **New agent → Refresh agents → Claude Code**.
Focalet supports images, model selection, streaming, interruption, tool approvals
and resuming chats started in Focalet. The CLI owns permissions and saved context;
Focalet does not import unrelated terminal chats or export canonical history.
Older terminal-compatibility chats have no native Claude session ID; start a new
Claude chat after upgrading. Existing manually configured CLI paths are reused.

Older Claude CLIs that reject `--include-partial-messages` can create chats with
whole-message updates. Reopening those chats requires an updated CLI because
older versions can change the conversation ID on resume. Choose **Update Claude
Code**, finish `claude update` in that runtime's terminal, then **Retry**. Saved
conversations stay unchanged when Focalet rejects an incompatible resume.

Gemini CLI connects through [`gemini --acp`](https://geminicli.com/docs/cli/acp-mode/).
With Node.js 20 or newer, install a recent version using
`npm install -g @google/gemini-cli`, then follow the
[Gemini test steps](#test-gemini-cli) below. Focalet preserves Gemini CLI's configured
authentication method. Its ACP interface supports resuming
chats started in Focalet but does not currently advertise a saved-chat listing
method, so unrelated terminal chats are not imported into the sidebar.

Gemini CLI **0.60.x and 0.61.x** have an upstream ACP `session/load` issue that
resets recorded messages before loading them. Focalet disables resume for these
versions and leaves saved conversation files unchanged. Start a new chat, or use
a CLI release that fixes this issue. **Refresh agents** still updates their model
list without reloading the active conversation.

OpenCode connects through [`opencode acp`](https://opencode.ai/docs/acp/).
Install a version with ACP support and run `opencode auth login` to connect your
provider, then select **OpenCode** in Focalet. After signing in or changing providers,
choose **New agent → Refresh agents** to reload the model lists without restarting
Focalet. Refresh is available when agents are idle and preserves your current chat and
model selection. Its models, tools, permissions and
saved sessions remain in OpenCode. Images, saved-chat loading and commands use
the capabilities advertised by that version; built-in `/undo` and `/redo` are
currently unavailable through OpenCode ACP.

OpenClaw ACP requires a reachable OpenClaw Gateway before it can connect. If
Focalet reports a Gateway handshake failure, run `openclaw gateway status` in the
same host and OS account as the selected runtime. Start a stopped local service
with `openclaw gateway start`; for first-time setup, use **Open OpenClaw setup**.
For a remote Gateway, check its configured URL and access. Once ready, choose
**Retry** in Focalet. Other agents and saved chats remain available.

### Test Gemini CLI

[Google retired personal Google sign-in for Gemini CLI](https://developers.google.com/gemini-code-assist/docs/deprecations/code-assist-individuals)
on June 18, 2026, including AI Pro and Ultra accounts. Personal accounts can use
a Gemini API key; Vertex AI and eligible Code Assist Standard or Enterprise
accounts remain alternatives.

1. Create an API key in [Google AI Studio](https://aistudio.google.com/apikey).
2. Run `gemini` in the same host and OS account that Focalet uses (Windows
   PowerShell for a Windows runtime, or the matching WSL distribution). Choose
   **Use Gemini API Key** and enter the key in Gemini's prompt. If Gemini is
   already open, use `/auth` to change the method. Recent CLI versions save the
   key in their own credential storage, so Focalet can reuse it.
3. Ask `Reply with GEMINI_OK only`. After a successful reply, quit and reopen
   `gemini` in a new terminal and repeat to confirm authentication persists.
4. In Focalet, choose **New agent → Refresh agents → Gemini CLI**, select a model,
   and send the same prompt. To check context capture, use **Alt+A** on selected
   text or **Alt+Shift+A** for an image, then ask Gemini about the selection.

If Focalet reports missing authentication, confirm the selected runtime uses the
same host and account as the successful terminal test, then retry. Setting
`GEMINI_API_KEY` only in a terminal does not pass it to an already running Focalet;
use Gemini's credential prompt or launch Focalet from the configured environment.
See [Gemini authentication](https://geminicli.com/docs/get-started/authentication/)
for API-key and Vertex AI setup.

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
2. Press **Alt+A** (or click **Select** in Focalet).
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
Focalet does not restart or reconfigure your browser.
[Browser setup and capture limitations](browser-context.md#connecting-a-chromium-browser).

## Troubleshooting

If an agent reports **model not found** or **model not supported**, first confirm
the selected host, account and profile match the agent that works in your
terminal. Choose **New agent → Refresh agents**, then select a model advertised
by that runtime. A listed model can still be rejected by its provider because of
account access or a stale upstream catalog.

Hermes ACP and Gateway use Hermes's own provider configuration. Switching a
Gateway profile starts a chat with that profile's model and reasoning defaults.
For OpenClaw Gateway, choose the model before creating a new chat; an existing
chat keeps its runtime model. Focalet preserves the provider with the model choice.

| Symptom | Next step |
| --- | --- |
| No agents found | Verify the CLI works in the same Windows/WSL/Mac environment; scan again or configure its executable |
| Agent needs authentication | Sign in through that agent, then retry in Focalet |
| Connecting or creating a chat times out | Use **Cancel** to keep navigating, then **Retry**. If it still fails, use **Restart agent connections**; confirm that the CLI works in the selected host |
| Codex times out during `initialize` | Read the host and startup diagnostic in the error. Run `codex app-server` in that same host to check for startup/configuration errors; update the CLI if needed, then Retry. A WSL launch failure and a silent app-server are different failures |
| An agent disconnects during a reply | Focalet keeps the chat and draft and attempts to reconnect. The unfinished request is not resent, and queued messages stay paused until you resume them |
| Alt+A does nothing | Try **Select**; check the configured shortcut and OS permissions |
| Capture says **Image only** | The source did not expose reliable text/structure; the selected image is still attached |
| Mac capture is blocked | Check Accessibility and Screen Recording for the app in Applications, then restart it |
| A saved Codex chat cannot be opened | Confirm the selected runtime/home; see [history lookup](codex-history-repair.md) before changing any files |
| A Pi chat cannot resume | Pi requires the exact session file it returned; do not substitute a session ID or guess a file path |

## Update, uninstall and verify

Choose **Quit** from Focalet's tray menu before installing an update; the window's
**X** only hides it. On Windows, remove it through
**Settings → Apps → Installed apps → Focalet**. On Mac, remove the app from
Applications. The Windows installer asks you to close Focalet, including its tray
icon, before replacing files. **App settings** shows the installed build revision.
Existing Focalet desktop and Start menu shortcuts are updated to the installed
copy and its current icon, including shortcuts from earlier desktop versions.

For a fresh Windows setup, select **Remove all Focalet settings, cached agent
detection and local session metadata** in the uninstaller, then reinstall.
This removes `%APPDATA%\Focalet` and `%LOCALAPPDATA%\Focalet`; the next launch
shows **Welcome to Focalet** and detects agents again. Leave it unchecked to keep
your settings. Automated uninstall can request the same reset with
`Uninstall.exe /S /PURGE=1`. Agent-owned accounts and conversations are retained.
Reset also stops Focalet's background WSL connections so they cannot recreate
the deleted cache. Other WSL processes and distributions are left running.

If an older uninstaller repeatedly reports **Could not stop a Focalet background
connection**, quit Focalet from the tray and install **v0.2.2 or later** over the
same installation first. This replaces the old uninstaller and cleanup helpers;
then retry uninstall with the reset option selected. Installing the update does
not require uninstalling the older version first.

If a pinned Windows shortcut still shows the previous logo after updating,
unpin it and pin Focalet again from the refreshed Start menu shortcut.

On Ubuntu, choose **Quit**, then install the newer `.deb` with the same `apt`
command. Use `sudo apt remove focalet` to uninstall. Removing or purging the package
retains your Focalet settings and agent-owned accounts/history in your home directory.

Each public release includes `SHA256SUMS.txt` and `focalet-release.json` with its
source revision and installer hashes. Compare your download before opening:

```powershell
Get-FileHash .\Focalet-Setup-x64.exe -Algorithm SHA256
```

```sh
shasum -a 256 Focalet-macOS-arm64.dmg
```

The result must match that filename's entry in the release's `SHA256SUMS.txt`.
