#!/usr/bin/env python3
"""Deterministic ACP runtime for Rust adapter process tests."""

import json
import os
import sys

# The runtime wire protocol is UTF-8, including on Windows redirected pipes.
sys.stdin.reconfigure(encoding="utf-8")
sys.stdout.reconfigure(encoding="utf-8")


session_id = os.environ.get("ZOMMI_FAKE_ACP_SESSION", "acp-session-new")
pending_prompt = None
request_log = os.environ.get("ZOMMI_FAKE_REQUEST_LOG")


def send(message):
    sys.stdout.write(json.dumps(message, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def log(message):
    if request_log:
        with open(request_log, "a", encoding="utf-8") as stream:
            stream.write(json.dumps(message, separators=(",", ":")) + "\n")


for line in sys.stdin:
    try:
        request = json.loads(line)
    except json.JSONDecodeError:
        continue
    log(request)
    method = request.get("method")
    request_id = request.get("id")

    if method == "session/cancel":
        if pending_prompt is not None:
            send({"jsonrpc": "2.0", "id": pending_prompt, "result": {"stopReason": "cancelled"}})
            pending_prompt = None
        continue
    if request_id is None:
        continue
    if method == "initialize":
        result = {
            "protocolVersion": 1,
            "agentInfo": {"name": "fixture-acp", "version": "3.2.1"},
            "agentCapabilities": {
                "loadSession": True,
                "promptCapabilities": {"image": True},
                "sessionCapabilities": {"list": {}, "resume": {}},
            },
            "authMethods": []
            if os.environ.get("ZOMMI_FAKE_ACP_NO_AUTH") == "1"
            else [{"id": "provider", "name": "Provider credentials"}],
        }
    elif method == "authenticate":
        result = {}
    elif method == "session/list":
        result = {
            "sessions": [
                {
                    "sessionId": session_id,
                    "title": "ACP fixture",
                    "updatedAt": "2026-08-30T00:00:00Z",
                    "cwd": "/work",
                }
            ]
        }
    elif method == "session/new":
        result = {
            "sessionId": session_id,
            "models": {
                "currentModelId": "provider:model-a",
                "availableModels": [
                    {"modelId": "provider:model-a", "name": "Model A"},
                    {"modelId": "provider:model-b", "name": "Model B"},
                ],
            },
        }
    elif method == "session/load":
        loaded = request["params"]["sessionId"]
        session_id = loaded
        send(
            {
                "jsonrpc": "2.0",
                "method": "session/update",
                "params": {
                    "sessionId": loaded,
                    "update": {
                        "sessionUpdate": "user_message_chunk",
                        "messageId": "saved-user",
                        "content": {"type": "text", "text": "saved question"},
                    },
                },
            }
        )
        send(
            {
                "jsonrpc": "2.0",
                "method": "session/update",
                "params": {
                    "sessionId": loaded,
                    "update": {
                        "sessionUpdate": "agent_message_chunk",
                        "messageId": "saved-agent",
                        "content": {"type": "text", "text": "saved answer"},
                    },
                },
            }
        )
        result = {}
    elif method == "session/set_model":
        result = {
            "models": {
                "currentModelId": request["params"]["modelId"],
                "availableModels": [
                    {"modelId": request["params"]["modelId"], "name": "Selected model"}
                ],
            }
        }
    elif method == "session/prompt":
        pending_prompt = request_id
        active_session = request["params"]["sessionId"]
        prompt_text = json.dumps(request["params"])
        send(
            {
                "jsonrpc": "2.0",
                "method": "session/update",
                "params": {
                    "sessionId": active_session,
                    "update": {
                        "sessionUpdate": "agent_thought_chunk",
                        "messageId": "thought-1",
                        "content": {"type": "text", "text": "considering"},
                    },
                },
            }
        )
        send(
            {
                "jsonrpc": "2.0",
                "method": "session/update",
                "params": {
                    "sessionId": active_session,
                    "update": {
                        "sessionUpdate": "agent_message_chunk",
                        "messageId": "agent-1",
                        "content": {"type": "text", "text": "ACP Rust reply"},
                    },
                },
            }
        )
        send(
            {
                "jsonrpc": "2.0",
                "method": "session/update",
                "params": {
                    "sessionId": active_session,
                    "update": {
                        "sessionUpdate": "tool_call_update",
                        "toolCallId": "tool-image",
                        "title": "Generate preview",
                        "status": "completed",
                        "content": [
                            {
                                "type": "image",
                                "mimeType": "image/png",
                                "data": "aGVsbG8=",
                            }
                        ],
                    },
                },
            }
        )
        if "request-approval" in prompt_text:
            send(
                {
                    "jsonrpc": "2.0",
                    "id": "permission-1",
                    "method": "session/request_permission",
                    "params": {
                        "sessionId": active_session,
                        "toolCall": {"toolCallId": "tool-a", "title": "Run command"},
                        "options": [
                            {"optionId": "allow_once", "kind": "allow_once", "name": "Allow once"}
                        ],
                    },
                }
            )
        if "exit-runtime" in prompt_text:
            sys.stderr.write(
                "token=acp-adapter-secret "
                "<zommi_invocation_context>captured private ACP context</zommi_invocation_context>"
            )
            sys.stderr.flush()
            raise SystemExit(25)
        if "hold-for-interrupt" not in prompt_text:
            send({"jsonrpc": "2.0", "id": request_id, "result": {"stopReason": "end_turn"}})
            pending_prompt = None
            if "late-frame" in prompt_text:
                send(
                    {
                        "jsonrpc": "2.0",
                        "method": "session/update",
                        "params": {
                            "sessionId": active_session,
                            "update": {
                                "sessionUpdate": "agent_message_chunk",
                                "messageId": "late-agent",
                                "content": {"type": "text", "text": "late ACP output"},
                            },
                        },
                    }
                )
        continue
    else:
        send(
            {
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {"code": -32601, "message": "unsupported ACP fixture method"},
            }
        )
        continue
    send({"jsonrpc": "2.0", "id": request_id, "result": result})
    if method in ("session/new", "session/load"):
        send({"jsonrpc":"2.0", "method":"session/update", "params":{"sessionId":session_id,"update":{"sessionUpdate":"available_commands_update", "availableCommands":[{"name":"inspect", "description":"Inspect this session", "input":{"hint":"target"}}]}}})
