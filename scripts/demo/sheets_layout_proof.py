"""Verify a two-region, one-turn layout edit against live workbook receipts."""

import base64
import io
import json
import posixpath
import re
import xml.etree.ElementTree as ET
import zipfile
from urllib.parse import urlsplit

from dashboard_proof import inline_objects_after
from sheets_proof import NS, workbook

REL = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"


def table_fills(archive, path, sheet, styles, appearance):
    """Sheets exports Alternating colors as table styles, not direct cell fills."""
    parts = sheet.findall("s:tableParts/s:tablePart", NS)
    if not parts:
        return
    directory, filename = posixpath.split(path)
    relationships = {
        node.attrib["Id"]: posixpath.normpath(directory + "/" + node.attrib["Target"])
        for node in ET.fromstring(
            archive.read(directory + "/_rels/" + filename + ".rels")
        )
    }
    differentials = styles.find("s:dxfs", NS)
    definitions = {
        node.attrib["name"]: node
        for node in styles.findall("s:tableStyles/s:tableStyle", NS)
    }

    def address(value):
        match = re.fullmatch(r"([A-Z]+)(\d+)", value)
        column = 0
        for character in match[1]:
            column = column * 26 + ord(character) - ord("A") + 1
        return column, int(match[2])

    for part in parts:
        table = ET.fromstring(
            archive.read(relationships[part.attrib["{" + REL + "}id"]])
        )
        info = table.find("s:tableStyleInfo", NS)
        if (
            table.get("headerRowCount", "1") != "1"
            or table.get("totalsRowCount", "0") != "0"
        ):
            raise ValueError("Unsupported table header or totals layout")
        definition = definitions[info.attrib["name"]]
        elements = {node.attrib["type"]: node for node in definition}
        if any(node.get("size", "1") != "1" for node in elements.values()):
            raise ValueError("Unsupported multi-row stripe size")
        left, top = address(table.attrib["ref"].split(":")[0])
        right, bottom = address(table.attrib["ref"].split(":")[-1])
        for cell, style in appearance.items():
            column, row = address(cell)
            if not (left <= column <= right and top <= row <= bottom) or style["solid"]:
                continue
            role = (
                "headerRow"
                if row == top
                else ("firstRowStripe" if (row - top) % 2 else "secondRowStripe")
            )
            if row != top and info.get("showRowStripes") != "1":
                continue
            element = elements.get(role)
            if element is None:
                continue
            fill = differentials[int(element.attrib["dxfId"])].find("s:fill", NS)
            if fill is not None:
                style["fill"] = ET.tostring(fill).decode()
                style["solid"] = (
                    fill.find("s:patternFill", NS).get("patternType") == "solid"
                )


