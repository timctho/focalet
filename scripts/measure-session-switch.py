#!/usr/bin/env python3
"""Measure synthetic session-open + history latency through the real Rust host.

Uses an isolated fake Codex process; does not read or resume real conversations.
Run against old and new host binaries with the same arguments for comparison.
This measures protocol work, not Flutter frame time or Windows/WSL latency.
"""

import argparse
import asyncio
import json
import os
import pathlib
import statistics
import sys
import tempfile
import time


async def measure(args):
    repository = pathlib.Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory(prefix="zommi-switch-benchmark-") as directory:
        temporary = pathlib.Path(directory)
        request_log = temporary / "requests.jsonl"
        process = await asyncio.create_subprocess_exec(
            str(pathlib.Path(args.core_host).resolve()),
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
            limit=64 * 1024 * 1024,
            env={
                **os.environ,
                "ZOMMI_CODEX_COMMAND": sys.executable,
                "ZOMMI_CODEX_ARGS_JSON": json.dumps([
                    str(repository / "crates/zommi-core-host/tests/fake_codex_app_server.py")
                ]),
                "ZOMMI_CORE_STATE_PATH": str(temporary / "binding.json"),
                "ZOMMI_RUNTIME_OVERRIDES_PATH": str(temporary / "overrides.json"),
                "ZOMMI_RUNTIME_DISCOVERY_CACHE_PATH": str(temporary / "discovery.json"),
                "ZOMMI_FAKE_REQUEST_LOG": str(request_log),
                "ZOMMI_FAKE_HISTORY_COUNT": str(args.turns),
                "ZOMMI_FAKE_REQUEST_DELAY_MS": str(args.delay_ms),
            },
        )
        sequence = 0

        async def request(operation, payload=None):
            nonlocal sequence
            sequence += 1
            identity = str(sequence)
            process.stdin.write((json.dumps({
                "id": identity, "protocolVersion": 1,
                "operation": operation, "payload": payload or {},
            }) + "\n").encode())
            await process.stdin.drain()
            while True:
                line = await asyncio.wait_for(process.stdout.readline(), 30)
                if not line:
                    raise RuntimeError("Core host exited before responding")
                response = json.loads(line)
                if response.get("id") != identity:
                    continue
                if not response["ok"]:
                    raise RuntimeError(response["error"])
                return response["result"], len(line)

        try:
            await request("core.initialize")
            discovery, _ = await request("runtime.discover")
            target = next(target for target in discovery["targets"]
                          if target["adapterId"] == "codex-app-server"
                          and target["executionHost"]["kind"] == "native"
                          and target["executablePath"] == sys.executable)
            await request("runtime.connect", {"runtimeTargetId": target["id"]})
            before_requests = len(request_log.read_text().splitlines())
            samples = []
            for index in range(args.switches):
                session = f"benchmark-chat-{index % args.chats}"
                payload = {"runtimeTargetId": target["id"], "sessionId": session}
                started = time.perf_counter()
                connection, size = await request("session.open", payload)
                history = connection.get("history")
                if history is None:
                    history, history_size = await request("session.read", payload)
                    size += history_size
                assert history["thread"]["id"] == session
                assert len(history["thread"]["turns"]) == args.turns
                samples.append({
                    "milliseconds": round((time.perf_counter() - started) * 1000, 2),
                    "response_bytes": size,
                    "catalog_bytes": len(json.dumps(connection["sessions"]).encode()),
                })
            requests = [json.loads(line).get("method") for line in
                        request_log.read_text().splitlines()[before_requests:]]
            print(json.dumps({
                "fixture": {"chats": args.chats, "turns_per_chat": args.turns,
                            "request_delay_ms": args.delay_ms, "switches": args.switches},
                "median_ms": statistics.median(sample["milliseconds"] for sample in samples),
                "median_response_bytes": statistics.median(sample["response_bytes"] for sample in samples),
                "last_catalog_bytes": samples[-1]["catalog_bytes"],
                "backend_requests": {method: requests.count(method) for method in
                                     ("thread/resume", "thread/read", "thread/list")},
                "samples": samples,
            }, indent=2))
            await request("core.shutdown")
            await asyncio.wait_for(process.wait(), 10)
        finally:
            if process.returncode is None:
                process.kill()
                await process.wait()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--core-host", default="target/debug/zommi-core-host")
    parser.add_argument("--chats", type=int, default=6)
    parser.add_argument("--turns", type=int, default=60)
    parser.add_argument("--switches", type=int, default=12)
    parser.add_argument("--delay-ms", type=float, default=20)
    args = parser.parse_args()
    if min(args.chats, args.turns, args.switches) < 1 or args.delay_ms < 0:
        parser.error("chats, turns and switches must be positive; delay must be nonnegative")
    asyncio.run(measure(args))
