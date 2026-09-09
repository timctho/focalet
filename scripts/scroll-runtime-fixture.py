#!/usr/bin/env python3
"""Deterministic agent boundary for packaged Flutter -> Rust scroll benchmarks."""

import json
import os
import sys
import threading
import time

THREAD = "scroll-benchmark"
COUNT = int(os.environ.get("ZOMMI_SCROLL_TURNS", "120"))
WORKLOAD = os.environ.get("ZOMMI_SCROLL_WORKLOAD", "standard")
lock = threading.Lock()
cancel = threading.Event()
signal_path = os.environ.get("ZOMMI_SCROLL_STREAM_SIGNAL")
watching = False


def send(value):
    with lock:
        # Windows redirected stdout may use a legacy code page. JSON escapes
        # preserve the Unicode workload without depending on console encoding.
        print(json.dumps(value, ensure_ascii=True, separators=(",", ":")), flush=True)


def answer(number, sections=8):
    paragraphs = [f"## Result {number}\n"]
    for section in range(sections):
        paragraphs.append(
            f"### Observation {number}.{section}\n\n"
            "Scrolling should keep the reading position stable while new messages arrive. "
            "這段文字用來量測中英文混排、文字選取與完整訊息渲染。 "
            "The worker reports the selected source, coordinates and document revision. "
            "**Preserve complete content**, [source links](https://example.com/reference), "
            "and `code identifiers` when rendering the conversation.\n\n"
            "- Read the selected content.\n- Validate the current document.\n- Return the result.\n\n"
        )
    paragraphs.append("| Case | Result | Count |\n| --- | --- | --- |\n| Text | Passed | 24 |\n| Images | Passed | 12 |\n\n")
    paragraphs.append("```python\ndef capture(source):\n    bounds = source.bounds\n    return {'text': source.text, 'bounds': bounds}\n```\n")
    return "".join(paragraphs)


history = []
for number in range(1, COUNT + 1):
    history.append({"id": f"history-{number}", "status": "completed", "items": [
        {"id": f"user-{number}", "type": "userMessage", "content": [{"type": "inputText", "text": f"Review item {number} and explain the result. 請保留原始內容。"}]},
        {"id": f"reason-{number}", "type": "reasoning", "summary": ["Inspecting the source and validating the selection."], "status": "completed"},
        {"id": f"tool-{number}", "type": "commandExecution", "command": "python verify.py", "aggregatedOutput": "24 checks passed", "status": "completed", "exitCode": 0},
        {"id": f"answer-{number}", "type": "agentMessage", "phase": "final", "text": answer(number, 32 if number == COUNT else 8)},
    ]})
    if WORKLOAD == "folded":
        activities = []
        for step in range(100):
            activities.extend([
                {"id": f"reason-{number}-{step}", "type": "reasoning", "status": "completed",
                 "summary": [f"Inspection {step}. " + "Hidden reasoning with **formatting**. " * 60]},
                {"id": f"tool-{number}-{step}", "type": "commandExecution", "status": "completed",
                 "command": f"python verify.py --step {step}", "exitCode": 0,
                 "aggregatedOutput": f"Result {step}. " + "Hidden tool output. " * 100},
            ])
        history[-1]["items"][1:3] = activities

history_path = os.environ.get("ZOMMI_SCROLL_HISTORY")
if history_path:
    with open(history_path, encoding="utf-8-sig") as source:
        history = json.load(source)["thread"]["turns"]
    COUNT = len(history)


def stream():
    if WORKLOAD == "folded":
        stream_folded()
        return
    turn = "streaming-turn"
    base = {"threadId": THREAD, "turnId": turn}
    send({"method": "turn/started", "params": {"threadId": THREAD, "turn": {"id": turn, "status": "inProgress"}}})
    send({"method": "item/started", "params": {**base, "item": {"id": "stream-answer", "type": "agentMessage", "phase": "final"}}})
    text = answer(COUNT + 1, 64)
    sent = ""
    for offset in range(0, len(text), 40):
        if cancel.wait(0.05):
            break
        fragment = text[offset:offset + 40]
        sent += fragment
        send({"method": "item/agentMessage/delta", "params": {**base, "itemId": "stream-answer", "delta": fragment}})
    send({"method": "item/completed", "params": {**base, "item": {"id": "stream-answer", "type": "agentMessage", "phase": "final", "text": sent, "status": "completed"}}})
    send({"method": "turn/completed", "params": {"threadId": THREAD, "turn": {"id": turn, "status": "completed"}}})


def stream_folded():
    # Update folded reasoning in the same turn as the long visible answer.
    turn = history[-1]["id"]
    base = {"threadId": THREAD, "turnId": turn}
    send({"method": "turn/started", "params": {"threadId": THREAD, "turn": {"id": turn, "status": "inProgress"}}})
    send({"method": "item/started", "params": {**base, "item": {"id": "live-reasoning", "type": "reasoning"}}})
    sent = ""
    for index in range(2400):
        if cancel.wait(0.05):
            break
        fragment = f"Inspecting step {index}. Hidden reasoning. "
        sent += fragment
        send({"method": "item/reasoning/summaryTextDelta", "params": {**base, "itemId": "live-reasoning", "delta": fragment, "summaryIndex": 0}})
    send({"method": "item/completed", "params": {**base, "item": {"id": "live-reasoning", "type": "reasoning", "summary": [sent], "status": "completed"}}})
    send({"method": "turn/completed", "params": {"threadId": THREAD, "turn": {"id": turn, "status": "completed"}}})


def wait_for_stream():
    while not os.path.exists(signal_path):
        time.sleep(0.05)
    stream()


for line in sys.stdin:
    request = json.loads(line)
    if "id" not in request:
        continue
    method = request["method"]
    if method == "initialize":
        result = {"userAgent": "codex-cli/scroll-benchmark"}
    elif method == "thread/list":
        result = {"data": [{"id": THREAD, "threadSource": "zommi", "name": "Scroll benchmark", "updatedAt": 1}]}
    elif method in ("thread/start", "thread/resume", "thread/read"):
        result = {"thread": {"id": THREAD, "turns": history, "cwd": os.getcwd()}}
    elif method in ("model/list", "mcpServerStatus/list"):
        result = {"data": []}
    elif method == "turn/start":
        send({"id": request["id"], "result": {"turn": {"id": "streaming-turn"}}})
        cancel.clear()
        threading.Thread(target=stream, daemon=True).start()
        continue
    elif method == "turn/interrupt":
        cancel.set()
        result = {}
    elif method == "thread/name/set":
        result = {}
    else:
        send({"id": request["id"], "error": {"code": -32601, "message": method}})
        continue
    send({"id": request["id"], "result": result})
    if method == "thread/read" and signal_path and not watching:
        watching = True
        threading.Thread(target=wait_for_stream, daemon=True).start()
