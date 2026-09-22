"""Encode reviewed frame spans while retaining their recorded timing."""

import math
import subprocess


def quoted(path):
    return "'" + str(path.resolve()).replace("'", "'\\''") + "'"


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
