"""Gate a real drawing-directed Sheets edit against whole-workbook readbacks."""

import colorsys
import json
import re
from urllib.parse import urlsplit

from dashboard_proof import inline_objects_after
from sheets_layout_proof import inspect


def verify(session, before, after, *, sheet_name, marked_cells):
    """marked_cells comes from a visual review of the actual annotated image."""
    turns = session["thread"]["turns"]
    if len(turns) != 1 or turns[0]["status"] != "completed":
        raise ValueError("One completed drawing-directed request is required")
    source = urlsplit(before["url"])
    later = urlsplit(after["url"])
    if (source.netloc, source.path) != (later.netloc, later.path) or not before["observedAt"] < after["observedAt"]:
        raise ValueError("Ordered readbacks of the same document are required")
    turn = turns[0]
    user = next(item for item in turn["items"] if item["type"] == "userMessage")
    text = "\n".join(item.get("text", "") for item in user["content"])
    prompt, _, context = text.partition("</user_message>")
    annotations = list(inline_objects_after(text, "User-added image annotations (baked into the attached image; source context describes the original app, not these marks):"))
    if (sum(item["type"] in ("image", "localImage") for item in user["content"]) != 1
        or len(annotations) != 1 or annotations[0].get("source") != "user"
        or annotations[0].get("bakedIntoImage") is not True
        or annotations[0].get("strokeCount") != 2
        or {str(tool).lower() for tool in annotations[0].get("tools", [])} != {"arrow"}):
        raise ValueError("The actual attachment must contain two user-drawn arrows")
    if source.path not in context or source.path in prompt or not re.search(r"\barrows\b", prompt, re.I):
        raise ValueError("Drawing and captured document identity must guide the request")
    if re.search(r"\b[A-Z]{1,3}\d+(?::[A-Z]{1,3}\d+)?\b", prompt):
        raise ValueError("Cell addresses must not replace the drawing in the prompt")
    calls = [item for item in turn["items"] if item["type"] == "mcpToolCall" and item["status"] == "completed"]
    pages = {item.get("arguments", {}).get("pageId") for item in calls if source.path in json.dumps(item.get("result", {}))} - {None}
    if not any(item.get("tool") in ("fill", "press_key", "click") and item.get("arguments", {}).get("pageId") in pages for item in calls):
        raise ValueError("Actual agent browser edits of the captured sheet are required")
    if not any(item.get("tool") == "evaluate_script" for item in calls):
        raise ValueError("Actual agent reads are required")
    old, new = inspect(before), inspect(after)
    if set(old) != set(new) or sheet_name not in old:
        raise ValueError("Workbook tabs changed")
    marked = set(marked_cells)
    if not marked or not marked <= set(old[sheet_name]["cells"]):
        raise ValueError("Reviewed drawing targets must be populated cells")
    for name, sheet in old.items():
        updated = new[name]
        if name != sheet_name:
            if sheet != updated:
                raise ValueError("An unrelated tab changed")
            continue
        for field in ("cells", "rules", "widths", "merges", "rows"):
            if sheet[field] != updated[field]:
                raise ValueError("Values, formulas or unrelated layout changed")
        for address in set(sheet["appearance"]) | set(updated["appearance"]):
            previous = sheet["appearance"].get(address)
            current = updated["appearance"].get(address)
            if address not in marked:
                if previous != current:
                    raise ValueError("An unmarked cell changed")
                continue
            if not current or not current["bold"] or not current["solid"] or previous == current:
                raise ValueError("Every marked cell must become bold and yellow")
            color = re.search(r'rgb="(?:FF)?([0-9A-Fa-f]{6})"', current["fill"])
            if not color:
                raise ValueError("Marked fill must have an explicit yellow color")
            rgb = [int(color[1][index:index + 2], 16) / 255 for index in (0, 2, 4)]
            hue, saturation, value = colorsys.rgb_to_hsv(*rgb)
            if not (40 <= hue * 360 <= 65 and 0.1 <= saturation <= 0.8 and value >= 0.9):
                raise ValueError("Marked cells are not pale yellow")
            if previous["fontSize"] != current["fontSize"] or previous["alignment"] != current["alignment"]:
                raise ValueError("Marked cells changed beyond the requested emphasis")
    return {"scene": "sheets", "scenario": "drawing-directed", "captureCount": 1,
            "annotationCount": 2, "agentCompleted": True, "documentVerified": True,
            "markedCellsVerified": len(marked), "unchangedDataVerified": True,
            "unmarkedCellsUnchanged": True, "agentToolEvents": len(calls)}
