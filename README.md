# Focalet — visual context for AI agents

**Show your agent what you mean.** Select and annotate screen regions, then share
screenshots and available browser or accessibility context. Choose the app that
fits how you already work:

| Product | Use it when | Availability |
| --- | --- | --- |
| **[Focalet Capture](docs/capture-tool.md)** | You want to stay in Cursor, a terminal, ChatGPT or another existing input. Capture several regions, then paste each image and its context in order. No agent setup is needed. | Windows tray tool; separate prototype package |
| **[Focalet Desktop](docs/install.md)** | You want a dedicated window for agent chats, saved sessions, model selection, approvals and captured attachments. | Windows, macOS and Ubuntu; existing Focalet installers |

Both apps live in this repository and share capture components. Capture does not
require Desktop, Flutter or the agent broker. [Use cases and product boundaries](docs/products.md).

The project, source packages and applications use the **Focalet** name.
Capture remains a separate Windows prototype. See [upgrade notes](docs/migration.md)
for earlier installations and release availability.

[![CI](https://github.com/timctho/focalet/actions/workflows/checks.yml/badge.svg?branch=main)](https://github.com/timctho/focalet/actions/workflows/checks.yml)
[![Latest release](https://img.shields.io/github/v/release/timctho/focalet)](https://github.com/timctho/focalet/releases/latest)
[![License: Apache 2.0](https://img.shields.io/badge/license-Apache%202.0-blue)](LICENSE)

[![Sketch a stacked chart and trend line, then watch the agent rebuild them](docs/demos/frontend-preview.webp)](docs/demos/frontend.mp4)

**Redesign a chart with a sketch.** Turn one chart into a channel breakdown and trend.

> Same six months: stacked channels left, revenue trend right.

[Watch the frontend demo](docs/demos/frontend.mp4) · [Documentation](https://timctho.github.io/focalet/)

## Download Desktop

| Platform | Architecture | Download |
| --- | --- | --- |
| Windows 10/11 | x64 | [Setup](https://github.com/timctho/focalet/releases/latest) |
| macOS 12+ | Apple Silicon (M1 or later) | [DMG](https://github.com/timctho/focalet/releases/latest) |
| macOS 12+ | Intel | [DMG](https://github.com/timctho/focalet/releases/latest) |
| Ubuntu 24.04 LTS · GNOME Wayland | x64 | [.deb](https://github.com/timctho/focalet/releases/latest) |

[Latest release and checksums](https://github.com/timctho/focalet/releases/latest)

Uses your existing agent account. [Installation guide](docs/install.md) ·
[Build from source](CONTRIBUTING.md)

Connect your agent, press **Alt+A** (**⌥ A** on Mac), select a region, and review
the attachment before sending. [Chrome and Edge setup](docs/guides/chrome-edge.md) ·
[Claude Code guide](docs/guides/claude-code.md) · [Ubuntu Wayland guide](docs/guides/ubuntu-wayland.md)

## Connect your agent in Desktop

Choose an installed agent, or use **Configure runtime → Add runtime** to add a
CLI. Repeat for additional runtimes, connect, then choose a model from the chat
header. Sign in through your agent's own flow if needed.

[![Configure agent runtimes, connect, and see the full Focalet window](docs/demos/setup-preview.webp)](docs/demos/setup.mp4)

| Agent | Support |
| --- | --- |
| **Codex** | Chats, images, saved sessions, models, approvals and native skills |
| **Claude Code** | Chats, images, models, tool approvals and session resume through stream-json |
| **OpenCode** | Chats, images, saved sessions, models, approvals and advertised commands through ACP |
| **Gemini CLI** | Chats, images, models, approvals and advertised commands through ACP; [resume limitations](docs/install.md#2-choose-the-agent-you-already-have) |
| **Hermes** | Chats and commands exposed by its ACP or Gateway profile |
| **OpenClaw** | Chats and commands exposed by its ACP or local Gateway configuration |
| **Pi** | Chats, images, models and runtime commands through RPC |

## Desktop examples

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

## Capture and share in Desktop

Press **Alt+A** (**⌥ A** on Mac), select a region, review the attachment and ask your question.
On Windows and Mac, use the drawing toolbar to annotate or add more regions, then press
**Attach**. Multiple attachments keep their **A**, **B**, **C** references.

On Windows, Ubuntu Wayland and macOS, attachments can include source identity, text, links, element
structure and coordinates through accessibility and an optional authorized
browser connection. When reliable alignment is unavailable, Desktop attaches
**Image only** with an explanation.

Capture happens when you invoke it. Review what you share: source metadata can
extend beyond the selected pixels. Your selected agent's provider and data
policies apply. [Capture controls and limitations](docs/browser-context.md)

First launch and App settings include **Full access (YOLO)**, enabled by default.
Turn it off to follow each agent’s permission policy and show its approval
requests. [Runtime permissions](docs/install.md#2-choose-the-agent-you-already-have)

## Desktop platforms

| Platform | Capture support |
| --- | --- |
| **Windows 10/11 · x64** | Multiple regions, drawing, accessibility and optional browser context |
| **macOS 12+ · Apple Silicon / Intel** | Multiple regions, drawing, native Accessibility and optional browser context |
| **Ubuntu 24.04 LTS · x64 · GNOME Wayland** | Multiple regions, drawing, AT-SPI and optional browser context; requires the bundled desktop integration and screen-sharing authorization; [install and test](docs/ubuntu-testing.md) |

Linux support targets Ubuntu 24.04's GNOME Wayland desktop. Enable **Focalet
Desktop Integration** in App settings for Alt+A and aligned app context.

[Releases](https://github.com/timctho/focalet/releases) ·
[Installation and permissions](docs/install.md) ·
[Contributing](CONTRIBUTING.md) · [Privacy](docs/privacy.md) ·
[Security](SECURITY.md) · [Code signing policy](docs/code-signing.md)

## License

Focalet is licensed under [Apache 2.0](LICENSE).
[Third-party components](THIRD_PARTY_NOTICES.md) retain their respective licenses.
