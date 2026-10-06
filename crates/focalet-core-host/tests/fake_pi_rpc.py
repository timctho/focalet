#!/usr/bin/env python3
"""Deterministic Pi RPC fixture for the Rust adapter."""

import json
import os
import sys

# The runtime wire protocol is UTF-8, including on Windows redirected pipes.
sys.stdin.reconfigure(encoding="utf-8")
sys.stdout.reconfigure(encoding="utf-8")


session_id = os.environ.get("FOCALET_FAKE_PI_SESSION", "pi-session-a")
session_file = os.environ.get("FOCALET_FAKE_PI_INITIAL_FILE", "/sessions/a.jsonl")
request_log = os.environ.get("FOCALET_FAKE_REQUEST_LOG")
active = False
session_files = {"pi-session-a": "/sessions/a.jsonl", "pi-session-new": "/sessions/new.jsonl", **json.loads(os.environ.get("FOCALET_FAKE_PI_SESSIONS", "{}"))}
if "--session" in sys.argv:
    selected = sys.argv[sys.argv.index("--session") + 1]
    if selected in session_files:
        session_id, session_file = selected, session_files[selected]
    elif selected in session_files.values():
        session_file = selected
        session_id = next(key for key, file in session_files.items() if file == selected)
    else:
        sys.exit(1)


def send(message):
    sys.stdout.write(json.dumps(message, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def log(message):
    if request_log:
        with open(request_log, "a", encoding="utf-8") as stream:
            stream.write(json.dumps(message, separators=(",", ":")) + "\n")


def response(request, data=None, success=True):
    send(
        {
            "type": "response",
            "id": request["id"],
            "success": success,
            "data": {} if data is None else data,
        }
    )


log({"startupSession": session_id, "startupArgs": sys.argv[1:], "cwd": os.getcwd()})

for line in sys.stdin:
    try:
        request = json.loads(line)
    except json.JSONDecodeError:
        continue
    log(request)
    request_type = request.get("type")
    if request_type == "extension_ui_response":
        if active:
            send({"type": "agent_end"})
            active = False
        continue
    if "id" not in request:
        continue

    if request_type == "get_state":
        response(
            request,
            {
                "version": "4.5.6",
                "sessionId": session_id,
                "sessionFile": session_file,
                "sessionName": "Pi fixture",
                "isStreaming": active,
                "isCompacting": False,
                "pendingMessageCount": 0,
                "model": {"provider": "openai", "id": "gpt-test"},
                "thinkingLevel": "high",
            },
        )
    elif request_type == "get_commands":
        response(request, {"commands":[{"name":"inspect", "description":"Inspect project", "source":"prompt"}, {"name":"local", "description":"Local extension", "source":"extension"}]})
    elif request_type == "get_available_models":
        response(
            request,
            {
                "models": [
                    {
                        "provider": "openai",
                        "id": "gpt-test",
                        "name": "GPT Test",
                        "reasoning": True,
                        "thinkingLevelMap": {
                            "minimal": None,
                            "low": None,
                            "medium": None,
                            "high": "high",
                            "xhigh": None,
                        },
                    }
                ]
            },
        )
    elif request_type == "get_messages":
        response(
            request,
            {
                "messages": [
                    {
                        "id": "u1",
                        "role": "user",
                        "content": [{"type": "text", "text": "saved question"}],
                    },
                    {
                        "id": "a1",
                        "role": "assistant",
                        "content": [
                            {"type": "thinking", "text": "saved thought"},
                            {"type": "text", "text": "saved answer"},
                        ],
                    },
                ]
            },
        )
    elif request_type == "switch_session":
        session_file = request["sessionPath"]
        session_id = next((key for key, file in session_files.items() if file == session_file), "pi-session-bound")
        if os.environ.get("FOCALET_FAKE_PI_WRONG_FILE") == session_file:
            session_id = "wrong-session"
        response(request, {"cancelled": False})
    elif request_type == "new_session":
        session_id = "pi-session-new"
        session_file = "/sessions/new.jsonl"
        response(request, {"cancelled": False})
    elif request_type in ("set_model", "set_thinking_level"):
        response(request)
    elif request_type == "prompt" and request.get("message") == "/local":
        response(request)
    elif request_type == "prompt":
        active = True
        response(request)
        send(
            {
                "type": "message_update",
                "assistantMessageEvent": {
                    "type": "thinking_delta",
                    "contentIndex": 0,
                    "delta": "considering",
                },
            }
        )
        send(
            {
                "type": "message_update",
                "assistantMessageEvent": {
                    "type": "text_delta",
                    "contentIndex": 1,
                    "delta": "Pi Rust reply",
                },
            }
        )
        send(
            {
                "type": "tool_execution_end",
                "toolName": "generate_preview",
                "toolCallId": "pi-tool-image",
                "result": {
                    "content": [
                        {
                            "type": "image",
                            "mimeType": "image/png",
                            "data": "aGVsbG8=",
                        },
                        {
                            "type": "resource_link",
                            "uri": "preview.html",
                            "title": "Preview",
                        },
                    ]
                },
            }
        )
        prompt_text = request.get("message", "")
        if "exit-runtime" in prompt_text:
            sys.stderr.write(
                "password=pi-adapter-secret "
                "<focalet_invocation_context>captured private Pi context</focalet_invocation_context>"
            )
            sys.stderr.flush()
            raise SystemExit(26)
        if "ask-question" in prompt_text:
            send(
                {
                    "type": "extension_ui_request",
                    "id": "ui-1",
                    "method": "confirm",
                    "title": "Continue?",
                    "message": "Run it?",
                }
            )
        elif "hold-for-interrupt" not in prompt_text:
            send({"type": "agent_end"})
            active = False
            if "late-frame" in prompt_text:
                send(
                    {
                        "type": "message_update",
                        "assistantMessageEvent": {
                            "type": "text_delta",
                            "contentIndex": 1,
                            "delta": "late Pi output",
                        },
                    }
                )
    elif request_type == "steer":
        response(request, {"accepted": True})
    elif request_type == "clear_queue":
        response(request)
    elif request_type == "abort":
        response(request)
        if active:
            send({"type": "agent_end"})
            active = False
    else:
        send(
            {
                "type": "response",
                "id": request["id"],
                "success": False,
                "error": "unsupported Pi fixture request",
            }
        )
