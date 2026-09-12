#!/usr/bin/env python3
from __future__ import annotations

import ctypes
from ctypes import byref, c_bool, c_char_p, c_int, c_long, c_uint, c_ulong, c_void_p
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time


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
        self.xtest.XTestFakeMotionEvent.argtypes = [
            c_void_p,
            c_int,
            c_int,
            c_int,
            c_ulong,
        ]
        self.xtest.XTestFakeMotionEvent.restype = c_int
        self.xtest.XTestFakeButtonEvent.argtypes = [
            c_void_p,
            c_uint,
            c_int,
            c_ulong,
        ]
        self.xtest.XTestFakeButtonEvent.restype = c_int

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

    def send_key(self, keysym: int) -> None:
        keycode = self.lib.XKeysymToKeycode(self.display, keysym)
        if keycode == 0:
            raise RuntimeError(f"X11 could not resolve keysym {keysym}.")
        self.xtest.XTestFakeKeyEvent(self.display, keycode, True, CURRENT_TIME)
        self.lib.XSync(self.display, False)
        self.xtest.XTestFakeKeyEvent(self.display, keycode, False, CURRENT_TIME)
        self.lib.XSync(self.display, False)

    def drag_region(self, start: tuple[int, int], end: tuple[int, int]) -> None:
        self.xtest.XTestFakeMotionEvent(
            self.display, self.screen, start[0], start[1], CURRENT_TIME
        )
        self.xtest.XTestFakeButtonEvent(
            self.display, 1, True, CURRENT_TIME
        )
        self.lib.XSync(self.display, False)
        time.sleep(0.05)
        self.xtest.XTestFakeMotionEvent(
            self.display, self.screen, end[0], end[1], CURRENT_TIME
        )
        self.lib.XSync(self.display, False)
        time.sleep(0.05)
        self.xtest.XTestFakeButtonEvent(
            self.display, 1, False, CURRENT_TIME
        )
        self.lib.XSync(self.display, False)

    def click_point(self, point: tuple[int, int]) -> None:
        self.xtest.XTestFakeMotionEvent(
            self.display, self.screen, point[0], point[1], CURRENT_TIME
        )
        self.lib.XSync(self.display, False)
        self.xtest.XTestFakeButtonEvent(self.display, 1, True, CURRENT_TIME)
        self.lib.XSync(self.display, False)
        time.sleep(0.05)
        self.xtest.XTestFakeButtonEvent(self.display, 1, False, CURRENT_TIME)
        self.lib.XSync(self.display, False)


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


def descendant_pids(process_id: int) -> list[int]:
    result = []
    pending = [process_id]
    while pending:
        parent = pending.pop()
        children_path = Path(f"/proc/{parent}/task/{parent}/children")
        try:
            children = [int(value) for value in children_path.read_text().split()]
        except (FileNotFoundError, ProcessLookupError):
            continue
        result.extend(children)
        pending.extend(children)
    return result


def capture_helper_running(process_id: int) -> bool:
    for child in descendant_pids(process_id):
        try:
            executable = Path(f"/proc/{child}/exe").resolve()
        except (FileNotFoundError, ProcessLookupError):
            continue
        if executable.name == "zommi-x11-capture":
            return True
    return False


