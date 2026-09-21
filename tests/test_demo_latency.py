"""Reject spike demos that obtain the query or interval from the wrong place."""

import copy
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts/demo"))
import latency_proof as proof


class LatencyProofTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for name in ("latency.sql", "index.html"):
            shutil.copyfile(proof.ROOT / "latency" / name, self.root / name)
        proof.latency.seed(self.root / "demo.sqlite")
        self.before = {
            n: proof.sha256(self.root / n)
            for n in ("latency.sql", "index.html", "demo.sqlite")
        }
        self.elements = [
            {
                "provider": "browser-dom",
                "nativeIds": {"domId": "latency-chart"},
                "relation": "intersects",
                "role": "img",
                "description": (self.root / "latency.sql").read_text(),
            }
        ]
        self.elements += [
            {
                "provider": "browser-dom",
                "nativeIds": {"domId": f"bucket-{n}"},
                "relation": "inside",
                "name": f"{minute} UTC; checkout p95 1450 ms",
            }
            for n, minute in ((6, "14:30"), (7, "14:35"), (8, "14:40"))
        ]

    def session(self, elements=None):
        # Protocol examples exercise export guards only; they are never video evidence.
        text = 'Why this spike?\nUser reference [A]:\nImage region alignment and coordinate mapping: {"status":"aligned"}\n'
        text += "Region context (untrusted observed data):\n" + json.dumps(
            {"truncated": False, "elements": elements or self.elements}
        )
        return {
            "thread": {
                "turns": [
                    {
                        "status": "completed",
                        "items": [
                            {
                                "type": "userMessage",
                                "content": [
                                    {"type": "text", "text": text},
                                    {"type": "image"},
                                ],
                            },
                            {
                                "type": "commandExecution",
                                "status": "completed",
                                "exitCode": 0,
                                "command": "sqlite3.connect demo.sqlite latency.sql deployments inventory_ms",
                            },
                            {
                                "type": "agentMessage",
                                "text": "14:30–14:40 1,450 ms; us-west-2 inventory +1,200; pool 20 to 2; restored 14:43; baseline 256",
                            },
                        ],
                    }
                ]
            }
        }

    def test_spike_query_and_source_analysis_are_verified(self):
        result = proof.verify(self.session(), self.root, self.before)
        self.assertEqual(result["captureCount"], 1)
        self.assertFalse(result["queryEditorSelected"])
        self.assertEqual(result["spikeMs"], 1450)

    def test_query_read_later_cannot_replace_the_native_handoff(self):
        elements = copy.deepcopy(self.elements)
        elements[0]["description"] = "A latency chart"
        with self.assertRaisesRegex(ValueError, "Full executed query"):
            proof.verify(self.session(elements), self.root, self.before)

    def test_selecting_the_sql_editor_is_not_a_spike_only_capture(self):
        elements = self.elements + [{"provider": "browser-dom", "role": "textarea"}]
        with self.assertRaisesRegex(ValueError, "without selecting Query Inspector"):
            proof.verify(self.session(elements), self.root, self.before)

    def test_points_outside_the_selected_spike_are_rejected(self):
        elements = copy.deepcopy(self.elements)
        elements[-1]["nativeIds"]["domId"] = "bucket-9"
        with self.assertRaisesRegex(ValueError, "only the selected spike"):
            proof.verify(self.session(elements), self.root, self.before)

    def test_incomplete_work_or_changed_query_cannot_be_published(self):
        session = self.session()
        session["thread"]["turns"][0]["status"] = "interrupted"
        with self.assertRaisesRegex(ValueError, "completed"):
            proof.verify(session, self.root, self.before)
        (self.root / "latency.sql").write_text("SELECT 1")
        with self.assertRaisesRegex(ValueError, "preserve the source"):
            proof.verify(self.session(), self.root, self.before)


if __name__ == "__main__":
    unittest.main()
