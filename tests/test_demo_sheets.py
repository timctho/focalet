"""Synthetic protocol/workbook fixtures test the real-footage export guard."""

import base64
import csv
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile

from PIL import Image

DEMO = Path(__file__).resolve().parents[1] / "scripts/demo"
sys.path.insert(0, str(DEMO))
import sheets_proof as proof  # noqa: E402 - local demo tools need the scripts path


class SheetsProofTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = "https://docs.google.com/spreadsheets/d/SAMPLE/edit?gid=0#gid=0"
        self.cells = {}
        values = {
            "F2": 270,
            "F3": 540,
            "F4": 680,
            "F5": 0,
            "F6": 81,
            "F7": 630,
            "H2": 170,
            "H3": 540,
            "H4": 580,
            "H6": 31,
        }
        for row_number, row in enumerate(
            csv.reader((DEMO / "sheets/event-budget.csv").read_text().splitlines()), 1
        ):
            for column, value in zip("ABCDEFGH", row):
                address = f"{column}{row_number}"
                formula = value[1:] if value.startswith("=") else None
                if row_number in (2, 3, 4, 6) and column in "FH":
                    formula = (
                        f"C{row_number}*D{row_number}*(1-E{row_number})"
                        if column == "F"
                        else f"F{row_number}-G{row_number}"
                    )
                if formula:
                    value = values[address]
                else:
                    try:
                        value = (
                            float(value[:-1]) / 100
                            if value.endswith("%")
                            else float(value) if value else None
                        )
                    except ValueError:
                        pass
                self.cells[address] = (value, formula)
        turns = []
        for count in (2, 1):
            content = [
                {
                    "type": "text",
                    "text": "<user_message>Fix this</user_message>\n"
                    + self.source
                    + "\n"
                    + 'Image region alignment and coordinate mapping: {"status":"aligned"}\n'
                    * count,
                }
            ]
            content += [{"type": "image"}] * count
            turns.append(
                {
                    "status": "completed",
                    "items": [
                        {"type": "userMessage", "content": content},
                        {
                            "type": "mcpToolCall",
                            "tool": "evaluate_script",
                            "status": "completed",
                            "arguments": {"pageId": 1},
                            "result": {"url": self.source},
                        },
                        {
                            "type": "mcpToolCall",
                            "tool": "type_text",
                            "status": "completed",
                            "arguments": {"pageId": 1},
                        },
                    ],
                }
            )
        self.session = {"thread": {"turns": turns}}
        self.screens = []
        for index, color in enumerate(
            ((255, 242, 204), (255, 255, 255), (255, 242, 204))
        ):
            path = self.root / f"{index}.png"
            Image.new("RGB", (1200, 500), color).save(path)
            self.screens.append(path)

    def receipt(self, cells, time, rule='AND($B2="Confirmed",$H2>500)', operator=None):
        ns = proof.NS["s"]
        sheet = ET.Element("worksheet", xmlns=ns)
        data = ET.SubElement(sheet, "sheetData")
        row = ET.SubElement(data, "row", r="1")
        strings = ET.Element("sst", xmlns=ns)
        for address, (value, formula) in cells.items():
            node = ET.SubElement(row, "c", r=address)
            if isinstance(value, str):
                node.set("t", "s")
                index = len(strings)
                ET.SubElement(ET.SubElement(strings, "si"), "t").text = value
                value = index
            if formula is not None:
                ET.SubElement(node, "f").text = formula
            if value is not None:
                ET.SubElement(node, "v").text = str(value)
        formatting = ET.SubElement(sheet, "conditionalFormatting", sqref="H2:H4 H6")
        attributes = (
            {"type": "cellIs", "operator": operator}
            if operator
            else {"type": "expression"}
        )
        ET.SubElement(
            ET.SubElement(formatting, "cfRule", **attributes), "formula"
        ).text = rule
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w") as archive:
            archive.writestr("xl/sharedStrings.xml", ET.tostring(strings))
            archive.writestr("xl/worksheets/sheet1.xml", ET.tostring(sheet))
        return {
            "url": self.source,
            "observedAt": time,
            "xlsx": base64.b64encode(buffer.getvalue()).decode(),
        }

    def receipts(self):
        changed = dict(self.cells, G3=(100, None), H3=(440, "F3-G3"))
        return [
            self.receipt(cells, str(index))
            for index, cells in enumerate((self.cells, changed, self.cells))
        ]

    def test_completed_journey_requires_both_native_handoffs_and_live_edits(self):
        result = proof.verify(self.session, *self.receipts(), self.screens)
        self.assertEqual(result["balanceReadbacks"], [540, 440, 540])
        self.assertNotIn(self.source, json.dumps(result))
        self.session["thread"]["turns"][1]["items"][-1]["arguments"]["pageId"] = 2
        with self.assertRaisesRegex(ValueError, "browser edits"):
            proof.verify(self.session, *self.receipts(), self.screens)

    def test_suggested_values_cannot_replace_live_formulas(self):
        self.cells["H3"] = (540, None)
        with self.assertRaisesRegex(ValueError, "formula"):
            proof.verify(self.session, *self.receipts(), self.screens)

    def test_loose_selections_keep_actual_reference_labels(self):
        turns = self.session["thread"]["turns"]
        first = turns[0]["items"][0]["content"]
        first.pop()
        first[0]["text"] = first[0]["text"].replace(
            'Image region alignment and coordinate mapping: {"status":"aligned"}\n',
            "",
            1,
        )
        for turn in turns:
            turn["items"][0]["content"][0]["text"] += "\nUser reference [B]:"
        result = proof.verify(
            self.session, *self.receipts(), self.screens, capture_counts=(1, 1)
        )
        self.assertEqual(result["referenceLabels"], ["B"])
        self.assertEqual(result["followupReferenceLabels"], ["B"])
        first[0]["text"] = first[0]["text"].replace("User reference [B]:", "")
        with self.assertRaisesRegex(ValueError, "reference labels"):
            proof.verify(
                self.session, *self.receipts(), self.screens, capture_counts=(1, 1)
            )

    def test_native_greater_than_rule_is_dynamic_and_direction_matters(self):
        changed = dict(self.cells, G3=(100, None), H3=(440, "F3-G3"))
        for operator in ("greaterThan", "lessThan"):
            receipts = [
                self.receipt(c, str(i), "500", operator)
                for i, c in enumerate((self.cells, changed, self.cells))
            ]
            if operator == "greaterThan":
                self.assertTrue(
                    proof.verify(self.session, *receipts, self.screens)[
                        "conditionalFormatVerified"
                    ]
                )
            else:
                with self.assertRaisesRegex(ValueError, "dynamic rule"):
                    proof.verify(self.session, *receipts, self.screens)

    def test_cancelled_rows_and_original_inputs_are_preserved(self):
        self.cells["G5"] = (50, None)
        with self.assertRaisesRegex(ValueError, "unrequested"):
            proof.verify(self.session, *self.receipts(), self.screens)

    def test_different_document_static_highlight_or_missing_rule_is_rejected(self):
        receipts = self.receipts()
        receipts[1]["url"] += "wrong"
        with self.assertRaisesRegex(ValueError, "same source"):
            proof.verify(self.session, *receipts, self.screens)
        receipts = self.receipts()
        receipts[0] = self.receipt(self.cells, "0", rule="TRUE")
        with self.assertRaisesRegex(ValueError, "dynamic rule"):
            proof.verify(self.session, *receipts, self.screens)
        with self.assertRaisesRegex(ValueError, "highlight"):
            proof.verify(self.session, *self.receipts(), [self.screens[0]] * 3)


if __name__ == "__main__":
    unittest.main()
