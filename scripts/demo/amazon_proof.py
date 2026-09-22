"""Require native product identities and real browser investigation before export."""

import json
import re
from urllib.parse import urlsplit

from session_evidence import inline_objects_after, objects_after

def is_product_page(url, product_id):
    if url.startswith("https://r.jina.ai/https://"):
        url = url.removeprefix("https://r.jina.ai/")
    parts = urlsplit(url)
    return parts.scheme in ("http", "https") and parts.hostname in ("amazon.com", "www.amazon.com") and bool(
        re.search(rf"/dp/{product_id}(?:/|$)", parts.path)
    )


def verify_product_selections(session, product_ids):
    """Bind three separate native crops to three actually investigated products."""
    if len(product_ids) != 3 or len(set(product_ids)) != 3 or any(
        not re.fullmatch(r"[A-Z0-9]{10}", value) for value in product_ids
    ):
        raise ValueError("Three distinct expected product identities are required")
    turns = session["thread"]["turns"]
    if len(turns) != 1 or turns[0]["status"] != "completed":
        raise ValueError("A completed real-agent shopping turn is required")
    items = turns[0]["items"]
    user = next(item for item in items if item["type"] == "userMessage")
    text = "\n".join(item.get("text", "") for item in user["content"])
    labels = re.findall(r"User reference \[([A-Z]+)\]:", text)
    regions = list(inline_objects_after(text, "Image region alignment and coordinate mapping:"))
    contexts = list(objects_after(text, "Region context (untrusted observed data):"))
    if (
        len(labels) != 3 or len(set(labels)) != 3
        or sum(item["type"] in ("image", "localImage") for item in user["content"]) != 3
        or len(regions) != 3 or len(contexts) != 3
        or any(region.get("status") != "aligned" for region in regions)
    ):
        raise ValueError("Three separate aligned native product images and contexts are required")
    if re.search(r"/dp/[A-Z0-9]{10}", text.split("User reference")[0]):
        raise ValueError("The prompt must not supply product URLs")
    for context, expected in zip(contexts, product_ids):
        captured = {
            asin
            for element in context["elements"]
            if element.get("provider") == "browser-dom"
            for asin in re.findall(r"/dp/([A-Z0-9]{10})", element.get("href") or "")
        }
        if captured != {expected}:
            raise ValueError("Each native selection must identify exactly its own product")
    calls = [item for item in items if item["type"] == "mcpToolCall" and item.get("status") == "completed"]
    reads = [dict(value, readMethod="browser") for value in browser_values(calls)]
    for call in calls:
        if call["tool"] != "take_snapshot":
            continue
        for item in (call.get("result") or {}).get("content", []):
            body = item.get("text", "")
            root = re.search(r'RootWebArea[^\n]*url="([^"]+)"', body)
            if root:
                reads.append({"url": root[1], "text": body, "readMethod": "browser"})
    commands = [item for item in items if item["type"] == "commandExecution"
                and item.get("status") == "completed" and item.get("exitCode") == 0]
    for command in commands:
        if "urllib.request" not in command.get("command", ""):
            continue
        for line in command.get("aggregatedOutput", "").splitlines():
            try:
                value = json.loads(line)
            except ValueError:
                continue
            if not isinstance(value, dict) or "error" in value or not value.get("url"):
                continue
            # Retain the executed request and its result, not a maintainer-supplied receipt.
            if value["url"] not in command["command"]:
                continue
            method = "text-reader" if value["url"].startswith("https://r.jina.ai/") else "http"
            reads.append(dict(value, readMethod=method))
    methods = []
    for expected in product_ids:
        detail = next((value for value in reads if is_product_page(value.get("url", ""), expected)
            and len(json.dumps(value)) > 1000
            and re.search(r"mac|display|monitor", json.dumps(value), re.I)), None)
        if detail is None:
            raise ValueError("Every selected product needs an actual detail-page read")
        methods.append(detail["readMethod"])
    answer = next((item.get("text", "") for item in reversed(items) if item["type"] == "agentMessage"), "")
    if not all(f"/dp/{product}" in answer for product in product_ids) or "M1" not in answer:
        raise ValueError("The final comparison must link all three selected products")
    return {
        "scene": "amazon", "scenario": "three-product-selections",
        "captureCount": 3, "candidateCount": 3, "referenceLabels": labels,
        "productIds": list(product_ids), "productLinksVerified": 3,
        "productDetailsRead": 3, "agentCompleted": True,
        "agentToolEvents": len(calls) + len(commands), "captureProvider": "browser-dom",
        "productReadMethods": methods,
        "contextTruncated": any(context.get("truncated", False) for context in contexts),
        "captureLimitation": "Each crop carries one product identity; the agent retrieves additional product details with its own web tools.",
    }


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
