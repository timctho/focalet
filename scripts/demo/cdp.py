"""Small driver for an owned, isolated browser used to render demo artwork."""

import base64
import json
from pathlib import Path
import subprocess
import tempfile
import time
from urllib.request import urlopen

import websocket


class Browser:
    def __init__(self, executable, url, width=1920, height=1080):
        self.profile = tempfile.TemporaryDirectory(prefix="zommi-demo-browser-")
        self.log = tempfile.TemporaryFile()
        self.socket = None
        self.sequence = 0
        self.process = subprocess.Popen(
            [
                str(executable),
                "--headless=new",
                "--no-sandbox",
                "--disable-gpu",
                "--no-first-run",
                "--disable-sync",
                "--disable-background-networking",
                "--remote-debugging-port=0",
                f"--user-data-dir={self.profile.name}",
                f"--window-size={width},{height}",
                url,
            ],
            stdout=self.log,
            stderr=self.log,
        )
        try:
            port_file = Path(self.profile.name, "DevToolsActivePort")
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                if self.process.poll() is not None:
                    raise RuntimeError("Demo browser exited during startup")
                if port_file.is_file():
                    lines = port_file.read_text().splitlines()
                    if len(lines) >= 2:
                        break
                time.sleep(0.1)
            else:
                raise TimeoutError("Demo browser did not start CDP")
            with urlopen(
                f"http://127.0.0.1:{lines[0]}/json/list", timeout=5
            ) as response:
                targets = json.load(response)
            target = next(target for target in targets if target["type"] == "page")
            self.socket = websocket.create_connection(
                target["webSocketDebuggerUrl"], timeout=15, suppress_origin=True
            )
            self.call(
                "Emulation.setDeviceMetricsOverride",
                {
                    "width": width,
                    "height": height,
                    "deviceScaleFactor": 1,
                    "mobile": False,
                },
            )
        except BaseException:
            self.close()
            raise

    def call(self, method, params=None):
        self.sequence += 1
        self.socket.send(
            json.dumps({"id": self.sequence, "method": method, "params": params or {}})
        )
        while True:
            result = json.loads(self.socket.recv())
            if result.get("id") != self.sequence:
                continue
            if "error" in result:
                raise RuntimeError(result["error"])
            return result.get("result", {})

    def evaluate(self, expression):
        result = self.call(
            "Runtime.evaluate",
            {"expression": expression, "returnByValue": True, "awaitPromise": True},
        )
        if "exceptionDetails" in result:
            raise RuntimeError(result["exceptionDetails"])
        return result["result"].get("value")

    def wait(self, expression, timeout=20):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.evaluate(expression):
                return
            time.sleep(0.1)
        raise TimeoutError("Demo page did not become ready")

    def screenshot(self, path):
        result = self.call("Page.captureScreenshot", {"format": "png"})
        Path(path).write_bytes(base64.b64decode(result["data"]))

    def close(self):
        if self.socket:
            self.socket.close()
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        self.log.close()
        self.profile.cleanup()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()
