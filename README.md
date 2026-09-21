<picture>
  <source media="(prefers-color-scheme: dark)" srcset="design/zommi-logo/exports/ocean/lockup-dark.svg">
  <img src="design/zommi-logo/exports/ocean/lockup-light.svg" alt="Zommi" width="240">
</picture>

# Show your agent what you mean.

You can see the products, the spike, the cells. Getting an agent to understand
exactly what you're looking at can take longer than asking the question.

**Select it. Ask. Keep going.** Zommi brings your existing agent to your screen,
attaching the selected image and available context—links, labels and structure—so
you can get straight to the request.

### [Download the Windows preview →](https://github.com/timctho/zommi-releases/releases)

Uses your existing agent account. No separate model API key to enter in Zommi.
[Setup guide](docs/install.md) · [See it in action ↓](#see-it-in-action)

## Connect your agent and choose a model

Choose from your installed agents, connect, then pick a model from the chat header.
The demo shows Codex and OpenCode model selection in the Ocean theme. If
sign-in is needed, Zommi opens your agent’s own sign-in flow. The demo speeds up
selection and ends on the full, ready-to-use Zommi window.

[![First launch: choose an agent and model, then see the full Zommi window](docs/demos/setup-preview.webp)](docs/demos/setup.mp4)

[Watch the setup demo](docs/demos/setup.mp4) · [Step-by-step setup](docs/install.md)

| Agent runtime | Connection | Support in Zommi |
| --- | --- | --- |
| **Codex** | Native app-server | Chats, saved sessions, models, approvals and native skills |
| **OpenCode** | ACP | Chats, image context, saved sessions, models, approvals and advertised commands |
| **Pi** | RPC | Chats, image context, models and runtime commands |
| **Hermes** | ACP or Gateway | Chats and commands exposed by the runtime and profile |
| **OpenClaw** | ACP or local Gateway | Chats and commands exposed by the configured agent |
| **Claude CLI** | Terminal compatibility | Text-only interaction; image attachments unsupported |

**Model families:** GPT and Codex models through Codex; GPT, Claude, Gemini and
other provider models through OpenCode or Pi, plus OpenCode Zen's catalog through
OpenCode. Hermes and OpenClaw use the model configured in their runtime; Claude
CLI uses its own Claude configuration.

Your installed agent supplies the available models, tools and permissions.
Availability depends on your account, provider configuration and runtime version.
After signing in or adding a provider, choose **New agent → Refresh agents** to
update the model list without restarting Zommi.
[Agent setup](docs/install.md#2-choose-the-agent-you-already-have) ·
[Runtime command support](docs/runtime-commands.md).

## See it in action

Three things that are easier to point at than explain. Animated previews play
automatically; click one for the clearer video.

### Compare the products you're actually considering

Draw **one box around all five candidates** on the Amazon listing grid.

> Which of these would let my M1 MacBook Air run two independent monitors?
> Check the exact listings.

[![Select five products and receive a sourced comparison](docs/demos/amazon-preview.webp)](docs/demos/amazon.mp4)

**Five exact links, one selection.** The agent checks each product and Apple's
display limits, then returns a sourced comparison. In this case, none of the
five hubs meets the requirement—even though the listings advertise dual HDMI.

[Watch Amazon demo · 29 seconds](docs/demos/amazon.mp4)

### Ask about this spike

Select **just the interval that looks wrong** on the latency chart.

> Why did latency spike here? Check the underlying query and source data.

[![Select a latency spike and investigate its cause](docs/demos/dashboard-preview.webp)](docs/demos/dashboard.mp4)

**“Here” comes with context.** The selected interval and the chart's exposed
query reach the agent together. It investigates the source data and traces the
p95 jump from 256 to 1,450 ms to an inventory-pool change.

[Watch dashboard demo · 25 seconds](docs/demos/dashboard.mp4)

### Sketch two quotes across a sheet

Use the **Pen** to loop items in three separate tables, draw connections to two
quote boxes, and cross out one option inside a loop.

> Turn my sketch into the two quotes. Each loop feeds the box it points to; skip
> the crossed-out option. Link to source cells and calculate subtotal, tax and
> total. Leave source data alone.

[![Freehand loops and connections become two linked quotes, excluding a crossed-out item](docs/demos/sheets-preview.webp)](docs/demos/sheets.mp4)

**The sketch defines the groups and the exception.** The agent combines items
from different tables into two formula-driven quotes, including each item's tax
rate. The prompt contains no item names or cell addresses. The clip ends with
the agent’s completed response.

[Watch the Sheets sketch demo · 29 seconds](docs/demos/sheets.mp4)

<details>
<summary>About these recordings</summary>

Real selections, agent replies and sheet edits, recorded with the Windows
development build. Setup shows Codex and OpenCode; the three task demos use Codex.
The downloadable preview may differ. Clips speed
up gestures, trim waits and include labelled context illustrations. Amazon and
dashboard conversations are reopened from the same completed sessions in Ocean.
The dashboard and sheet use synthetic data.

Context depends on what the source exposes. This sample chart exposes its SQL
through accessibility metadata; the agent already has access to its database.
Zommi supplies context, and your agent supplies the tools and permissions to
research or edit. [Recording details and full demos](docs/demos/README.md).

</details>

## What comes with a selection

On Windows, **UI Automation** and an optional, authorized **Chrome DevTools
Protocol (CDP)** connection connect your selection to the app's structure.
Depending on what the source exposes, an attachment can carry:

| Context | What your agent receives |
| --- | --- |
| **The selection** | The cropped image, its actual dimensions and an **A/B reference** that stays associated with its context |
| **Source identity** | App and window, process identity, page URL, and browser tab/document identifiers when available |
| **Meaning and structure** | Text, labels, descriptions, values, destination links, element roles and states, parent/child relationships and provider IDs |
| **Spatial relationships** | Element bounds in image pixels, full or partial overlap with the selection, verified screen/CSS coordinate mappings, and table headers/grid indices when exposed |
| **Freshness and coverage** | Snapshot ID, capture/expiry times, and explicit flags for truncated or unavailable context |

The **Rust core** packages the image and bounded structured context through a
shared handoff to the selected runtime. Image-capable adapters send both in the
request, with each image tied to its source and reference.

Source and geometry checks keep context aligned with the selected pixels.
If the app exposes no usable structure or alignment cannot be confirmed, Zommi
attaches **Image only** with a reason. Captured content is marked as untrusted
data, and the handoff asks the agent to obtain fresh state before acting.
[Capture architecture and limits](docs/browser-context.md).

## Platforms

| Platform | Availability | Capture support |
| --- | --- | --- |
| **Windows 10/11 · x64** | Preview installer | Multiple regions, drawing tools, UI Automation and optional browser DOM context |
| **macOS 12+ · Apple Silicon / Intel** | Source / test builds; desktop validation pending | Native region images and screen geometry |
| **Linux · X11** | Source build | Native region images; no DOM/UIA enrichment |
| **Linux · Wayland** | Source build; requires desktop portals | Portal-based screenshots and shortcuts; reduced window context |

Choose a package actually listed in [Releases](https://github.com/timctho/zommi-releases/releases).
[Installation and permissions](docs/install.md) · [Build from source](CONTRIBUTING.md).

## Try it on the thing you're looking at

1. **Install Zommi.** Get `Zommi-Setup-x64.exe` from
   [Releases](https://github.com/timctho/zommi-releases/releases).
2. **Connect your agent.** Choose an installed, signed-in runtime. Windows
   discovers agents in both Windows and WSL.
3. **Press Alt+A, select and ask.** On Windows, add arrows or sketches if useful,
   then press **Attach**. Review the attachment and send a short request such as
   “What should I do next?”

For several regions on Windows, hold **Ctrl** during the first drag, add the
next region, then press **Enter**. Refer to them as **A**, **B**, and so on.

### [Download Zommi and try your first selection →](https://github.com/timctho/zommi-releases/releases)

## You choose what to share

Zommi captures when you invoke it. Review the image and context before sending;
source metadata can include information beyond the selected pixels. Your
selected agent's provider and data policies apply.
[How capture works](docs/browser-context.md).

---

[Build & contribute](CONTRIBUTING.md) ·
[Runtime reference](docs/runtime-commands.md) ·
[Desktop reference](docs/desktop-reference.md)
