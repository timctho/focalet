#!/usr/bin/env python3
"""Deterministic JSONL fixture for Flutter -> Rust -> Codex integration tests."""

import json
import os
import sys
import time
import pathlib
import threading


thread_id = os.environ.get("ZOMMI_FAKE_THREAD_ID", "thread-rust-flutter")
fresh_thread_id = os.environ.get("ZOMMI_FAKE_FRESH_THREAD_ID", thread_id)
turn_id = os.environ.get("ZOMMI_FAKE_TURN_ID", "turn-rust-flutter")
request_log = os.environ.get("ZOMMI_FAKE_REQUEST_LOG")
control = pathlib.Path(sys.argv[sys.argv.index("--control-dir") + 1]) if "--control-dir" in sys.argv else None
if control:
    request_log = str(control / "requests.jsonl")
    turn_id += "-" + str(os.getpid())
rekey_completion = os.environ.get("ZOMMI_FAKE_REKEY_COMPLETION") == "1"
fragments = ["Book", "keeper", " sees ", "1", "1", "1", ". 世界", "世界", "."] if rekey_completion else ["Rust-owned Codex reply"]
completed_text = "".join(fragments)
goals = {}
created_thread_count = 0


def send(message):
    sys.stdout.write(json.dumps(message, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def log(message):
    if not request_log:
        return
    with open(request_log, "a", encoding="utf-8") as stream:
        stream.write(json.dumps(message, separators=(",", ":")) + "\n")


log({"fixtureOriginator": os.environ.get("CODEX_INTERNAL_ORIGINATOR_OVERRIDE")})
if control:
    log({"fixturePid": os.getpid(), "startedAt": time.monotonic()})

    def crash_when_requested():
        while True:
            try:
                should_exit = (control / "exit-pid").read_text() == str(os.getpid())
            except OSError:
                should_exit = False
            if should_exit:
                sys.stderr.write("fixture requested crash token=fixture-private\n")
                sys.stderr.flush()
                os._exit(26)
            time.sleep(0.01)

    threading.Thread(target=crash_when_requested, daemon=True).start()


for line in sys.stdin:
    try:
        request = json.loads(line)
    except json.JSONDecodeError:
        continue
    log(request)
    request_id = request.get("id")
    method = request.get("method")
    if request_id is None:
        continue

    if method == "initialize":
        if control and (control / "stall-initialize").exists():
            continue
        result = {"userAgent": "codex-cli/9.8.7 (fixture)"}
    elif method == "thread/loaded/list":
        if control and (control / "stall-probe-pid").exists() and (control / "stall-probe-pid").read_text() == str(os.getpid()):
            continue
        result = {"data": [thread_id]}
    elif method in ("model/list", "mcpServerStatus/list"):
        result = {"data": []}
    elif method == "thread/list":
        result = {
            "data": [
                {
                    "id": thread_id,
                    "threadSource": "zommi",
                    "name": "Zommi · Fixture",
                    "updatedAt": 10,
                }
            ]
        }
    elif method == "thread/start":
        created_thread_count += 1
        new_id = fresh_thread_id
        if os.environ.get("ZOMMI_FAKE_UNIQUE_THREADS") == "1" and created_thread_count > 1:
            new_id += "-" + str(created_thread_count)
        result = {"thread": {"id": new_id, "turns": []}}
    elif method == "thread/resume":
        if os.environ.get("ZOMMI_FAKE_BUSY_RESUME") == "1" or (control and (control / "reject-resume").exists()):
            send(
                {
                    "id": request_id,
                    "error": {
                        "code": -32600,
                        "message": "thread already has an active writer",
                    },
                }
            )
            continue
        result = {"thread": {"id": request["params"]["threadId"], "turns": []}}
    elif method == "thread/read":
        result = {"thread": {"id": request["params"]["threadId"], "turns": []}}
    elif method == "thread/name/set":
        result = {}
    elif method == "thread/settings/update":
        result = {}
    elif method.startswith("thread/goal/"):
        if os.environ.get("ZOMMI_FAKE_GOAL_UNSUPPORTED") == "1":
            send({"id": request_id, "error": {"code": -32601, "message": "Goals are unavailable"}})
            continue
        params = request["params"]
        goal_thread = params["threadId"]
        if method == "thread/goal/clear":
            goals.pop(goal_thread, None)
        elif method == "thread/goal/set":
            if "objective" in params:
                goals[goal_thread] = {"threadId": goal_thread, "objective": params["objective"], "status": "active", "tokensUsed": 0, "timeUsedSeconds": 0}
            if goal_thread not in goals:
                send({"id": request_id, "error": {"code": -32600, "message": "No goal set"}})
                continue
            goals[goal_thread]["status"] = params.get("status", "active")
        result = {"goal": goals.get(goal_thread)}
        send({"id": request_id, "result": result})
        if method != "thread/goal/get":
            send({"method": "thread/goal/cleared" if method.endswith("clear") else "thread/goal/updated", "params": {"threadId": goal_thread, **result}})
        if method == "thread/goal/set" and params.get("status") == "active" and os.environ.get("ZOMMI_FAKE_GOAL_TURNS") == "1":
            send({"method": "turn/started", "params": {"threadId": goal_thread, "turn": {"id": turn_id, "status": "inProgress"}}})
            send({"method": "item/completed", "params": {"threadId": goal_thread, "turnId": turn_id, "item": {"id": "goal-answer", "type": "agentMessage", "phase": "final", "text": "Working on the goal"}}})
        continue
    elif method == "turn/start":
        result = {"turn": {"id": turn_id}}
        send({"id": request_id, "result": result})
        send(
            {
                "method": "turn/started",
                "params": {
                    "threadId": request["params"]["threadId"],
                    "turn": {"id": turn_id, "status": "inProgress"},
                },
            }
        )
        if "exit-runtime" in json.dumps(request["params"]):
            sys.stderr.write(
                "token=fixture-private <zommi_invocation_context>captured private context</zommi_invocation_context>\n"
            )
            sys.stderr.flush()
            time.sleep(0.05)
            sys.exit(26)
        send(
            {
                "method": "item/started",
                "params": {
                    "threadId": request["params"]["threadId"],
                    "turnId": turn_id,
                    "item": {"id": "agent-fixture", "type": "agentMessage", "phase": "final"},
                },
            }
        )
        for fragment in fragments:
            send(
                {
                    "method": "item/agentMessage/delta",
                    "params": {
                        "threadId": request["params"]["threadId"],
                        "turnId": turn_id,
                        "itemId": "agent-fixture",
                        "delta": fragment,
                    },
                }
            )
        send(
            {
                "method": "item/completed",
                "params": {
                    "threadId": request["params"]["threadId"],
                    "turnId": turn_id,
                    "item": {
                        "id": "canonical-agent-fixture" if rekey_completion else "agent-fixture",
                        "type": "agentMessage",
                        "phase": "final",
                        "status": "completed",
                        "text": completed_text,
                    },
                },
            }
        )
        if "hold-for-interrupt" not in json.dumps(request["params"]):
            send(
                {
                    "method": "turn/completed",
                    "params": {
                        "threadId": request["params"]["threadId"],
                        "turn": {"id": turn_id, "status": "completed"},
                    },
                }
            )
        continue
    elif method == "turn/interrupt":
        result = {}
        send({"id": request_id, "result": result})
        send(
            {
                "method": "turn/completed",
                "params": {
                    "threadId": request["params"]["threadId"],
                    "turn": {"id": request["params"]["turnId"], "status": "interrupted"},
                },
            }
        )
        continue
    else:
        send(
            {
                "id": request_id,
                "error": {"code": -32601, "message": "unsupported fixture request " + str(method)},
            }
        )
        continue

    send({"id": request_id, "result": result})
