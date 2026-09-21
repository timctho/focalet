#!/usr/bin/env python3
"""Reject unreviewed public demo changes, raw profiles and private media metadata."""

import hashlib
import json
from pathlib import Path
import re
import subprocess

from PIL import Image

ROOT = Path(__file__).resolve().parents[1] / "docs/demos"
ALLOWED_TAGS = {
    "major_brand",
    "minor_version",
    "compatible_brands",
    "encoder",
    "language",
    "handler_name",
    "vendor_id",
}


def probe_media(path):
    # ffprobe does not decode animated WebP on several supported toolchains.
    # Pillow exposes its animation frames and metadata without treating it as
    # a static poster or dropping EXIF/XMP from the privacy check.
    if Path(path).suffix.lower() == ".webp":
        with Image.open(path) as picture:
            if getattr(picture, "is_animated", False):
                private_tags = {
                    name: "present" for name in picture.info
                    if name not in {"loop", "background", "duration", "timestamp"}
                }
                return {
                    "streams": [{"codec_type": "video", "width": picture.width, "height": picture.height}],
                    "format": {"tags": private_tags},
                }
    return json.loads(
        subprocess.check_output(
            [
                "ffprobe",
                "-v",
                "error",
                "-show_entries",
                "format_tags:stream=codec_type,width,height:stream_tags",
                "-of",
                "json",
                str(path),
            ],
            text=True,
            timeout=15,
        )
    )


def verify(directory=ROOT, probe=probe_media):
    manifest = json.loads((directory / "manifest.json").read_text())
    if set(manifest) - {"schemaVersion", "recordedAt", "recordings"}:
        raise ValueError("Unreviewed manifest metadata")
    if manifest.get("schemaVersion") != 1:
        raise ValueError("Unknown demo manifest version")
    declared = set()
    for recording in manifest["recordings"]:
        if set(recording) - {
            "name",
            "buildCommit",
            "platform",
            "display",
            "runtime",
            "response",
            "syntheticSource",
            "sourceKind",
            "audio",
            "review",
            "assets",
        }:
            raise ValueError("Unreviewed recording metadata")
        if not re.fullmatch(r"[0-9a-f]{40}", recording["buildCommit"]):
            raise ValueError("Demo must identify its actual recording build")
        review = recording["review"]
        if set(review) == {"ocrStatus", "rawFramesScanned", "visualReview"}:
            frames_scanned = review["rawFramesScanned"]
        elif set(review) == {"ocrStatus", "exportedFramesScanned", "visualReview"}:
            frames_scanned = review["exportedFramesScanned"]
        else:
            raise ValueError("Unreviewed privacy-review metadata")
        source_kind = recording.get("sourceKind", "synthetic")
        if source_kind not in {"synthetic", "public-product-pages"} or (
            recording["syntheticSource"] is not (source_kind == "synthetic")
        ):
            raise ValueError("Demo source classification is missing or inconsistent")
        if recording["audio"]:
            raise ValueError("Public demos require no recorded audio")
        if (
            review["ocrStatus"] != "no-matches"
            or not isinstance(frames_scanned, int)
            or isinstance(frames_scanned, bool)
            or frames_scanned < 1
            or not review["visualReview"]
        ):
            raise ValueError("Privacy review is incomplete")
        for asset in recording["assets"]:
            if set(asset) != {"file", "bytes", "sha256"}:
                raise ValueError("Unreviewed asset metadata")
            name = asset["file"]
            if (
                Path(name).name != name
                or "/" in name
                or "\\" in name
                or Path(name).suffix not in {".mp4", ".gif", ".webp"}
            ):
                raise ValueError("Only reviewed media basenames are allowed")
            if name in declared:
                raise ValueError("Duplicate public asset")
            declared.add(name)
            path = directory / name
            if path.is_symlink() or not path.is_file():
                raise ValueError("Public assets must be regular files")
            content = path.read_bytes()
            if (
                len(content) != asset["bytes"]
                or hashlib.sha256(content).hexdigest() != asset["sha256"]
            ):
                raise ValueError(f"Reviewed asset changed: {name}")
            metadata = probe(path)
            streams = metadata.get("streams", [])
            if len(streams) != 1 or streams[0].get("codec_type") != "video":
                raise ValueError(f"Unexpected audio or additional tracks: {name}")
            for container in [metadata.get("format", {}), *streams]:
                if set(container.get("tags", {})) - ALLOWED_TAGS:
                    raise ValueError(f"Unreviewed media metadata: {name}")
    actual = {
        str(path.relative_to(directory))
        for path in directory.rglob("*")
        if path.is_file() or path.is_symlink()
    }
    if actual != declared | {"README.md", "manifest.json"}:
        raise ValueError(
            "Unreviewed files in docs/demos; keep profiles, raw frames and logs outside the repo"
        )
    return len(declared)


if __name__ == "__main__":
    print(f"{verify()} reviewed demo assets verified; no extra files or audio tracks.")
