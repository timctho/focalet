---
title: Focalet — visual context for AI agents
description: Capture screen context into your existing tools, or work with your agents in a dedicated desktop app.
---
![Focalet aperture icon](assets/focalet-icon.png){ width="72" }

# Focalet — visual context for AI agents

**Show your agent what you mean.** Select and annotate screen regions, then share
the images with available text, links and structure.

<video controls autoplay muted loop playsinline preload="metadata" poster="demos/frontend-poster.webp" style="width: 100%; border-radius: 12px;" aria-label="Desktop demo: sketch a chart and ask an agent to rebuild it">
  <source src="demos/frontend.mp4" type="video/mp4">
  <a href="demos/frontend.mp4">Watch the Desktop demo</a>.
</video>

This is a historical Desktop recording from before the rename. Its original
footage is retained; new builds display Focalet.

## Choose your workflow

| | Focalet Capture | Focalet Desktop |
| --- | --- | --- |
| Use it for | Adding screen context to your existing editor, terminal or chat app | Managing agent chats, saved sessions, models and attachments in a dedicated window |
| Examples | Show Cursor a UI bug; paste a chart into ChatGPT; give a terminal agent several annotated regions | Switch between project conversations; review captured attachments; respond to agent approvals |
| Setup | No agent connection or sign-in in Capture | Connect an installed agent and use its existing account |
| Platforms | Windows, macOS and Ubuntu GNOME Wayland | Windows, macOS and Ubuntu GNOME Wayland |

### Download

| Platform | Focalet Capture | Focalet Desktop |
| --- | --- | --- |
| Windows 10/11 · x64 | [Windows setup](https://github.com/timctho/focalet/releases/download/v0.3.1/Focalet-Capture-Setup-x64.exe) | [Windows setup](https://github.com/timctho/focalet/releases/download/v0.3.1/Focalet-Setup-x64.exe) |
| macOS 12+ · Apple Silicon | [Apple Silicon DMG](https://github.com/timctho/focalet/releases/download/v0.3.1/Focalet-Capture-macOS-arm64.dmg) | [Apple Silicon DMG](https://github.com/timctho/focalet/releases/download/v0.3.1/Focalet-macOS-arm64.dmg) |
| macOS 12+ · Intel | [Intel DMG](https://github.com/timctho/focalet/releases/download/v0.3.1/Focalet-Capture-macOS-x64.dmg) | [Intel DMG](https://github.com/timctho/focalet/releases/download/v0.3.1/Focalet-macOS-x64.dmg) |
| Ubuntu 24.04 · x64 · GNOME Wayland | [Ubuntu package](https://github.com/timctho/focalet/releases/download/v0.3.1/Focalet-Capture-Ubuntu-amd64.deb) | [Ubuntu package](https://github.com/timctho/focalet/releases/download/v0.3.1/Focalet-Ubuntu-amd64.deb) |

Install either app independently. Capture runs from the system tray or menu bar;
Desktop opens an agent workspace. All downloads above are **v0.3.1**.

## Capture: keep your existing input

Select a page fragment, an error message and a chart in one batch. Click the
input in your existing tool and paste **image A → context A → image B → context B**.
Images remain separate. Text still arrives in inputs that do not accept images;
the receiver decides how to display attachments. See [Capture usage](capture-tool.md).

## Desktop: work across agent sessions

Connect an installed agent, choose a model, and manage chats, drafts and
attachments in a dedicated window. Runtime support includes Codex, Claude Code,
OpenCode, Gemini CLI, Hermes, OpenClaw and Pi; features depend on each protocol.
The selected agent continues to own credentials, tools, permissions and history.

- [Install Desktop and connect an agent](install.md).
- [Share screen context with Claude Code from Desktop](guides/claude-code.md).
- [Connect Chrome and Edge for browser DOM context](guides/chrome-edge.md).
- [Capture on Ubuntu Wayland in Desktop](guides/ubuntu-wayland.md).
- [Understand capture limits](browser-context.md) and [privacy](privacy.md).

## Build and contribute

Capture uses native Windows, macOS and GTK APIs. Desktop uses Flutter, a Rust agent
broker and platform capture helpers. See the [contributor guide](../CONTRIBUTING.md),
[component map](desktop-reference.md) and [coding agent guide](../AGENTS.md).

Focalet is licensed under [Apache 2.0](../LICENSE).
[Code signing policy](code-signing.md) · [Security policy](../SECURITY.md)
