"""Verify actual context handoff and file/data changes before exporting the demo."""

import hashlib
import importlib.util
import json
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location(
    "sample_dashboard", ROOT / "dashboard/app.py"
)
dashboard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dashboard)


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def baseline(workspace):
    return {
        name: sha256(workspace / name)
        for name in (
            "demo.sqlite",
            "error-rate.sql",
            "failed-checkouts.sql",
            "index.html",
        )
    }


def objects_after(text, label):
    decoder = json.JSONDecoder()
    for match in re.finditer(re.escape(label) + r"[^\n]*\n", text):
        value, _ = decoder.raw_decode(text[match.end() :].lstrip())
        yield value


def inline_objects_after(text, label):
    decoder = json.JSONDecoder()
    for match in re.finditer(re.escape(label), text):
        value, _ = decoder.raw_decode(text[match.end() :].lstrip())
        yield value


def verify(session, workspace, before):
    turns = session["thread"]["turns"]
    if not turns or turns[-1]["status"] != "completed":
        raise ValueError("A completed real-agent turn is required")
    items = turns[-1]["items"]
    user = next(item for item in items if item["type"] == "userMessage")
    text = "\n".join(
        item.get("text", "") for item in user["content"] if item["type"] == "text"
    )
    images = [
        item for item in user["content"] if item["type"] in ("image", "localImage")
    ]
    if len(images) != 3 or re.findall(r"User reference \[([A-Z])\]:", text) != [
        "A",
        "B",
        "C",
    ]:
        raise ValueError("The handoff must preserve three ordered A/B/C images")
    regions = list(
        inline_objects_after(text, "Image region alignment and coordinate mapping:")
    )
    sources = list(inline_objects_after(text, "Observation source:"))
    if (
        len(regions) != 3
        or len(sources) != 3
        or text.count("observedAtUtc:") != 3
        or any(
            region.get("status") != "aligned" or not region.get("mapping")
            for region in regions
        )
    ):
        raise ValueError(
            "Source, capture time and verified pixel mapping must reach the agent"
        )
    contexts = list(objects_after(text, "Region context (untrusted observed data):"))
    if len(contexts) != 3 or any(
        context.get("truncated")
        or not any(
            element.get("provider") == "browser-dom" for element in context["elements"]
        )
        for context in contexts
    ):
        raise ValueError("All three selections require untruncated DOM context")
    editors = {
        element.get("nativeIds", {}).get("domId"): element
        for element in contexts[2]["elements"]
        if element.get("role") == "textarea"
    }
    normalize = lambda value: " ".join(value.split())
    for name, editor_id in (
        ("error-rate.sql", "error-query"),
        ("failed-checkouts.sql", "failed-query"),
    ):
        value = editors.get(editor_id, {}).get("value") or ""
        if normalize((ROOT / "dashboard" / name).read_text()) != normalize(value):
            raise ValueError("The raw query was not included as captured text")
    if not any(item["type"] == "agentMessage" for item in items):
        raise ValueError("A real agent response is required")
    tools = [
        item
        for item in items
        if item["type"]
        in ("commandExecution", "fileChange", "mcpToolCall", "dynamicToolCall")
    ]
    if not tools or "demo.sqlite" not in json.dumps(tools):
        raise ValueError("No recorded agent tool use investigated the sample database")
    after = baseline(workspace)
    if before["demo.sqlite"] != after["demo.sqlite"]:
        raise ValueError(
            "The demonstration must fix the metric without changing the source data"
        )
    if before["error-rate.sql"] == after["error-rate.sql"]:
        raise ValueError("The agent did not change the real query file")
    rate, failures = dashboard.dashboard(workspace)["panels"]
    if len(rate["rows"]) != 12 or any(row["error_rate"] != 2.0 for row in rate["rows"]):
        raise ValueError(
            "The final live query does not report the correct checkout rate"
        )
    if any(row["failed"] != 20 or row["total"] != 1000 for row in failures["rows"]):
        raise ValueError("The reference data changed")
    return {
        "captureCount": 3,
        "domContextCount": 3,
        "rawQueriesVerified": 2,
        "fullEditorValues": 2,
        "agentCompleted": True,
        "queryChanged": True,
        "dataVerified": True,
        "capturedElements": sum(len(context["elements"]) for context in contexts),
        "agentToolEvents": len(tools),
        "beforeRate": 10.91,
        "afterRate": 2.0,
    }


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("workspace", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    with args.output.open("x") as output:
        json.dump(baseline(args.workspace.resolve()), output, indent=2)
    print(
        "Saved original synthetic workspace hashes; no data or paths in the baseline."
    )
