<picture>
  <source media="(prefers-color-scheme: dark)" srcset="design/zommi-logo/exports/ocean/lockup-dark.png">
  <img src="design/zommi-logo/exports/ocean/lockup-light.png" alt="Zommi" width="240">
</picture>

# Show your agent what you mean.

**Select it. Ask. Keep going.** Zommi connects what you see on screen to your
existing agent. Select a region, add a sketch if useful, and send the image with
available text, links and structure.

## Download

| Platform | Architecture | Download |
| --- | --- | --- |
| Windows 10/11 | x64 | [Setup · preview.5](https://github.com/timctho/zommi/releases/download/v0.1.1-preview.5/Zommi-Setup-x64.exe) |
| macOS 12+ | Apple Silicon (M1 or later) | [Mac releases](https://github.com/timctho/zommi/releases) · `Zommi-macOS-arm64.dmg` planned for preview.5 |
| macOS 12+ | Intel | [Mac releases](https://github.com/timctho/zommi/releases) · `Zommi-macOS-x64.dmg` planned for preview.5 |
| Ubuntu 24.04 LTS · GNOME Wayland | x64 | [.deb · preview.5](https://github.com/timctho/zommi/releases/download/v0.1.1-preview.5/Zommi-Ubuntu-amd64.deb) |

Mac installers will appear after the preview.5 release builds pass and publish.
[All releases and checksums](https://github.com/timctho/zommi/releases)

Uses your existing agent account. [Installation guide](docs/install.md) ·
[Build from source](CONTRIBUTING.md)

## Connect your agent

Choose an installed agent, or use **Configure runtime → Add runtime** to add a
CLI. Repeat for additional runtimes, connect, then choose a model from the chat
header. Sign in through your agent's own flow if needed.

[![Configure agent runtimes, connect, and see the full Zommi window](docs/demos/setup-preview.webp)](docs/demos/setup.mp4)

| Agent | Support |
| --- | --- |
| **Codex** | Chats, images, saved sessions, models, approvals and native skills |
| **OpenCode** | Chats, images, saved sessions, models, approvals and advertised commands through ACP |
| **Gemini CLI** | Chats, images, models, approvals and advertised commands through ACP; [resume limitations](docs/install.md#2-choose-the-agent-you-already-have) |
| **Pi** | Chats, images, models and runtime commands through RPC |
| **Hermes** | Chats and commands exposed by its ACP or Gateway profile |
| **OpenClaw** | Chats and commands exposed by its ACP or local Gateway configuration |
| **Claude Code** | Chats, images, models, tool approvals and session resume through stream-json |

## See it in action

Animated previews play automatically; click one for the clearer video.

### Compare three products

Hold **Ctrl** while drawing three separate boxes, one per product, then attach
them together. Each selection keeps its own product link.

> Which of these three would let my M1 MacBook Air run two independent monitors?
> Check the exact listings.

[![Three separate product selections become a sourced compatibility comparison](docs/demos/amazon-preview.webp)](docs/demos/amazon.mp4)

### Investigate a latency spike

Select the interval that looks wrong. This chart exposes its query and data
points, giving the agent context to investigate the source database.

> Why did latency spike here? Check the underlying query and source data.

[![Select a latency spike and investigate its cause](docs/demos/dashboard-preview.webp)](docs/demos/dashboard.mp4)

### Sketch two quotes across a sheet

Use the **Pen** to loop items across three tables, connect them to two quote
boxes, and cross out an option. The agent turns the sketch into linked formulas.

> Turn my sketch into the two quotes. Each loop feeds the box it points to;
> skip the crossed-out option. Link to source cells and calculate subtotal,
> tax and total. Leave source data alone.

[![Freehand groups, connections and an exclusion become two linked quotes](docs/demos/sheets-preview.webp)](docs/demos/sheets.mp4)

## Capture and share

Press **Alt+A** (**⌥ A** on Mac), select a region, review the attachment and ask your question.
On Windows and Mac, use the drawing toolbar to annotate or add more regions, then press
**Attach**. Multiple attachments keep their **A**, **B**, **C** references.

On Windows, Ubuntu Wayland and macOS, attachments can include source identity, text, links, element
structure and coordinates through accessibility and an optional authorized
browser connection. When reliable alignment is unavailable, Zommi attaches
**Image only** with an explanation.

Capture happens when you invoke it. Review what you share: source metadata can
extend beyond the selected pixels. Your selected agent's provider and data
policies apply. [Capture controls and limitations](docs/browser-context.md)

First launch and App settings include **Full access (YOLO)**, enabled by default.
Turn it off to follow each agent’s permission policy and show its approval
requests. [Runtime permissions](docs/install.md#2-choose-the-agent-you-already-have)

## Platforms

| Platform | Capture support |
| --- | --- |
| **Windows 10/11 · x64** | Multiple regions, drawing, accessibility and optional browser context |
| **macOS 12+ · Apple Silicon / Intel** | Multiple regions, drawing, native Accessibility and optional browser context |
| **Ubuntu 24.04 LTS · x64 · GNOME Wayland** | Multiple regions, drawing, AT-SPI and optional browser context; requires the bundled desktop integration and screen-sharing authorization; [install and test](docs/ubuntu-testing.md) |

Linux support targets Ubuntu 24.04's GNOME Wayland desktop. Enable **Zommi
Desktop Integration** in App settings for Alt+A and aligned app context.

[Releases](https://github.com/timctho/zommi/releases) ·
[Installation and permissions](docs/install.md) ·
[Contributing](CONTRIBUTING.md)

## License

Zommi is licensed under [Apache 2.0](LICENSE).
[Third-party components](THIRD_PARTY_NOTICES.md) retain their respective licenses.
