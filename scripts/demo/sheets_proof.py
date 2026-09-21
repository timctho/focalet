"""Verify the real two-turn sheet journey against authenticated XLSX readbacks."""

import base64
from collections import Counter
import csv
import io
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET
import zipfile

from PIL import Image
from dashboard_proof import inline_objects_after

NS = {"s": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}


def workbook(receipt, *, sheet_path="xl/worksheets/sheet1.xml"):
    archive = zipfile.ZipFile(io.BytesIO(base64.b64decode(receipt["xlsx"])))
    strings = ET.fromstring(archive.read("xl/sharedStrings.xml"))
    strings = ["".join(node.itertext()) for node in strings]
    sheet = ET.fromstring(archive.read(sheet_path))
    cells, shared = {}, {}
    for cell in sheet.findall(".//s:sheetData/s:row/s:c", NS):
        address = cell.attrib["r"]
        value = cell.findtext("s:v", default=None, namespaces=NS)
        if value is not None:
            value = strings[int(value)] if cell.get("t") == "s" else float(value)
        formula = cell.find("s:f", NS)
        expression = None
        if formula is not None:
            expression = formula.text
            if formula.get("t") == "shared":
                identity = formula.attrib["si"]
                if expression:
                    shared[identity] = (address, expression)
                else:
                    origin, expression = shared[identity]
                    # This fixture's shared formulas run down a single column.
                    if re.sub(r"\d", "", origin) != re.sub(r"\d", "", address):
                        raise ValueError("Unexpected shared formula layout")
                    offset = int(re.search(r"\d+", address)[0]) - int(
                        re.search(r"\d+", origin)[0]
                    )
                    expression = re.sub(
                        r"(\$?[A-Z]+)(\$?)(\d+)",
                        lambda match: match[1]
                        + match[2]
                        + str(int(match[3]) + (0 if match[2] else offset)),
                        expression,
                    )
        cells[address] = {"value": value, "formula": expression}
    rules = [
        (
            node.attrib["sqref"],
            (
                "cellIs:" + rule.get("operator", "")
                if rule.get("type") == "cellIs"
                else rule.get("type")
            ),
            rule.findtext("s:formula", namespaces=NS),
        )
        for node in sheet.findall("s:conditionalFormatting", NS)
        for rule in node.findall("s:cfRule", NS)
    ]
    return cells, rules


