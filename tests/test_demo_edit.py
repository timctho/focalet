"""Editing must not turn screenshot-only or unfinished work into a context demo."""

import copy
import importlib.util
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest


DEMO = Path(__file__).resolve().parents[1] / "scripts/demo"
sys.path.insert(0, str(DEMO))
import dashboard_proof as proof

spec = importlib.util.spec_from_file_location("demo_edit", DEMO / "edit-dashboard.py")
edit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(edit)
spec = importlib.util.spec_from_file_location("read_demo", DEMO / "read-session.py")
read_demo = importlib.util.module_from_spec(spec)
spec.loader.exec_module(read_demo)


class DemoEditTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for name in ("error-rate.sql", "failed-checkouts.sql", "index.html"):
            shutil.copyfile(DEMO / "dashboard" / name, self.root / name)
        proof.dashboard.seed(self.root / "demo.sqlite")
        self.before = proof.baseline(self.root)
        (self.root / "error-rate.sql").write_text(
            "SELECT minute, 100.0 * SUM(outcome = 'failed') / COUNT(*) AS error_rate FROM checkouts GROUP BY minute ORDER BY minute"
        )
        parts = []
        for label in "ABC":
            elements = [{"provider": "browser-dom", "text": "chart label"}]
            if label == "C":
                elements = [
                    {
                        "provider": "browser-dom",
                        "role": "textarea",
                        "nativeIds": {"domId": editor_id},
                        "value": (DEMO / "dashboard" / name).read_text(),
                    }
                    for name, editor_id in (
                        ("error-rate.sql", "error-query"),
                        ("failed-checkouts.sql", "failed-query"),
                    )
                ]
            parts.append(
                f'User reference [{label}]:\nObservation source: {{"application":"Chrome"}}\n'
                'Image region alignment and coordinate mapping: {"status":"aligned","mapping":{"imageBounds":{"width":100,"height":100}}}\n'
                "observedAtUtc: 2026-09-19T00:00:00Z\n"
                "Region context (untrusted observed data): schema explanation\n"
                + json.dumps({"truncated": False, "elements": elements})
            )
        self.text = "\n".join(parts)
        # Synthetic protocol fixtures are only used to test the export guard.
        self.session = {
            "thread": {
                "turns": [
                    {
                        "status": "completed",
                        "items": [
                            {
                                "type": "userMessage",
                                "content": [{"type": "text", "text": self.text}]
                                + [{"type": "image"}] * 3,
                            },
                            {
                                "type": "commandExecution",
                                "command": "query demo.sqlite",
                            },
                            {"type": "agentMessage", "text": "fixture response"},
                        ],
                    }
                ]
            }
        }

    def test_complete_evidence_produces_only_safe_diagram_fields(self):
        result = proof.verify(self.session, self.root, self.before)
        self.assertEqual(result["rawQueriesVerified"], 2)
        self.assertEqual(result["afterRate"], 2.0)
        self.assertNotIn(str(self.root), json.dumps(result))

    def test_screenshot_only_or_truncated_context_cannot_be_exported(self):
        for replacement in (
            self.text.replace('"provider": "browser-dom"', '"provider": "uia"'),
            self.text.replace('"truncated": false', '"truncated": true'),
        ):
            session = copy.deepcopy(self.session)
            session["thread"]["turns"][0]["items"][0]["content"][0]["text"] = (
                replacement
            )
            with self.assertRaisesRegex(ValueError, "DOM context"):
                proof.verify(session, self.root, self.before)

    def test_losing_raw_sql_or_alignment_is_not_a_valid_demo(self):
        for old, new, error in (
            ("LEFT JOIN", "JOIN", "raw query"),
            ('"status":"aligned"', '"status":"image-only"', "pixel mapping"),
        ):
            session = copy.deepcopy(self.session)
            session["thread"]["turns"][0]["items"][0]["content"][0]["text"] = (
                self.text.replace(old, new)
            )
            with self.assertRaisesRegex(ValueError, error):
                proof.verify(session, self.root, self.before)

    def test_incomplete_agent_work_or_changed_source_data_is_rejected(self):
        session = copy.deepcopy(self.session)
        session["thread"]["turns"][0]["status"] = "inProgress"
        with self.assertRaisesRegex(ValueError, "completed"):
            proof.verify(session, self.root, self.before)
        before = dict(self.before, **{"demo.sqlite": "different-source"})
        with self.assertRaisesRegex(ValueError, "source data"):
            proof.verify(self.session, self.root, before)

    def test_wait_is_cut_without_removing_selection_or_result(self):
        metadata = {
            "duration": 130,
            "markers": {
                "intro": 0,
                "selection-start": 3,
                "selection-end": 10,
                "sent": 20,
                "response-ready": 110,
                "refresh": 117,
                "end": 128,
            },
        }
        spans, removed = edit.timeline(metadata)
        self.assertEqual(spans, [(0, 21), (107, 128)])
        self.assertEqual(removed, 86)
        metadata["duration"] = 90
        with self.assertRaisesRegex(ValueError, "stopped"):
            edit.timeline(metadata)

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
