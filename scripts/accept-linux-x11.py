#!/usr/bin/env python3
from __future__ import annotations

import base64
import ctypes
from ctypes import byref, c_bool, c_char_p, c_int, c_long, c_uint, c_ulong, c_void_p
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import tempfile
import time


ONE_PIXEL_PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
)
CURRENT_TIME = 0
REVERT_TO_PARENT = 2
IS_VIEWABLE = 2
PROP_MODE_REPLACE = 0


class XWindowAttributes(ctypes.Structure):
    _fields_ = [
        ("x", c_int),
        ("y", c_int),
        ("width", c_int),
        ("height", c_int),
        ("border_width", c_int),
        ("depth", c_int),
        ("visual", c_void_p),
        ("root", c_ulong),
        ("window_class", c_int),
        ("bit_gravity", c_int),
        ("win_gravity", c_int),
        ("backing_store", c_int),
        ("backing_planes", c_ulong),
        ("backing_pixel", c_ulong),
        ("save_under", c_int),
        ("colormap", c_ulong),
        ("map_installed", c_int),
        ("map_state", c_int),
        ("all_event_masks", c_long),
        ("your_event_mask", c_long),
        ("do_not_propagate_mask", c_long),
        ("override_redirect", c_int),
        ("screen", c_void_p),
    ]


