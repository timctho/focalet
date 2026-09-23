#!/usr/bin/env python3
"""Exercise discovery and command dispatch through the real Rust core process."""
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parent.parent
HOST = ROOT / "target/debug" / ("zommi-core-host.exe" if os.name == "nt" else "zommi-core-host")
FIXTURES = ROOT / "crates/zommi-core-host/tests"


class Core:
    def __init__(self, environment):
        self.process = subprocess.Popen([str(HOST)], cwd=ROOT, env=environment,
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, text=True, encoding="utf-8")
        self.messages = queue.Queue()
        self.events = []
        self.sequence = 0

        def read():
            for line in self.process.stdout:
                self.messages.put(json.loads(line))
            self.messages.put(None)
        self.reader = threading.Thread(target=read, daemon=True)
        self.reader.start()

    def receive(self):
        message = self.messages.get(timeout=20)
        if message is None:
            raise AssertionError("Core exited without a response")
        if "event" in message:
            self.events.append(message["event"])
        return message

    def request(self, operation, payload=None, *, ok=True):
        self.sequence += 1
        identity = str(self.sequence)
        self.process.stdin.write(json.dumps({"id": identity, "protocolVersion": 1,
                                            "operation": operation, "payload": payload or {}}) + "\n")
        self.process.stdin.flush()
        while True:
            message = self.receive()
            if message.get("id") == identity:
                if ok and not message["ok"]:
                    raise AssertionError(message)
                return message.get("result") if ok else message

    def completed(self, operation_id):
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            for event in self.events:
                if event["name"] == "turn.completed" and event.get("clientOperationId") == operation_id:
                    return event
            self.receive()
        raise AssertionError("Command never completed")

    def close(self):
        try:
            if self.process.poll() is None:
                self.request("core.shutdown")
                self.process.wait(timeout=10)
        finally:
            if self.process.poll() is None:
                self.process.kill()
                self.process.wait(timeout=10)
            self.process.stdin.close()
            self.reader.join(timeout=5)
            self.process.stdout.close()


