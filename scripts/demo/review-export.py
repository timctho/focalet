#!/usr/bin/env python3
"""Decode and OCR every frame of the exact media bytes proposed for publication."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from verify_demo_assets import ALLOWED_TAGS, probe_media


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("media", nargs="+", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--forbid-file", required=True, type=Path)
    parser.add_argument("--tesseract", default="tesseract")
    parser.add_argument("--workers", type=int, choices=range(1, 17), default=6)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    receipts = []
    for index, media in enumerate(args.media):
        content_hash = hashlib.sha256(media.read_bytes()).hexdigest()
        metadata = probe_media(media)
        streams = metadata.get("streams", [])
        if len(streams) != 1 or streams[0].get("codec_type") != "video":
            raise ValueError("Unexpected audio or additional streams")
        if any(
            set(item.get("tags", {})) - ALLOWED_TAGS
            for item in [metadata.get("format", {}), *streams]
        ):
            raise ValueError("Unreviewed media metadata")
        directory = args.output / str(index)
        frames = directory / "frames"
        frames.mkdir(parents=True)
        animated_webp = False
        if media.suffix.lower() == ".webp":
            with Image.open(media) as picture:
                animated_webp = getattr(picture, "is_animated", False)
                if animated_webp:
                    for frame in range(picture.n_frames):
                        picture.seek(frame)
                        picture.convert("RGB").save(frames / f"{frame + 1:06d}.png")
        if not animated_webp:
            subprocess.run(
                [
                    "ffmpeg",
                    "-v",
                    "error",
                    "-i",
                    str(media),
                    "-vsync",
                    "0",
                    str(frames / "%06d.png"),
                ],
                check=True,
            )
        result = subprocess.run(
            [
                sys.executable,
                str(Path(__file__).with_name("review.py")),
                str(directory),
                "--forbid-file",
                str(args.forbid_file),
                "--tesseract",
                args.tesseract,
                "--frame-scope",
                "exported",
                "--workers",
                str(args.workers),
            ],
            check=False,
        )
        if (
            result.returncode not in (0, 1)
            or not (directory / "privacy-scan.json").exists()
        ):
            raise RuntimeError("Export privacy scan did not complete")
        scan = json.loads((directory / "privacy-scan.json").read_text())
        if hashlib.sha256(media.read_bytes()).hexdigest() != content_hash:
            raise ValueError("Media changed during review")
        receipts.append({"file": media.name, "sha256": content_hash, **scan})
    receipt = {
        "scope": "All decoded frames of every specified exported asset",
        "exportedFramesScanned": sum(item["framesScanned"] for item in receipts),
        "status": (
            "no-matches"
            if all(item["status"] == "no-matches" for item in receipts)
            else "needs-review"
        ),
        "assets": receipts,
        "visualReview": False,
    }
    (args.output / "review.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps({key: value for key, value in receipt.items() if key != "assets"}))
    return 0 if receipt["status"] == "no-matches" else 1


if __name__ == "__main__":
    raise SystemExit(main())
