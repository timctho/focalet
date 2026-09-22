"""Verify the native Pen sketch, real agent edit and live quote recalculation."""

import base64
import io
import json
import math
import posixpath
import re
import zipfile
import xml.etree.ElementTree as ET
from urllib.parse import urlsplit

from session_evidence import inline_objects_after
from workbook_evidence import inspect

OUTPUTS = {"G4", "G5", "G6", "G13", "G14", "G15"}
EXPECTED = {"G4": 520, "G5": 44.8, "G6": 564.8,
            "G13": 750, "G14": 64.8, "G15": 814.8}
CHANGED = dict(EXPECTED, G13=850, G14=72.8, G15=922.8)


def layout(receipt):
    """Retain all exported column definitions, including columns after E."""
    archive = zipfile.ZipFile(io.BytesIO(base64.b64decode(receipt["xlsx"])))
    ns = {"s": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
    result = {}
    for path in archive.namelist():
        if not re.fullmatch(r"xl/worksheets/sheet\d+\.xml", path):
            continue
        sheet = ET.fromstring(archive.read(path))
        result[path] = {
            "columnsAndMerges": [ET.tostring(node).decode() for node in sheet
                                 if node.tag.split("}")[-1] in ("cols", "sheetFormatPr", "mergeCells")],
            "rows": {row.get("r"): {k: v for k, v in row.attrib.items()
                                     if k not in ("spans", "s")}
                     for row in sheet.findall("s:sheetData/s:row", ns)},
        }
    return result


def styles(receipt):
    """Resolve style indexes so reordered XLSX style tables compare by content."""
    archive = zipfile.ZipFile(io.BytesIO(base64.b64decode(receipt["xlsx"])))
    ns = {"s": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
    root = ET.fromstring(archive.read("xl/styles.xml"))
    custom = {x.get("numFmtId"): x.get("formatCode")
              for x in root.findall("s:numFmts/s:numFmt", ns)}
    definitions = []
    for xf in root.find("s:cellXfs", ns):
        attributes = dict(xf.attrib)
        for key, group in (("fontId", "fonts"), ("fillId", "fills"), ("borderId", "borders")):
            nodes = root.find("s:" + group, ns)
            index = int(attributes.pop(key, "0"))
            attributes[key] = ET.tostring(nodes[index]).decode() if nodes is not None else ""
        fmt = attributes.pop("numFmtId", "0")
        attributes["numberFormat"] = custom.get(fmt, "builtin:" + fmt)
        base = int(attributes.pop("xfId", "0"))
        bases = root.find("s:cellStyleXfs", ns)
        attributes["baseStyle"] = ET.tostring(bases[base]).decode() if bases is not None else ""
        definitions.append((attributes, [ET.tostring(child).decode() for child in xf]))
    relations = {x.get("Id"): posixpath.normpath("xl/" + x.get("Target"))
                 for x in ET.fromstring(archive.read("xl/_rels/workbook.xml.rels"))}
    rel = "{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id"
    return {sheet.get("name"): {
        cell.get("r"): definitions[int(cell.get("s", "0"))]
        for cell in ET.fromstring(archive.read(relations[sheet.get(rel)])).findall("s:sheetData/s:row/s:c", ns)
    } for sheet in ET.fromstring(archive.read("xl/workbook.xml")).findall("s:sheets/s:sheet", ns)}


def values(cells, expected):
    for address, amount in expected.items():
        cell = cells.get(address, {})
        if not cell.get("formula") or not math.isclose(float(cell.get("value", "nan")), amount, abs_tol=1e-6):
            raise ValueError(f"Incorrect formula or calculated value at {address}")
        if cell.get("value") is None:
            raise ValueError("Missing calculated formula value")


def verify(session, before, after, changed, restored, *, reviewed_groups,
           sheet_name="Quote builder"):
    # Maintainer input comes from the actual attachment, never the prompt/workspace.
    if reviewed_groups != {"A": [4, 17], "B": [5, 11, 18], "excluded": [19]}:
        raise ValueError("The reviewed sketch does not match this fixture")
    receipts = [before, after, changed, restored]
    identity = lambda r: (urlsplit(r["url"]).netloc, urlsplit(r["url"]).path)
    if any(identity(r) != identity(before) for r in receipts):
        raise ValueError("Readbacks identify different documents")
    if any(a["observedAt"] >= b["observedAt"] for a, b in zip(receipts, receipts[1:])):
        raise ValueError("Readbacks must be ordered")
    turns = session["thread"]["turns"]
    if len(turns) != 1 or turns[0]["status"] != "completed":
        raise ValueError("One completed real agent turn is required")
    user = next(x for x in turns[0]["items"] if x["type"] == "userMessage")
    text = "\n".join(x.get("text", "") for x in user["content"])
    prompt, separator, context = text.partition("</user_message>")
    annotation = list(inline_objects_after(text, "User-added image annotations (baked into the attached image; source context describes the original app, not these marks):"))
    if (sum(x["type"] in ("image", "localImage") for x in user["content"]) != 1
            or len(annotation) != 1 or annotation[0].get("source") != "user"
            or annotation[0].get("bakedIntoImage") is not True
            or annotation[0].get("strokeCount") != 17
            or {x.lower() for x in annotation[0].get("tools", [])} != {"pen"}):
        raise ValueError("The actual attachment must have the reviewed 17 native Pen strokes")
    if (not separator or identity(before)[1] not in context
            or re.search(r"https?://|\b[A-Z]{1,3}\d+\b", prompt)
            or any(name.lower() in prompt.lower() for name in
                   ("Lighting", "Display", "Signage", "Coffee", "Snack", "Staff meal"))):
        raise ValueError("The image must supply the groups and captured document identity")
    calls = [x for x in turns[0]["items"] if x["type"] == "mcpToolCall" and x["status"] == "completed"]
    pages = {x.get("arguments", {}).get("pageId") for x in calls
             if identity(before)[1] in json.dumps(x.get("result", {}))} - {None}
    if not any(x["tool"] in ("fill", "type_text", "press_key", "click")
               and x.get("arguments", {}).get("pageId") in pages for x in calls):
        raise ValueError("Agent browser edits of the captured document are required")
    if not any(x["tool"] == "evaluate_script" for x in calls):
        raise ValueError("Agent live reads are required")
    books = [inspect(r) for r in receipts]
    original, edited, recalculated, reset = books
    if any(set(b) != set(original) for b in books):
        raise ValueError("Workbook tabs changed")
    if any(layout(r) != layout(before) for r in receipts[1:]):
        raise ValueError("Exported column or merged-cell layout changed")
    original_styles = styles(before)
    for receipt in receipts[1:]:
        current_styles = styles(receipt)
        for name, cells in original_styles.items():
            for address in cells.keys() | current_styles[name].keys():
                previous, current = cells.get(address), current_styles[name].get(address)
                if name == sheet_name and address in OUTPUTS and previous and current:
                    # Writing the quote may format its six outputs as decimal amounts.
                    previous = ({k: v for k, v in previous[0].items() if k != "numberFormat"}, previous[1])
                    current = ({k: v for k, v in current[0].items() if k != "numberFormat"}, current[1])
                if previous != current:
                    raise ValueError("Formatting outside the quote amounts changed")
    if styles(after) != styles(changed) or styles(after) != styles(restored):
        raise ValueError("Formatting changed during recalculation")
    for name in original:
        if name != sheet_name:
            if any(b[name] != original[name] for b in books[1:]):
                raise ValueError("An unrelated worksheet changed")
            continue
        old = original[name]
        for b in books[1:]:
            current = b[name]
            for field in ("rules", "appearance", "widths", "merges", "rows"):
                if current[field] != old[field]:
                    raise ValueError(f"Unexpected change to {field}")
            for address in set(old["cells"]) | set(current["cells"]):
                if address in OUTPUTS:
                    if address in old["cells"]:
                        raise ValueError("Quote outputs were not initially empty")
                    continue
                expected = old["cells"].get(address)
                if b is recalculated and address == "C5":
                    expected = dict(expected, value=230.0)
                if current["cells"].get(address) != expected:
                    raise ValueError(f"Unexpected source change at {address}")
        cells = edited[name]["cells"]
        values(cells, EXPECTED)
        values(recalculated[name]["cells"], CHANGED)
        values(reset[name]["cells"], EXPECTED)
        if edited != reset:
            raise ValueError("Restoring the source did not restore the workbook")
        for address in OUTPUTS:
            if any(b[name]["cells"][address]["formula"] != cells[address]["formula"]
                   for b in books[2:]):
                raise ValueError("Formulas changed during the recalculation check")
        # Recursively follow outputs, rejecting constants substituted for source inputs.
        def sources(address, seen=None):
            seen = set() if seen is None else seen
            if address in seen:
                raise ValueError("Cyclic output formula")
            if address not in OUTPUTS:
                return {address}
            refs = re.findall(r"\$?([A-Z]+)\$?(\d+)", cells[address]["formula"])
            result = set()
            for column, row in refs:
                result |= sources(column + row, seen | {address})
            return result
        for outputs, rows in ((("G4", "G5", "G6"), [4, 17]),
                              (("G13", "G14", "G15"), [5, 11, 18])):
            for index, address in enumerate(outputs):
                columns = "BC" if index == 0 else "BCD"
                if sources(address) != {f"{c}{r}" for c in columns for r in rows}:
                    raise ValueError("Quotes must link to exactly the sketched source inputs")
    return {"scene": "sheets", "scenario": "handdrawn-quotes", "captureCount": 1,
            "annotationCount": 17, "annotationTools": ["pen"], "agentCompleted": True,
            "agentToolEvents": len(calls), "formulaCellsVerified": 6,
            "otherTabsUnchanged": True, "sourceDataRestored": True,
            "recalculationVerified": True, "crossedOutOptionExcluded": True}
