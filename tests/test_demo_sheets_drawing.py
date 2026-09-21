"""Drawing evidence must constrain the edit, including cells outside the arrows."""

import base64
import copy
import io
import json
import unittest
import xml.etree.ElementTree as ET
import zipfile

import test_demo_sheets_layout as layout_fixture
import sheets_drawing_proof as proof


class SheetsDrawingTests(unittest.TestCase):
    def setUp(self):
        fixture = layout_fixture.SheetsLayoutTests()
        fixture.setUp()
        self.before = fixture.receipt()
        self.after = copy.deepcopy(self.before)
        self.after["observedAt"] = "2026-09-20T02:00:00Z"
        self.before["observedAt"] = "2026-09-20T01:00:00Z"
        self.marked = [f"{col}{row}" for row in (4, 15) for col in "ABCDE"]
        self.session = fixture.session
        text = ('<user_message>Make only the rows marked by arrows pale yellow and bold. '
                'Keep all values and formulas.</user_message>' + fixture.source + '\n'
                'User-added image annotations (baked into the attached image; source context describes the original app, not these marks): '
                + json.dumps({"source": "user", "bakedIntoImage": True, "strokeCount": 2, "tools": ["arrow"]}))
        self.session["thread"]["turns"][0]["items"][0]["content"] = [{"type": "text", "text": text}, {"type": "image"}]
        archive = zipfile.ZipFile(io.BytesIO(base64.b64decode(self.before["xlsx"])))
        self.files = {name: archive.read(name) for name in archive.namelist()}
        ns = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"
        styles = ET.fromstring(self.files["xl/styles.xml"])
        fill = ET.SubElement(styles.find(ns + "fills"), ns + "fill")
        pattern = ET.SubElement(fill, ns + "patternFill", patternType="solid")
        ET.SubElement(pattern, ns + "fgColor", rgb="FFFFF2CC")
        ET.SubElement(styles.find(ns + "cellXfs"), ns + "xf", fontId="1", fillId="4")
        self.files["xl/styles.xml"] = ET.tostring(styles)
        sheet = ET.fromstring(self.files["xl/worksheets/sheet2.xml"])
        for cell in sheet.iter(ns + "c"):
            if cell.get("r") in self.marked:
                cell.set("s", "4")
        self.files["xl/worksheets/sheet2.xml"] = ET.tostring(sheet)
        self.pack()

    def pack(self):
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w") as archive:
            for name, data in self.files.items():
                archive.writestr(name, data)
        self.after["xlsx"] = base64.b64encode(buffer.getvalue()).decode()

    def verify(self):
        return proof.verify(self.session, self.before, self.after,
                            sheet_name="Event overview", marked_cells=self.marked)

    def test_two_arrows_change_only_the_reviewed_cells(self):
        result = self.verify()
        self.assertEqual(result["markedCellsVerified"], 10)
        self.assertTrue(result["unmarkedCellsUnchanged"])

    def test_an_unmarked_row_cannot_be_substituted(self):
        self.marked = [f"{col}{row}" for row in (5, 15) for col in "ABCDE"]
        with self.assertRaisesRegex(ValueError, "marked"):
            self.verify()

    def test_annotations_cannot_be_decorative_or_missing(self):
        content = self.session["thread"]["turns"][0]["items"][0]["content"]
        content[0]["text"] = content[0]["text"].replace('"strokeCount": 2', '"strokeCount": 0')
        with self.assertRaisesRegex(ValueError, "two user-drawn arrows"):
            self.verify()

    def test_drawing_does_not_authorize_a_formula_change(self):
        self.files["xl/worksheets/sheet2.xml"] = self.files["xl/worksheets/sheet2.xml"].replace(b'C3*D3', b'C3+D3')
        self.pack()
        with self.assertRaisesRegex(ValueError, "Values, formulas"):
            self.verify()

    def test_prompt_cannot_name_the_cells_instead_of_pointing(self):
        content = self.session["thread"]["turns"][0]["items"][0]["content"]
        content[0]["text"] = content[0]["text"].replace('rows marked by arrows', 'rows A4:E4 marked by arrows')
        with self.assertRaisesRegex(ValueError, "Cell addresses"):
            self.verify()


if __name__ == "__main__":
    unittest.main()
