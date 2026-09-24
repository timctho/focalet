#!/usr/bin/env python3
"""Exercise real GNOME 46, portals, PipeWire and AT-SPI in a private Wayland session.

The test driver extension and all apps/data belong to this temporary session.
No existing desktop, account, extension settings or agent is used.
"""

from __future__ import annotations
import argparse
import ast
import base64
import io
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import sys
import tempfile
import time
import threading

ROOT = Path(__file__).resolve().parents[1]


def wait(description, predicate, seconds=25):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.1)
    raise RuntimeError(f"Timed out waiting for {description}")


class Session:
    def __init__(self, root, evidence, extension):
        self.root, self.evidence = root, evidence
        self.processes = []
        self.lines = {}
        for name in ("run", "config", "data", "cache", "state"):
            (root / name).mkdir(mode=0o700)
        self.env = {
            **os.environ,
            "XDG_RUNTIME_DIR": str(root / "run"),
            "XDG_CONFIG_HOME": str(root / "config"),
            "XDG_DATA_HOME": str(root / "data"),
            "XDG_CACHE_HOME": str(root / "cache"),
            "XDG_STATE_HOME": str(root / "state"),
            "XDG_SESSION_TYPE": "wayland",
            "XDG_CURRENT_DESKTOP": "GNOME",
            "XDG_SESSION_DESKTOP": "gnome",
            "WAYLAND_DISPLAY": "zommi-test",
            "GDK_BACKEND": "wayland",
            "LIBGL_ALWAYS_SOFTWARE": "1",
            "GSK_RENDERER": "cairo",
            "NO_AT_BRIDGE": "0",
            "DBUS_SYSTEM_BUS_ADDRESS": f"unix:path={root}/run/system-bus",
            "ZOMMI_RUNTIME_DISCOVERY_MODE": "configured-only",
        }
        self.env.pop("DISPLAY", None)
        self.env.pop("GSETTINGS_BACKEND", None)
        extensions = root / "data/gnome-shell/extensions"
        extensions.mkdir(parents=True)
        if extension is not None:
            shutil.copytree(extension, extensions / "zommi@zommi")
            self.run("glib-compile-schemas", str(extensions / "zommi@zommi/schemas"))
        driver = extensions / "zommi-test@zommi"
        driver.mkdir()
        (driver / "metadata.json").write_text(
            json.dumps(
                {
                    "uuid": "zommi-test@zommi",
                    "name": "Zommi acceptance driver",
                    "description": "Private test session only",
                    "shell-version": ["46"],
                }
            )
        )
        shutil.copy2(
            ROOT / "tests/fixtures/gnome-test-driver.js", driver / "extension.js"
        )

    def run(self, *args, **kwargs):
        try:
            return subprocess.run(
                list(map(str, args)),
                env=self.env,
                check=True,
                capture_output=True,
                text=True,
                timeout=15,
                **kwargs,
            )
        except subprocess.CalledProcessError as error:
            error.add_note(error.stderr or error.stdout)
            raise

    def start(self, name, command, pipes=False, env=None):
        log = (self.evidence / f"{name}.log").open("w")
        process = subprocess.Popen(
            list(map(str, command)),
            env=env or self.env,
            stdin=subprocess.PIPE if pipes else subprocess.DEVNULL,
            stdout=subprocess.PIPE if pipes else log,
            stderr=log,
            text=True,
            bufsize=1,
        )
        self.processes.append(process)
        if pipes:
            messages = queue.Queue()
            self.lines[process.pid] = messages

            def read():
                for line in process.stdout:
                    messages.put(line)
                messages.put(None)

            threading.Thread(target=read, daemon=True).start()
        return process

    def line(self, process, timeout=0.1):
        try:
            line = self.lines[process.pid].get(timeout=timeout)
        except queue.Empty:
            return None
        if line is None:
            raise RuntimeError(f"Helper {process.pid} exited; see its log")
        return json.loads(line)

    def bus(self, service, path, method, *args):
        return ast.literal_eval(
            self.run(
                "gdbus",
                "call",
                "--session",
                "--dest",
                service,
                "--object-path",
                path,
                "--method",
                method,
                *args,
            ).stdout
        )[0:1]

    def driver(self, method, *args):
        return self.bus(
            "com.zommi.TestDriver",
            "/com/zommi/TestDriver",
            "com.zommi.TestDriver." + method,
            *map(str, args),
        )

    def start_desktop(self):
        self.start(
            "system-bus",
            [
                "dbus-daemon",
                "--session",
                "--nofork",
                "--address=" + self.env["DBUS_SYSTEM_BUS_ADDRESS"],
            ],
        )
        wait("private system bus", lambda: (self.root / "run/system-bus").exists())
        self.run(
            "dbus-update-activation-environment",
            *[key for key in self.env if key.startswith("XDG_")],
            "WAYLAND_DISPLAY",
            "DBUS_SYSTEM_BUS_ADDRESS",
            "GSK_RENDERER",
            "LIBGL_ALWAYS_SOFTWARE",
        )
        self.run(
            "gsettings",
            "set",
            "org.gnome.shell",
            "enabled-extensions",
            "['zommi@zommi','zommi-test@zommi']",
        )
        self.run(
            "gsettings", "set", "org.gnome.shell", "disable-user-extensions", "false"
        )
        self.run(
            "gsettings", "set", "org.gnome.desktop.screensaver", "lock-enabled", "false"
        )
        self.run("gsettings", "set", "org.gnome.desktop.session", "idle-delay", "0")
        for setting, value in (("picture-uri", "''"), ("picture-uri-dark", "''"),
                               ("primary-color", "'#0d3355'"), ("color-shading-type", "'solid'")):
            self.run("gsettings", "set", "org.gnome.desktop.background", setting, value)
        self.run(
            "gsettings",
            "set",
            "org.gnome.desktop.notifications",
            "show-banners",
            "false",
        )
        self.shell = self.start(
            "gnome",
            [
                "gnome-shell",
                "--wayland",
                "--headless",
                "--no-x11",
                "--virtual-monitor",
                "1600x1000",
                "--wayland-display",
                "zommi-test",
            ],
        )

        def ready():
            if self.shell.poll() is not None:
                raise RuntimeError("GNOME exited; see gnome.log")
            try:
                self.driver("Ready")
                return True
            except subprocess.CalledProcessError:
                return False

        wait("GNOME integration", ready)
        self.start("pipewire", ["pipewire"])
        wait("PipeWire socket", lambda: (self.root / "run/pipewire-0").exists())
        self.start("wireplumber", ["wireplumber"])
        self.start("portal", ["/usr/libexec/xdg-desktop-portal"])
        time.sleep(2)

    def portal_action(self, cancel=False):
        import pyatspi

        for app in pyatspi.Registry.getDesktop(0):
            if "portal-gnome" not in app.name:
                continue
            pending = [app]
            while pending:
                obj = pending.pop(0)
                try:
                    if obj.getRoleName() == "push button" and obj.name.lower() == (
                        "cancel" if cancel else "share"
                    ):
                        obj.queryAction().doAction(0)
                        return True
                    pending.extend(obj)
                except Exception:
                    continue
        return False

    def request(self, process, method, params=None, authorize=None):
        process.stdin.write(
            json.dumps({"id": method, "method": method, "params": params or {}}) + "\n"
        )
        process.stdin.flush()
        deadline = time.monotonic() + (45 if authorize is not None else 22)
        acted = False
        while time.monotonic() < deadline:
            result = self.line(process)
            if result is not None:
                (self.evidence / f"{method}-result.json").write_text(
                    json.dumps(result, indent=2)
                )
                return result
            if authorize is not None and not acted:
                acted = self.portal_action(cancel=not authorize)
        raise RuntimeError(f"{method} did not complete")

    def key(self, key):
        self.driver("Key", key, "true")
        self.driver("Key", key, "false")

    def shortcut(self):
        self.driver("Key", 0xFFE9, "true")
        self.key(ord("a"))
        self.driver("Key", 0xFFE9, "false")

    def drag(self, start, end):
        self.driver("Motion", *start)
        self.driver("Button", "true")
        for step in range(1, 9):
            self.driver(
                "Motion", *[round(a + (b - a) * step / 8) for a, b in zip(start, end)]
            )
            time.sleep(0.03)
        self.driver("Button", "false")
        time.sleep(0.15)

    def close(self):
        for process in reversed(self.processes):
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=4)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=4)


