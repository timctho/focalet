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

Intent checkpoint only. No implementation or runtime integration exists yet.

## Core boundary

- Local and account-free by default.
- Floating desktop UX rather than a browser-only chat surface.
- Structured URL, path, selection, window, and pointer context before images.
- Ephemeral by default; observation does not imply recording or persistence.
- Attached to an explicit existing agent session.
- No bundled chatbot, inference provider, or credential store.
- Runtime integration fails open and never restricts the agent's native tools.
