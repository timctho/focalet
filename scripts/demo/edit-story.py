#!/usr/bin/env python3
"""Apply a reviewed edit list to actual frames, with an evidence-backed insert."""

import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile

from amazon_proof import verify_product_selections
from latency_proof import verify as verify_latency

import media_edit as editor


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("recording", type=Path)
    parser.add_argument("--cut", required=True, type=Path)
    parser.add_argument("--browser", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    cut = json.loads(args.cut.read_text())

    def read(path):
        return json.loads(path.read_text(encoding="utf-8-sig"))

    session = read(args.recording / "private-session.json")
    if cut["scene"] == "amazon":
        proof = verify_product_selections(session, cut["productIds"])
    elif cut["scene"] == "dashboard":
        proof = verify_latency(
            session, Path(cut["workspace"]), read(args.recording / "baseline.json")
        )
    else:
        raise ValueError("This scene requires an implemented evidence verifier")
    metadata = read(args.recording / "recording.json")
    frames = sorted((args.recording / "frames").glob("*.png"))
    times = metadata["frameTimes"]
    if len(frames) != len(times) or any(b <= a for a, b in zip(times, times[1:])):
        raise ValueError("Recording frames and timestamps are incomplete")
    sources = {"main": (frames, times, metadata)}
    if cut.get("additionalRecordings"):
        raise ValueError("Selection and result must belong to the main recording")
    previous_end, flow_count = {}, 0
    for item in cut["segments"]:
        if item.get("flow"):
            flow_count += 1
            continue
        start, end = item["span"]
        name = item.get("recording", "main")
        if not previous_end.get(name, 0) <= start < end <= sources[name][2]["duration"]:
            raise ValueError("Source spans must preserve actual chronology")
        previous_end[name] = end
    if flow_count != 1:
        raise ValueError("One explanatory insert is required")
    poster_frame = frames[-1]
    if "posterTime" in cut:
        moment = cut["posterTime"]
        if not any(
            item.get("recording", "main") == "main"
            and not item.get("flow")
            and item["span"][0] <= moment < item["span"][1]
            for item in cut["segments"]
        ):
            raise ValueError("The poster must come from a reviewed source span")
        poster_frame = frames[
            min(range(len(times)), key=lambda i: abs(times[i] - moment))
        ]
    for suffix in (".mp4", ".gif"):
        if args.output.with_suffix(suffix).exists():
            raise ValueError("Use a fresh output stem")
    with tempfile.TemporaryDirectory(prefix="zommi-story-edit-") as temporary:
        directory = Path(temporary)
        evidence = directory / "proof.json"
        evidence.write_text(json.dumps(proof))
        flow = directory / "flow.mp4"
        subprocess.run(
            [
                sys.executable,
                str(Path(__file__).with_name("render-flow.py")),
                "--scene",
                cut["scene"],
                "--seconds",
                str(cut.get("flowSeconds", 5)),
                "--browser",
                args.browser,
                "--evidence",
                str(evidence),
                "--output",
                str(flow),
            ],
            check=True,
        )
        segments = []
        for index, item in enumerate(cut["segments"]):
            if item.get("flow"):
                segments.append(flow)
                continue
            crop = item.get("crop")
            selected_frames, selected_times, _ = sources[item.get("recording", "main")]
            segments.append(
                editor.segment(
                    selected_frames,
                    selected_times,
                    *item["span"],
                    directory,
                    str(index),
                    crop=crop,
                    speed=item.get("speed", 1),
                )
            )
        sequence = directory / "sequence.txt"
        sequence.write_text(
            "\n".join("file " + editor.quoted(path) for path in segments) + "\n"
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
                str(poster_frame),
                "-vf",
                cut["posterCrop"] + ",scale=1600:-2",
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
            {"cut": cut, "proof": proof, "scriptedAgentResponses": False}, indent=2
        )
        + "\n"
    )
    print("Edited real footage. Export privacy and visual review remain required.")


if __name__ == "__main__":
    main()