def desktop_status_without_gnome(session, helper):
    status = json.loads(session.run(helper, "status").stdout)
    assert not status["ready"] and not status["canEnable"], status
    assert status["reason"] in ("gnome-unavailable", "wslg-without-gnome"), status
    disconnected = json.loads(session.run(
        "env", "DBUS_SESSION_BUS_ADDRESS=unix:path=/nonexistent-zommi-test-bus",
        helper, "status",
    ).stdout)
    assert disconnected["reason"] == "session-bus-unavailable", disconnected
    assert not disconnected["canEnable"], disconnected
    (session.evidence / "desktop-unavailable.json").write_text(
        json.dumps({"noGnome": status, "noSessionBus": disconnected}, indent=2)
    )


def desktop_status_acceptance(session, helper):
    def status(command="status", reported=None):
        prefix = [] if reported is None else [
            "env", "-u", "WAYLAND_DISPLAY", "-u", "XDG_SESSION_TYPE",
            *([f"XDG_SESSION_TYPE={reported}"] if reported else []),
        ]
        return json.loads(session.run(*prefix, helper, command).stdout)

    def ready():
        session.driver("Ready")
        return status()["ready"]

    wait("desktop status ready", ready)
    results = {}
    for reported in ("wayland", "tty", "x11", ""):
        result = status(reported=reported)
        assert result["ready"] and result["wayland"], result
        assert result["diagnostics"]["compositorSession"] == "wayland", result
        assert result["diagnostics"]["reportedSession"] == reported, result
        assert not result["diagnostics"]["waylandDisplayPresent"], result
        results[reported or "unset"] = result
    try:
        session.driver("DisconnectIntegration")
        disconnected = status()
        assert disconnected["reason"] == "extension-unresponsive", disconnected
        assert disconnected["canEnable"], disconnected
        assert status("enable-extension")["ready"]
        results["disconnected"] = disconnected
        session.run("gnome-extensions", "disable", "zommi@zommi")
        disabled = status()
        assert disabled["reason"] == "extension-disabled", disabled
        assert disabled["canEnable"], disabled
        assert status("enable-extension")["ready"]
        results["disabled"] = disabled
        session.run("gsettings", "set", "org.gnome.shell", "disable-user-extensions", "true")
        blocked = status()
        assert blocked["reason"] == "extensions-disabled", blocked
        assert not blocked["canEnable"], blocked
        assert status("enable-extension")["reason"] == "extensions-disabled"
        results["globallyDisabled"] = blocked
    finally:
        session.run("gsettings", "set", "org.gnome.shell", "disable-user-extensions", "false")
        session.run(helper, "enable-extension")
    wait("desktop status recovered", ready)
    (session.evidence / "desktop-session-matrix.json").write_text(json.dumps(results, indent=2))
    print("PASS desktop diagnostics: stale/unset session environment, disabled integration and global extension switch.", flush=True)