class X11:
    def __init__(self) -> None:
        self.lib = ctypes.CDLL("libX11.so.6")
        self.xtest = ctypes.CDLL("libXtst.so.6")
        self._declare()
        self.display = self.lib.XOpenDisplay(None)
        if not self.display:
            raise RuntimeError("Linux X11 acceptance requires a live DISPLAY.")
        self.screen = self.lib.XDefaultScreen(self.display)
        self.root = self.lib.XRootWindow(self.display, self.screen)

    def _declare(self) -> None:
        lib = self.lib
        lib.XOpenDisplay.argtypes = [c_char_p]
        lib.XOpenDisplay.restype = c_void_p
        lib.XCloseDisplay.argtypes = [c_void_p]
        lib.XDefaultScreen.argtypes = [c_void_p]
        lib.XDefaultScreen.restype = c_int
        lib.XRootWindow.argtypes = [c_void_p, c_int]
        lib.XRootWindow.restype = c_ulong
        lib.XCreateSimpleWindow.argtypes = [
            c_void_p,
            c_ulong,
            c_int,
            c_int,
            c_uint,
            c_uint,
            c_uint,
            c_ulong,
            c_ulong,
        ]
        lib.XCreateSimpleWindow.restype = c_ulong
        lib.XStoreName.argtypes = [c_void_p, c_ulong, c_char_p]
        lib.XMapWindow.argtypes = [c_void_p, c_ulong]
        lib.XDestroyWindow.argtypes = [c_void_p, c_ulong]
        lib.XSetInputFocus.argtypes = [c_void_p, c_ulong, c_int, c_ulong]
        lib.XGetInputFocus.argtypes = [c_void_p, ctypes.POINTER(c_ulong), ctypes.POINTER(c_int)]
        lib.XFetchName.argtypes = [c_void_p, c_ulong, ctypes.POINTER(c_void_p)]
        lib.XFetchName.restype = c_int
        lib.XFree.argtypes = [c_void_p]
        lib.XInternAtom.argtypes = [c_void_p, c_char_p, c_bool]
        lib.XInternAtom.restype = c_ulong
        lib.XChangeProperty.argtypes = [
            c_void_p,
            c_ulong,
            c_ulong,
            c_ulong,
            c_int,
            c_int,
            ctypes.POINTER(ctypes.c_ubyte),
            c_int,
        ]
        lib.XGetWindowProperty.argtypes = [
            c_void_p,
            c_ulong,
            c_ulong,
            c_long,
            c_long,
            c_bool,
            c_ulong,
            ctypes.POINTER(c_ulong),
            ctypes.POINTER(c_int),
            ctypes.POINTER(c_ulong),
            ctypes.POINTER(c_ulong),
            ctypes.POINTER(c_void_p),
        ]
        lib.XGetWindowProperty.restype = c_int
        lib.XQueryTree.argtypes = [
            c_void_p,
            c_ulong,
            ctypes.POINTER(c_ulong),
            ctypes.POINTER(c_ulong),
            ctypes.POINTER(ctypes.POINTER(c_ulong)),
            ctypes.POINTER(c_uint),
        ]
        lib.XQueryTree.restype = c_int
        lib.XGetWindowAttributes.argtypes = [
            c_void_p,
            c_ulong,
            ctypes.POINTER(XWindowAttributes),
        ]
        lib.XGetWindowAttributes.restype = c_int
        lib.XKeysymToKeycode.argtypes = [c_void_p, c_ulong]
        lib.XKeysymToKeycode.restype = c_uint
        lib.XFlush.argtypes = [c_void_p]
        lib.XSync.argtypes = [c_void_p, c_bool]
        self.xtest.XTestFakeKeyEvent.argtypes = [c_void_p, c_uint, c_int, c_ulong]
        self.xtest.XTestFakeKeyEvent.restype = c_int

    def close(self) -> None:
        if self.display:
            self.lib.XCloseDisplay(self.display)
            self.display = None

    def create_fixture(self, title: str) -> int:
        window = self.lib.XCreateSimpleWindow(
            self.display, self.root, 40, 40, 420, 220, 0, 0, 0x223344
        )
        self.lib.XStoreName(self.display, window, title.encode("ascii"))
        pid_atom = self.atom("_NET_WM_PID")
        cardinal = self.atom("CARDINAL")
        value = c_ulong(os.getpid())
        self.lib.XChangeProperty(
            self.display,
            window,
            pid_atom,
            cardinal,
            32,
            PROP_MODE_REPLACE,
            ctypes.cast(byref(value), ctypes.POINTER(ctypes.c_ubyte)),
            1,
        )
        self.lib.XMapWindow(self.display, window)
        self.lib.XSync(self.display, False)
        return window

    def atom(self, name: str) -> int:
        return self.lib.XInternAtom(self.display, name.encode("ascii"), False)

    def focus(self, window: int) -> None:
        self.lib.XSetInputFocus(
            self.display, window, REVERT_TO_PARENT, CURRENT_TIME
        )
        self.lib.XSync(self.display, False)

    def focused_window(self) -> int:
        window = c_ulong()
        revert = c_int()
        self.lib.XGetInputFocus(self.display, byref(window), byref(revert))
        return window.value

    def title(self, window: int) -> str:
        net_name = self.property_bytes(window, "_NET_WM_NAME")
        if net_name:
            return net_name.decode("utf-8", errors="replace")
        pointer = c_void_p()
        if not self.lib.XFetchName(self.display, window, byref(pointer)) or not pointer.value:
            return ""
        try:
            return ctypes.string_at(pointer).decode("utf-8", errors="replace")
        finally:
            self.lib.XFree(pointer)

    def property_bytes(self, window: int, name: str) -> bytes:
        actual_type = c_ulong()
        actual_format = c_int()
        item_count = c_ulong()
        remaining = c_ulong()
        pointer = c_void_p()
        status = self.lib.XGetWindowProperty(
            self.display,
            window,
            self.atom(name),
            0,
            1024,
            False,
            0,
            byref(actual_type),
            byref(actual_format),
            byref(item_count),
            byref(remaining),
            byref(pointer),
        )
        if status != 0 or actual_format.value != 8 or not pointer.value:
            return b""
        try:
            return ctypes.string_at(pointer, item_count.value)
        finally:
            self.lib.XFree(pointer)

    def pid(self, window: int) -> int | None:
        actual_type = c_ulong()
        actual_format = c_int()
        item_count = c_ulong()
        remaining = c_ulong()
        pointer = c_void_p()
        status = self.lib.XGetWindowProperty(
            self.display,
            window,
            self.atom("_NET_WM_PID"),
            0,
            1,
            False,
            self.atom("CARDINAL"),
            byref(actual_type),
            byref(actual_format),
            byref(item_count),
            byref(remaining),
            byref(pointer),
        )
        if status != 0 or item_count.value != 1 or not pointer.value:
            return None
        try:
            return int(ctypes.cast(pointer, ctypes.POINTER(c_ulong))[0])
        finally:
            self.lib.XFree(pointer)

    def children(self, window: int) -> list[int]:
        root = c_ulong()
        parent = c_ulong()
        children = ctypes.POINTER(c_ulong)()
        count = c_uint()
        if not self.lib.XQueryTree(
            self.display,
            window,
            byref(root),
            byref(parent),
            byref(children),
            byref(count),
        ):
            return []
        try:
            return [int(children[index]) for index in range(count.value)]
        finally:
            if children:
                self.lib.XFree(children)

    def parent(self, window: int) -> int:
        root = c_ulong()
        parent = c_ulong()
        children = ctypes.POINTER(c_ulong)()
        count = c_uint()
        if not self.lib.XQueryTree(
            self.display,
            window,
            byref(root),
            byref(parent),
            byref(children),
            byref(count),
        ):
            return 0
        if children:
            self.lib.XFree(children)
        return int(parent.value)

    def attributes(self, window: int) -> XWindowAttributes:
        attributes = XWindowAttributes()
        if not self.lib.XGetWindowAttributes(self.display, window, byref(attributes)):
            raise RuntimeError(f"Could not inspect X11 window {window}.")
        return attributes

    def find_zommi_window(self) -> int | None:
        for window in self.children(self.root):
            if self.title(window).startswith("Zommi"):
                return window
        return None

    def is_descendant(self, window: int, ancestor: int) -> bool:
        current = window
        for _ in range(12):
            if current == ancestor:
                return True
            parent = self.parent(current)
            if not parent or parent == current:
                return False
            current = parent
        return False

    def send_shortcut(self, *, shift: bool) -> None:
        keysyms = [0xFFE9]
        if shift:
            keysyms.append(0xFFE1)
        keysyms.append(ord("a"))
        keycodes = [self.lib.XKeysymToKeycode(self.display, value) for value in keysyms]
        if any(value == 0 for value in keycodes):
            raise RuntimeError("X11 could not resolve the acceptance shortcut keycodes.")
        for keycode in keycodes:
            self.xtest.XTestFakeKeyEvent(
                self.display, keycode, True, CURRENT_TIME
            )
            self.lib.XSync(self.display, False)
            time.sleep(0.05)
        for keycode in reversed(keycodes):
            self.xtest.XTestFakeKeyEvent(
                self.display, keycode, False, CURRENT_TIME
            )
            self.lib.XSync(self.display, False)
            time.sleep(0.05)


