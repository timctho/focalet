# Zommi

Zommi is a local floating context companion for Codex CLI sessions. On Windows,
it starts a fresh session in the default WSL distribution and binds it
automatically.

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
- zero-configuration launch of a fresh Codex CLI session in default WSL;
- exact automatic binding through a one-time launch token and lifecycle hook;
- browser URL, Explorer path/selection, and pointer accessibility capture;
- an expiring, shared-memory snapshot with pause, freeze, and detach; and
- fail-open `UserPromptSubmit` handoff to the launched WSL Codex CLI session.

The packaged candidate has passed native Windows 11 capture checks and a real
Codex CLI 0.149 create/resume flow from WSL. The exact evidence boundary is in
[docs/acceptance-report.md](docs/acceptance-report.md).

Build and walkthrough instructions are in
[docs/windows-prototype.md](docs/windows-prototype.md).

## Launch

1. Extract the entire `zommi-win-x64.zip` archive to a local Windows folder.
2. Double-click `Zommi.exe`.

That is the complete setup. Zommi installs its local WSL hook, opens Windows
Terminal, starts a new Codex CLI chat in the default WSL distribution's home
directory, and binds only that launched session. Use **New Codex in WSL** when
you want another fresh bound session.

Codex CLI must already be installed, signed in, and available on the WSL shell
`PATH`. The prototype is unsigned, so Windows SmartScreen may require **More
info → Run anyway** on first launch.

Run the cross-platform contract checks with:

```sh
dotnet run --project tests/Zommi.Tests/Zommi.Tests.csproj
```

The Windows runtime suite is `scripts/test-windows-runtime.ps1`; package first,
then run it from Windows PowerShell as described in the acceptance report.

## Core boundary

- Local and account-free by default.
- Floating desktop UX rather than a browser-only chat surface.
- Structured URL, path, selection, window, and pointer context before images.
- Ephemeral by default; observation does not imply recording or persistence.
- Attached to the exact fresh session Zommi deliberately launches; it never
  guesses from recent or foreground sessions.
- No bundled chatbot, inference provider, or credential store.
- Runtime integration fails open and never restricts the agent's native tools.
