#!/usr/bin/env python3
"""Summarize packaged Windows scroll receipts; durations are milliseconds."""

import argparse
import json
import math
from pathlib import Path


def distribution(values):
    values = sorted(values)
    if not values:
        raise ValueError("Missing timing samples")
    return {
        "count": len(values),
        **{f"p{p}Ms": round(values[max(0, math.ceil(len(values) * p / 100) - 1)] / 1000, 3)
           for p in (50, 95, 99)},
        "maxMs": round(values[-1] / 1000, 3),
    }


def summarize(path):
    result = json.loads(Path(path).read_text(encoding="utf-8-sig"))
    scenarios = {}
    for scenario in ("static", "streaming"):
        samples = [sample["data"] for sample in result["samples"] if sample["scenario"] == scenario]
        if not samples:
            raise ValueError(f"Missing {scenario} scenario")
        flat = lambda key: [value for sample in samples for value in sample[key]]
        build, raster = flat("buildUs"), flat("rasterUs")
        busy = [max(ui, gpu) for ui, gpu in zip(build, raster, strict=True)]
        inputs = sum(sample["inputCount"] for sample in samples)
        scenarios[scenario] = {
            "samples": len(samples),
            "inputs": inputs,
            "travelPx": round(sum(sample["travel"] for sample in samples)),
            "build": distribution(build),
            "raster": distribution(raster),
            "totalSpan": distribution(flat("totalUs")),
            "receiptToRaster": distribution(flat("receiptToRasterUs")),
            "receiptTimingCoveragePct": round(100 * len(flat("receiptToRasterUs")) / inputs, 2),
            "framesWithUiOrRasterOver16_7MsPct": round(100 * sum(value > 16667 for value in busy) / len(busy), 2),
            "counts": {key: sum(sample["counts"].get(key, 0) for sample in samples)
                       for key in sorted({key for sample in samples for key in sample["counts"]})},
            "costMs": {key: round(sum(sample["costUs"].get(key, 0) for sample in samples) / 1000, 3)
                       for key in sorted({key for sample in samples for key in sample["costUs"]})},
        }
    return {"source": str(path), "commit": result["packageCommit"], "ready": result["ready"], "scenarios": scenarios}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("results", nargs="+", type=Path)
    args = parser.parse_args()
    print(json.dumps([summarize(path) for path in args.results], indent=2))
