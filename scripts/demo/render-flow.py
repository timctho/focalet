#!/usr/bin/env python3
"""Render the explanatory insert; unverified renders carry a storyboard watermark."""

import argparse
import json
from pathlib import Path
import subprocess
import tempfile

from cdp import Browser


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--browser", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--seconds", type=float, default=5)
    parser.add_argument(
        "--scene", choices=("dashboard", "amazon", "sheets"), default="dashboard"
    )
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--evidence", type=Path)
    mode.add_argument("--preview", action="store_true")
    args = parser.parse_args()
    if not 3 <= args.seconds <= 12:
        raise ValueError("The context insert must last between 3 and 12 seconds")
    if args.output.exists():
        raise ValueError("Use a fresh output filename")
    with tempfile.TemporaryDirectory(prefix="zommi-context-flow-") as directory:
        with Browser(
            args.browser, Path(__file__).with_name("context-flow.html").as_uri()
        ) as browser:
            browser.wait("typeof render === 'function'")
            browser.evaluate("setScene(" + json.dumps(args.scene) + ")")
            browser.evaluate("document.fonts.ready.then(() => true)")
            if args.evidence:
                browser.evaluate(
                    "setEvidence("
                    + json.dumps(json.loads(args.evidence.read_text()))
                    + ")"
                )
            for frame in range(round(args.seconds * 24)):
                browser.evaluate(f"render({frame / 24 * 8 / args.seconds})")
                browser.screenshot(Path(directory, f"{frame:05}.png"))
            browser.screenshot(args.output.with_suffix(".png"))
        subprocess.run(
            [
                "ffmpeg",
                "-v",
                "error",
                "-framerate",
                "24",
                "-i",
                str(Path(directory, "%05d.png")),
                "-c:v",
                "libx264",
                "-crf",
                "20",
                "-pix_fmt",
                "yuv420p",
                "-an",
                "-map_metadata",
                "-1",
                "-movflags",
                "+faststart",
                str(args.output),
            ],
            check=True,
        )
    print(
        json.dumps(
            {
                "illustration": str(args.output),
                "seconds": args.seconds,
                "preview": args.preview,
            }
        )
    )


if __name__ == "__main__":
    main()
