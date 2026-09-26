#!/usr/bin/env python3
"""Record capture replies only from the disposable Wayland acceptance desktop."""

import base64
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading


def main():
    helper = os.environ["ZOMMI_CAPTURE_TRACE_HELPER"]
    if sys.argv[1:] != ["--capture-host"]:
        os.execv(helper, [helper, *sys.argv[1:]])
    output = Path(os.environ["ZOMMI_CAPTURE_TRACE_DIR"])
    output.mkdir(parents=True, exist_ok=True)
    process = subprocess.Popen(
        [helper, *sys.argv[1:]], stdin=subprocess.PIPE, stdout=subprocess.PIPE
    )
    signal.signal(signal.SIGTERM, lambda *_: process.terminate())

    def forward():
        try:
            for line in sys.stdin.buffer:
                process.stdin.write(line)
                process.stdin.flush()
            process.stdin.close()
        except BrokenPipeError:
            pass

    threading.Thread(target=forward, daemon=True).start()
    try:
        for index, line in enumerate(process.stdout):
            message = json.loads(line)
            prefix = f"{os.getpid()}-{index}"
            result = message.get("result", {})
            for image_index, item in enumerate([result, *result.get("frames", [])]):
                url = item.pop("dataUrl", None)
                if url:
                    name = f"{prefix}-{image_index}.png"
                    (output / name).write_bytes(base64.b64decode(url.split(",", 1)[1]))
                    item["imageFile"] = name
            (output / f"{prefix}.json").write_text(json.dumps(message, indent=2))
            sys.stdout.buffer.write(line)
            sys.stdout.buffer.flush()
        return process.wait()
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=5)


if __name__ == "__main__":
    raise SystemExit(main())
