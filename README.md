# Zommi

Zommi is a local floating context companion for agent sessions that are already
running.

Its goal is to let someone browse, point, and ask naturally while their chosen
agent receives a compact description of what they are seeing. Zommi does not
host a model, require model API keys, or replace Codex, Hermes, or another agent
runtime.

The product intent and initial success boundary are documented in
[docs/product-intent.md](docs/product-intent.md). Project-specific language is
defined in [CONTEXT.md](CONTEXT.md).

## Status

Windows prototype implemented. It provides:

- an always-on-top WinForms companion;
- exact Codex session discovery and explicit binding through lifecycle hooks;
- browser URL, Explorer path/selection, and pointer accessibility capture;
- an expiring, single-snapshot local store with pause, freeze, and detach; and
- a fail-open `UserPromptSubmit` handoff to the bound Codex CLI session.

Build and walkthrough instructions are in
[docs/windows-prototype.md](docs/windows-prototype.md).

Run the cross-platform contract checks with:

```sh
dotnet run --project tests/Zommi.Tests/Zommi.Tests.csproj
```

## Core boundary

- Local and account-free by default.
- Floating desktop UX rather than a browser-only chat surface.
- Structured URL, path, selection, window, and pointer context before images.
- Ephemeral by default; observation does not imply recording or persistence.
- Attached to an explicit existing agent session.
- No bundled chatbot, inference provider, or credential store.
- Runtime integration fails open and never restricts the agent's native tools.
