#!/usr/bin/env python3
"""Trim real agent waiting time and insert a clearly labelled context illustration."""

import argparse
import json
import math
from pathlib import Path
import subprocess
import sys
import tempfile

from dashboard_proof import verify


def quoted(path):
    return "'" + str(path.resolve()).replace("'", "'\\''") + "'"


def timeline(metadata):
    marks = metadata["markers"]
    points = [
        marks[key]
        for key in (
            "intro",
            "selection-start",
            "selection-end",
            "sent",
            "response-ready",
            "refresh",
            "end",
        )
    ]
    if any(right <= left for left, right in zip(points, points[1:])):
        raise ValueError("Recording markers are incomplete or out of order")
    before = marks["sent"] + 1.0
    after = max(before, marks["response-ready"] - 3.0)
    if marks["end"] > metadata["duration"]:
        raise ValueError("The recorder stopped before the result was captured")
    return [(0, before), (after, marks["end"])], after - before


def segment(frames, times, start, end, directory, name, crop=None, speed=1):
    if (
        not isinstance(speed, (int, float))
        or not math.isfinite(speed)
        or not 0 < speed <= 16
    ):
        raise ValueError("Playback speed must be finite and between 0 and 16")
    selected = [i for i, time in enumerate(times) if start <= time < end]
    if len(selected) < 2:
        raise ValueError("Missing recorded frames for a required scene")
    lines = []
    for i in selected:
        next_time = times[i + 1] if i + 1 < len(times) else end
        lines += [
            "file " + quoted(frames[i]),
            f"duration {(min(next_time, end) - times[i]) / speed:.6f}",
        ]
    lines.append("file " + quoted(frames[selected[-1]]))
    sequence = directory / (name + ".txt")
    sequence.write_text("\n".join(lines) + "\n")
    output = directory / (name + ".mp4")
    scale = "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2:color=0xeef5fa,setsar=1"
    if crop:
        scale = crop + "," + scale
    subprocess.run(
        [
            "ffmpeg",
            "-v",
            "error",
            "-f",
            "concat",
            "-safe",
            "0",
            "-i",
            str(sequence),
            "-vf",
            scale,
            "-r",
            "24",
            "-c:v",
            "libx264",
            "-crf",
            "20",
            "-pix_fmt",
            "yuv420p",
            "-an",
            "-map_metadata",
            "-1",
            str(output),
        ],
        check=True,
    )
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("recording", type=Path)
    parser.add_argument("--session", type=Path, required=True)
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--browser", required=True)
    parser.add_argument(
        "--output",
        type=Path,
        required=True,
        help="Output stem, initially outside docs/demos",
    )
    args = parser.parse_args()
    if args.output.with_suffix(".mp4").exists():
        raise ValueError("Use a fresh output stem")
    proof = verify(
        json.loads(args.session.read_text()),
        args.workspace.resolve(),
        json.loads(args.baseline.read_text()),
    )
    metadata = json.loads(
        (args.recording / "recording.json").read_text(encoding="utf-8-sig")
    )
    spans, removed = timeline(metadata)
    frames = sorted((args.recording / "frames").glob("*.png"))
    times = metadata["frameTimes"]
    if len(frames) != len(times) or any(b <= a for a, b in zip(times, times[1:])):
        raise ValueError("Raw recording frames/timestamps are incomplete")
    proof_path = args.recording / "context-proof.json"
    proof_path.write_text(json.dumps(proof, indent=2) + "\n")
    with tempfile.TemporaryDirectory(prefix="zommi-dashboard-edit-") as temporary:
        directory = Path(temporary)
        flow = directory / "flow.mp4"
        subprocess.run(
            [
                sys.executable,
                str(Path(__file__).with_name("render-flow.py")),
                "--browser",
                args.browser,
                "--evidence",
                str(proof_path),
                "--output",
                str(flow),
            ],
            check=True,
        )
        beginning = segment(frames, times, *spans[0], directory, "selection")
        # Keep the actual response and refresh, then enlarge the recorded charts
        # so the final values remain legible when the browser covers the chat.
        zoom_at = metadata["markers"]["refresh"] + 2
        if not spans[1][0] < zoom_at < spans[1][1]:
            raise ValueError("The refreshed graph was not held long enough to show")
        ending = segment(
            frames,
            times,
            spans[1][0],
            zoom_at,
            directory,
            "response",
            crop="crop=1120:630:1200:620",
        )
        graph = segment(
            frames,
            times,
            zoom_at,
            spans[1][1],
            directory,
            "live-graph",
            crop="crop=1120:630:0:0",
        )
        sequence = directory / "edit.txt"
        sequence.write_text(
            "\n".join(
                "file " + quoted(path) for path in (beginning, flow, ending, graph)
            )
            + "\n"
        )
        subprocess.run(
            [
                "ffmpeg",
                "-v",
                "error",
                "-f",
                "concat",
                "-safe",
                "0",
                "-i",
                str(sequence),
                "-c",
                "copy",
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
                "-i",
                str(args.output.with_suffix(".mp4")),
                "-filter_complex",
                "fps=8,scale=960:-2:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=3",
                "-an",
                "-map_metadata",
                "-1",
                str(args.output.with_suffix(".gif")),
            ],
            check=True,
        )
        subprocess.run(
            [
                "ffmpeg",
                "-v",
                "error",
                "-i",
                str(frames[-1]),
                "-vf",
                "crop=1120:630:0:0,scale=1600:900",
                "-frames:v",
                "1",
                "-map_metadata",
                "-1",
                str(args.output.parent / (args.output.name + "-poster.webp")),
            ],
            check=True,
        )
    (args.recording / "edit.json").write_text(
        json.dumps(
            {
                "sourceSpans": spans,
                "removedWaitSeconds": removed,
                "illustrationSeconds": 8,
                "scriptedAgentResponses": False,
                "graphZoom": {
                    "sourceSpan": [zoom_at, spans[1][1]],
                    "crop": [0, 0, 1120, 630],
                },
            },
            indent=2,
        )
        + "\n"
    )
    print(
        "Edited actual footage. Review every exported frame and metadata before publication."
    )


if __name__ == "__main__":
    main()
