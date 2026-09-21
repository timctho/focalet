<picture>
  <source media="(prefers-color-scheme: dark)" srcset="design/zommi-logo/exports/relay/lockup-white.svg">
  <img src="design/zommi-logo/exports/relay/lockup-ink.svg" alt="Zommi" width="240">
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

## See it in action

Three things that are easier to point at than explain. Each demo is under
30 seconds.

### Compare the products you're actually considering

Draw **one box around all five candidates** on the Amazon listing grid.

> Which of these would let my M1 MacBook Air run two independent monitors?
> Check the exact listings.



**Five exact links, one selection.** The agent checks each product and Apple's
display limits, then returns a sourced comparison. In this case, none of the
five hubs meets the requirement—even though the listings advertise dual HDMI.

[Watch Amazon demo · 29 seconds](docs/demos/amazon.mp4)

### Ask about this spike

Select **just the interval that looks wrong** on the latency chart.

> Why did latency spike here? Check the underlying query and source data.



**“Here” comes with context.** The selected interval and the chart's exposed
query reach the agent together. It investigates the source data and traces the
p95 jump from 256 to 1,450 ms to an inventory-pool change.

[Watch dashboard demo · 26 seconds](docs/demos/dashboard.mp4)

### Two selections. Two different layouts.

Loosely frame two areas of a Google Sheet. Zommi labels them **A** and **B**.

> Make A compact with navy headers. Make B spacious with orange headers,
> taller rows and larger text. Keep values and formulas.



**Each instruction lands in the right place.** The agent turns A into a compact
navy table and B into a roomy orange agenda. Values and formulas stay intact.
The selections supply the document context; the prompt only refers to A and B.

[Watch Sheets demo · 23 seconds](docs/demos/sheets.mp4)

<details>
<summary>About these recordings</summary>

Real selections, agent replies and sheet edits, recorded with the Windows
development build and Codex. The downloadable preview may differ. Clips speed
up gestures and typing, trim waits and include labelled context illustrations.
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

## Bring your agent

| Agent runtime | Connection | Support in Zommi |
| --- | --- | --- |
| **Codex** | Native app-server | Chats, saved sessions, models, approvals and native skills |
| **Pi** | RPC | Chats, image context, models and runtime commands |
| **Hermes** | ACP or Gateway | Chats and commands exposed by the runtime and profile |
| **OpenClaw** | ACP or local Gateway | Chats and commands exposed by the configured agent |
| **Claude CLI** | Terminal compatibility | Text-only interaction; image attachments unsupported |

Your agent keeps its account, models, tools and permissions. Features depend on
the installed runtime and protocol version.
[Agent setup](docs/install.md#2-choose-the-agent-you-already-have) ·
[Runtime command support](docs/runtime-commands.md).

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
