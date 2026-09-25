#!/usr/bin/env python3
"""Deterministic ACP runtime for Rust adapter process tests."""

import json
import os
import sys
import uuid

# The runtime wire protocol is UTF-8, including on Windows redirected pipes.
sys.stdin.reconfigure(encoding="utf-8")
sys.stdout.reconfigure(encoding="utf-8")


session_id = os.environ.get("ZOMMI_FAKE_ACP_SESSION", "acp-session-new")
pending_prompt = None
request_log = os.environ.get("ZOMMI_FAKE_REQUEST_LOG")
gemini = os.environ.get("ZOMMI_FAKE_ACP_GEMINI") == "1"

# Read once, like an agent that discovers credentials/models at startup.
model_file = os.environ.get("ZOMMI_FAKE_ACP_MODEL_FILE")
model_config = json.load(open(model_file, encoding="utf-8")) if model_file else None


def send(message):
    if gemini and message.get("method") == "session/update":
        message["params"]["update"].pop("messageId", None)
    sys.stdout.write(json.dumps(message, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def log(message):
    if request_log:
        with open(request_log, "a", encoding="utf-8") as stream:
            stream.write(json.dumps(message, separators=(",", ":")) + "\n")


log({"launchArgs": sys.argv[1:], "fixturePid": os.getpid(), "permissionEnvironment": {key: os.environ.get(key) for key in ["OPENCODE_PERMISSION", "HERMES_YOLO_MODE"]}})

for line in sys.stdin:
    try:
        request = json.loads(line)
    except json.JSONDecodeError:
        continue
    log(request)
    method = request.get("method")
    request_id = request.get("id")

    if method is None and request_id == "permission-1":
        if pending_prompt is not None:
            send({"jsonrpc":"2.0", "id":pending_prompt, "result":{"stopReason":"end_turn"}})
            pending_prompt = None
        continue
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
        if gemini:
            # Gemini advertises several login methods but session/new reuses
            # its configured account. It supports load, not session/list.
            result["agentCapabilities"].pop("sessionCapabilities")
            result["authMethods"] = [
                {"id": "oauth-personal", "name": "Log in with Google"},
                {"id": "gemini-api-key", "name": "Gemini API key"},
                {"id": "vertex-ai", "name": "Vertex AI"},
            ]
    elif method == "authenticate":
        if gemini:
            raise AssertionError("Client must not switch Gemini's configured account")
        result = {}
    elif method == "session/list":
        if gemini:
            raise AssertionError("Gemini does not advertise session/list")
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
        if os.environ.get("ZOMMI_FAKE_UNIQUE_SESSIONS") == "1":
            session_id = str(uuid.uuid4())
        auth_state = os.environ.get("ZOMMI_FAKE_ACP_AUTH_STATE_PATH")
        if auth_state and not os.path.isfile(auth_state):
            send({"jsonrpc": "2.0", "id": request_id, "error": {
                "code": -32000, "message": "Gemini API key is missing or not configured."
            }})
            continue
        result = {
            "sessionId": session_id,
            "models": {
                "currentModelId": "provider:model-b" if os.environ.get("ZOMMI_FAKE_ACP_CONFIG_OPTIONS") == "1" else "provider:model-a",
                "availableModels": [
                    {"modelId": "provider:model-a", "name": "Model A"},
                    {"modelId": "provider:model-b", "name": "Model B"},
                ],
            },
        }
    elif method == "session/load":
        if model_config and model_config.get("failLoad"):
            send({"jsonrpc": "2.0", "id": request_id,
                  "error": {"code": -32000, "message": "Session not found"}})
            continue
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
    elif method == "session/set_config_option":
        assert request["params"]["configId"] == "provider-model"
        result = {"models": {"currentModelId": request["params"]["value"],
                             "availableModels": [{"modelId": request["params"]["value"], "name": "Selected model"}]}}
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
        if "hold-for-interrupt" not in prompt_text and "request-approval" not in prompt_text:
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
    if model_config is not None and method in ("session/new", "session/load", "session/set_config_option", "session/set_model"):
        result["models"] = {
            "currentModelId": request.get("params", {}).get("value", model_config.get("current", "provider:model-b")),
            "availableModels": model_config["models"],
        }
    if os.environ.get("ZOMMI_FAKE_ACP_CONFIG_OPTIONS") == "1" and "models" in result:
        models = result.pop("models")
        result["configOptions"] = [{"id": "provider-model", "category": "model", "name": "Model", "type": "select",
            "currentValue": models["currentModelId"], "options": [{"group": "provider", "name": "Provider",
            "options": [{"value": m["modelId"], "name": m["name"]} for m in models["availableModels"]]}]}]
    if gemini and method == "session/set_model":
        result = {}  # Gemini acknowledges a model change without returning its catalog.
    send({"jsonrpc": "2.0", "id": request_id, "result": result})
    if method in ("session/new", "session/load"):
        send({"jsonrpc":"2.0", "method":"session/update", "params":{"sessionId":session_id,"update":{"sessionUpdate":"available_commands_update", "availableCommands":[{"name":"inspect", "description":"Inspect this session", "input":{"hint":"target"}}]}}})
