"""Require native product identities and real browser investigation before export."""

import json
import re
from urllib.parse import urlsplit

from dashboard_proof import inline_objects_after, objects_after

PRODUCTS = (
    "https://www.amazon.com/dp/B09TQY97MJ",
    "https://www.amazon.com/dp/B08R6YMVW1",
)
LAPTOP = "https://support.apple.com/en-us/111883"
MANUFACTURER = "https://plugable.com/products/ud-6950pdh"


def canonical(url):
    parts = urlsplit(url)
    return f"{parts.scheme}://{parts.netloc}{parts.path}".rstrip("/")


def browser_values(calls):
    for call in calls:
        if call["tool"] != "evaluate_script":
            continue
        for item in (call.get("result") or {}).get("content", []):
            match = re.search(r"```json\n(.*?)\n```", item.get("text", ""), re.S)
            if match:
                value = json.loads(match[1])
                if isinstance(value, dict):
                    yield value


def verify(session):
    turns = session["thread"]["turns"]
    if len(turns) != 1 or turns[0]["status"] != "completed":
        raise ValueError("A completed real-agent shopping turn is required")
    items = turns[0]["items"]
    user = next(item for item in items if item["type"] == "userMessage")
    text = "\n".join(item.get("text", "") for item in user["content"])
    labels = re.findall(r"User reference \[([A-Z]+)\]:", text)
    if len(labels) == 1:
        return verify_grid(items, user, text, labels)
    if (
        len(labels) != 3
        or len(set(labels)) != 3
        or sum(item["type"] in ("image", "localImage") for item in user["content"]) != 3
    ):
        raise ValueError("Three separate native image references are required")
    regions = list(
        inline_objects_after(text, "Image region alignment and coordinate mapping:")
    )
    if len(regions) != 3 or any(
        region.get("status") != "aligned" for region in regions
    ):
        raise ValueError("Every selected source must be aligned")
    blocks = re.split(r"User reference \[[A-Z]+\]:", text)
    if any(url in blocks[0] for url in (*PRODUCTS, LAPTOP)):
        raise ValueError("The prompt must not supply the source URLs")
    for block, expected in zip(blocks[1:], (*PRODUCTS, LAPTOP)):
        if expected not in block:
            raise ValueError(
                "A captured product or laptop identity is missing or swapped"
            )
    calls = [
        item
        for item in items
        if item["type"] == "mcpToolCall" and item["status"] == "completed"
    ]
    reads = list(browser_values(calls))
    for source in PRODUCTS:
        if not any(
            canonical(value.get("url", "")) == source
            and value.get("product")
            and len(json.dumps(value)) > 1000
            and value.get("features")
            for value in reads
        ):
            raise ValueError(
                "The agent must read additional details from both actual products"
            )
    if not any(
        canonical(value.get("url", "")) == LAPTOP
        and "One external display" in value.get("text", "")
        for value in reads
    ):
        raise ValueError("The laptop display constraint was not checked live")
    if not any(
        canonical(value.get("url", "")) == MANUFACTURER
        and "DisplayLink" in value.get("text", "")
        for value in reads
    ):
        raise ValueError("The manufacturer compatibility source was not read")
    answer = "\n".join(
        item["text"]
        for item in items
        if item["type"] == "agentMessage" and item.get("phase") == "final"
    )
    if not answer:
        answer = next(
            (
                item.get("text", "")
                for item in reversed(items)
                if item["type"] == "agentMessage"
            ),
            "",
        )
    if any(
        value not in answer
        for value in (
            *PRODUCTS,
            LAPTOP,
            MANUFACTURER,
            "DisplayLink",
            "M1",
            "Screen Recording",
            "cables",
            "power adapter",
        )
    ):
        raise ValueError(
            "The final sourced comparison omits a required setup constraint"
        )
    return {
        "scene": "amazon",
        "captureCount": 3,
        "referenceLabels": labels,
        "productLinksVerified": 2,
        "laptopSourceVerified": True,
        "productDetailsRead": 2,
        "manufacturerSourceVerified": True,
        "agentCompleted": True,
        "agentToolEvents": len(calls),
        "captureProvider": "windows-uia",
        "captureLimitation": "The source URLs and native images were captured; the agent read full product details with its browser tools.",
    }


def verify_grid(items, user, text, labels):
    """A single real listing crop must carry all selected candidate identities."""
    if sum(item["type"] in ("image", "localImage") for item in user["content"]) != 1:
        raise ValueError("One native grid image is required")
    regions = list(
        inline_objects_after(text, "Image region alignment and coordinate mapping:")
    )
    contexts = list(objects_after(text, "Region context (untrusted observed data):"))
    if len(regions) != 1 or regions[0].get("status") != "aligned" or len(contexts) != 1:
        raise ValueError("An aligned grid image and its observed context are required")
    elements = contexts[0]["elements"]
    candidates = set()
    for element in elements:
        if element.get("provider") == "browser-dom":
            candidates.update(
                re.findall(r"/dp/([A-Z0-9]{10})", element.get("href") or "")
            )
    if len(candidates) < 3:
        raise ValueError("The one grid crop must carry at least three product links")
    if re.search(r"/dp/[A-Z0-9]{10}", text.split("User reference")[0]):
        raise ValueError("The prompt must not supply candidate URLs")
    calls = [
        i
        for i in items
        if i["type"] == "mcpToolCall" and i.get("status") == "completed"
    ]
    reads = [
        json.dumps(i.get("result", {}))
        for i in calls
        if i["tool"] in ("evaluate_script", "take_snapshot")
    ]
    for candidate in candidates:
        if not any(
            candidate in value
            and len(value) > 1000
            and re.search(r"mac|display|monitor", value, re.I)
            for value in reads
        ):
            raise ValueError(
                "Every captured candidate requires an actual detail-page read"
            )
    answer = next(
        (i.get("text", "") for i in reversed(items) if i["type"] == "agentMessage"), ""
    )
    if not all(candidate in answer for candidate in candidates) or "M1" not in answer:
        raise ValueError(
            "The final comparison must identify and link every selected candidate"
        )
    return {
        "scene": "amazon",
        "scenario": "listing-grid",
        "captureCount": 1,
        "referenceLabels": labels,
        "candidateCount": len(candidates),
        "productLinksVerified": len(candidates),
        "productDetailsRead": len(candidates),
        "agentCompleted": True,
        "agentToolEvents": len(calls),
        "captureProvider": "browser-dom",
        "contextTruncated": contexts[0].get("truncated", False),
        "captureLimitation": "The grid capture retains candidate links; full details are read with the agent's browser tools.",
    }
