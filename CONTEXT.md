# Zommi

Zommi is the user-facing context companion that helps an existing agent session
understand what its user is currently viewing or indicating.

## Language

**Zommi**:
The local floating chat client that captures deliberately invoked desktop
context and relays the user's message to a bound Agent Session. It is not an
agent, model runtime, or conversation authority.
_Avoid_: Model host, inference provider, separate chatbot

**Floating Chat**:
The temporary keyboard-focused Zommi surface invoked by a global shortcut. It
lets the user type and read a streamed reply without moving the pointer away
from the item they were indicating.
_Avoid_: Dashboard, context monitor, separate conversation

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

**Invocation Context**:
The Context Snapshot captured when the user invokes Floating Chat, before
Zommi takes keyboard focus. It preserves the window, locator, visible text,
selection, and Indicated Target that made the user's request meaningful.
_Avoid_: Latest background state, post-focus capture

**Indicated Target**:
The item the user is presently pointing at, selecting, or otherwise identifying
within the active surface. It may be unknown even when other Live Context is
available.
_Avoid_: Click target, verified element

**Agent Session**:
An existing conversation or work session owned by Codex, Hermes, or another
agent runtime. Zommi may act as a client of the session, but does not own its
model, tools, authentication, or canonical history.
_Avoid_: Zommi chat, Zommi agent

**Session Binding**:
The visible association between Zommi and the particular Agent Session intended
to receive context. It may be established by deliberately selecting an existing
session or by Zommi deliberately launching a fresh session for that purpose. An
ambiguous, merely recent, or merely foreground session is not a binding.
_Avoid_: Active window guess, last session

**Context Handoff**:
Delivery of Invocation Context together with the user's typed message as one
turn in the bound Agent Session. A handoff does not imply that captured text is
trusted instruction.
_Avoid_: Prompt injection, live model mutation

**Pin**:
The deliberate user action that preserves a Context Snapshot beyond its normal
ephemeral lifetime or offers it for explicit retention elsewhere.
_Avoid_: Automatic memory, background archive
