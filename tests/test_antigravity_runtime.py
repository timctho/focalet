"""Real broker acceptance for Antigravity's persistent streaming interface."""
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

from test_runtime_commands import Core, FIXTURES


class AntigravityTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="zommi-antigravity-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("ZOMMI_")}
        self.env.update(
            ZOMMI_RUNTIME_DISCOVERY_MODE="configured-only",
            ZOMMI_AGY_COMMAND=sys.executable,
            ZOMMI_ANTIGRAVITY_ARGS_JSON=json.dumps([str(FIXTURES / "fake_antigravity_runtime.py")]),
            ZOMMI_CORE_STATE_PATH=str(self.root / "binding.json"),
            ZOMMI_RUNTIME_OVERRIDES_PATH=str(self.root / "overrides.json"),
            ZOMMI_RUNTIME_DISCOVERY_CACHE_PATH=str(self.root / "targets.json"),
            ZOMMI_FAKE_AGY_STATE=str(self.root),
        )
        self.core = Core(self.env)
        self.addCleanup(lambda: self.core.close())
        self.core.request("core.initialize")
        self.target = self.core.request("runtime.discover")["targets"][0]
        self.target_id = self.target["id"]

    def connect(self):
        connection = self.core.request("runtime.connect", {"runtimeTargetId": self.target_id, "cwd": str(self.root)})
        self.identity = {"runtimeTargetId": self.target_id, "sessionId": connection["sessionId"]}
        return connection

    def turn(self, text, key, **extra):
        before = len(self.core.events)
        receipt = self.core.request("turn.start", dict(self.identity, message=text, clientOperationId=key, **extra))
        completed = self.core.completed(key)
        events = self.core.events[before:]
        response = "".join(e.get("payload", {}).get("text", "") for e in events if e.get("payload", {}).get("kind") == "assistant")
        return receipt, completed, response

    def test_stream_models_and_resume_keep_native_identity(self):
        self.core.request("runtime.prepare", {"runtimeTargetId": self.target_id, "cwd": str(self.root)})
        self.assertFalse((self.root / "binding.json").exists())
        launches = [json.loads(line) for line in (self.root / "launches.jsonl").read_text().splitlines()]
        self.assertTrue(all(q["args"] == ["models"] for q in launches))
        connection = self.connect()
        self.assertNotIn("input.image.v1", connection["capabilities"])
        self.assertNotIn("approval.resolve.v1", connection["capabilities"])
        self.assertNotIn("history.read.v1", connection["capabilities"])
        receipt, completed, response = self.turn("remember ocean", "test:first")
        self.assertEqual(response, "Hello Antigravity", "final result must not duplicate deltas")
        self.assertEqual(completed["payload"]["status"], "completed")
        duplicate = self.core.request("turn.start", dict(self.identity, message="remember ocean", clientOperationId="test:first"))
        self.assertEqual(duplicate, receipt)
        (self.root / "more-models").touch()
        refreshed = self.core.request("runtime.refreshModels", {"runtimeTargetId": self.target_id})
        self.assertEqual(len(refreshed["models"]), 3)
        self.assertEqual(json.loads((self.root / "binding.json").read_text())["sessionId"], self.identity["sessionId"])
        _, _, response = self.turn("recall", "test:model", model="gemini-test-deep")
        self.assertIn("remember ocean", response)
        self.core.close()
        self.core = Core(self.env)
        self.core.request("core.initialize")
        self.core.request("runtime.discover")
        restored = self.connect()
        self.assertEqual(restored["sessionId"], connection["sessionId"])
        _, _, response = self.turn("recall", "test:restart")
        self.assertIn("remember ocean", response)
        launches = [json.loads(line) for line in (self.root / "launches.jsonl").read_text().splitlines()]
        self.assertTrue(all(q["cwd"] == str(self.root) for q in launches))
        self.assertTrue(all("--dangerously-skip-permissions" not in q["args"] for q in launches))

    def test_authentication_failure_does_not_block_recovery(self):
        (self.root / "signed-out").touch()
        failed = self.core.request("runtime.connect", {"runtimeTargetId": self.target_id, "cwd": str(self.root)}, ok=False)
        self.assertEqual(failed["error"]["code"], "authentication-required")
        self.assertFalse((self.root / "binding.json").exists())
        self.assertTrue(self.core.request("runtime.discover")["targets"])
        (self.root / "signed-out").unlink()
        self.connect()
        self.assertEqual(self.turn("hello", "test:login")[1]["payload"]["status"], "completed")

    def test_stop_crash_and_protocol_failure_can_resume(self):
        self.connect()
        receipt = self.core.request("turn.start", dict(self.identity, message="wait", clientOperationId="test:stop"))
        self.core.request("turn.interrupt", dict(self.identity, turnId=receipt["turnId"]))
        self.assertEqual(self.core.completed("test:stop")["payload"]["status"], "interrupted")
        self.assertEqual(self.turn("hello", "test:after-stop")[1]["payload"]["status"], "completed")
        self.assertEqual(self.turn("crash", "test:crash")[1]["payload"]["status"], "failed")
        self.assertEqual(self.turn("hello", "test:after-crash")[1]["payload"]["status"], "completed")
        self.assertEqual(self.turn("invalid-json", "test:malformed")[1]["payload"]["status"], "failed")
        self.assertEqual(self.turn("hello", "test:after-malformed")[1]["payload"]["status"], "completed")

    def test_unsupported_input_and_failed_model_change_preserve_chat(self):
        self.connect()
        failed = self.core.request("turn.start", dict(self.identity, message="describe", images=["data:image/png;base64,AA=="], clientOperationId="test:image"), ok=False)
        self.assertEqual(failed["error"]["code"], "capability-unavailable")
        (self.root / "reject-model").touch()
        failed = self.core.request("session.configure", dict(self.identity, model="gemini-test-deep"), ok=False)
        self.assertEqual(failed["error"]["code"], "runtime-request-failed")
        self.assertEqual(self.turn("hello", "test:after-model")[1]["payload"]["status"], "completed")
        saved = json.loads((self.root / (self.identity["sessionId"] + ".json")).read_text())
        self.assertEqual(len(saved), 1, "rejected requests must not reach the runtime")


if __name__ == "__main__":
    unittest.main()
