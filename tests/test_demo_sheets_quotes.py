"""Reject decorative sketches, hardcoded results and collateral sheet changes."""

import base64
import io
import json
import unittest
import xml.etree.ElementTree as ET
import zipfile

import test_demo_sheets_layout as fixture
import sheets_quote_proof as proof


class SheetQuoteTests(unittest.TestCase):
    def setUp(self):
        sample = fixture.SheetsLayoutTests()
        sample.setUp()
        self.session = sample.session
        text = ('<user_message>Turn my sketch into two quotes. Skip the crossed-out '
                'option and link source cells.</user_message>' + sample.source + '\n'
                'User-added image annotations (baked into the attached image; source context describes the original app, not these marks): '
                + json.dumps({"source": "user", "bakedIntoImage": True,
                              "strokeCount": 17, "tools": ["pen"]}))
        self.session["thread"]["turns"][0]["items"][0]["content"] = [
            {"type": "text", "text": text}, {"type": "image"}]
        self.template = sample.receipt()
        self.ns = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"
        self.formulas = {
            "G4": "B4*C4+B17*C17", "G5": "B4*C4*D4+B17*C17*D17", "G6": "SUM(G4:G5)",
            "G13": "B5*C5+B11*C11+B18*C18", "G14": "B5*C5*D5+B11*C11*D11+B18*C18*D18",
            "G15": "SUM(G13:G14)"}
        self.receipts = [self.receipt(i) for i in range(4)]

    def receipt(self, stage):
        archive = zipfile.ZipFile(io.BytesIO(base64.b64decode(self.template["xlsx"])))
        files = {p: archive.read(p) for p in archive.namelist()}
        files["xl/workbook.xml"] = files["xl/workbook.xml"].replace(b"Event overview", b"Quote builder")
        sheet = ET.fromstring(files["xl/worksheets/sheet2.xml"])
        data = sheet.find(self.ns + "sheetData")
        data.clear()
        sources = {4: (4, 90, .08), 5: (2, 230 if stage == 2 else 180, .08),
                   11: (6, 25, .08), 17: (40, 4, .1), 18: (30, 8, .1), 19: (8, 18, .1)}
        for row in range(1, 20):
            node = ET.SubElement(data, self.ns + "row", r=str(row))
            for col, value in zip("BCD", sources.get(row, (0, 0, 0))):
                cell = ET.SubElement(node, self.ns + "c", r=f"{col}{row}", s="0")
                ET.SubElement(cell, self.ns + "v").text = str(value)
            if f"G{row}" in self.formulas:
                address = f"G{row}"
                cell = ET.SubElement(node, self.ns + "c", r=address, s="0")
                if stage:
                    ET.SubElement(cell, self.ns + "f").text = self.formulas[address]
                    ET.SubElement(cell, self.ns + "v").text = str((proof.CHANGED if stage == 2 else proof.EXPECTED)[address])
        files["xl/worksheets/sheet2.xml"] = ET.tostring(sheet)
        result = dict(self.template, observedAt=str(stage))
        self.pack(result, files)
        return result

    @staticmethod
    def pack(receipt, files):
        out = io.BytesIO()
        with zipfile.ZipFile(out, "w") as archive:
            for path, data in files.items():
                archive.writestr(path, data)
        receipt["xlsx"] = base64.b64encode(out.getvalue()).decode()

    def mutate(self, stage, path, old, new):
        receipt = self.receipts[stage]
        archive = zipfile.ZipFile(io.BytesIO(base64.b64decode(receipt["xlsx"])))
        files = {p: archive.read(p) for p in archive.namelist()}
        self.assertIn(old, files[path])
        files[path] = files[path].replace(old, new)
        self.pack(receipt, files)

    def verify(self):
        return proof.verify(self.session, *self.receipts,
                            reviewed_groups={"A": [4, 17], "B": [5, 11, 18], "excluded": [19]})

    def test_real_sketch_and_linked_recalculation_pass(self):
        self.assertTrue(self.verify()["recalculationVerified"])

    def test_arrow_tool_cannot_substitute_for_freehand_pen(self):
        content = self.session["thread"]["turns"][0]["items"][0]["content"]
        content[0]["text"] = content[0]["text"].replace('"pen"', '"arrow"')
        with self.assertRaisesRegex(ValueError, "Pen strokes"):
            self.verify()

    def test_prompt_cannot_supply_the_answer(self):
        content = self.session["thread"]["turns"][0]["items"][0]["content"]
        content[0]["text"] = content[0]["text"].replace('two quotes', 'G4 and Lighting quotes')
        with self.assertRaisesRegex(ValueError, "image must supply"):
            self.verify()

    def test_correct_cached_numbers_do_not_prove_source_links(self):
        for stage in (1, 2, 3):
            self.mutate(stage, "xl/worksheets/sheet2.xml", b"B4*C4+B17*C17", b"520")
        with self.assertRaisesRegex(ValueError, "sketched source inputs"):
            self.verify()

    def test_price_change_must_recalculate_the_connected_quote(self):
        self.mutate(2, "xl/worksheets/sheet2.xml", b"922.8", b"814.8")
        with self.assertRaisesRegex(ValueError, "calculated value"):
            self.verify()

    def test_crossed_out_item_cannot_replace_the_selected_item(self):
        for stage in (1, 2, 3):
            self.mutate(stage, "xl/worksheets/sheet2.xml", b"B18*C18", b"B19*C19")
        with self.assertRaisesRegex(ValueError, "sketched source inputs"):
            self.verify()

    def test_other_tab_changes_are_rejected(self):
        self.mutate(1, "xl/worksheets/sheet1.xml", b"99", b"98")
        with self.assertRaisesRegex(ValueError, "unrelated worksheet"):
            self.verify()

    def test_output_column_resize_is_not_hidden_by_five_column_inspector(self):
        self.mutate(1, "xl/worksheets/sheet2.xml", b"<ns0:sheetData>",
                    b'<ns0:cols><ns0:col min="7" max="7" width="80" /></ns0:cols><ns0:sheetData>')
        with self.assertRaisesRegex(ValueError, "column"):
            self.verify()

    def test_source_number_format_changes_are_rejected(self):
        for stage in (1, 2, 3):
            self.mutate(stage, "xl/styles.xml", b'fontId="0" fillId="0"',
                        b'fontId="0" fillId="0" numFmtId="10"')
        with self.assertRaisesRegex(ValueError, "Formatting outside"):
            self.verify()


if __name__ == "__main__":
    unittest.main()