def wait_until(description: str, predicate, timeout: float = 20.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.1)
    raise RuntimeError(f"Timed out waiting for {description}.")


def read_events(path: Path) -> list[dict[str, object]]:
    if not path.exists():
        return []
    events = []
    for line in path.read_text(encoding="utf-8").splitlines():
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return events


def event(path: Path, name: str) -> dict[str, object] | None:
    return next(
        (item for item in reversed(read_events(path)) if item.get("event") == name),
        None,
    )


def write_tool_wrapper(path: Path, tool: str) -> None:
    command = " ".join(
        [
            shlex.quote(sys.executable),
            shlex.quote(str(Path(__file__).resolve())),
            "--tool",
            shlex.quote(tool),
            '"$@"',
        ]
    )
    path.write_text(f"#!/bin/sh\nexec {command}\n", encoding="utf-8")
    path.chmod(0o755)


def run_tool(tool: str, arguments: list[str]) -> int:
    if tool == "gnome-screenshot":
        control = Path(os.environ["ZOMMI_CAPTURE_FIXTURE_CONTROL"])
        if control.read_text(encoding="utf-8").strip() != "success":
            return 0
        try:
            image_index = arguments.index("-f") + 1
            Path(arguments[image_index]).write_bytes(ONE_PIXEL_PNG)
        except (ValueError, IndexError):
            return 2
        return 0

    if tool != "xdotool":
        return 2
    x11 = X11()
    try:
        if arguments == ["getactivewindow"]:
            print(x11.focused_window())
            return 0
        if len(arguments) != 2:
            return 2
        window = int(arguments[1], 0)
        if arguments[0] == "getwindowname":
            print(x11.title(window))
            return 0
        if arguments[0] == "getwindowpid":
            pid = x11.pid(window)
            if pid is None:
                return 1
            print(pid)
            return 0
        return 2
    finally:
        x11.close()


def stop_process(process: subprocess.Popen[str]) -> None:
    if process.poll() is not None:
        return
    process.send_signal(signal.SIGTERM)
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def run_case(
    package: Path,
    x11: X11,
    fixture: int,
    temporary: Path,
    name: str,
    *,
    shortcut_shift: bool,
    capture_mode: str,
    expected_event: str,
    expect_expanded: bool,
) -> dict[str, object]:
    trace = temporary / f"{name}.jsonl"
    runtime_log = temporary / f"{name}.log"
    control = temporary / "capture-control"
    control.write_text(capture_mode, encoding="utf-8")
    environment = os.environ.copy()
    environment["PATH"] = f"{temporary}:{environment.get('PATH', '')}"
    environment["GDK_BACKEND"] = "x11"
    environment["LIBGL_ALWAYS_SOFTWARE"] = "1"
    environment["ZOMMI_ACCEPTANCE_LOG"] = str(trace)
    environment["ZOMMI_CAPTURE_FIXTURE_CONTROL"] = str(control)
    with runtime_log.open("w", encoding="utf-8") as output:
        process = subprocess.Popen(
            [str(package / "zommi")],
            cwd=package,
            env=environment,
            stdout=output,
            stderr=subprocess.STDOUT,
            text=True,
        )
    try:
        ready = wait_until("desktop readiness trace", lambda: event(trace, "desktop.ready"))
        if not ready.get("contextShortcut") or not ready.get("imageShortcut"):
            raise RuntimeError(f"Global shortcut registration was not ready: {ready}")
        zommi = wait_until("the Zommi X11 window", x11.find_zommi_window)

        def compact_window() -> XWindowAttributes | None:
            attributes = x11.attributes(zommi)
            if (
                attributes.map_state == IS_VIEWABLE
                and attributes.width <= 320
                and attributes.height <= 320
            ):
                return attributes
            return None

        initial = wait_until("the compact Zommi surface", compact_window)
        x11.focus(fixture)
        if x11.focused_window() != fixture:
            raise RuntimeError("The external context fixture did not receive X11 focus.")
        x11.send_shortcut(shift=shortcut_shift)
        result = wait_until(expected_event, lambda: event(trace, expected_event))

        if expect_expanded:
            def expanded_and_focused() -> bool:
                attributes = x11.attributes(zommi)
                focus = x11.focused_window()
                return (
                    attributes.map_state == IS_VIEWABLE
                    and attributes.width >= 640
                    and attributes.height >= 500
                    and x11.is_descendant(focus, zommi)
                )

            wait_until("the expanded focused Zommi surface", expanded_and_focused)
        else:
            time.sleep(0.5)
            after = compact_window()
            if (
                after is None
                or after.width != initial.width
                or after.height != initial.height
            ):
                raise RuntimeError("Cancelled image selection expanded or hid the compact surface.")

        if process.poll() is not None:
            raise RuntimeError(f"Zommi exited during {name} with code {process.returncode}.")
        return result
    except Exception as error:
        log = runtime_log.read_text(encoding="utf-8", errors="replace")
        trace_output = trace.read_text(encoding="utf-8", errors="replace") if trace.exists() else ""
        raise RuntimeError(
            f"{error}\n--- {name} acceptance trace ---\n{trace_output[:12000]}"
            f"\n--- {name} runtime log ---\n{log[:12000]}"
        ) from error
    finally:
        stop_process(process)


