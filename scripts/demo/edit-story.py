#!/usr/bin/env python3
"""Apply a reviewed edit list to actual frames, with an evidence-backed insert."""

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile

from sheets_proof import verify as verify_sheets
from sheets_layout_proof import verify as verify_sheets_layout
from amazon_proof import MANUFACTURER, verify as verify_amazon
from latency_proof import verify as verify_latency

spec = importlib.util.spec_from_file_location(
    "dashboard_edit", Path(__file__).with_name("edit-dashboard.py")
)
editor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(editor)


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
    if cut["scene"] == "sheets" and cut.get("scenario") in (
        "two-region-layout",
        "contrasting-layouts",
    ):
        if cut.get("additionalRecordings"):
            raise ValueError("The layout result must belong to the main take")
        proof = verify_sheets_layout(
            session,
            read(args.cut.parent / "sheets-before-export.json"),
            read(args.cut.parent / "sheets-after-export.json"),
            scenario=cut["scenario"],
            sheet_name=cut.get("sheetName", "Event overview"),
        )
    elif cut["scene"] == "sheets":
        verification_root = Path(cut.get("verificationRecording", args.recording))
        if verification_root.resolve() != args.recording.resolve() and not any(
            Path(path).resolve() == verification_root.resolve()
            for path in cut.get("additionalRecordings", {}).values()
        ):
            raise ValueError(
                "The verification recording must be declared and identified"
            )
        sheet_receipts = [
            read(args.cut.parent / f"sheets-{name}-export.json")
            for name in ("final", "changed", "restored")
        ]
        proof = verify_sheets(
            session,
            *sheet_receipts,
            [
                verification_root / name
                for name in ("result.png", "deposit-changed.png", "end.png")
            ],
            capture_counts=tuple(cut.get("captureCounts", [2, 1])),
            highlight_box=tuple(cut.get("highlightBox", [1005, 386, 1130, 410])),
        )
    elif cut["scene"] == "amazon":
        proof = verify_amazon(session)
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
    for name, path in cut.get("additionalRecordings", {}).items():
        if name == "main":
            raise ValueError("Cannot replace the main recording")
        extra = Path(path)
        extra_metadata = read(extra / "recording.json")
        amazon_source = (
            cut["scene"] == "amazon"
            and extra_metadata.get("scene") == "amazon-source-check"
            and extra_metadata.get("source") == MANUFACTURER
        )
        sheet_verification = (
            cut["scene"] == "sheets"
            and extra.resolve() == verification_root.resolve()
            and extra_metadata.get("scene") == "sheets-recalculation"
            and extra_metadata.get("sourceDocumentSha256")
            == hashlib.sha256(sheet_receipts[0]["url"].encode()).hexdigest()
        )
        if not (amazon_source or sheet_verification):
            raise ValueError(
                "Additional footage must identify the verified source check"
            )
        extra_frames = sorted((extra / "frames").glob("*.png"))
        extra_times = extra_metadata["frameTimes"]
        if len(extra_frames) != len(extra_times) or any(
            b <= a for a, b in zip(extra_times, extra_times[1:])
        ):
            raise ValueError("Additional native frames/timestamps are incomplete")
        if extra_metadata.get("sameCompletedAgentSession") != session["thread"]["id"]:
            raise ValueError(
                "Source check must identify the same completed agent session"
            )
        sources[name] = extra_frames, extra_times, extra_metadata
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
            if item.get("waitTrimmed"):
                crop += ",drawbox=x=0:y=0:w=iw:h=50:color=0x123a30:t=fill,drawtext=text='Follow-up wait trimmed':x=24:y=12:fontsize=24:fontcolor=white"
            if item.get("sourceCheck"):
                crop += ",drawbox=x=0:y=0:w=iw:h=54:color=0x123a30:t=fill,drawtext=text='Cited manufacturer page - separate live source check':x=24:y=16:fontsize=24:fontcolor=white"
            if item.get("recalculationCheck") or (
                cut["scene"] == "sheets" and item.get("recording", "main") != "main"
            ):
                if cut["scene"] != "sheets" or item.get("recording", "main") == "main":
                    raise ValueError(
                        "Recalculation label requires the verified source recording"
                    )
                crop += ",drawbox=x=0:y=0:w=iw:h=38:color=0x123a30:t=fill,drawtext=text='Live recalculation - separately recorded check':x=18:y=9:fontsize=18:fontcolor=white"
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
