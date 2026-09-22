"""Export guards reject challenges, guesses and incorrectly paired product crops."""

import copy
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts/demo"))
import amazon_proof as proof


class ThreeProductSelectionTests(unittest.TestCase):
    def setUp(self):
        self.products = ("B000000001", "B000000002", "B000000003")
        self.urls = [f"https://www.amazon.com/dp/{asin}" for asin in self.products]
        blocks = []
        calls = []
        for label, url in zip("CDE", self.urls):
            context = {"elements": [{"provider": "browser-dom", "href": url}]}
            blocks.append(
                f"User reference [{label}]:\n"
                'Image region alignment and coordinate mapping: {"status":"aligned"}\n'
                "Region context (untrusted observed data):\n" + json.dumps(context)
            )
            detail = {"url": url, "features": "Fixture external monitor compatibility detail. " * 40}
            calls.append({
                "type": "mcpToolCall", "tool": "evaluate_script", "status": "completed",
                "result": {"content": [{"type": "text", "text": "```json\n" + json.dumps(detail) + "\n```"}]},
            })
        content = [{"type": "text", "text": "Which works on an M1 Air?\n" + "\n".join(blocks)}]
        content.extend({"type": "image"} for _ in range(3))
        self.items = [{"type": "userMessage", "content": content}, *calls,
                      {"type": "agentMessage", "text": "M1 comparison: " + " ".join(self.urls)}]
        self.session = {"thread": {"turns": [{"status": "completed", "items": self.items}]}}

    def verify(self):
        return proof.verify_product_selections(self.session, self.products)

    def test_three_separate_products_retain_actual_reference_labels(self):
        result = self.verify()
        self.assertEqual(result["referenceLabels"], ["C", "D", "E"])
        self.assertEqual(result["productDetailsRead"], 3)

    def test_three_links_inside_one_image_are_not_three_selections(self):
        self.items[0]["content"].pop()
        with self.assertRaisesRegex(ValueError, "Three separate"):
            self.verify()

    def test_each_crop_must_keep_its_own_product_identity(self):
        text = self.items[0]["content"][0]
        text["text"] = text["text"].replace(self.urls[0], self.urls[1])
        with self.assertRaisesRegex(ValueError, "exactly its own product"):
            self.verify()

    def test_listing_grid_read_is_not_a_product_detail_read(self):
        result = self.items[1]["result"]["content"][0]
        result["text"] = result["text"].replace(self.urls[0], "https://www.amazon.com/s?k=usb+hub")
        with self.assertRaisesRegex(ValueError, "detail-page read"):
            self.verify()

    def test_detail_snapshot_is_accepted_but_a_challenge_is_not(self):
        call = self.items[1]
        call["tool"] = "take_snapshot"
        result = call["result"]["content"][0]
        result["text"] = f'RootWebArea "Fixture hub" url="{self.urls[0]}"\n' + "Mac display detail. " * 100
        self.verify()
        result["text"] = f'RootWebArea "Amazon.com" url="{self.urls[0]}"\nContinue shopping'
        with self.assertRaisesRegex(ValueError, "detail-page read"):
            self.verify()

    def test_incomplete_investigation_cannot_be_exported(self):
        self.items[3]["status"] = "failed"
        with self.assertRaisesRegex(ValueError, "detail-page read"):
            self.verify()

    def test_executed_text_reader_preserves_source_and_retrieval_method(self):
        url = "https://r.jina.ai/" + self.urls[0]
        self.items[1] = {
            "type": "commandExecution", "status": "completed", "exitCode": 0,
            "command": f"python -c 'import urllib.request; urllib.request.urlopen(\"{url}\")'",
            "aggregatedOutput": json.dumps({"url": url, "matches": ["Mac external monitor detail. " * 50]}),
        }
        self.assertEqual(self.verify()["productReadMethods"], ["text-reader", "browser", "browser"])
        self.items[1]["exitCode"] = 1
        with self.assertRaisesRegex(ValueError, "detail-page read"):
            self.verify()

    def test_unrelated_command_output_is_not_a_source_read(self):
        self.items[1] = {
            "type": "commandExecution", "status": "completed", "exitCode": 0,
            "command": "cat old-notes.json",
            "aggregatedOutput": json.dumps({"url": self.urls[0], "matches": ["Mac display detail. " * 100]}),
        }
        with self.assertRaisesRegex(ValueError, "detail-page read"):
            self.verify()

    def test_answer_must_link_the_third_product(self):
        self.items[-1]["text"] = "M1 comparison: " + " ".join(self.urls[:2])
        with self.assertRaisesRegex(ValueError, "link all three"):
            self.verify()


if __name__ == "__main__":
    unittest.main()
