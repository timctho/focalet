"""Synthetic workbook and browser-session inputs for quote verification tests."""

import base64
import io
from pathlib import Path
import sys
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts/demo"))
import workbook_evidence as proof


class WorkbookFixture:
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