def run_acceptance(package: Path) -> int:
    application = package / "zommi"
    core = package / "zommi-core-host"
    if not application.is_file() or not os.access(application, os.X_OK):
        raise RuntimeError(f"Executable Flutter entrypoint not found in {package}.")
    if not core.is_file() or not os.access(core, os.X_OK):
        raise RuntimeError(f"Executable Rust core not found in {package}.")
    if not os.environ.get("DISPLAY"):
        raise RuntimeError("Run Linux X11 acceptance under xvfb-run or a dedicated X11 session.")

    x11 = X11()
    fixture_title = "ZOMMI_X11_CONTEXT_FIXTURE"
    fixture = x11.create_fixture(fixture_title)
    try:
        with tempfile.TemporaryDirectory(prefix="zommi-x11-acceptance-") as directory:
            temporary = Path(directory)
            write_tool_wrapper(temporary / "xdotool", "xdotool")
            write_tool_wrapper(temporary / "gnome-screenshot", "gnome-screenshot")

            context = run_case(
                package,
                x11,
                fixture,
                temporary,
                "context",
                shortcut_shift=False,
                capture_mode="cancel",
                expected_event="shortcut.context",
                expect_expanded=True,
            )
            if context.get("windowTitle") != fixture_title or not context.get("attached"):
                raise RuntimeError(f"Alt+A did not preserve the focused context title: {context}")

            cancelled = run_case(
                package,
                x11,
                fixture,
                temporary,
                "image-cancel",
                shortcut_shift=True,
                capture_mode="cancel",
                expected_event="shortcut.image.cancelled",
                expect_expanded=False,
            )

            image = run_case(
                package,
                x11,
                fixture,
                temporary,
                "image-success",
                shortcut_shift=True,
                capture_mode="success",
                expected_event="shortcut.image",
                expect_expanded=True,
            )
            expected_image = {
                "attached": True,
                "hasImage": True,
                "hasPointerContext": True,
                "width": 1,
                "height": 1,
            }
            for key, value in expected_image.items():
                if image.get(key) != value:
                    raise RuntimeError(f"Alt+Shift+A image contract failed: {image}")

            print(
                json.dumps(
                    {
                        "x11ContextShortcut": True,
                        "contextTitle": context["windowTitle"],
                        "imageCancelPreservedCompact": bool(cancelled),
                        "imageShortcut": True,
                        "imageDimensions": [image["width"], image["height"]],
                        "pointerContextPaired": image["hasPointerContext"],
                    },
                    separators=(",", ":"),
                )
            )
        return 0
    finally:
        x11.lib.XDestroyWindow(x11.display, fixture)
        x11.close()


def main() -> int:
    if len(sys.argv) >= 3 and sys.argv[1] == "--tool":
        return run_tool(sys.argv[2], sys.argv[3:])
    if len(sys.argv) != 2:
        print("usage: scripts/accept-linux-x11.py <package-directory>", file=sys.stderr)
        return 2
    return run_acceptance(Path(sys.argv[1]).resolve())


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"Linux X11 acceptance failed: {error}", file=sys.stderr)
        raise