def inspect(receipt):
    archive = zipfile.ZipFile(io.BytesIO(base64.b64decode(receipt["xlsx"])))
    book = ET.fromstring(archive.read("xl/workbook.xml"))
    relations = {
        node.attrib["Id"]: posixpath.normpath("xl/" + node.attrib["Target"])
        for node in ET.fromstring(archive.read("xl/_rels/workbook.xml.rels"))
    }
    styles = ET.fromstring(archive.read("xl/styles.xml"))
    fonts = styles.find("s:fonts", NS)
    fills = styles.find("s:fills", NS)
    formats = styles.find("s:cellXfs", NS)
    default_size = (
        float(fonts[0].find("s:sz", NS).get("val"))
        if fonts[0].find("s:sz", NS) is not None
        else 10
    )
    result = {}
    for entry in book.findall("s:sheets/s:sheet", NS):
        path = relations[entry.attrib["{" + REL + "}id"]]
        sheet = ET.fromstring(archive.read(path))
        cells, rules = workbook(receipt, sheet_path=path)
        # Formatting a blank cell must not count as adding or removing data.
        cells = {
            key: value
            for key, value in cells.items()
            if value["value"] is not None or value["formula"] is not None
        }
        appearance = {}
        for cell in sheet.findall("s:sheetData/s:row/s:c", NS):
            fmt = formats[int(cell.get("s", "0"))]
            font = fonts[int(fmt.get("fontId", "0"))]
            fill = fills[int(fmt.get("fillId", "0"))]
            appearance[cell.attrib["r"]] = {
                "bold": font.find("s:b", NS) is not None,
                "fontSize": (
                    float(font.find("s:sz", NS).get("val"))
                    if font.find("s:sz", NS) is not None
                    else default_size
                ),
                "font": ET.tostring(font).decode(),
                "fill": ET.tostring(fill).decode(),
                "solid": fill.find("s:patternFill", NS).get("patternType") == "solid",
                "alignment": (
                    ET.tostring(fmt.find("s:alignment", NS)).decode()
                    if fmt.find("s:alignment", NS) is not None
                    else ""
                ),
            }
        table_fills(archive, path, sheet, styles, appearance)
        defaults = sheet.find("s:sheetFormatPr", NS)
        widths = [float(defaults.get("defaultColWidth", "8.43"))] * 5
        for col in sheet.findall("s:cols/s:col", NS):
            for index in range(int(col.get("min")), min(int(col.get("max")), 5) + 1):
                widths[index - 1] = float(col.get("width", widths[index - 1]))
        result[entry.attrib["name"]] = {
            "cells": cells,
            "rules": rules,
            "appearance": appearance,
            "widths": widths,
            "merges": sorted(
                cell.attrib["ref"]
                for cell in sheet.findall("s:mergeCells/s:mergeCell", NS)
            ),
            "rows": {
                row.attrib["r"]: row.get("ht", defaults.get("defaultRowHeight", "15"))
                for row in sheet.findall("s:sheetData/s:row", NS)
            },
        }
    return result


