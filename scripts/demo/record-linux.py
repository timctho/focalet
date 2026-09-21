#!/usr/bin/env python3
"""Record the shipped Linux app on an isolated X11 desktop with synthetic content.

Run inside dbus-run-session and xvfb-run. The result is a real native-app
recording on a virtual display, not evidence of physical Windows capture.
"""

import argparse
import ctypes
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location(
    "x11_acceptance", ROOT / "scripts/accept-linux-x11.py"
)
x11_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(x11_module)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--browser", type=Path, required=True)
    parser.add_argument("--agent-executable", required=True)
    parser.add_argument("--workspace", default="/tmp/zommi-demo-workspace")
    parser.add_argument("--scene", choices=["compare", "error"], default="compare")
    parser.add_argument("--send-prompt", action="store_true")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False, mode=0o700)
    workspace = Path(args.workspace)
    workspace.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            sys.executable,
            str(Path(__file__).with_name("prepare.py")),
            "--package",
            str(args.package),
            "--profile",
            str(args.output / "profile"),
            "--workspace",
            str(workspace),
            "--agent-executable",
            args.agent_executable,
        ],
        check=True,
    )
    environment = dict(
        os.environ,
        **json.loads((args.output / "profile/demo-environment.json").read_text()),
    )
    environment["ZOMMI_ACCEPTANCE_LOG"] = str(args.output / "private-desktop.jsonl")
    environment["LIBGL_ALWAYS_SOFTWARE"] = "1"
    environment["GDK_BACKEND"] = "x11"
    environment["XDG_SESSION_TYPE"] = "x11"
    environment.pop("WAYLAND_DISPLAY", None)
    x11 = x11_module.X11()
    x11.lib.XMoveResizeWindow.argtypes = [
        ctypes.c_void_p,
        ctypes.c_ulong,
        ctypes.c_int,
        ctypes.c_int,
        ctypes.c_uint,
        ctypes.c_uint,
    ]
    x11.lib.XRaiseWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
    browser = app = recorder = None

    def move(window, x, y, width, height):
        x11.lib.XMoveResizeWindow(x11.display, window, x, y, width, height)
        x11.lib.XRaiseWindow(x11.display, window)
        x11.lib.XSync(x11.display, False)

    def screenshot(name):
        subprocess.run(
            [
                "ffmpeg",
                "-v",
                "error",
                "-y",
                "-f",
                "x11grab",
                "-video_size",
                "2000x1120",
                "-i",
                os.environ["DISPLAY"],
                "-frames:v",
                "1",
                str(args.output / name),
            ],
            check=True,
        )

    try:
        with (args.output / "private-browser.log").open("w") as log:
            browser = subprocess.Popen(
                [
                    str(args.browser),
                    "--no-sandbox",
                    "--disable-gpu",
                    "--no-first-run",
                    "--disable-sync",
                    "--disable-background-networking",
                    "--no-default-browser-check",
                    "--force-device-scale-factor=1",
                    "--disable-features=ChromeForTestingInfoBar",
                    "--kiosk",
                    "--user-data-dir=" + str(args.output / "browser"),
                    Path(__file__).with_name("fixture.html").as_uri()
                    + "?scene="
                    + args.scene,
                ],
                stdout=log,
                stderr=log,
            )
        source = x11_module.wait_until(
            "sample browser",
            lambda: next(
                (
                    window
                    for window in x11.children(x11.root)
                    if "Zommi sample workspace" in x11.title(window)
                ),
                None,
            ),
        )
        move(source, 0, 0, 2000, 1120)
        with (args.output / "private-app.log").open("w") as log:
            app = subprocess.Popen(
                [str(args.package / "zommi")], env=environment, stdout=log, stderr=log
            )
        window = x11_module.wait_until(
            "native app",
            lambda: next(
                (
                    candidate
                    for candidate in x11.children(x11.root)
                    if x11.pid(candidate) == app.pid and x11.title(candidate) == "Zommi"
                ),
                None,
            ),
            30,
        )
        x11_module.wait_until(
            "visible native app",
            lambda: x11.attributes(window).map_state == x11_module.IS_VIEWABLE,
            30,
        )
        move(window, 1120, 60, 850, 1000)
        x11.focus(window)
        time.sleep(6)
        # Close the sidebar before any frame becomes a public recording.
        x11.click_point((1150, 92))
        time.sleep(1)
        screenshot("inspection.png")
        print(
            "Inspection ready. Create record.ready after reviewing this actual desktop.",
            flush=True,
        )
        x11_module.wait_until(
            "recording approval marker",
            lambda: (args.output / "record.ready").exists(),
            300,
        )
        recorder = subprocess.Popen(
            [
                "ffmpeg",
                "-v",
                "error",
                "-y",
                "-f",
                "x11grab",
                "-framerate",
                "12",
                "-video_size",
                "2000x1120",
                "-draw_mouse",
                "1",
                "-i",
                os.environ["DISPLAY"],
                "-c:v",
                "libx264",
                "-preset",
                "ultrafast",
                "-crf",
                "18",
                "-pix_fmt",
                "yuv420p",
                "-an",
                "-map_metadata",
                "-1",
                str(args.output / "raw.mp4"),
            ],
            stdin=subprocess.PIPE,
        )
        started = time.monotonic()
        time.sleep(1.5)
        x11.send_shortcut(shift=False)
        time.sleep(1.5)
        start, end = (
            ((54, 356), (1046, 816))
            if args.scene == "compare"
            else ((54, 356), (895, 852))
        )
        x11.xtest.XTestFakeMotionEvent(x11.display, x11.screen, *start, 0)
        x11.xtest.XTestFakeButtonEvent(x11.display, 1, True, 0)
        for step in range(1, 31):
            x11.xtest.XTestFakeMotionEvent(
                x11.display,
                x11.screen,
                int(start[0] + (end[0] - start[0]) * step / 30),
                int(start[1] + (end[1] - start[1]) * step / 30),
                0,
            )
            x11.lib.XSync(x11.display, False)
            time.sleep(0.03)
        x11.xtest.XTestFakeButtonEvent(x11.display, 1, False, 0)
        x11.lib.XSync(x11.display, False)
        time.sleep(2)
        move(window, 1120, 60, 850, 1000)
        x11.focus(window)
        x11.click_point((1500, 1022))
        time.sleep(0.75)
        prompt = (
            "which plan is cheaper for six seats? include the annual total."
            if args.scene == "compare"
            else "what failed and how do i fix it? two bullets only."
        )
        shift = x11.lib.XKeysymToKeycode(x11.display, 0xFFE1)
        for character in prompt:
            shifted = character == "?"
            if shifted:
                x11.xtest.XTestFakeKeyEvent(x11.display, shift, True, 0)
            x11.send_key(ord(character))
            if shifted:
                x11.xtest.XTestFakeKeyEvent(x11.display, shift, False, 0)
            x11.lib.XSync(x11.display, False)
            time.sleep(0.04)
        time.sleep(2)
        if args.send_prompt:
            x11.send_key(0xFF0D)
            time.sleep(24)
        screenshot("end.png")
        recorder.communicate(b"q", timeout=10)
        if recorder.returncode:
            raise RuntimeError("Native desktop recorder failed")
        manifest = json.loads((args.package / "release-manifest.json").read_text())
        (args.output / "recording.json").write_text(
            json.dumps(
                {
                    "scene": args.scene,
                    "gitCommit": manifest["gitCommit"],
                    "capture": "Linux native app on isolated X11 virtual display",
                    "syntheticSource": True,
                    "realRuntime": "Codex",
                    "promptSent": args.send_prompt,
                    "audio": False,
                    "duration": time.monotonic() - started,
                },
                indent=2,
            )
        )
        print(
            "Recorded real native application frames. Privacy review is still required.",
            flush=True,
        )
    finally:
        for process in (recorder, app, browser):
            if process is not None and process.poll() is None:
                x11_module.stop_process(process)
        x11.close()


if __name__ == "__main__":
    main()
