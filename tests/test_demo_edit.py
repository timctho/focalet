"""Editing must not turn screenshot-only or unfinished work into a context demo."""

import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest


DEMO = Path(__file__).resolve().parents[1] / "scripts/demo"
sys.path.insert(0, str(DEMO))

spec = importlib.util.spec_from_file_location("read_demo", DEMO / "read-session.py")
read_demo = importlib.util.module_from_spec(spec)
spec.loader.exec_module(read_demo)


class DemoEditTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def test_session_reader_follows_only_the_owned_profile_runtime_and_workspace(self):
        (self.root / "demo-identity.json").write_text(
            json.dumps(
                {
                    "runtimeTargetId": "demo",
                    "sessionId": "empty-setup",
                    "workspace": "/tmp/sample",
                }
            )
        )
        binding = {
            "runtimeTargetId": "demo",
            "sessionId": "submitted-chat",
            "cwd": "/tmp/sample",
        }
        (self.root / "binding.json").write_text(json.dumps(binding))
        self.assertEqual(
            read_demo.demo_identity(self.root)["sessionId"], "submitted-chat"
        )
        binding["cwd"] = "/somewhere-else"
        (self.root / "binding.json").write_text(json.dumps(binding))
        with self.assertRaisesRegex(ValueError, "prepared demo"):
            read_demo.demo_identity(self.root)


if __name__ == "__main__":
    unittest.main()