def verify(
    session, before, after, *, scenario="two-region-layout", sheet_name="Event overview"
):
    if scenario not in ("two-region-layout", "contrasting-layouts"):
        raise ValueError("Unknown sheet layout scenario")
    turns = session["thread"]["turns"]
    if len(turns) != 1 or turns[0]["status"] != "completed":
        raise ValueError("One completed layout request is required")
    source = urlsplit(before["url"])
    if (source.netloc, source.path) != (
        urlsplit(after["url"]).netloc,
        urlsplit(after["url"]).path,
    ) or not before["observedAt"] < after["observedAt"]:
        raise ValueError("Ordered readbacks of the same document are required")
    turn = turns[0]
    user = next(item for item in turn["items"] if item["type"] == "userMessage")
    text = "\n".join(item.get("text", "") for item in user["content"])
    labels = re.findall(r"User reference \[([A-Z]+)\]:", text)
    regions = list(
        inline_objects_after(text, "Image region alignment and coordinate mapping:")
    )
    if (
        len(labels) != 2
        or len(set(labels)) != 2
        or sum(item["type"] in ("image", "localImage") for item in user["content"]) != 2
        or len(regions) != 2
        or any(region.get("status") != "aligned" for region in regions)
    ):
        raise ValueError("Two distinct aligned native selections are required")
    prompt, _, context = text.partition("</user_message>")
    if source.path not in context or source.path in prompt:
        raise ValueError("Document identity must arrive through captured context")
    if scenario == "contrasting-layouts":
        if not all(re.search(r"\b" + label + r"\b", prompt) for label in labels):
            raise ValueError(
                "The request must explicitly identify both native references"
            )
        bounds = [region.get("screenBounds", {}) for region in regions]
        if (
            not all(bound.get("height", 0) > 0 for bound in bounds)
            or not bounds[0]["y"] + bounds[0]["height"] < bounds[1]["y"]
        ):
            raise ValueError("Capture order must identify the upper and lower blocks")
    calls = [
        item
        for item in turn["items"]
        if item["type"] == "mcpToolCall" and item["status"] == "completed"
    ]
    pages = {
        item.get("arguments", {}).get("pageId")
        for item in calls
        if source.path in json.dumps(item.get("result", {}))
    } - {None}
    if not any(
        item["tool"] in ("fill", "press_key", "click")
        and item.get("arguments", {}).get("pageId") in pages
        for item in calls
    ) or not any(item["tool"] == "evaluate_script" for item in calls):
        raise ValueError("Actual browser edits and live reads are required")
    original, edited = inspect(before), inspect(after)
    if original.keys() != edited.keys():
        raise ValueError("Unrequested sheets were added or removed")
    for name in original:
        if original[name]["cells"] != edited[name]["cells"]:
            raise ValueError("Source values or formulas changed")
        if name != sheet_name and original[name] != edited[name]:
            raise ValueError("An unrelated sheet changed")
    old, new = original[sheet_name], edited[sheet_name]
    if scenario == "two-region-layout" and not any(
        b > a * 1.2 for a, b in zip(old["widths"], new["widths"])
    ):
        raise ValueError("No meaningful column layout change was verified")
    for title, header, body in ((1, 2, 3), (11, 12, 13)):
        if not all(
            new["appearance"].get(f"{col}{header}", {}).get("bold")
            and new["appearance"][f"{col}{header}"]["solid"]
            for col in "ABCDE"
        ):
            raise ValueError("Both blocks need visibly styled headers")
        if new["appearance"].get(f"A{title}") == old["appearance"].get(f"A{title}"):
            raise ValueError("Both section titles must change visually")
        fills = [new["appearance"][f"A{row}"]["fill"] for row in range(body, body + 5)]
        if scenario == "two-region-layout" and not (
            fills[0] == fills[2] == fills[4] and fills[1] == fills[3] != fills[0]
        ):
            raise ValueError("Both blocks need verified alternating row fills")
    if scenario == "contrasting-layouts":
        verify_contrast(new)
    return {
        "scene": "sheets",
        "scenario": scenario,
        "captureCount": 2,
        "referenceLabels": labels,
        "agentCompleted": True,
        "documentVerified": True,
        "layoutVerified": True,
        "blocksFormatted": 2,
        "unchangedDataVerified": True,
        "agentToolEvents": len(calls),
        **(
            {"referenceStylesVerified": True}
            if scenario == "contrasting-layouts"
            else {}
        ),
    }


def verify_contrast(sheet):
    """Require the requested style on the correct block, not merely two colors."""

    def rgb(address):
        fill = ET.fromstring(sheet["appearance"][address]["fill"])
        color = fill.find("s:patternFill/s:fgColor", NS)
        value = color.get("rgb", "") if color is not None else ""
        if not re.fullmatch(r"[A-Fa-f0-9]{8}", value):
            raise ValueError("Explicit header colors are required")
        return tuple(int(value[i : i + 2], 16) for i in (2, 4, 6))

    for column in "ABCDE":
        red, green, blue = rgb(f"{column}2")
        if not (blue > red + 40 and blue > green + 15 and red + green + blue < 440):
            raise ValueError("The upper reference must have navy headers")
        red, green, blue = rgb(f"{column}12")
        if not (red > green + 25 and green > blue + 25 and red >= 150):
            raise ValueError("The lower reference must have orange headers")
    upper_heights = [float(sheet["rows"][str(row)]) for row in range(3, 8)]
    lower_heights = [float(sheet["rows"][str(row)]) for row in range(13, 18)]
    upper_fonts = [
        sheet["appearance"][f"{column}{row}"]["fontSize"]
        for row in range(3, 8)
        for column in "ABCDE"
    ]
    lower_fonts = [
        sheet["appearance"][f"{column}{row}"]["fontSize"]
        for row in range(13, 18)
        for column in "ABCDE"
    ]
    if min(lower_heights) < max(upper_heights) * 1.25 or min(lower_fonts) <= max(
        upper_fonts
    ):
        raise ValueError("The lower reference needs taller rows and larger text")