def native_acceptance(session, helper, toolkit="3.0"):
    from PIL import Image, ImageChops

    token_path = Path(session.env["XDG_STATE_HOME"]) / "zommi/screencast-restore-token"
    token_path.unlink(missing_ok=True)

    fixture = session.root / f"fixture-{toolkit}"
    fixture.mkdir()
    app = session.start(
        f"fixture-{toolkit}",
        [sys.executable, ROOT / "tests/fixtures/wayland-app.py", fixture, toolkit],
    )
    wait("native GTK fixture", lambda: (fixture / "fixture.json").exists())
    identity = json.loads((fixture / "fixture.json").read_text())
    assert (
        identity["displayType"] == "GdkWaylandDisplay"
        and identity["x11Display"] is None
    )
    time.sleep(0.5)

    def desktop_ready():
        session.driver("Ready")
        status = json.loads(session.run(helper, "status").stdout)
        (session.evidence / "desktop-status.json").write_text(json.dumps(status))
        return status["ready"]

    wait("desktop ready after startup", desktop_ready)
    shortcuts = session.start("shortcuts", [helper, "shortcuts"], pipes=True)
    assert session.line(shortcuts, 8)["contextShortcut"]
    session.shortcut()
    assert session.line(shortcuts, 5)["event"] == "activated"
    # Capture must work even when a launcher reports the wrong session type.
    host = session.start("capture", [helper, "--capture-host"], pipes=True,
                         env={**session.env, "XDG_SESSION_TYPE": "tty"})
    cancelled = session.request(host, "selectContent", authorize=False)
    assert cancelled["ok"] and cancelled["result"]["cancelled"], cancelled
    capture = session.request(host, "selectContent", authorize=True)
    assert capture["ok"], capture
    assert token_path.is_file(), "The remembered grant was not saved"
    frame = capture["result"]["frames"][0]
    source = next(w for w in frame["windows"] if w.get("processId") == app.pid)
    bounds = source["bufferBounds"]
    region = {"x": bounds["x"] + 36, "y": bounds["y"] + 70, "width": 340, "height": 240}
    if toolkit == "4.0":
        bounds = source["bounds"]
        region.update(x=bounds["x"] + 10, y=bounds["y"] + 10)
    # Allow the portal dismissal/focus animation to finish before asserting a
    # static accessibility tree. The editor normally provides this interval.
    time.sleep(0.5)
    result = session.request(host, "observe", {"bounds": region})
    assert result["ok"], result
    observation = result["result"]
    assert observation["stable"], observation
    if not (observation.get("regionContext") or {}).get("elements"):
        import pyatspi

        inventory = []
        for accessible_app in pyatspi.Registry.getDesktop(0):
            for window in accessible_app:
                try:
                    rect = window.queryComponent().getExtents(pyatspi.WINDOW_COORDS)
                    inventory.append(
                        {
                            "application": accessible_app.name,
                            "pid": accessible_app.get_process_id(),
                            "window": window.name,
                            "bounds": [rect.x, rect.y, rect.width, rect.height],
                        }
                    )
                except Exception as error:
                    inventory.append({"error": str(error)})
        (session.evidence / "atspi-window-inventory.json").write_text(
            json.dumps(inventory, indent=2)
        )
    text = json.dumps(observation["regionContext"])
    assert "WAYLAND_VISIBLE_LABEL" in text, text
    if toolkit == "4.0":
        assert "WAYLAND_EDITABLE_VALUE" not in text
        assert "masked fields" in observation["limitation"]
    else:
        assert "WAYLAND_EDITABLE_VALUE" in text, text
    assert (
        "SYNTHETIC_SECRET" not in text
        and "SYNTHETIC_HIDDEN" not in text
        and "WAYLAND_OUTSIDE_CROP" not in text
    ), text
    assert any(
        e["state"]["toggle"] == "on" for e in observation["regionContext"]["elements"]
    )
    original = Image.open(
        io.BytesIO(base64.b64decode(frame["dataUrl"].split(",", 1)[1]))
    )
    current = Image.open(
        io.BytesIO(base64.b64decode(observation["dataUrl"].split(",", 1)[1]))
    )
    mask = None
    for plane, color in zip(current.convert("RGB").split(), (36, 96, 128)):
        selected = plane.point(lambda value: 255 if value == color else 0)
        mask = selected if mask is None else ImageChops.multiply(mask, selected)
    label = next(
        e
        for e in observation["regionContext"]["elements"]
        if e["name"] == "WAYLAND_VISIBLE_LABEL"
    )
    box = label["visibleBounds"]
    assert mask.getbbox() == tuple(
        round(v)
        for v in (box["x"], box["y"], box["x"] + box["width"], box["y"] + box["height"])
    ), (mask.getbbox(), box)
    crop = (
        int(region["x"]),
        int(region["y"]),
        int(region["x"] + region["width"]),
        int(region["y"] + region["height"]),
    )
    assert (
        original.crop(crop).tobytes() == current.tobytes()
    ), "Pixels do not match the frozen source"
    (fixture / "change").touch()
    time.sleep(0.25)
    changed = session.request(host, "observe", {"bounds": region})
    if toolkit == "3.0":
        assert "CHANGED_VALUE" in json.dumps(changed)
    assert (
        changed["result"]["dataUrl"] != observation["dataUrl"]
    ), "Changed pixels must invalidate the old attachment"
    session.request(host, "release")
    restored = session.request(host, "selectContent")
    assert restored["ok"] and restored["result"]["frames"], restored
    assert token_path.read_text(), "The returned portal grant was not saved"
    session.request(host, "release")
    token_path.write_text("00000000-0000-0000-0000-000000000000")
    revoked = session.request(host, "selectContent", authorize=False)
    assert revoked["ok"] and revoked["result"]["cancelled"], revoked
    assert not token_path.exists(), "A rejected grant must not keep breaking retries"
    renewed = session.request(host, "selectContent", authorize=True)
    assert renewed["ok"] and renewed["result"]["frames"], renewed
    session.request(host, "release")
    session.run("gnome-extensions", "disable", "zommi@zommi")
    assert not json.loads(session.run(helper, "status").stdout)["ready"]
    unavailable = session.request(host, "selectContent")
    assert not unavailable["ok"] and "App settings" in unavailable["error"], unavailable
    host.wait(timeout=5)
    assert json.loads(session.run(helper, "enable-extension").stdout)["ready"]
    session.shortcut()

    def reactivated():
        return (session.line(shortcuts) or {}).get("event") == "activated"

    wait("shortcut after extension re-enable", reactivated)
    host = session.start("capture-reconnected", [helper, "--capture-host"], pipes=True)
    recovered = session.request(host, "selectContent")
    assert recovered["ok"], recovered
    session.request(host, "release")
    host.terminate()
    host.wait(timeout=5)
    shortcuts.terminate()
    shortcuts.wait(timeout=5)
    print(
        f"PASS GTK {toolkit} on GNOME Wayland: Alt+A, cancel/retry, ScreenCast pixels, window identity, AT-SPI alignment, filtering, changed pixels, remembered sharing and helper/extension recovery.",
        flush=True,
    )
    return app, source


