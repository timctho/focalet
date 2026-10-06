"""Isolate runtime probes from a parent desktop application's routing context."""
import re


CONTEXT_NAMESPACE = re.compile(
    r"^(.+?)_(?:AGENT_(?:HOOK|LAUNCH)_|ORCHESTRATION_|PANE_|SHELL_READY_|"
    r"TAB_|TERMINAL_|USER_DATA_|WORKTREE_|CLI_COMMAND$|CODEX_(?:HOME|LAUNCH_PREFLIGHT)$)",
    re.I,
)


def without_parent_context(environment):
    namespaces = {
        match[1].upper() + "_"
        for key in environment
        if not key.upper().startswith("FOCALET_") and (match := CONTEXT_NAMESPACE.match(key))
    }
    return {
        key: value for key, value in environment.items()
        if not any(key.upper().startswith(namespace) for namespace in namespaces)
    }