def verify(
    session,
    final,
    changed,
    restored,
    screenshots,
    *,
    capture_counts=(2, 1),
    highlight_box=(1005, 386, 1130, 410),
):
    turns = session["thread"]["turns"]
    if len(turns) != 2 or any(turn["status"] != "completed" for turn in turns):
        raise ValueError("Two completed turns in the same session are required")
    source = final["url"]
    if any(receipt["url"] != source for receipt in (changed, restored)):
        raise ValueError("Readbacks must belong to the same source document")
    if not final["observedAt"] < changed["observedAt"] < restored["observedAt"]:
        raise ValueError("Live readbacks are not in observation order")
    tools = []
    source_pages = set()
    labels_by_turn = []
    if capture_counts not in ((1, 1), (2, 1)):
        raise ValueError("Unsupported two-turn selection sequence")
    for turn, count in zip(turns, capture_counts):
        user = next(item for item in turn["items"] if item["type"] == "userMessage")
        text = "\n".join(item.get("text", "") for item in user["content"])
        labels_by_turn.append(re.findall(r"User reference \[([A-Z]+)\]:", text))
        if capture_counts == (1, 1) and len(labels_by_turn[-1]) != count:
            raise ValueError(
                "Actual reference labels are required for the loose selections"
            )
        if (
            sum(item["type"] in ("image", "localImage") for item in user["content"])
            != count
        ):
            raise ValueError("Missing native selection images")
        regions = list(
            inline_objects_after(text, "Image region alignment and coordinate mapping:")
        )
        if len(regions) != count or any(
            region.get("status") != "aligned" for region in regions
        ):
            raise ValueError("Missing aligned native context")
        if source not in text or source in text.split("</user_message>")[0]:
            raise ValueError("Document identity must arrive through captured context")
        calls = [
            item
            for item in turn["items"]
            if item["type"] == "mcpToolCall" and item["status"] == "completed"
        ]
        source_pages.update(
            item.get("arguments", {}).get("pageId")
            for item in calls
            if source in json.dumps(item.get("result", {}))
        )
        source_pages.discard(None)
        if not any(
            item["tool"] in ("fill", "type_text", "press_key")
            and item.get("arguments", {}).get("pageId") in source_pages
            for item in calls
        ):
            raise ValueError("No actual browser edits recorded")
        if not any(item["tool"] == "evaluate_script" for item in calls):
            raise ValueError("No live browser readback recorded")
        tools.extend(calls)
    after, rules = workbook(final)
    alternate, changed_rules = workbook(changed)
    restored_cells, restored_rules = workbook(restored)
    expected = list(
        csv.reader(
            (Path(__file__).parent / "sheets/event-budget.csv").read_text().splitlines()
        )
    )
    for row_number, row in enumerate(expected, 1):
        for column, value in zip("ABCDEFGH", row):
            address = f"{column}{row_number}"
            actual = after.get(address, {"value": None, "formula": None})
            if row_number in (2, 3, 4, 6) and column in "FH":
                formula = (
                    f"C{row_number}*D{row_number}*(1-E{row_number})"
                    if column == "F"
                    else f"F{row_number}-G{row_number}"
                )
                if actual["formula"] != formula:
                    raise ValueError("A requested formula is missing")
            elif value.startswith("="):
                if actual["formula"] != value[1:]:
                    raise ValueError("An exception formula changed")
            else:
                try:
                    value = (
                        float(value[:-1]) / 100
                        if value.endswith("%")
                        else float(value) if value else None
                    )
                except ValueError:
                    pass
                if actual["value"] != value:
                    raise ValueError("An unrequested input or exception row changed")
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
    if any(after[address]["value"] != value for address, value in values.items()):
        raise ValueError("Live computed values do not match the requested edits")
    if rules not in (
        [("H2:H4 H6", "expression", 'AND($B2="Confirmed",$H2>500)')],
        [("H2:H4 H6", "cellIs:greaterThan", "500")],
    ):
        raise ValueError("Expected a dynamic rule restricted to confirmed rows")
    expected_changed = {key: dict(value) for key, value in after.items()}
    expected_changed["G3"]["value"] = 100
    expected_changed["H3"]["value"] = 440
    if (
        alternate != expected_changed
        or restored_cells != after
        or not rules == changed_rules == restored_rules
    ):
        raise ValueError(
            "Deposit recalculation/restoration changed unexpected cells or rules"
        )
    # These are native desktop images; inspect the same cell background in all three.
    colors = [
        Counter(
            Image.open(path).convert("RGB").crop(highlight_box).getdata()
        ).most_common(1)[0][0]
        for path in screenshots
    ]
    if colors != [(255, 242, 204), (255, 255, 255), (255, 242, 204)]:
        raise ValueError("The recorded cell highlight did not clear and return")
    return {
        "scene": "sheets",
        "firstTurnCaptureCount": capture_counts[0],
        "followupCaptureCount": 1,
        "referenceLabels": labels_by_turn[0],
        "followupReferenceLabels": labels_by_turn[1],
        "agentCompleted": True,
        "documentVerified": True,
        "formulasVerified": True,
        "unchangedRowsVerified": True,
        "recalculationVerified": True,
        "conditionalFormatVerified": True,
        "agentToolEvents": len(tools),
        "balanceReadbacks": [540, 440, 540],
        "captureProvider": "windows-uia",
        "captureLimitation": "Accessibility traversal was truncated; the agent read live cells using browser tools.",
    }