def browser_acceptance(session, helper, browser, browser_host):
    page = session.root / "browser.html"
    page.write_text("""<!doctype html><title>Zommi DOM fixture</title>
<style>body{margin:0;background:#eef6fa;font:24px sans-serif}main{margin:30px;padding:40px;background:#acdcee;width:500px;height:320px}</style>
<main><button>CAPTURE_DOM_SENTINEL</button><p>Native Wayland browser DOM</p></main>
<div style="height:2200px">Below the crop</div>""")
    profile = session.root / "browser-profile"
    app = session.start(
        "browser",
        [
            browser,
            "--ozone-platform=wayland",
            "--no-sandbox",
            "--disable-dev-shm-usage",
            "--force-renderer-accessibility",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-background-networking",
            "--disable-component-update",
            "--disable-sync",
            "--remote-debugging-port=0",
            f"--user-data-dir={profile}",
            "--window-size=1000,700",
            page.as_uri(),
        ],
    )
    port = profile / "DevToolsActivePort"
    wait(
        "native Wayland browser",
        lambda: port.exists()
        and json.loads(session.driver("Window", app.pid)[0]).get("width"),
    )
    time.sleep(0.5)
    capture = session.start("browser-capture", [helper, "--capture-host"], pipes=True)
    frame = session.request(capture, "selectContent", authorize=True)["result"][
        "frames"
    ][0]
    source = next(w for w in frame["windows"] if w.get("processId") == app.pid)
    b = source["bounds"]
    anchor = {"x": b["x"] + 100, "y": b["y"] + 350, "width": 8, "height": 8}
    observation = session.request(capture, "observe", {"bounds": anchor})
    viewport = observation["result"].get("browserViewport")
    assert viewport, observation
    region = {
        "x": viewport["x"] + 20,
        "y": viewport["y"] + 20,
        "width": 600,
        "height": 290,
    }
    current = session.request(capture, "observe", {"bounds": region})["result"]
    assert current["stable"], current
    command = (
        ["dotnet", browser_host] if browser_host.suffix == ".dll" else [browser_host]
    )
    host = session.start(
        "browser-dom",
        command,
        pipes=True,
        env={
            **session.env,
            "ZOMMI_BROWSER_CDP_ENDPOINT": "http://127.0.0.1:"
            + port.read_text().splitlines()[0],
        },
    )
    observed = session.request(
        host,
        "observe",
        {
            "source": current["source"],
            "windows": current["windows"],
            "viewport": current["browserViewport"],
            "bounds": region,
            "imageWidth": 600,
            "imageHeight": 290,
        },
    )
    assert observed["ok"] and observed["result"]["available"], observed
    confirmed = session.request(host, "confirm")
    assert confirmed["ok"] and confirmed["result"]["available"], confirmed
    elements = confirmed["result"]["regionContext"]["elements"]
    assert "CAPTURE_DOM_SENTINEL" in json.dumps(elements)
    for element in elements:
        visible = element["visibleBounds"]
        assert visible["x"] >= -0.01 and visible["y"] >= -0.01
        assert (
            visible["x"] + visible["width"] <= 600.01
            and visible["y"] + visible["height"] <= 290.01
        )
    session.request(host, "shutdown")
    host.wait(timeout=5)
    session.request(capture, "shutdown")
    capture.wait(timeout=5)
    app.terminate()
    app.wait(timeout=10)
    print(
        "PASS native Wayland Chromium: GNOME window binding, AT-SPI viewport and shared DOM geometry.",
        flush=True,
    )


