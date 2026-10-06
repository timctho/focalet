#!/usr/bin/env python3
"""Process regression: launcher environment changes must not switch Codex history."""

import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parent.parent
HOST = Path(os.environ.get("FOCALET_TEST_CORE_HOST", ROOT / "target/debug" / ("focalet-core-host.exe" if os.name == "nt" else "focalet-core-host")))


class Core:
    def __init__(self, environment):
        self.process = subprocess.Popen([str(HOST)], cwd=ROOT, env=environment,
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, text=True, encoding="utf-8")
        self.messages = queue.Queue()
        self.sequence = 0
        def read():
            for line in self.process.stdout:
                self.messages.put(json.loads(line))
            self.messages.put(None)
        self.reader = threading.Thread(target=read, daemon=True)
        self.reader.start()

    def request(self, operation, payload=None):
        self.sequence += 1
        identity = str(self.sequence)
        self.process.stdin.write(json.dumps({"id": identity, "protocolVersion": 1,
                                            "operation": operation, "payload": payload or {}}) + "\n")
        self.process.stdin.flush()
        while True:
            message = self.messages.get(timeout=20)
            if message is None:
                raise AssertionError("Core exited without a response")
            if message.get("id") == identity:
                return message

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


class HomePersistenceTests(unittest.TestCase):
    def test_restarts_pin_home_and_reject_mismatch_or_corruption(self):
        self.assertTrue(HOST.is_file(), "Build focalet-core-host first")
        with tempfile.TemporaryDirectory(prefix="focalet-home-test-") as directory:
            root = Path(directory)
            first = str(root / "first home")
            second = str(root / "second home")
            log = root / "requests.jsonl"
            environment = dict(os.environ, FOCALET_CODEX_COMMAND=sys.executable,
                               FOCALET_CODEX_ARGS_JSON=json.dumps([str(ROOT / "crates/focalet-core-host/tests/fake_codex_app_server.py")]),
                               FOCALET_CORE_STATE_PATH=str(root / "binding.json"),
                               FOCALET_RUNTIME_OVERRIDES_PATH=str(root / "overrides.json"),
                               FOCALET_RUNTIME_DISCOVERY_CACHE_PATH=str(root / "discovery.json"),
                               FOCALET_FAKE_REPORT_CODEX_HOME="1", FOCALET_FAKE_REQUEST_LOG=str(log))

            def connect(home, reported=None):
                env = dict(environment, CODEX_HOME=home)
                if reported:
                    env["FOCALET_FAKE_REPORTED_HOME"] = reported
                core = Core(env)
                try:
                    self.assertTrue(core.request("core.initialize")["ok"])
                    targets = core.request("runtime.discover")["result"]["targets"]
                    target = next(t for t in targets if t["adapterId"] == "codex-app-server" and t["executionHost"]["kind"] == "native")
                    return core.request("runtime.connect", {"runtimeTargetId": target["id"], "cwd": str(root)})
                finally:
                    core.close()

            self.assertTrue(connect(first)["ok"])
            self.assertTrue(connect(second)["ok"])
            homes = [entry["fixtureCodexHome"] for entry in map(json.loads, log.read_text().splitlines()) if "fixtureCodexHome" in entry]
            self.assertEqual(homes, [first, first])
            response = connect(second, second)
            self.assertFalse(response["ok"])
            self.assertEqual(response["error"]["code"], "runtime-home-mismatch")
            binding, = (root / "codex-homes").glob("*.json")
            self.assertEqual(json.loads(binding.read_text())["codexHome"], first)
            binding.write_text("invalid")
            response = connect(second)
            self.assertFalse(response["ok"])
            self.assertEqual(response["error"]["code"], "persistence-failed")


if __name__ == "__main__":
    unittest.main()
