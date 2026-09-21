#!/usr/bin/env python3
"""OCR every frame in a private review directory for accidental private data.

Use with an isolated synthetic recording and visual review, not as a substitute
for either. OCR is imperfect. Raw OCR text is kept outside published assets.
"""

import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import re
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("recording", type=Path)
    parser.add_argument("--tesseract", default="tesseract")
    parser.add_argument("--workers", type=int, choices=range(1, 17), default=6)
    parser.add_argument("--frame-scope", choices=("raw", "exported"), default="raw")
    parser.add_argument(
        "--forbid-file",
        type=Path,
        required=True,
        help="Private, local list of account names/project names to reject; never publish this file",
    )
    args = parser.parse_args()
    forbidden = [
        line.strip().casefold()
        for line in args.forbid_file.read_text().splitlines()
        if line.strip()
    ]
    patterns = [
        re.compile(r"[\w.+-]+@[\w.-]+\.[a-z]{2,}", re.I),
        re.compile(r"(?:[a-z]:\\Users\\(?!Public\b)|/home/|/Users/)", re.I),
        re.compile(r"\b(?:sk-[a-z0-9_-]{16,}|gh[pousr]_[a-z0-9]{16,})", re.I),
    ]
    frames = sorted((args.recording / "frames").glob("*.png"))
    if not frames:
        raise ValueError("No captured frames to review")
    directory = args.recording / "private-ocr"
    directory.mkdir(exist_ok=True)

    def review(frame):
        output = subprocess.check_output(
            [args.tesseract, str(frame), "stdout", "--psm", "11"],
            text=True,
            stderr=subprocess.DEVNULL,
            env=dict(os.environ, OMP_THREAD_LIMIT="1"),
        )
        (directory / (frame.stem + ".txt")).write_text(output)
        folded = output.casefold()
        suspect = any(word in folded for word in forbidden) or any(
            pattern.search(output) for pattern in patterns
        )
        return frame.name if suspect else None

    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        suspects = [name for name in pool.map(review, frames) if name]
    result = {
        "framesScanned": len(frames),
        "suspectFrames": suspects,
        "status": "needs-review" if suspects else "no-matches",
        "scope": f"Every {args.frame_scope} frame; OCR must be combined with visual and source review.",
    }
    (args.recording / "privacy-scan.json").write_text(
        json.dumps(result, indent=2) + "\n"
    )
    print(json.dumps(result))
    return 1 if suspects else 0


if __name__ == "__main__":
    raise SystemExit(main())
