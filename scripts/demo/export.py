#!/usr/bin/env python3
"""Export a silent desktop recording, preserving capture timing and stripping metadata."""

import argparse
import json
from pathlib import Path
import subprocess
import tempfile

from PIL import Image


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("recording", type=Path)
    parser.add_argument(
        "output", type=Path, help="Output stem; writes .mp4, .gif and -poster.webp"
    )
    args = parser.parse_args()
    metadata = json.loads(
        (args.recording / "recording.json").read_text(encoding="utf-8-sig")
    )
    raw_video = args.recording / "raw.mp4"
    frames = sorted((args.recording / "frames").glob("*.png"))
    times = metadata.get("frameTimes", [])
    if not raw_video.exists() and (len(frames) != len(times) or len(frames) < 2):
        raise ValueError("Incomplete recording")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="zommi-demo-export-") as directory:
        if raw_video.exists():
            input_args = ["-i", str(raw_video)]
            # Remove browser chrome, retaining the entire native app and source.
            filters = "crop=iw:ih-60:0:60,scale=1600:-2:flags=lanczos"
        else:
            sequence = Path(directory, "frames.txt")
            lines = []
            for index, frame in enumerate(frames):
                escaped = str(frame.resolve()).replace("'", "'\\''")
                end = (
                    times[index + 1] if index + 1 < len(times) else metadata["duration"]
                )
                lines += [
                    f"file '{escaped}'",
                    f"duration {max(0.001, end - times[index]):.6f}",
                ]
            lines += [lines[-2]]
            sequence.write_text("\n".join(lines) + "\n")
            input_args = ["-f", "concat", "-safe", "0", "-i", str(sequence)]
            filters = "scale=1600:-2:flags=lanczos"
        subprocess.run(
            [
                "ffmpeg",
                "-v",
                "error",
                "-y",
                *input_args,
                "-vf",
                filters,
                "-r",
                "24",
                "-c:v",
                "libx264",
                "-crf",
                "22",
                "-pix_fmt",
                "yuv420p",
                "-an",
                "-map_metadata",
                "-1",
                "-movflags",
                "+faststart",
                str(args.output.with_suffix(".mp4")),
            ],
            check=True,
        )
        subprocess.run(
            [
                "ffmpeg",
                "-v",
                "error",
                "-y",
                "-i",
                str(args.output.with_suffix(".mp4")),
                "-t",
                "24",
                "-filter_complex",
                "fps=8,scale=960:-2:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=3",
                "-an",
                "-map_metadata",
                "-1",
                str(args.output.with_suffix(".gif")),
            ],
            check=True,
        )
    poster = Image.open(args.recording / "end.png").convert("RGB")
    if raw_video.exists():
        poster = poster.crop((0, 60, poster.width, poster.height))
    poster.thumbnail((1600, 1600))
    poster.save(args.output.parent / (args.output.name + "-poster.webp"), quality=88)
    print(
        "Exported silent MP4, preview GIF and poster. Review frames before committing."
    )


if __name__ == "__main__":
    main()
