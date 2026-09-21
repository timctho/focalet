"""Export guards reject challenges, guesses and incorrectly paired product crops."""

import copy
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts/demo"))
import amazon_proof as proof


class AmazonProofTests(unittest.TestCase):
    def setUp(self):
        # Protocol fixtures only; these are never used as demo agent evidence.
        blocks = [
            f"User reference [{label}]:\n{source}\n"
            'Image region alignment and coordinate mapping: {"status":"aligned"}\n'
            for label, source in zip("BCE", (*proof.PRODUCTS, proof.LAPTOP))
        ]
        content = [
            {
                "type": "text",
                "text": "<user_message>Which works?</user_message>\n" + "".join(blocks),
            }
        ]
        content += [{"type": "image"}] * 3
        values = [
            {
                "url": url,
                "product": "Fixture product",
                "features": "Fixture compatibility detail. " * 60,
            }
            for url in proof.PRODUCTS
        ]
        values += [
            {"url": proof.LAPTOP, "text": "One external display"},
            {"url": proof.MANUFACTURER, "text": "DisplayLink"},
        ]
        calls = [
            {
                "type": "mcpToolCall",
                "tool": "evaluate_script",
                "status": "completed",
                "result": {
                    "content": [
                        {
                            "type": "text",
                            "text": "```json\n" + json.dumps(value) + "\n```",
                        }
                    ]
                },
            }
            for value in values
        ]
        answer = " ".join(
            (
                *proof.PRODUCTS,
                proof.LAPTOP,
                proof.MANUFACTURER,
                "DisplayLink M1 Screen Recording cables power adapter",
            )
        )
        self.session = {
            "thread": {
                "turns": [
                    {
                        "status": "completed",
                        "items": [
                            {"type": "userMessage", "content": content},
                            *calls,
                            {"type": "agentMessage", "phase": "final", "text": answer},
                        ],
                    }
                ]
            }
        }

    def test_actual_reference_labels_are_retained(self):
        self.assertEqual(proof.verify(self.session)["referenceLabels"], ["B", "C", "E"])

    def test_a_challenge_or_title_only_read_is_not_product_investigation(self):
        item = self.session["thread"]["turns"][0]["items"][1]
        item["result"]["content"][0]["text"] = (
            "```json\n"
            + json.dumps(
                {
                    "url": proof.PRODUCTS[0],
                    "title": "Amazon.com",
                    "fallback": "Continue shopping",
                }
            )
            + "\n```"
        )
        with self.assertRaisesRegex(ValueError, "additional details"):
            proof.verify(self.session)

    def test_image_only_capture_or_swapped_product_identity_is_rejected(self):
        for old, new in (
            ("aligned", "image-only"),
            (proof.PRODUCTS[0], proof.PRODUCTS[1]),
        ):
            session = copy.deepcopy(self.session)
            text = session["thread"]["turns"][0]["items"][0]["content"][0]
            text["text"] = text["text"].replace(old, new)
            with self.assertRaises(ValueError):
                proof.verify(session)

    def test_opening_a_page_does_not_count_as_reading_its_details(self):
        self.session["thread"]["turns"][0]["items"][1]["tool"] = "new_page"
        with self.assertRaisesRegex(ValueError, "additional details"):
            proof.verify(self.session)


if __name__ == "__main__":
    unittest.main()