def events(path, name):
    values = []
    for line in path.read_text().splitlines() if path.exists() else []:
        try:
            item = json.loads(line)
            if item.get("event") == name:
                values.append(item)
        except json.JSONDecodeError:
            pass
    return values


def document_acceptance(session, package):
    from PIL import Image, ImageChops

    fixture = session.root / "deck.html"
    fixture.write_text("""<!doctype html><style>
body{background:#123344;color:#fff;font:24px sans-serif}section{display:none;padding:30px}
section:target{display:grid;grid-template-columns:1fr 1fr;gap:24px}.card{background:#246080;padding:30px}
</style><section id="slide-12"><div class="card">Ocean preview</div><div class="card">Styled grid</div></section>
<script>document.title='Synthetic document'</script>""")
    config = session.root / "document-config/zommi"
    config.mkdir(parents=True)
    (config / "settings.json").write_text('{"runtimeSetupCompleted":true}')
    report_path = session.evidence / "document-report.json"
    report_path.unlink(missing_ok=True)
    trace = session.evidence / "document-events.jsonl"
    trace.unlink(missing_ok=True)
    app = session.start(
        "document",
        [package / "zommi"],
        env={
            **session.env,
            "XDG_CONFIG_HOME": str(config.parent),
            "ZOMMI_DOCUMENT_PREVIEW_PATH": fixture.as_uri() + "#slide-12",
            "ZOMMI_DOCUMENT_PREVIEW_PROBE": str(report_path),
            "ZOMMI_DOCUMENT_THUMBNAIL_PROBE": "1",
            "ZOMMI_ACCEPTANCE_LOG": str(trace),
            **(
                {"WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS": "1"}
                if os.geteuid() == 0
                else {}
            ),
        },
    )
    wait("floating HTML preview", report_path.exists)
    report = json.loads(report_path.read_text())
    session.driver("Ready")
    time.sleep(0.5)
    assert report["status"] == "opened", report
    page = report["document"]
    assert page["target"]["display"] == "grid" and page["hash"] == "#slide-12", page
    assert page["stylesheets"] >= 1 and page["scripts"] >= 1, page
    assert report["thumbnail"]["width"] == 1280 and report["thumbnail"]["height"] == 720

    def document_bounds():
        path = session.evidence / "document-screen.png"
        session.driver("Snapshot", path)
        with Image.open(path) as image:
            mask = None
            for plane, color in zip(image.convert("RGB").split(), (18, 51, 68)):
                selected = plane.point(lambda value: 255 if value == color else 0)
                mask = selected if mask is None else ImageChops.multiply(mask, selected)
            return mask.getbbox()

    original = wait("rendered document pixels", document_bounds)
    assert original[2] - original[0] == page["viewport"]["width"]
    assert original[3] - original[1] == page["viewport"]["height"]
    session.driver("Click", original[0] + 100, original[1] + 100)
    session.shortcut()
    wait("document capture editor", lambda: events(trace, "capture.editor.ready"))
    assert document_bounds() is None, "The document covers the editor"
    session.key(0xFF1B)
    result = wait(
        "document capture cancellation", lambda: events(trace, "selection.content")
    )[-1]
    assert result["count"] == 0, result
    wait("restored document bounds", lambda: document_bounds() == original)
    session.driver("Click", original[0] - 15, original[1] + 20)
    wait("outside-click dismissal", lambda: document_bounds() is None)
    assert app.poll() is None
    app.terminate()
    app.wait(timeout=10)
    print(
        "PASS Wayland floating HTML: CSS, JavaScript, fragment, full-layout thumbnail, capture suspension/recovery and outside-click dismissal.",
        flush=True,
    )


