"""Reject incomplete or data-changing edits in the two-region layout demo."""

import base64
import copy
import io
import json
from pathlib import Path
import sys
import unittest
import xml.etree.ElementTree as ET
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts/demo"))
import sheets_layout_proof as proof  # noqa: E402


class SheetsLayoutTests(unittest.TestCase):
    def setUp(self):
        self.source = "https://docs.google.com/spreadsheets/d/SAMPLE/edit?gid=2"
        context = "<user_message>Format these two blocks.</user_message>" + self.source
        for label in ("C", "D"):
            context += f"\nUser reference [{label}]:\n"
            context += (
                'Image region alignment and coordinate mapping: {"status":"aligned"}'
            )
        self.session = {
            "thread": {
                "turns": [
                    {
                        "status": "completed",
                        "items": [
                            {
                                "type": "userMessage",
                                "content": [
                                    {"type": "text", "text": context},
                                    {"type": "image"},
                                    {"type": "image"},
                                ],
                            },
                            {
                                "type": "mcpToolCall",
                                "status": "completed",
                                "tool": "evaluate_script",
                                "arguments": {"pageId": 3},
                                "result": {"url": self.source},
                            },
                            {
                                "type": "mcpToolCall",
                                "status": "completed",
                                "tool": "click",
                                "arguments": {"pageId": 3},
                            },
                        ],
                    }
                ]
            }
        }

    def receipt(
        self, layout=False, only_first=False, value=10, formula="C3*D3", unrelated=99
    ):
        ns = proof.NS["s"]
        sheets = '<sheets><sheet name="Other" sheetId="1" r:id="a"/><sheet name="Event overview" sheetId="2" r:id="b"/></sheets>'
        rows = []
        for row in (*range(1, 8), *range(11, 18)):
            styled = layout and (not only_first or row < 10)
            style = 0 if not styled else 1 if row in (1, 2, 11, 12) else 2 + row % 2
            cells = []
            for col in "ABCDE":
                expression = f"<f>{formula}</f>" if col == "E" and row == 3 else ""
                cells.append(
                    f'<c r="{col}{row}" s="{style}">{expression}<v>{value if col == "B" and row == 13 else row}</v></c>'
                )
            rows.append(f'<row r="{row}">{"".join(cells)}</row>')
        widths = '<cols><col min="1" max="5" width="25"/></cols>' if layout else ""
        sheet = f'<worksheet xmlns="{ns}"><sheetFormatPr defaultColWidth="12" defaultRowHeight="15"/>{widths}<sheetData>{"".join(rows)}</sheetData></worksheet>'
        styles = f"""<styleSheet xmlns="{ns}">
<fonts><font><name val="Arial"/></font><font><b/><name val="Arial"/></font></fonts>
<fills><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FF123456"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FFFFFFFF"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FFABCDEF"/></patternFill></fill></fills>
<cellXfs><xf fontId="0" fillId="0"/><xf fontId="1" fillId="1"/><xf fontId="0" fillId="2"/><xf fontId="0" fillId="3"/></cellXfs></styleSheet>"""
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w") as archive:
            archive.writestr(
                "xl/workbook.xml",
                f'<workbook xmlns="{ns}" xmlns:r="{proof.REL}">{sheets}</workbook>',
            )
            archive.writestr(
                "xl/_rels/workbook.xml.rels",
                '<Relationships><Relationship Id="a" Target="worksheets/sheet1.xml"/><Relationship Id="b" Target="worksheets/sheet2.xml"/></Relationships>',
            )
            archive.writestr("xl/sharedStrings.xml", f'<sst xmlns="{ns}"/>')
            archive.writestr("xl/styles.xml", styles)
            archive.writestr("xl/worksheets/sheet2.xml", sheet)
            archive.writestr(
                "xl/worksheets/sheet1.xml",
                f'<worksheet xmlns="{ns}"><sheetFormatPr/><sheetData><row r="1"><c r="A1"><v>{unrelated}</v></c></row></sheetData></worksheet>',
            )
        return {
            "url": self.source,
            "observedAt": "2" if layout else "1",
            "xlsx": base64.b64encode(buffer.getvalue()).decode(),
        }

    def test_two_regions_one_turn_and_second_worksheet_are_verified(self):
        result = proof.verify(self.session, self.receipt(), self.receipt(True))
        self.assertEqual(result["referenceLabels"], ["C", "D"])
        self.assertEqual(result["blocksFormatted"], 2)
        self.assertNotIn(self.source, json.dumps(result))

    def test_one_styled_block_is_not_a_completed_layout_demo(self):
        with self.assertRaisesRegex(ValueError, "Both blocks"):
            proof.verify(
                self.session, self.receipt(), self.receipt(True, only_first=True)
            )

    def table_receipt(self, *, stripes="1"):
        receipt = self.receipt(True)
        source = zipfile.ZipFile(io.BytesIO(base64.b64decode(receipt["xlsx"])))
        files = {name: source.read(name) for name in source.namelist()}
        ns = proof.NS["s"]
        styles = ET.fromstring(files["xl/styles.xml"])
        differentials = ET.SubElement(styles, "{" + ns + "}dxfs")
        for fill in list(styles.find("s:fills", proof.NS))[1:]:
            differential = ET.SubElement(differentials, "{" + ns + "}dxf")
            differential.append(copy.deepcopy(fill))
        for fmt in styles.find("s:cellXfs", proof.NS):
            fmt.set("fillId", "0")
        table_styles = ET.SubElement(styles, "{" + ns + "}tableStyles")
        definition = ET.SubElement(
            table_styles, "{" + ns + "}tableStyle", name="Sample"
        )
        for index, kind in enumerate(
            ("headerRow", "firstRowStripe", "secondRowStripe")
        ):
            ET.SubElement(
                definition, "{" + ns + "}tableStyleElement", type=kind, dxfId=str(index)
            )
        files["xl/styles.xml"] = ET.tostring(styles)
        sheet = ET.fromstring(files["xl/worksheets/sheet2.xml"])
        parts = ET.SubElement(sheet, "{" + ns + "}tableParts")
        relations = []
        for index, span in enumerate(("A2:E7", "A12:E17"), 1):
            ET.SubElement(
                parts, "{" + ns + "}tablePart", {"{" + proof.REL + "}id": f"t{index}"}
            )
            relations.append(
                f'<Relationship Id="t{index}" Target="../tables/table{index}.xml"/>'
            )
            files[f"xl/tables/table{index}.xml"] = (
                f'<table xmlns="{ns}" ref="{span}"><tableStyleInfo name="Sample" showRowStripes="{stripes}"/></table>'.encode()
            )
        files["xl/worksheets/sheet2.xml"] = ET.tostring(sheet)
        files["xl/worksheets/_rels/sheet2.xml.rels"] = (
            "<Relationships>" + "".join(relations) + "</Relationships>"
        ).encode()
        output = io.BytesIO()
        with zipfile.ZipFile(output, "w") as archive:
            for name, data in files.items():
                archive.writestr(name, data)
        receipt["xlsx"] = base64.b64encode(output.getvalue()).decode()
        return receipt

    def test_native_alternating_colors_export_as_table_styles(self):
        result = proof.verify(self.session, self.receipt(), self.table_receipt())
        self.assertTrue(result["layoutVerified"])
        with self.assertRaisesRegex(ValueError, "alternating row"):
            proof.verify(self.session, self.receipt(), self.table_receipt(stripes="0"))

    def contrasting_receipt(self):
        receipt = self.receipt(True)
        source = zipfile.ZipFile(io.BytesIO(base64.b64decode(receipt["xlsx"])))
        files = {name: source.read(name) for name in source.namelist()}
        ns = proof.NS["s"]
        styles = ET.fromstring(files["xl/styles.xml"])
        fonts = styles.find("s:fonts", proof.NS)
        for original in list(fonts):
            font = copy.deepcopy(original)
            ET.SubElement(font, "{" + ns + "}sz", val="14")
            fonts.append(font)
        fills = styles.find("s:fills", proof.NS)
        orange = copy.deepcopy(fills[1])
        orange.find("s:patternFill/s:fgColor", proof.NS).set("rgb", "FFE69138")
        fills.append(orange)
        formats = styles.find("s:cellXfs", proof.NS)
        for original in list(formats):
            fmt = copy.deepcopy(original)
            fmt.set("fontId", str(int(fmt.get("fontId")) + 2))
            if fmt.get("fillId") == "1":
                fmt.set("fillId", "4")
            formats.append(fmt)
        sheet = ET.fromstring(files["xl/worksheets/sheet2.xml"])
        for row in sheet.findall("s:sheetData/s:row", proof.NS):
            if int(row.get("r")) >= 11:
                row.set("ht", "30")
                for cell in row:
                    cell.set("s", str(int(cell.get("s")) + 4))
        files["xl/styles.xml"] = ET.tostring(styles)
        files["xl/worksheets/sheet2.xml"] = ET.tostring(sheet)
        output = io.BytesIO()
        with zipfile.ZipFile(output, "w") as archive:
            for name, data in files.items():
                archive.writestr(name, data)
        receipt["xlsx"] = base64.b64encode(output.getvalue()).decode()
        return receipt

    def contrasting_session(self):
        session = copy.deepcopy(self.session)
        text = session["thread"]["turns"][0]["items"][0]["content"][0]
        text["text"] = text["text"].replace(
            "Format these two blocks.",
            "Make C compact and navy; make D spacious and orange.",
        )
        marker = '{"status":"aligned"}'
        for y in (100, 300):
            text["text"] = text["text"].replace(
                marker,
                json.dumps(
                    {"status": "aligned", "screenBounds": {"y": y, "height": 100}}
                ),
                1,
            )
        return session

    def test_different_layouts_are_verified_per_reference(self):
        result = proof.verify(
            self.contrasting_session(),
            self.receipt(),
            self.contrasting_receipt(),
            scenario="contrasting-layouts",
        )
        self.assertTrue(result["referenceStylesVerified"])
        self.assertEqual(result["referenceLabels"], ["C", "D"])

    def test_matching_or_swapped_styles_and_color_only_changes_are_rejected(self):
        matching = proof.inspect(self.receipt(True))["Event overview"]
        with self.assertRaisesRegex(ValueError, "orange"):
            proof.verify_contrast(matching)
        different = proof.inspect(self.contrasting_receipt())["Event overview"]
        swapped = copy.deepcopy(different)
        for column in "ABCDE":
            (
                swapped["appearance"][f"{column}2"],
                swapped["appearance"][f"{column}12"],
            ) = (
                swapped["appearance"][f"{column}12"],
                swapped["appearance"][f"{column}2"],
            )
        with self.assertRaisesRegex(ValueError, "navy"):
            proof.verify_contrast(swapped)
        same_fonts = copy.deepcopy(different)
        for row in range(13, 18):
            for column in "ABCDE":
                same_fonts["appearance"][f"{column}{row}"]["fontSize"] = 10
        with self.assertRaisesRegex(ValueError, "larger text"):
            proof.verify_contrast(same_fonts)
        for row in range(13, 18):
            different["rows"][str(row)] = "15"
        with self.assertRaisesRegex(ValueError, "taller rows"):
            proof.verify_contrast(different)

    def test_reference_identity_and_spatial_order_are_required(self):
        after = self.contrasting_receipt()
        with self.assertRaisesRegex(ValueError, "explicitly identify"):
            proof.verify(
                self.session, self.receipt(), after, scenario="contrasting-layouts"
            )
        session = self.contrasting_session()
        text = session["thread"]["turns"][0]["items"][0]["content"][0]
        text["text"] = text["text"].replace('"y": 100', '"y": 500')
        with self.assertRaisesRegex(ValueError, "Capture order"):
            proof.verify(session, self.receipt(), after, scenario="contrasting-layouts")

    def test_values_formulas_and_other_sheet_must_be_preserved(self):
        for change in ({"value": 11}, {"formula": "C3+D3"}, {"unrelated": 100}):
            with self.subTest(change=change), self.assertRaisesRegex(
                ValueError, "values or formulas"
            ):
                proof.verify(self.session, self.receipt(), self.receipt(True, **change))

    def test_missing_selection_or_unfinished_turn_is_rejected(self):
        original = copy.deepcopy(self.session)
        self.session["thread"]["turns"][0]["items"][0]["content"].pop()
        with self.assertRaisesRegex(ValueError, "Two distinct"):
            proof.verify(self.session, self.receipt(), self.receipt(True))
        original["thread"]["turns"][0]["status"] = "inProgress"
        with self.assertRaisesRegex(ValueError, "completed layout"):
            proof.verify(original, self.receipt(), self.receipt(True))

    def test_wrong_source_or_browser_edit_is_rejected(self):
        after = self.receipt(True)
        after["url"] = after["url"].replace("SAMPLE", "OTHER")
        with self.assertRaisesRegex(ValueError, "same document"):
            proof.verify(self.session, self.receipt(), after)
        self.session["thread"]["turns"][0]["items"][-1]["arguments"]["pageId"] = 9
        with self.assertRaisesRegex(ValueError, "browser edits"):
            proof.verify(self.session, self.receipt(), self.receipt(True))


if __name__ == "__main__":
    unittest.main()
