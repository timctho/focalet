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
Zommi takes keyboard focus. It preserves Surface Selection first, then the
window, locator, Indicated Target, and surrounding context that made the
user's request meaningful.
_Avoid_: Latest background state, post-focus capture

**Surface Selection**:
The text, range, file, or visual objects deliberately selected in the active
surface when Zommi is invoked. It is the strongest available indication of
what the user means and may contain one or multiple selected items.
_Avoid_: Selected text only, pointer target, inferred region

**Indicated Target**:
The accessibility item directly under the pointer when Zommi is invoked. It is
a fallback indication when Surface Selection is absent and may be broad or
unknown when an application exposes only a canvas or document.
_Avoid_: Surface Selection, click target, verified element

**Agent Session**:
An existing conversation or work session owned by Codex, Hermes, or another
agent runtime. Zommi may act as a client of the session, but does not own its
model, tools, authentication, or canonical history.
_Avoid_: Zommi chat, Zommi agent

**Execution Host**:
The local or remote environment in which an agent runtime is available. Native
Windows and each WSL distribution are separate Execution Hosts even when they
belong to the same computer.
_Avoid_: Agent, session, generic machine

**Runtime Adapter**:
The Zommi boundary that translates common session and turn operations to one
agent runtime's machine-readable interaction contract.
_Avoid_: Agent runtime, terminal skin, model provider

**Runtime-Owned Bridge**:
A machine-readable bridge supplied by the agent runtime that resolves its own
credentials and projects its canonical sessions without revealing authentication
material to Zommi.
_Avoid_: Zommi credential proxy, copied token, terminal scraper

**Runtime Target**:
A specific agent runtime interaction mode on one Execution Host, including the
runtime-owned identity needed to reach it. Two modes of the same agent product
are separate Runtime Targets when their session authority or capabilities differ.
_Avoid_: Agent name, discovered process, most recent session

**Compatibility Adapter**:
A visibly degraded Runtime Adapter for a terminal-only agent. It may launch and
drive a terminal interface, but cannot imply exact session, history, approval,
or turn semantics that the underlying runtime does not expose.
_Avoid_: Native adapter, protocol adapter, full support

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
