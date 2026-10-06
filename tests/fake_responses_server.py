#!/usr/bin/env python3
"""Minimal local Responses-compatible server for Codex hook acceptance tests."""

from __future__ import annotations

import argparse
import json
import re
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


PROBE_URL = "https://windows-runtime-probe.example/focalet"


def find_focalet_url(value: object) -> str | None:
    if isinstance(value, str) and "FOCALET LIVE CONTEXT" in value:
        match = re.search(r"(?:^|\r?\n)URL: ([^\r\n]+)", value)
        return match.group(1).strip() if match else None
    if isinstance(value, dict):
        for child in value.values():
            found = find_focalet_url(child)
            if found:
                return found
    if isinstance(value, list):
        for child in value:
            found = find_focalet_url(child)
            if found:
                return found
    return None


def response_object(response_id: str, status: str, output: list[dict], usage: dict | None) -> dict:
    return {
        "id": response_id,
        "object": "response",
        "created_at": int(time.time()),
        "status": status,
        "background": False,
        "error": None,
        "incomplete_details": None,
        "instructions": None,
        "max_output_tokens": None,
        "max_tool_calls": None,
        "model": "focalet-acceptance-model",
        "output": output,
        "parallel_tool_calls": True,
        "previous_response_id": None,
        "prompt_cache_key": None,
        "reasoning": {"effort": None, "summary": None},
        "safety_identifier": None,
        "service_tier": "default",
        "store": False,
        "temperature": 1.0,
        "text": {"format": {"type": "text"}, "verbosity": "medium"},
        "tool_choice": "auto",
        "tools": [],
        "top_logprobs": 0,
        "top_p": 1.0,
        "truncation": "disabled",
        "usage": usage,
        "user": None,
        "metadata": {},
    }


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        length = int(self.headers.get("content-length", "0"))
        raw_body = self.rfile.read(length)
        request = json.loads(raw_body)
        self.server.request_log.write_text(  # type: ignore[attr-defined]
            json.dumps(request, indent=2, sort_keys=True), encoding="utf-8"
        )

        text = find_focalet_url(request) or "READY"
        response_id = "resp_focalet_acceptance"
        message_id = "msg_focalet_acceptance"
        message = {
            "id": message_id,
            "type": "message",
            "status": "completed",
            "role": "assistant",
            "content": [
                {
                    "type": "output_text",
                    "text": text,
                    "annotations": [],
                    "logprobs": [],
                }
            ],
        }
        usage = {
            "input_tokens": 1,
            "input_tokens_details": {"cached_tokens": 0},
            "output_tokens": 1,
            "output_tokens_details": {"reasoning_tokens": 0},
            "total_tokens": 2,
        }
        events = [
            {
                "type": "response.created",
                "sequence_number": 0,
                "response": response_object(response_id, "in_progress", [], None),
            },
            {
                "type": "response.output_item.added",
                "sequence_number": 1,
                "output_index": 0,
                "item": {
                    "id": message_id,
                    "type": "message",
                    "status": "in_progress",
                    "role": "assistant",
                    "content": [],
                },
            },
            {
                "type": "response.content_part.added",
                "sequence_number": 2,
                "item_id": message_id,
                "output_index": 0,
                "content_index": 0,
                "part": {"type": "output_text", "text": "", "annotations": [], "logprobs": []},
            },
            {
                "type": "response.output_text.delta",
                "sequence_number": 3,
                "item_id": message_id,
                "output_index": 0,
                "content_index": 0,
                "delta": text,
                "logprobs": [],
            },
            {
                "type": "response.output_text.done",
                "sequence_number": 4,
                "item_id": message_id,
                "output_index": 0,
                "content_index": 0,
                "text": text,
                "logprobs": [],
            },
            {
                "type": "response.content_part.done",
                "sequence_number": 5,
                "item_id": message_id,
                "output_index": 0,
                "content_index": 0,
                "part": message["content"][0],
            },
            {
                "type": "response.output_item.done",
                "sequence_number": 6,
                "output_index": 0,
                "item": message,
            },
            {
                "type": "response.completed",
                "sequence_number": 7,
                "response": response_object(response_id, "completed", [message], usage),
            },
        ]
        payload = "".join(
            f"event: {event['type']}\ndata: {json.dumps(event, separators=(',', ':'))}\n\n"
            for event in events
        ).encode()

        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("content-length", str(len(payload)))
        self.send_header("connection", "close")
        self.end_headers()
        self.wfile.write(payload)
        self.wfile.flush()

    def log_message(self, _format: str, *_args: object) -> None:
        return


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--request-log", type=Path, required=True)
    args = parser.parse_args()

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.request_log = args.request_log  # type: ignore[attr-defined]
    print(f"READY {args.port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
