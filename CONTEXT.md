# Zommi

Zommi is the user-facing context companion that helps an existing agent session
understand what its user is currently viewing or indicating.

## Language

**Zommi**:
The local, user-facing companion that observes deliberately available desktop
context and offers it to an existing Agent Session. It is not an agent or model
runtime.
_Avoid_: Chatbot, model host, screen recorder

**Live Context**:
The currently observable, user-side state that may help an agent understand a
request, including the active surface, current locator, selection, and indicated
target. It is transient and does not become retained knowledge by observation.
_Avoid_: Memory, Context Prior, recording

**Context Snapshot**:
A bounded representation of Live Context observed at one moment for possible
handoff to an Agent Session. It expires or is replaced unless the user
deliberately pins it.
_Avoid_: Screenshot, transcript, durable record

**Indicated Target**:
The item the user is presently pointing at, selecting, or otherwise identifying
within the active surface. It may be unknown even when other Live Context is
available.
_Avoid_: Click target, verified element

**Agent Session**:
An existing conversation or work session owned by Codex, Hermes, or another
agent runtime. Zommi supplies context to it without becoming its model provider.
_Avoid_: Zommi chat, Zommi agent

**Session Binding**:
The visible association between Zommi and the particular Agent Session intended
to receive context. An ambiguous set of sessions is not a binding.
_Avoid_: Active window guess, last session

**Context Handoff**:
Delivery of a Context Snapshot to its bound Agent Session at an input boundary
supported by that runtime. A handoff does not imply interruption of work already
in progress.
_Avoid_: Prompt injection, live model mutation

**Pin**:
The deliberate user action that preserves a Context Snapshot beyond its normal
ephemeral lifetime or offers it for explicit retention elsewhere.
_Avoid_: Automatic memory, background archive