def stop_process(process: subprocess.Popen[str]) -> None:
    if process.poll() is not None:
        return
    process.send_signal(signal.SIGTERM)
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def select_point_context(capture: Path, x11: X11, fixture: int) -> dict[str, object]:
    x11.focus(fixture)
    process = subprocess.Popen(
        [str(capture), "point-context"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        time.sleep(0.15)
        x11.click_point((100, 100))
        stdout, stderr = process.communicate(timeout=10)
    except BaseException:
        stop_process(process)
        raise
    if process.returncode != 0:
        raise RuntimeError(f"X11 point-context selector failed: {stderr}")
    result = json.loads(stdout.strip().splitlines()[-1])
    if result.get("cancelled") or not result.get("windowTitle"):
        raise RuntimeError(f"X11 point-context selector returned no target: {result}")
    return result


def run_case(
    package: Path,
    x11: X11,
    fixture: int,
    temporary: Path,
    name: str,
    *,
    shortcut_shift: bool,
    selection_action: str | None,
    expected_event: str,
    expect_focused: bool,
) -> dict[str, object]:
    trace = temporary / f"{name}.jsonl"
    runtime_log = temporary / f"{name}.log"
    environment = os.environ.copy()
    environment["GDK_BACKEND"] = "x11"
    environment["LIBGL_ALWAYS_SOFTWARE"] = "1"
    environment["ZOMMI_ACCEPTANCE_LOG"] = str(trace)
    environment["XDG_STATE_HOME"] = str(temporary / f"{name}-state")
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
        if not ready.get("contextShortcut") or ready.get("imageShortcut"):
            raise RuntimeError(f"Global shortcut registration was not ready: {ready}")
        zommi = wait_until("the Zommi X11 window", x11.find_zommi_window)

        def taskbar_window() -> XWindowAttributes | None:
            attributes = x11.attributes(zommi)
            if (
                attributes.map_state == IS_VIEWABLE
                and attributes.width >= 640
                and attributes.height >= 500
            ):
                return attributes
            return None

        initial = wait_until("the taskbar Zommi surface", taskbar_window)
        x11.focus(fixture)
        if x11.focused_window() != fixture:
            raise RuntimeError("The external context fixture did not receive X11 focus.")
        x11.send_shortcut(shift=shortcut_shift)
        if selection_action is not None:
            wait_until(
                "the Rust X11 region selector",
                lambda: capture_helper_running(process.pid),
            )
            time.sleep(0.15)
            if selection_action == "cancel":
                x11.send_key(0xFF1B)
            elif selection_action == "click":
                x11.click_point((100, 100))
            elif selection_action == "drag":
                x11.drag_region((100, 100), (140, 130))
            else:
                raise RuntimeError(f"Unknown selector action: {selection_action}")
        result = wait_until(expected_event, lambda: event(trace, expected_event))

        if expect_focused:
            def taskbar_window_focused() -> bool:
                attributes = x11.attributes(zommi)
                focus = x11.focused_window()
                return (
                    attributes.map_state == IS_VIEWABLE
                    and attributes.width >= 640
                    and attributes.height >= 500
                    and x11.is_descendant(focus, zommi)
                )

            wait_until("the focused taskbar Zommi surface", taskbar_window_focused)
        else:
            time.sleep(0.5)
            after = taskbar_window()
            if (
                after is None
                or after.width != initial.width
                or after.height != initial.height
            ):
                raise RuntimeError("Cancelled image selection resized or hid the taskbar surface.")

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
    capture = package / "zommi-x11-capture"
    if not application.is_file() or not os.access(application, os.X_OK):
        raise RuntimeError(f"Executable Flutter entrypoint not found in {package}.")
    if not core.is_file() or not os.access(core, os.X_OK):
        raise RuntimeError(f"Executable Rust core not found in {package}.")
    if not capture.is_file() or not os.access(capture, os.X_OK):
        raise RuntimeError(f"Executable Rust X11 capture host not found in {package}.")
    if not os.environ.get("DISPLAY"):
        raise RuntimeError("Run Linux X11 acceptance under xvfb-run or a dedicated X11 session.")

    x11 = X11()
    fixture_title = "ZOMMI_X11_CONTEXT_FIXTURE"
    fixture = x11.create_fixture(fixture_title)
    try:
        with tempfile.TemporaryDirectory(prefix="zommi-x11-acceptance-") as directory:
            temporary = Path(directory)
            context = run_case(
                package,
                x11,
                fixture,
                temporary,
                "context",
                shortcut_shift=False,
                selection_action="drag",
                expected_event="selection.content",
                expect_focused=True,
            )
            if context.get("count") != 1:
                raise RuntimeError(f"Alt+A did not attach one rectangle: {context}")
            image = context["items"][0]
            expected_bounds = {"x": 100, "y": 100, "width": 40, "height": 30}
            if not image.get("hasImage") or image.get("bounds") != expected_bounds:
                raise RuntimeError(f"Alt+A did not preserve the selected image rectangle: {context}")
            if image.get("alignmentStatus") != "image-only":
                raise RuntimeError(f"X11 rectangle claimed unavailable semantic alignment: {context}")

            clicked = run_case(
                package,
                x11,
                fixture,
                temporary,
                "content-click",
                shortcut_shift=False,
                selection_action="click",
                expected_event="selection.content",
                expect_focused=True,
            )
            if clicked.get("count") != 0:
                raise RuntimeError(f"A click without a rectangle attached an item: {clicked}")

            pointed = select_point_context(capture, x11, fixture)
            if pointed.get("windowTitle") != fixture_title:
                raise RuntimeError(
                    f"Point context did not preserve the clicked window title: {pointed}"
                )

            cancelled = run_case(
                package,
                x11,
                fixture,
                temporary,
                "content-cancel",
                shortcut_shift=False,
                selection_action="cancel",
                expected_event="selection.content",
                expect_focused=True,
            )

            if cancelled.get("count") != 0:
                raise RuntimeError(f"Cancelled content selection attached an item: {cancelled}")

            print(
                json.dumps(
                    {
                        "x11ContextShortcut": True,
                        "contextImageBounds": image["bounds"],
                        "contextClickWithoutRectangleIgnored": True,
                        "pointContextTitle": pointed["windowTitle"],
                        "contentCancelRestoredFocusedTaskbar": bool(cancelled),
                        "imageShortcut": False,
                    },
                    separators=(",", ":"),
                )
            )
        return 0
    finally:
        x11.lib.XDestroyWindow(x11.display, fixture)
        x11.close()


def main() -> int:
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