class RuntimeCommandsTests(unittest.TestCase):
    def test_added_runtime_is_selected_without_replacing_the_saved_chat(self):
        with tempfile.TemporaryDirectory(prefix="zommi-runtime-add-") as directory:
            path = Path(directory)
            env = {key: value for key, value in os.environ.items() if not key.startswith("ZOMMI_")}
            env.update(
                ZOMMI_RUNTIME_DISCOVERY_MODE="configured-only",
                ZOMMI_CORE_STATE_PATH=str(path / "binding.json"),
                ZOMMI_RUNTIME_OVERRIDES_PATH=str(path / "overrides.json"),
                ZOMMI_RUNTIME_DISCOVERY_CACHE_PATH=str(path / "targets.json"),
            )
            core = Core(env)
            try:
                core.request("core.initialize")
                platform = "windows" if os.name == "nt" else "macos" if sys.platform == "darwin" else "linux"
                host = {
                    "id": "native:" + platform,
                    "kind": "native",
                    "platform": platform,
                    "displayName": "Local", "isDefault": True,
                }
                override = {"id": "", "adapterId": "codex-app-server",
                            "executablePath": sys.executable, "executionHost": host}
                first = core.request("runtime.addOverride", {"override": override})
                first_id = first["selectedTargetId"]
                saved = {"runtimeTargetId": first_id, "sessionId": "saved-chat", "cwd": directory}
                (path / "binding.json").write_text(json.dumps(saved))
                second = core.request("runtime.addOverride", {
                    "override": dict(override, adapterId="opencode-acp")})
                added = next(target for target in second["targets"]
                             if target["id"] == second["selectedTargetId"])
                self.assertEqual(added["adapterId"], "opencode-acp")
                self.assertNotEqual(added["id"], first_id)
                self.assertEqual(len(second["settings"]["overrides"]), 2)
                self.assertEqual(json.loads((path / "binding.json").read_text()), saved)
                self.assertEqual(core.request("runtime.discover")["selectedTargetId"], first_id)
            finally:
                core.close()

    def exercise(self, adapter, fixture, command, wire_method):
        with tempfile.TemporaryDirectory(prefix="zommi-runtime-commands-") as directory:
            path = Path(directory)
            log = path / "requests.jsonl"
            env = dict(os.environ,
                       ZOMMI_CORE_STATE_PATH=str(path / "binding.json"),
                       ZOMMI_RUNTIME_OVERRIDES_PATH=str(path / "overrides.json"),
                       ZOMMI_RUNTIME_DISCOVERY_CACHE_PATH=str(path / "targets.json"),
                       ZOMMI_OPENCLAW_DEVICE_IDENTITY_PATH=str(path / "device.json"),
                       ZOMMI_FAKE_REQUEST_LOG=str(log))
            gateway = None
            if adapter == "openclaw-gateway":
                gateway = subprocess.Popen([sys.executable, str(FIXTURES / fixture), "--mode", "openclaw"],
                                           env=env, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
                endpoint = gateway.stdout.readline().strip().split(" ", 1)[1]
                env.update(ZOMMI_OPENCLAW_GATEWAY_URL=endpoint, ZOMMI_OPENCLAW_GATEWAY_AGENT_ID="main",
                           OPENCLAW_GATEWAY_TOKEN="fixture-runtime-owned-token")
            else:
                runtime = {"codex-app-server":"CODEX", "pi-rpc":"PI", "opencode-acp":"OPENCODE", "gemini-acp":"GEMINI"}.get(adapter, "HERMES")
                if adapter == "gemini-acp":
                    env["ZOMMI_FAKE_ACP_GEMINI"] = "1"
                args = [str(FIXTURES / fixture)]
                suffix = "ARGS_JSON"
                if adapter == "hermes-gateway":
                    args += ["--mode", "hermes"]
                    suffix = "GATEWAY_ARGS_JSON"
                env[f"ZOMMI_{runtime}_COMMAND"] = sys.executable
                env[f"ZOMMI_{runtime}_{suffix}"] = json.dumps(args)
            core = Core(env)
            try:
                core.request("core.initialize")
                targets = core.request("runtime.discover")["targets"]
                target = next(t for t in targets if t["adapterId"] == adapter and (adapter == "openclaw-gateway" or t["executionHost"]["kind"] == "native"))
                connection = core.request("runtime.connect", {"runtimeTargetId":target["id"], "cwd":directory})
                identity = {"runtimeTargetId":target["id"], "sessionId":connection["sessionId"]}
                if adapter.endswith("-acp"):
                    # ACP MAY publish after session/new responds.
                    while not any(e["name"] == "commands.updated" for e in core.events):
                        core.receive()
                catalog = core.request("session.commands", identity)["commands"]
                self.assertIn(command.split()[0][1:], [c["name"] for c in catalog])
                before = log.read_text().splitlines()
                core.request("session.commands", identity)
                self.assertEqual(before, log.read_text().splitlines(), "cached reads should not query the runtime again")
                rejected = core.request("command.execute", dict(identity, message="/unadvertised", clientOperationId="test:rejected"), ok=False)
                self.assertFalse(rejected["ok"])
                operation_id = "test:command"
                payload = dict(identity, message=command, clientOperationId=operation_id)
                receipt = core.request("command.execute", payload)
                self.assertTrue(receipt["accepted"])
                self.assertEqual(core.completed(operation_id)["payload"]["status"], "completed")
                # Retrying an accepted operation returns the same receipt without
                # running control actions or model prompts a second time.
                self.assertEqual(core.request("command.execute", payload), receipt)
                conflict = core.request("turn.start", payload, ok=False)
                self.assertEqual(conflict["error"]["code"], "conflict")
                requests = [json.loads(line) for line in log.read_text().splitlines()]
                calls = [q for q in requests if q.get("method", q.get("type")) == wire_method]
                self.assertEqual(len(calls), 1)
                if adapter == "codex-app-server":
                    inputs = calls[0]["params"]["input"]
                    self.assertIn({"type":"skill", "name":"inspect", "path":"/skills/inspect/SKILL.md"}, inputs)
                    self.assertNotIn("/skill:inspect", inputs[0]["text"])
                elif adapter.endswith("-acp"):
                    self.assertEqual(calls[0]["params"]["prompt"][0]["text"], command)
                elif adapter == "pi-rpc":
                    self.assertEqual(calls[0]["message"], command)
                elif adapter == "openclaw-gateway":
                    self.assertEqual(calls[0]["params"]["message"], command)
                else:
                    prompts = [q for q in requests if q.get("method") == "prompt.submit"]
                    if command.startswith("/skill-test"):
                        self.assertEqual(prompts[0]["params"]["text"], "Expanded Hermes skill")
                    else:
                        self.assertFalse(prompts)
                    if command.startswith("/quick"):
                        self.assertEqual(calls[0]["params"]["command"], "/inspect src")
                    disabled = core.request("command.execute", dict(identity, message="/quit", clientOperationId="test:disabled"), ok=False)
                    self.assertFalse(disabled["ok"])
            finally:
                core.close()
                if gateway:
                    gateway.terminate()
                    gateway.wait(timeout=5)
                    gateway.stdout.close()

    def test_acp_advertised_command(self):
        self.exercise("hermes-acp", "fake_acp_runtime.py", "/inspect src", "session/prompt")

    def test_opencode_advertised_command(self):
        self.exercise("opencode-acp", "fake_acp_runtime.py", "/inspect src", "session/prompt")

    def test_gemini_advertised_command(self):
        self.exercise("gemini-acp", "fake_acp_runtime.py", "/inspect src", "session/prompt")

    def test_pi_prompt_command(self):
        self.exercise("pi-rpc", "fake_pi_rpc.py", "/inspect src", "prompt")

    def test_pi_extension_without_agent_events(self):
        self.exercise("pi-rpc", "fake_pi_rpc.py", "/local", "prompt")

    def test_codex_native_skill_input(self):
        self.exercise("codex-app-server", "fake_codex_app_server.py", "/skill:inspect src", "turn/start")

    def test_hermes_skill_expansion(self):
        self.exercise("hermes-gateway", "fake_gateway_runtime.py", "/skill-test src", "command.dispatch")

    def test_hermes_quick_alias(self):
        self.exercise("hermes-gateway", "fake_gateway_runtime.py", "/quick src", "slash.exec")

    def test_hermes_native_control(self):
        self.exercise("hermes-gateway", "fake_gateway_runtime.py", "/inspect src", "slash.exec")

    def test_openclaw_immediate_control(self):
        self.exercise("openclaw-gateway", "fake_gateway_runtime.py", "/stop", "chat.send")

    def test_openclaw_command_prefix(self):
        self.exercise("openclaw-gateway", "fake_gateway_runtime.py", "/inspect src", "chat.send")


if __name__ == "__main__":
    unittest.main()
