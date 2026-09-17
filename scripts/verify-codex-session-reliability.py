#!/usr/bin/env python3
"""Exercise real Codex session switching through the Rust host in an isolated home.

Generation uses a local Responses fixture. No existing chats or credentials are
read, and no request is sent to a model provider. This is a protocol acceptance
check, not a packaged Windows UI test.
"""

import argparse
import asyncio
import importlib.util
import json
import os
from pathlib import Path
import shutil
import tempfile
import threading
from http.server import ThreadingHTTPServer


async def verify(args):
    repository = Path(__file__).resolve().parent.parent
    spec = importlib.util.spec_from_file_location(
        "responses_fixture", repository / "tests/fake_responses_server.py"
    )
    fixture = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(fixture)
    with tempfile.TemporaryDirectory(prefix="zommi-real-codex-") as directory:
        root = Path(directory)
        server = ThreadingHTTPServer(("127.0.0.1", 0), fixture.Handler)
        server.request_log = root / "provider-request.json"
        threading.Thread(target=server.serve_forever, daemon=True).start()
        (root / "config.toml").write_text(
            'model = "gpt-5.4"\nmodel_provider = "local_fixture"\n'
            '[model_providers.local_fixture]\nname = "Local fixture"\n'
            f'base_url = "http://127.0.0.1:{server.server_port}/v1"\n'
            'wire_api = "responses"\nrequires_openai_auth = false\n'
        )
        environment = {k: v for k, v in os.environ.items() if not k.startswith("PARENT_APP_")}
        environment.update({
            "CODEX_HOME": str(root),
            "ZOMMI_CODEX_COMMAND": str(Path(args.codex).absolute()),
            "ZOMMI_CODEX_ARGS_JSON": '["app-server"]',
            "ZOMMI_CORE_STATE_PATH": str(root / "binding.json"),
            "ZOMMI_RUNTIME_OVERRIDES_PATH": str(root / "overrides.json"),
            "ZOMMI_RUNTIME_DISCOVERY_CACHE_PATH": str(root / "discovery.json"),
        })
        async def launch_core():
            return await asyncio.create_subprocess_exec(
                str(Path(args.core_host).resolve()), cwd=root, env=environment,
                stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL, limit=64 * 1024 * 1024,
            )

        process = await launch_core()
        sequence = 0
        events = []

        async def receive():
            line = await asyncio.wait_for(process.stdout.readline(), 30)
            if not line:
                raise RuntimeError("Core host exited before responding")
            value = json.loads(line)
            if "event" in value:
                events.append(value["event"])
            return value

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
                value = await receive()
                if value.get("id") == identity:
                    if not value["ok"]:
                        raise RuntimeError(f"{operation}: {value['error']}")
                    return value["result"]

        try:
            await request("core.initialize")
            discovery = await request("runtime.discover")
            target = next(t for t in discovery["targets"]
                          if t["adapterId"] == "codex-app-server"
                          and t["executionHost"]["kind"] == "native")
            payload = {"runtimeTargetId": target["id"], "cwd": str(root)}
            connection = await request("runtime.connect", payload)
            ids = [connection["sessionId"]]
            for _ in range(4):
                ids.append((await request("session.create", payload))["sessionId"])
            for index in range(args.switches):
                selected = {**payload, "sessionId": ids[index % len(ids)]}
                connection = await request("session.open", selected)
                assert connection["sessionId"] == selected["sessionId"]
                assert connection["history"]["thread"]["turns"] == []
                assert (await request("session.read", selected))["thread"]["turns"] == []
            selected = {**payload, "sessionId": ids[0]}
            await request("session.open", selected)
            await request("turn.start", {**selected, "message": "Reply READY", "clientOperationId": "local:first-turn"})
            while not any(e["name"] == "turn.completed" for e in events):
                await receive()
            completed = next(e for e in events if e["name"] == "turn.completed")
            assert completed["payload"]["status"] == "completed", completed
            await request("session.open", {**payload, "sessionId": ids[1]})
            connection = await request("session.open", selected)
            turns = connection["history"]["thread"]["turns"]
            assert len(turns) == 1, turns
            assert "READY" in json.dumps(turns)
            assert not any(e["name"] == "runtime.recovered" for e in events)
            assert server.request_log.exists()
            result = {"emptyChats": len(ids), "switches": args.switches,
                      "firstTurnPreserved": True, "unexpectedRestarts": 0,
                      "runtimeVersion": connection.get("runtimeVersion")}
            if args.verify_rewind:
                async def send_turn(message):
                    receipt = await request("turn.start", {
                        **selected, "message": message, "clientOperationId": message,
                    })
                    while not any(e["name"] == "turn.completed" and e.get("turnId") == receipt["turnId"] for e in events):
                        await receive()
                    completed = next(e for e in events if e["name"] == "turn.completed" and e.get("turnId") == receipt["turnId"])
                    assert completed["payload"]["status"] == "completed", completed

                await send_turn("REWIND_DROP_ORIGINAL")
                await send_turn("REWIND_DROP_LATER")
                before = (await request("session.read", selected))["thread"]["turns"]
                assert len(before) == 3
                prefix = await request("session.rewind", {
                    **selected, "turnId": before[1]["id"],
                    "expectedLastTurnId": before[-1]["id"],
                })
                assert [t["id"] for t in prefix["thread"]["turns"]] == [before[0]["id"]]
                await send_turn("REWIND_REPLACEMENT")
                model_input = json.dumps(json.loads(server.request_log.read_text())["input"])
                assert "Reply READY" in model_input and "REWIND_REPLACEMENT" in model_input
                assert "REWIND_DROP_ORIGINAL" not in model_input and "REWIND_DROP_LATER" not in model_input
                await request("session.open", {**payload, "sessionId": ids[1]})
                reopened = await request("session.open", selected)
                after = reopened["history"]["thread"]["turns"]
                assert len(after) == 2 and "REWIND_DROP" not in json.dumps(after)
                empty = await request("session.rewind", {
                    **selected, "turnId": after[0]["id"], "expectedLastTurnId": after[-1]["id"],
                })
                assert empty["thread"]["turns"] == []
                await send_turn("REWIND_FIRST_REPLACEMENT")
                model_input = json.dumps(json.loads(server.request_log.read_text())["input"])
                assert "REWIND_FIRST_REPLACEMENT" in model_input
                assert "Reply READY" not in model_input and "REWIND_DROP" not in model_input
                assert "REWIND_REPLACEMENT" not in model_input
                await request("core.shutdown")
                await asyncio.wait_for(process.wait(), 10)
                process = await launch_core()
                await request("core.initialize")
                await request("runtime.discover")
                await request("runtime.connect", payload)
                restored = await request("session.open", selected)
                durable = restored["history"]["thread"]["turns"]
                assert len(durable) == 1 and "REWIND_FIRST_REPLACEMENT" in json.dumps(durable)
                assert "Reply READY" not in json.dumps(durable) and "REWIND_DROP" not in json.dumps(durable)
                result["rewind"] = {"middleTurnRemovedSuffix": True, "firstTurnRemovedAllHistory": True,
                                    "providerInputExcludedRemovedMessages": True, "reopenedHistoryStayedRewound": True,
                                    "runtimeRestartPreservedRewind": True}
            print(json.dumps(result, indent=2))
            await request("core.shutdown")
            await asyncio.wait_for(process.wait(), 10)
        finally:
            if process.returncode is None:
                process.kill()
                await process.wait()
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--core-host", default="target/debug/zommi-core-host")
    parser.add_argument("--codex", default=shutil.which("codex"))
    parser.add_argument("--switches", type=int, default=40)
    parser.add_argument("--verify-rewind", action="store_true")
    args = parser.parse_args()
    if not args.codex or args.switches < 1:
        parser.error("an installed Codex executable and positive switch count are required")
    asyncio.run(verify(args))
