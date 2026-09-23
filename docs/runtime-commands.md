# Runtime command discovery

The composer discovers slash commands when a runtime session connects. Command
metadata is cached for that session and refreshed after a workspace/profile
change, a runtime recovery, an advertised catalog change, or the menu's Refresh
commands action. A failed or unsupported discovery request does not prevent chat.

| Adapter | Catalog | Execution |
| --- | --- | --- |
| Codex app-server | Existing native controls plus `skills/list` | `/clear`, `/new`, `/goal`, and `/help` keep their existing mappings. `/skill:name` uses a typed Codex `skill` input with the discovered path. |
| OpenCode / Gemini CLI / Hermes / OpenClaw ACP | `session/update:available_commands_update` | `session/prompt`, with the slash text preserved at the start. Later advertisements replace that session's catalog, including empty lists. |
| Pi RPC | `get_commands` | `prompt`, preserving command text. Extension commands that finish without agent events receive a completed turn after the runtime confirms it is idle. |
| Hermes Gateway | `commands.catalog` | `slash.exec`, or `command.dispatch` for skills and quick commands; runtime-produced skill/prompt expansions go to `prompt.submit`. Plain command output is rendered without a model prompt. |
| OpenClaw Gateway | `commands.list` for the session's agent and text scope | `chat.send`, preserving command text. |
| Terminal compatibility (Claude CLI) | None | No structured command discovery. |

Catalogs describe the commands available through each protocol, not every command
in the runtime's terminal application. Pi explicitly omits built-in terminal
commands. Hermes terminal commands and session actions requiring a separate
client workflow remain visible but disabled. Model/provider/profile/workspace and
reasoning commands use Zommi's settings controls until adapters can synchronize
authoritative post-command settings; otherwise the next prompt could overwrite
the command's changes. Unexpected interactive result types return an explicit
error. Codex does not expose a universal built-in command
catalog, so new built-in controls still need explicit API mappings.

Discovered runtime commands are disabled while the chat is busy or read-only.
Attachments must be sent or removed before a runtime command runs: adding captured context to command
arguments would change their meaning. Ordinary messages keep the existing context
handoff. Unknown commands on structured adapters are rejected, retaining the
draft, rather than being submitted as a model request.

## Core contract

- `session.commands` takes `runtimeTargetId`, `sessionId`, and optional `force`.
  It returns normalized `commands` with name, description, input hint, optional
  subcommands, source, and disabled reason. Discovery is bounded to five seconds.
- `commands.updated` carries the complete replacement list for an exact runtime
  and session. `commands.invalidated` causes rediscovery for that runtime. Push
  updates take precedence over older pending reads in the controller.
- `command.execute` takes the same identity, model settings, and operation ID as
  `turn.start`. The adapter validates the command against its catalog before
  dispatching it. It uses the normal turn event stream and operation deduplication;
  command intent participates in the operation fingerprint. An accepted or
  uncertain operation is never replayed automatically.

The core normalizes bounded metadata and chooses the dispatch method itself. A
catalog entry cannot supply an arbitrary RPC method or executable.

## Verification

`tests/test_runtime_commands.py` exercises the real core host against protocol
fixtures for ACP, Codex, Hermes, OpenClaw, Pi prompts, and Pi extensions. It checks
raw command prefixes, native skill input, immediate Gateway/extension completion, rejection, and
duplicate-operation behavior. Flutter tests cover caching, stale reads, session
isolation, empty replacements, fallback, completion, and the rendered menu.
