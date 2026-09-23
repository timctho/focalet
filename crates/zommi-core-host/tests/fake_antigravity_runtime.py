#!/usr/bin/env python3
"""Documented Antigravity stream contract, with durable fixture conversations."""
import json
import os
from pathlib import Path
import sys
import time
import uuid


def emit(value):
    print(json.dumps(value), flush=True)


def flag(name):
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else None


root = Path(os.environ["ZOMMI_FAKE_AGY_STATE"])
root.mkdir(exist_ok=True)
with (root / "launches.jsonl").open("a") as output:
    output.write(json.dumps({"args": sys.argv[1:], "cwd": os.getcwd()}) + "\n")
if (root / "signed-out").exists():
    print("Error: authentication required. Run agy to sign in.", file=sys.stderr)
    sys.exit(1)
if "models" in sys.argv:
    print("gemini-test-fast\tGemini Test Fast")
    print("gemini-test-deep    Gemini Test Deep")
    if (root / "more-models").exists():
        print("claude-test    Claude Test")
    sys.exit(0)

identity = flag("--conversation") or str(uuid.uuid4())
saved = root / (identity + ".json")
if flag("--conversation") and not saved.exists():
    emit({"event": "result", "result": {"status": "ERROR", "error": "Conversation not found"}})
    sys.exit(1)
if flag("--model") == "gemini-test-deep" and (root / "reject-model").exists():
    emit({"event": "result", "result": {"status": "ERROR", "error": "Model temporarily unavailable"}})
    sys.exit(1)
messages = json.loads(saved.read_text()) if saved.exists() else []
saved.write_text(json.dumps(messages))
emit({"event": "init", "conversation_id": identity, "init": {"cwd": os.getcwd(), "permission_mode": "request-review"}})
for line in sys.stdin:
    value = json.loads(line)
    text = value["message"]["content"]
    messages.append(text)
    saved.write_text(json.dumps(messages))
    if text.startswith("crash"):
        print("transport closed", file=sys.stderr)
        sys.exit(1)
    if text.startswith("invalid-json"):
        print("malformed", flush=True)
        time.sleep(10)
    if text.startswith("wait"):
        time.sleep(60)
    response = ("remembered: " + messages[0]) if text.startswith("recall") else "Hello Antigravity"
    for delta in [response[:6], response[6:]]:
        emit({"event": "step_update", "step_update": {"conversation_id": identity, "step_index": len(messages), "step_type": "agent_response", "state": "ACTIVE", "text_delta": delta}})
    emit({"event": "result", "result": {"conversation_id": identity, "status": "SUCCESS", "response": response, "num_turns": len(messages)}})
