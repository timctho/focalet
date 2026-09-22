"""Require a single spike crop, full query metadata, and real database analysis."""

import importlib.util
import json
from pathlib import Path
import re

from session_evidence import inline_objects_after, objects_after, sha256

ROOT = Path(__file__).parent
spec = importlib.util.spec_from_file_location("latency_sample", ROOT / "latency/app.py")
latency = importlib.util.module_from_spec(spec)
spec.loader.exec_module(latency)


def verify(session, workspace, before):
    turns = session["thread"]["turns"]
    if len(turns) != 1 or turns[0]["status"] != "completed":
        raise ValueError("A completed actual analysis turn is required")
    items = turns[0]["items"]
    user = next(item for item in items if item["type"] == "userMessage")
    text = "\n".join(item.get("text", "") for item in user["content"])
    if sum(item["type"] in ("image", "localImage") for item in user["content"]) != 1:
        raise ValueError("Select only one spike region")
    labels = re.findall(r"User reference \[([A-Z]+)\]:", text)
    regions = list(
        inline_objects_after(text, "Image region alignment and coordinate mapping:")
    )
    contexts = list(objects_after(text, "Region context (untrusted observed data):"))
    if len(labels) != 1 or len(regions) != 1 or regions[0].get("status") != "aligned":
        raise ValueError("An aligned native image and context are required")
    if len(contexts) != 1 or contexts[0].get("truncated"):
        raise ValueError("Untruncated chart DOM context is required")
    elements = contexts[0]["elements"]
    if any(e.get("provider") != "browser-dom" for e in elements):
        raise ValueError("Chart DOM context is required")
    chart = next(
        (e for e in elements if e.get("nativeIds", {}).get("domId") == "latency-chart"),
        {},
    )
    query = (ROOT / "latency/latency.sql").read_text()
    if query not in chart.get("description", ""):
        raise ValueError("Full executed query must arrive in captured chart metadata")
    if chart.get("relation") != "intersects" or any(
        e.get("role") == "textarea" for e in elements
    ):
        raise ValueError("Select part of the chart without selecting Query Inspector")
    buckets = {
        e.get("nativeIds", {}).get("domId"): e
        for e in elements
        if e.get("nativeIds", {}).get("domId", "").startswith("bucket-")
    }
    if set(buckets) != {"bucket-6", "bucket-7", "bucket-8"}:
        raise ValueError("The captured points must identify only the selected spike")
    for number, minute in ((6, "14:30"), (7, "14:35"), (8, "14:40")):
        point = buckets[f"bucket-{number}"]
        if (
            point.get("relation") != "inside"
            or minute not in point.get("name", "")
            or "1450 ms" not in point["name"]
        ):
            raise ValueError("Selected point time and value are missing")
    if "SELECT" in text.split("User reference")[0]:
        raise ValueError("The prompt must not supply the query")
    calls = [
        i
        for i in items
        if i["type"] == "commandExecution"
        and i.get("status") == "completed"
        and i.get("exitCode") == 0
    ]
    evidence = json.dumps(calls)
    if not all(
        value in evidence
        for value in (
            "demo.sqlite",
            "sqlite3.connect",
            "latency.sql",
            "deployments",
            "inventory_ms",
        )
    ):
        raise ValueError("Actual database and deployment analysis is required")
    answer = "\n".join(i.get("text", "") for i in items if i["type"] == "agentMessage")
    if not all(
        value in answer
        for value in (
            "14:30",
            "14:40",
            "14:43",
            "1,200",
            "us-west-2",
            "20",
            "256",
            "1,450",
        )
    ):
        raise ValueError(
            "The recorded answer does not explain this spike with evidence"
        )
    for name, digest in before.items():
        if sha256(workspace / name) != digest:
            raise ValueError("Analysis must preserve the source data and query")
    rows = latency.dashboard(workspace)["rows"]
    if [r["p95_ms"] for r in rows] != [256] * 6 + [1450] * 3 + [256] * 3 or any(
        r["requests"] != 500 for r in rows
    ):
        raise ValueError("Live query no longer matches the captured incident")
    return {
        "scene": "dashboard",
        "scenario": "latency-spike",
        "captureCount": 1,
        "referenceLabels": labels,
        "fullQueryVerified": True,
        "spikeIntervalVerified": True,
        "queryEditorSelected": False,
        "agentCompleted": True,
        "dataVerified": True,
        "agentToolEvents": len(calls),
        "captureProvider": "browser-dom",
        "selectedInterval": "14:30–14:40 UTC",
        "baselineMs": 256,
        "spikeMs": 1450,
    }
