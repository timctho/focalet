"""Inspect workbook values, formulas and appearance in demo readbacks."""

import base64
import io
import posixpath
import re
import xml.etree.ElementTree as ET
import zipfile

NS = {"s": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
REL = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"


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
