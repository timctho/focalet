#!/usr/bin/env python3
"""Deterministic Hermes/OpenClaw Gateway fixture using only the Python stdlib."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import socket
import struct
import sys
import threading
import time
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlsplit


GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
LOG_PATH = os.environ.get("ZOMMI_FAKE_REQUEST_LOG")


def write_log(frame: dict[str, Any]) -> None:
    if not LOG_PATH:
        return
    safe = json.loads(json.dumps(frame))
    if safe.get("method") == "connect" and isinstance(safe.get("params"), dict):
        auth = safe["params"].get("auth")
        if isinstance(auth, dict):
            safe["params"]["auth"] = {key: "<redacted>" for key in auth}
    with Path(LOG_PATH).open("a", encoding="utf-8") as output:
        output.write(json.dumps(safe, separators=(",", ":")) + "\n")


def read_http_request(connection: socket.socket) -> tuple[str, dict[str, str]]:
    data = bytearray()
    while b"\r\n\r\n" not in data:
        chunk = connection.recv(4096)
        if not chunk:
            raise EOFError("request closed")
        data.extend(chunk)
        if len(data) > 65536:
            raise ValueError("request too large")
    lines = data.decode("iso-8859-1").split("\r\n")
    headers: dict[str, str] = {}
    for line in lines[1:]:
        if ":" in line:
            key, value = line.split(":", 1)
            headers[key.strip().lower()] = value.strip()
    return lines[0], headers


def websocket_handshake(connection: socket.socket, headers: dict[str, str]) -> None:
    key = headers.get("sec-websocket-key", "")
    accept = base64.b64encode(hashlib.sha1((key + GUID).encode("ascii")).digest()).decode("ascii")
    connection.sendall(
        (
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Accept: {accept}\r\n\r\n"
        ).encode("ascii")
    )


def recv_exact(connection: socket.socket, size: int) -> bytes:
    data = bytearray()
    while len(data) < size:
        chunk = connection.recv(size - len(data))
        if not chunk:
            raise EOFError("socket closed")
        data.extend(chunk)
    return bytes(data)


def read_ws(connection: socket.socket) -> dict[str, Any] | None:
    while True:
        first, second = recv_exact(connection, 2)
        opcode = first & 0x0F
        masked = bool(second & 0x80)
        length = second & 0x7F
        if length == 126:
            length = struct.unpack("!H", recv_exact(connection, 2))[0]
        elif length == 127:
            length = struct.unpack("!Q", recv_exact(connection, 8))[0]
        mask = recv_exact(connection, 4) if masked else b""
        payload = bytearray(recv_exact(connection, length))
        if masked:
            for index in range(length):
                payload[index] ^= mask[index % 4]
        if opcode == 8:
            return None
        if opcode == 9:
            send_ws_raw(connection, bytes(payload), opcode=10)
            continue
        if opcode != 1:
            continue
        return json.loads(payload.decode("utf-8"))


def send_ws_raw(connection: socket.socket, payload: bytes, opcode: int = 1) -> None:
    header = bytearray([0x80 | opcode])
    if len(payload) < 126:
        header.append(len(payload))
    elif len(payload) < 65536:
        header.append(126)
        header.extend(struct.pack("!H", len(payload)))
    else:
        header.append(127)
        header.extend(struct.pack("!Q", len(payload)))
    connection.sendall(bytes(header) + payload)


def send_ws(connection: socket.socket, frame: dict[str, Any]) -> None:
    send_ws_raw(connection, json.dumps(frame, separators=(",", ":")).encode("utf-8"))


def hermes_event(connection: socket.socket, event_type: str, session_id: str, payload: dict[str, Any]) -> None:
    send_ws(
        connection,
        {
            "jsonrpc": "2.0",
            "method": "event",
            "params": {"type": event_type, "session_id": session_id, "payload": payload},
        },
    )


def serve_hermes(connection: socket.socket) -> None:
    runtime_session_id = "hermes-runtime-session"
    stored_session_id = "hermes-stored-session"
    pending_interactions = {"approval": False, "question": False}
    timeline_history: list[dict[str, Any]] = []
    pending_timeline: list[tuple[str, dict[str, Any]]] = []
    current_turn = ""
    while True:
        request = read_ws(connection)
        if request is None:
            return
        write_log(request)
        method = request.get("method")
        params = request.get("params") or {}
        result: dict[str, Any] = {}
        if method == "session.list":
            profile = str(params.get("profile") or "default")
            listed_session_id = (
                "hermes-coder-session" if profile == "coder" else stored_session_id
            )
            result = {
                "sessions": [
                    {
                        "id": listed_session_id,
                        "title": f"Saved Hermes {profile} chat",
                        "preview": "saved",
                        "started_at": 12,
                        "message_count": 2,
                    }
                ]
            }
        elif method == "session.create":
            profile = str(params.get("profile") or "default")
            created_session_id = (
                "hermes-coder-session" if profile == "coder" else stored_session_id
            )
            result = {
                "session_id": runtime_session_id,
                "stored_session_id": created_session_id,
                "messages": [],
                "info": {
                    "model": "gpt-test",
                    "provider": "copilot",
                    "reasoning_effort": "medium",
                    "cwd": params.get("cwd") or "/workspace/default",
                    "profile_name": profile,
                },
            }
        elif method == "session.resume":
            profile = str(params.get("profile") or "default")
            result = {
                "session_id": runtime_session_id,
                "resumed": params.get("session_id"),
                "session_key": params.get("session_id"),
                "running": bool(pending_timeline) and params.get("session_id") == stored_session_id,
                "messages": timeline_history if timeline_history and params.get("session_id") == stored_session_id else [
                    {"role": "user", "text": "saved question"},
                    {"role": "assistant", "text": "saved answer"},
                ],
                "info": {
                    "model": "gpt-test",
                    "provider": "copilot",
                    "reasoning_effort": "medium",
                    "cwd": "/workspace/default",
                    "profile_name": profile,
                },
            }
        elif method == "session.cwd.set":
            result = {
                "cwd": params.get("cwd"),
                "profile_name": "default",
            }
        elif method == "model.options":
            result = {
                "providers": [
                    {
                        "slug": "copilot",
                        "models": [{"id": "gpt-test", "name": "GPT Test"}],
                    }
                ]
            }
        elif method == "commands.catalog":
            result = {"pairs":[["/inspect", "Inspect project"], ["/skill-test", "A skill"], ["/quit", "Exit"], ["/quick", "Quick alias"]], "categories":[{"name":"User commands", "pairs":[["/quick", "Quick alias"]]}], "skills":{"/skill-test":{}}, "canon":{}}
        elif method == "slash.exec":
            result = {"output":"Hermes command result"}
        elif method == "command.dispatch":
            result = {"type":"alias", "target":"inspect"} if params.get("name") == "quick" else {"type":"skill", "message":"Expanded Hermes skill"}
        elif method == "prompt.submit":
            current_turn = str(params.get("text", ""))
            result = {"status": "streaming"}
        elif method == "image.attach_bytes":
            result = {"attached": True}
        elif method == "approval.respond":
            pending_interactions["approval"] = True
            result = {"ok": True}
        elif method == "clarify.respond":
            pending_interactions["question"] = True
            result = {"ok": True}
        elif method == "session.interrupt":
            result = {"ok": True}
        elif method == "config.set":
            result = {"ok": True}
        send_ws(connection, {"jsonrpc": "2.0", "id": request.get("id"), "result": result})

        if method == "prompt.submit":
            if "timeline-order" in current_turn:
                frames = [
                    ("message.start", {}),
                    ("thinking.delta", {"text": "First reasoning"}),
                    ("message.delta", {"text": "Checking files"}),
                    ("reasoning.available", {"text": "Checking files"}),
                    ("message.interim", {"text": "Checking files", "already_streamed": True}),
                    ("tool.start", {"tool_id": "inspect", "name": "terminal", "context": "git status"}),
                    ("thinking.delta", {"text": "Second reasoning"}),
                    ("message.interim", {"text": "Checking results", "already_streamed": False}),
                    ("tool.progress", {"tool_id": "inspect", "name": "terminal", "text": "Working"}),
                    ("tool.complete", {"tool_id": "inspect", "name": "terminal", "result": "Clean"}),
                    ("message.delta", {"text": "An obsolete final candidate"}),
                    ("reasoning.available", {"text": "An obsolete final candidate"}),
                    ("message.complete", {"text": "Verified answer", "reasoning": "Final reasoning", "status": "complete"}),
                ]
                timeline_history = [
                    {"role":"user", "text":current_turn, "row_id":100},
                    {"role":"assistant", "text":"Checking files", "reasoning_content":"First reasoning", "row_id":101},
                    {"role":"tool", "name":"terminal", "context":"git status"},
                    {"role":"assistant", "text":"Checking results", "reasoning":"Second reasoning", "row_id":102},
                    {"role":"assistant", "text":"Verified answer", "reasoning":"Final reasoning", "row_id":103},
                ]
                if "timeline-order-hold" in current_turn:
                    pending_timeline = frames[6:]
                    frames = frames[:6]
                for event_type, payload in frames:
                    hermes_event(connection, event_type, runtime_session_id, payload)
                continue
            hermes_event(connection, "message.delta", runtime_session_id, {"text": "Hermes Rust "})
            if "request-interactions" in current_turn:
                hermes_event(
                    connection,
                    "approval.request",
                    runtime_session_id,
                    {
                        "request_id": "hermes-approval-1",
                        "command": "git status",
                        "choices": ["once", "deny"],
                    },
                )
                hermes_event(
                    connection,
                    "clarify.request",
                    runtime_session_id,
                    {
                        "request_id": "hermes-question-1",
                        "question": "Which branch?",
                        "choices": ["main", "dev"],
                    },
                )
            elif "hold-for-interrupt" not in current_turn and "disconnect-after-accept" not in current_turn:
                hermes_event(
                    connection,
                    "message.complete",
                    runtime_session_id,
                    {"text": "Hermes Rust reply", "reasoning": "checked", "status": "complete"},
                )
                if "late-frame" in current_turn:
                    hermes_event(
                        connection,
                        "message.complete",
                        runtime_session_id,
                        {"text": "duplicate", "status": "complete"},
                    )
                    hermes_event(connection, "message.delta", runtime_session_id, {"text": "late"})
            elif "disconnect-after-accept" in current_turn:
                time.sleep(0.03)
                connection.shutdown(socket.SHUT_RDWR)
                connection.close()
                return
        elif method == "session.resume" and params.get("session_id") == stored_session_id and pending_timeline:
            for event_type, payload in pending_timeline:
                hermes_event(connection, event_type, runtime_session_id, payload)
            pending_timeline = []
        elif method in {"approval.respond", "clarify.respond"} and all(pending_interactions.values()):
            hermes_event(
                connection,
                "message.complete",
                runtime_session_id,
                {"text": "Hermes Rust reply", "reasoning": "checked", "status": "complete"},
            )
        elif method == "session.interrupt":
            hermes_event(
                connection,
                "message.complete",
                runtime_session_id,
                {"text": "", "status": "cancelled"},
            )


OPENCLAW_METHODS = [
    "commands.list",
    "sessions.list",
    "sessions.create",
    "sessions.messages.subscribe",
    "sessions.messages.unsubscribe",
    "chat.history",
    "chat.send",
    "chat.abort",
    "models.list",
    "approval.resolve",
    "question.resolve",
]


def openclaw_event(connection: socket.socket, event: str, payload: dict[str, Any], seq: int) -> None:
    send_ws(connection, {"type": "event", "event": event, "payload": payload, "seq": seq})


def serve_openclaw(connection: socket.socket) -> None:
    active_key = "agent:main:zommi-rust"
    run_counter = 0
    active_run = ""
    pending_interactions = {"approval": False, "question": False}
    openclaw_event(
        connection,
        "connect.challenge",
        {"nonce": "fixture-nonce", "ts": 1_800_000_000_000},
        0,
    )
    while True:
        request = read_ws(connection)
        if request is None:
            return
        write_log(request)
        method = request.get("method")
        params = request.get("params") or {}
        if method == "connect":
            send_ws(
                connection,
                {
                    "type": "res",
                    "id": request.get("id"),
                    "ok": True,
                    "payload": {
                        "type": "hello-ok",
                        "protocol": 4,
                        "features": {"methods": OPENCLAW_METHODS, "events": ["chat"]},
                        "server": {"version": "2026.8.1", "connId": "fixture-connection"},
                        "auth": {
                            "role": "operator",
                            "scopes": params.get("scopes", []),
                            "deviceToken": "fixture-issued-device-token",
                        },
                        "policy": {"maxPayload": 25000000, "tickIntervalMs": 15000},
                    },
                },
            )
            continue
        result: dict[str, Any] = {"ok": True}
        if method == "sessions.list":
            result = {
                "sessions": [
                    {
                        "key": active_key,
                        "derivedTitle": "Saved OpenClaw chat",
                        "updatedAt": 12,
                        "model": "gpt-test",
                        "modelProvider": "copilot",
                    }
                ]
            }
        elif method == "sessions.create":
            result = {"ok": True, "key": active_key}
        elif method == "chat.history":
            result = {
                "messages": [
                    {"role": "user", "content": [{"type": "text", "text": "saved question"}]},
                    {"role": "assistant", "content": [{"type": "text", "text": "saved answer"}]},
                ]
            }
        elif method == "models.list":
            result = {
                "models": [
                    {"id": "gpt-test", "name": "GPT Test", "provider": "copilot"}
                ]
            }
        elif method == "commands.list":
            result = {"commands":[{"name":"inspect", "description":"Inspect project", "acceptsArgs":True}, {"name":"stop", "description":"Stop"}]}
        elif method == "chat.send" and params.get("message") == "/stop":
            send_ws(connection, {"type":"res", "id":request.get("id"), "ok":True, "payload":{"ok":True, "aborted":False, "runIds":[]}})
            continue
        elif method == "chat.send":
            run_counter += 1
            active_run = f"openclaw-run-{run_counter}"
            result = {"runId": active_run, "status": "started"}
        send_ws(
            connection,
            {"type": "res", "id": request.get("id"), "ok": True, "payload": result},
        )

        if method == "chat.send":
            message = str(params.get("message", ""))
            openclaw_event(
                connection,
                "chat",
                {
                    "state": "delta",
                    "runId": active_run,
                    "sessionKey": active_key,
                    "seq": 0,
                    "deltaText": "OpenClaw Rust ",
                    "replace": False,
                },
                10 + run_counter,
            )
            if "request-interactions" in message:
                openclaw_event(
                    connection,
                    "exec.approval.requested",
                    {
                        "id": "openclaw-approval-1",
                        "sessionKey": active_key,
                        "presentation": {"title": "Run command"},
                    },
                    20,
                )
                openclaw_event(
                    connection,
                    "question.requested",
                    {
                        "id": "openclaw-question-1",
                        "sessionKey": active_key,
                        "createdAtMs": 1,
                        "expiresAtMs": 10,
                        "status": "pending",
                        "questions": [
                            {
                                "questionId": "branch",
                                "header": "Branch",
                                "question": "Which branch?",
                                "options": [{"label": "main"}, {"label": "dev"}],
                            },
                            {
                                "questionId": "reason",
                                "header": "Reason",
                                "question": "Why?",
                                "options": [],
                                "isOther": True,
                            },
                        ],
                    },
                    21,
                )
            elif "agent-lifecycle" in message:
                openclaw_event(
                    connection,
                    "agent",
                    {
                        "sessionKey": active_key,
                        "runId": active_run,
                        "stream": "lifecycle",
                        "data": {"phase": "end"},
                    },
                    29,
                )
            elif "hold-for-interrupt" not in message and "disconnect-after-accept" not in message:
                openclaw_event(
                    connection,
                    "chat",
                    {
                        "state": "final",
                        "runId": active_run,
                        "sessionKey": active_key,
                        "seq": 1,
                        "message": {
                            "role": "assistant",
                            "content": [{"type": "text", "text": "OpenClaw Rust reply"}],
                        },
                    },
                    30,
                )
                if "late-frame" in message:
                    openclaw_event(
                        connection,
                        "chat",
                        {
                            "state": "final",
                            "runId": active_run,
                            "sessionKey": active_key,
                            "seq": 1,
                            "message": {
                                "role": "assistant",
                                "content": [{"type": "text", "text": "duplicate"}],
                            },
                        },
                        31,
                    )
                    openclaw_event(
                        connection,
                        "chat",
                        {
                            "state": "delta",
                            "runId": active_run,
                            "sessionKey": active_key,
                            "seq": 2,
                            "deltaText": "late",
                            "replace": False,
                        },
                        32,
                    )
            elif "disconnect-after-accept" in message:
                time.sleep(0.03)
                connection.shutdown(socket.SHUT_RDWR)
                connection.close()
                return
        elif method in {"approval.resolve", "question.resolve"}:
            pending_interactions["approval" if method == "approval.resolve" else "question"] = True
            if all(pending_interactions.values()):
                openclaw_event(
                    connection,
                    "chat",
                    {
                        "state": "final",
                        "runId": active_run,
                        "sessionKey": active_key,
                        "seq": 1,
                        "message": {
                            "role": "assistant",
                            "content": [{"type": "text", "text": "OpenClaw Rust reply"}],
                        },
                    },
                    40,
                )
        elif method == "chat.abort":
            openclaw_event(
                connection,
                "chat",
                {
                    "state": "aborted",
                    "runId": params.get("runId"),
                    "sessionKey": params.get("sessionKey"),
                    "seq": 1,
                },
                50,
            )


def handle_connection(connection: socket.socket, mode: str) -> None:
    connection.settimeout(30)
    try:
        request_line, headers = read_http_request(connection)
        if mode == "hermes" and "upgrade" not in headers:
            if request_line.startswith("GET /api/sessions?") and not os.environ.get("ZOMMI_FAKE_HERMES_LEGACY_SESSION_LIST"):
                if headers.get("x-hermes-session-token") != os.environ.get("HERMES_DASHBOARD_SESSION_TOKEN"):
                    connection.sendall(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                    return
                params = parse_qs(urlsplit(request_line.split()[1]).query)
                profile = params.get("profile", ["default"])[0]
                write_log({"method": "http.sessions", "params": params, "pid": os.getpid()})
                time.sleep(float(os.environ.get("ZOMMI_FAKE_CATALOG_DELAY", "0")))
                payload = {"sessions": [{
                    "id": "hermes-coder-session" if profile == "coder" else "hermes-stored-session",
                    "title": f"Saved Hermes {profile} chat",
                    "started_at": 12,
                    "last_active": 50.5 if profile == "coder" else 40.25,
                    "message_count": 2,
                }]}
            elif request_line.startswith("GET /api/profiles/active "):
                payload = {"active": "default", "current": "default"}
            elif request_line.startswith("GET /api/profiles "):
                payload = {
                    "profiles": [
                        {"name": "default", "is_default": True, "model": "gpt-test"},
                        {"name": "coder", "is_default": False, "model": "gpt-test"},
                    ]
                }
            else:
                payload = {"ok": True, "auth_required": False, "version": "0.20.0"}
            body = json.dumps(payload).encode()
            connection.sendall(
                (
                    "HTTP/1.1 200 OK\r\n"
                    "Content-Type: application/json\r\n"
                    f"Content-Length: {len(body)}\r\n"
                    "Connection: close\r\n\r\n"
                ).encode("ascii")
                + body
            )
            return
        if "upgrade" not in headers or "websocket" not in headers.get("upgrade", "").lower():
            raise ValueError(f"expected websocket upgrade, got {request_line}")
        websocket_handshake(connection, headers)
        if mode == "hermes":
            send_ws(
                connection,
                {"jsonrpc": "2.0", "method": "event", "params": {"type": "gateway.ready", "payload": {}}},
            )
            serve_hermes(connection)
        else:
            serve_openclaw(connection)
    except (BrokenPipeError, ConnectionResetError, EOFError, OSError, ValueError, json.JSONDecodeError):
        return
    finally:
        try:
            connection.close()
        except OSError:
            pass


def main() -> int:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--mode", choices=["hermes", "openclaw"], required=True)
    parser.add_argument("--port", type=int, default=0)
    args, _unknown = parser.parse_known_args()
    if args.mode == "hermes":
        failure_marker = os.environ.get("ZOMMI_FAKE_STARTUP_FAILURE_MARKER")
        if failure_marker and not os.path.exists(failure_marker):
            with open(failure_marker, "w") as marker:
                marker.write("failed once")
            return 1
        time.sleep(float(os.environ.get("ZOMMI_FAKE_STARTUP_DELAY", "0")))
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", args.port))
    server.listen(8)
    port = server.getsockname()[1]
    if args.mode == "hermes":
        print(f"HERMES_BACKEND_READY port={port}", flush=True)
    else:
        print(f"OPENCLAW_GATEWAY_READY ws://127.0.0.1:{port}", flush=True)
    while True:
        connection, _address = server.accept()
        if args.mode == "hermes":
            # Health probe and WebSocket arrive sequentially; keep accepting.
            thread = threading.Thread(target=handle_connection, args=(connection, args.mode), daemon=True)
            thread.start()
        else:
            handle_connection(connection, args.mode)


if __name__ == "__main__":
    raise SystemExit(main())