def assert_app_surface(session, app, name, expected_size=None):
    from PIL import Image

    path = session.evidence / f"{name}.png"

    def painted():
        window = json.loads(session.driver("Window", app.pid)[0])
        if not window.get("focused"):
            return False
        if expected_size and (window["width"], window["height"]) != expected_size:
            return False
        session.driver("Snapshot", path)
        with Image.open(path) as image:
            pixels = image.convert("RGB")
            x, y, width, height = (window[key] for key in ("x", "y", "width", "height"))
            header = pixels.getpixel((x + width // 2, y + 25))
            sidebar = pixels.getpixel((x + 30, y + height // 2))
            # A live process or an all-white/transparent surface is not a UI.
            if min(header) < 240 or sum(abs(a - b) for a, b in zip(header, sidebar)) < 20:
                return False
            for dx, dy in ((1, 1), (width - 2, 1), (1, height - 2), (width - 2, height - 2)):
                corner = pixels.getpixel((x + dx, y + dy))
                if max(abs(a - b) for a, b in zip(corner, (13, 51, 85))) > 2:
                    return False
        (session.evidence / f"{name}.json").write_text(json.dumps(window, indent=2))
        return window

    return wait(f"painted app surface after {name}", painted, seconds=5)


def ui_acceptance(session, package, fixture_app):
    trace = session.evidence / "ui-events.jsonl"
    trace.unlink(missing_ok=True)
    config = session.root / "ui-config/zommi"
    config.mkdir(parents=True)
    (config / "settings.json").write_text('{"runtimeSetupCompleted":true,"themeMode":"light"}')
    app = session.start(
        "ui",
        [package / "zommi"],
        env={
            **session.env,
            "XDG_CONFIG_HOME": str(config.parent),
            "ZOMMI_ACCEPTANCE_LOG": str(trace),
        },
    )
    ready = wait("packaged desktop readiness", lambda: events(trace, "desktop.ready"))[
        -1
    ]
    assert ready["contextShortcut"] and not ready["imageShortcut"], ready
    wait(
        "packaged Wayland window",
        lambda: json.loads(session.driver("Window", app.pid)[0]).get("width"),
    )
    session.driver("Activate", app.pid)
    initial = assert_app_surface(session, app, "startup-surface")
    size = (initial["width"], initial["height"])
    assert size[0] < 1600 and size[1] < 968, "The test must exercise a normal-sized window"
    for index, action in enumerate(("draw", "cancel", "draw")):
        session.driver("Activate", fixture_app.pid)
        wait(
            "focused source fixture",
            lambda: json.loads(session.driver("Window", fixture_app.pid)[0]).get(
                "focused"
            ),
        )
        time.sleep(0.3)
        origin = json.loads(session.driver("Window", fixture_app.pid)[0])
        # Keep the live source's hover state identical before and after capture.
        session.driver("Motion", 1200, 740)
        before = len(events(trace, "capture.editor.ready"))
        selections = len(events(trace, "selection.content"))
        session.shortcut()
        wait(
            "capture editor",
            lambda: len(events(trace, "capture.editor.ready")) > before,
        )
        time.sleep(0.4)
        canvas = events(trace, "capture.editor.ready")[-1]
        window = json.loads(session.driver("Window", app.pid)[0])
        (session.evidence / "editor-geometry.json").write_text(
            json.dumps({"canvas": canvas, "window": window, "source": origin}, indent=2)
        )
        assert window["focused"], window
        bounds = canvas["localBounds"]

        def point(x, y):
            return (
                round(
                    window["x"]
                    + bounds["x"]
                    + x * bounds["width"] / canvas["imageWidth"]
                ),
                round(
                    window["y"]
                    + bounds["y"]
                    + y * bounds["height"] / canvas["imageHeight"]
                ),
            )

        if action == "cancel":
            session.key(0xFF1B)
        else:
            x, y = origin["x"] + 36, origin["y"] + 70
            session.drag(point(x, y), point(x + 340, y + 240))
            # Hover every drawing/color/action control in the packaged app.
            # A tooltip failure formerly replaced the entire editor with white.
            from PIL import Image, ImageChops

            controls = canvas["controls"]
            def control_point(name):
                rect = controls[name]
                return round(window["x"] + rect["x"] + rect["width"] / 2), round(window["y"] + rect["y"] + rect["height"] / 2)

            time.sleep(0.2)
            baseline = session.evidence / f"editor-before-hover-{index}.png"
            session.driver("Snapshot", baseline)
            crop = (round(window["x"] + bounds["x"]), round(window["y"] + bounds["y"]),
                    round(window["x"] + bounds["x"] + bounds["width"]),
                    round(window["y"] + bounds["y"] + bounds["height"] * 0.6))
            with Image.open(baseline) as image:
                expected = image.convert("RGB").crop(crop)
            for tool_index, name in enumerate(controls):
                session.driver("Motion", *control_point(name))
                time.sleep(0.25)
                hovered = session.evidence / f"editor-hover-{index}-{tool_index}.png"
                session.driver("Snapshot", hovered)
                with Image.open(hovered) as image:
                    difference = ImageChops.difference(expected, image.convert("RGB").crop(crop)).convert("L")
                    changed = sum(count for value, count in enumerate(difference.histogram()) if value > 8)
                    assert changed < expected.width * expected.height * 0.01, f"Canvas changed while hovering {name}"
                assert app.poll() is None, name
            session.driver("Click", *control_point("Stroke width"))
            time.sleep(0.3)
            session.key(0xFF1B)  # Dismiss only the menu, preserving the editor.
            assert len(events(trace, "selection.content")) == selections
            session.driver("Click", *control_point("Pen (P)"))
            session.drag(point(x + 15, y + 15), point(x + 160, y + 100))
            session.driver("Snapshot", session.evidence / "editor-drawn.png")
            session.driver("Motion", 1200, 740)
            session.key(0xFF0D)
        result = wait(
            "attached selection",
            lambda: events(trace, "selection.content")[selections:],
        )[-1]
        if action == "cancel":
            assert result["count"] == 0, result
        else:
            assert result["count"] == 1, result
            item = result["items"][0]
            assert item["hasImage"] and item["annotationCount"] == 1, item
            assert (
                item["alignmentStatus"] == "aligned" and item["elementCount"] >= 3
            ), item
            for key, expected in {"x": x, "y": y, "width": 340, "height": 240}.items():
                assert abs(item["bounds"][key] - expected) <= 2, item
        wait(
            "restored focused app",
            lambda: json.loads(session.driver("Window", app.pid)[0]).get("focused"),
        )
        assert_app_surface(session, app, f"returned-{index}-{action}", size)
        # selection.content precedes the controller's final composer focus.
        # Let that restoration finish before simulating the next app switch.
        time.sleep(1)
        assert app.poll() is None
    app.terminate()
    app.wait(timeout=10)
    print(
        "PASS packaged Wayland UI: transparent corners, painted startup/return, restored size, remembered sharing, Alt+A, aligned region, handwritten stroke, cancel, retry and focus recovery.",
        flush=True,
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", type=Path)
    parser.add_argument("--system-extension", action="store_true",
                        help="Test the .deb-installed GNOME extension instead of a temporary user copy")
    parser.add_argument(
        "--helper", type=Path, default=ROOT / "target/debug/zommi-linux-capture"
    )
    parser.add_argument("--browser", type=Path)
    parser.add_argument(
        "--browser-host",
        type=Path,
        default=ROOT
        / "src/Zommi.BrowserCapture/bin/Release/net8.0/zommi-browser-capture.dll",
    )
    parser.add_argument(
        "--output", type=Path, default=ROOT / "artifacts/wayland-acceptance"
    )
    parser.add_argument("--inside", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if not args.inside:
        return subprocess.call(
            [
                "dbus-run-session",
                "--",
                sys.executable,
                __file__,
                *sys.argv[1:],
                "--inside",
            ]
        )
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    helper = (
        args.package / "zommi-linux-capture" if args.package else args.helper
    ).resolve()
    extension = (
        args.package / "gnome-extension/zommi@zommi"
        if args.package
        else ROOT / "src/Zommi.Gnome"
    )
    with tempfile.TemporaryDirectory(prefix="zommi-wayland-acceptance-") as temporary:
        session = Session(Path(temporary), args.output, None if args.system_extension else extension)
        try:
            desktop_status_without_gnome(session, helper)
            session.start_desktop()
            desktop_status_acceptance(session, helper)
            if args.system_extension:
                status = json.loads(session.run(helper, "status").stdout)
                assert status["diagnostics"]["extensionPath"] == "/usr/share/gnome-shell/extensions/zommi@zommi", status
            fixture_app, _ = native_acceptance(session, helper)
            gtk4, _ = native_acceptance(session, helper, "4.0")
            gtk4.terminate()
            gtk4.wait(timeout=5)
            if args.browser:
                browser_host = (
                    args.package / "browser-capture/zommi-browser-capture"
                    if args.package
                    else args.browser_host
                )
                browser_acceptance(
                    session, helper, args.browser.resolve(), browser_host.resolve()
                )
            if args.package:
                ui_acceptance(session, args.package.resolve(), fixture_app)
                document_acceptance(session, args.package.resolve())
            # GNOME cannot retry an ERROR state through disable/enable. Do not
            # offer an ineffective repair loop; retain the actual load error.
            session.driver("FailIntegration")
            for command in ("status", "enable-extension"):
                failed = json.loads(session.run(helper, command).stdout)
                assert failed["reason"] == "extension-error", failed
                assert not failed["canEnable"], failed
                assert "Synthetic integration failure" in failed["diagnostics"]["extensionError"], failed
            (session.evidence / "desktop-extension-error.json").write_text(json.dumps(failed, indent=2))
            print("PASS extension load error: actionable diagnostics without an ineffective repair.", flush=True)
        finally:
            session.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
