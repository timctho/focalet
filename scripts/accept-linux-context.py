#!/usr/bin/env python3
"""Exercise X11 pixels and real GTK/AT-SPI context in an isolated test desktop.

Run with: xvfb-run -a dbus-run-session -- python3 scripts/accept-linux-context.py
No real desktop or agent session is used.
"""
import argparse
import base64
import ctypes
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import time


def fixture(directory):
    gtk = ctypes.CDLL('libgtk-3.so.0')
    glib = ctypes.CDLL('libglib-2.0.so.0')
    pointer = ctypes.c_void_p
    def function(name, result, *arguments):
        value = getattr(gtk, name)
        value.restype = result
        value.argtypes = arguments
        return value
    function('gtk_init_check', ctypes.c_int, pointer, pointer)(None, None)
    window = function('gtk_window_new', pointer, ctypes.c_int)(0)
    function('gtk_window_set_title', None, pointer, ctypes.c_char_p)(window, b'Zommi accessibility fixture')
    function('gtk_window_set_default_size', None, pointer, ctypes.c_int, ctypes.c_int)(window, 720, 400)
    function('gtk_window_move', None, pointer, ctypes.c_int, ctypes.c_int)(window, 0, 0)
    fixed = function('gtk_fixed_new', pointer)()
    function('gtk_container_add', None, pointer, pointer)(window, fixed)
    label = function('gtk_label_new', pointer, ctypes.c_char_p)
    put = function('gtk_fixed_put', None, pointer, pointer, ctypes.c_int, ctypes.c_int)
    size = function('gtk_widget_set_size_request', None, pointer, ctypes.c_int, ctypes.c_int)
    visible = label(b'CAPTURE_VISIBLE_SENTINEL'); put(fixed, visible, 20, 20); size(visible, 300, 40)
    entry = function('gtk_entry_new', pointer)
    set_text = function('gtk_entry_set_text', None, pointer, ctypes.c_char_p)
    secret = entry(); set_text(secret, b'NEVER_EXPOSE_PASSWORD'); put(fixed, secret, 20, 80); size(secret, 300, 40)
    function('gtk_entry_set_visibility', None, pointer, ctypes.c_int)(secret, 0)
    check = function('gtk_check_button_new_with_label', pointer, ctypes.c_char_p)(b'Fixture option')
    put(fixed, check, 20, 140); size(check, 300, 40)
    function('gtk_toggle_button_set_active', None, pointer, ctypes.c_int)(check, 1)
    value = entry(); set_text(value, b'READABLE_VALUE'); put(fixed, value, 20, 200); size(value, 300, 40)
    hidden = label(b'NEVER_EXPOSE_HIDDEN'); put(fixed, hidden, 20, 260)
    outside = label(b'OUTSIDE_SELECTION'); put(fixed, outside, 390, 30)
    counter = label(b'0'); put(fixed, counter, 390, 150)
    set_label = function('gtk_label_set_text', None, pointer, ctypes.c_char_p)
    count = 0
    callback_type = ctypes.CFUNCTYPE(ctypes.c_int, pointer)
    @callback_type
    def tick(_):
        nonlocal count
        count += 1
        set_label(counter, str(count).encode())
        if (directory / 'inside').exists():
            set_text(value, str(count).encode())
        return 1
    glib.g_timeout_add.argtypes = [ctypes.c_uint, callback_type, pointer]
    glib.g_timeout_add(10, tick, None)
    function('gtk_widget_show_all', None, pointer)(window)
    function('gtk_widget_hide', None, pointer)(hidden)
    (directory / 'ready').write_text('ready')
    function('gtk_main', None)()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', type=Path, default=Path(__file__).resolve().parents[1] / 'target/debug/zommi-x11-capture')
    parser.add_argument('--fixture', type=Path)
    args = parser.parse_args()
    if args.fixture:
        fixture(args.fixture)
        return
    # This is the test's private session bus, not the user's accessibility setting.
    subprocess.run(['gdbus', 'call', '--session', '--dest', 'org.a11y.Bus', '--object-path', '/org/a11y/bus',
        '--method', 'org.freedesktop.DBus.Properties.Set', 'org.a11y.Status', 'IsEnabled', '<true>'], check=True, capture_output=True)
    with tempfile.TemporaryDirectory(prefix='zommi-atspi-test-') as temporary:
        directory = Path(temporary)
        process = subprocess.Popen([sys.executable, __file__, '--fixture', str(directory)],
            env={**os.environ, 'NO_AT_BRIDGE': '0', 'GDK_BACKEND': 'x11'}, stdout=subprocess.DEVNULL)
        try:
            deadline = time.monotonic() + 10
            while not (directory / 'ready').exists():
                if process.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError('GTK accessibility fixture failed to start')
                time.sleep(.05)
            time.sleep(.6)
            def native(*arguments):
                result = subprocess.run([str(args.host.resolve()), *arguments], check=True, capture_output=True, text=True, timeout=15)
                return json.loads(result.stdout)
            source = None
            for _ in range(10):
                frame = native('snapshot')['frames'][0]
                source = next((window for window in frame['windows'] if window['windowTitle'] == 'Zommi accessibility fixture'), None)
                if source:
                    break
                time.sleep(.2)
            assert source, frame['windows']
            assert source['processId'] == process.pid
            assert source['processStartToken']
            region = {'x': source['bounds']['x'] + 10, 'y': source['bounds']['y'] + 10, 'width': 330, 'height': 290}
            observations = []
            for _ in range(5):
                observed = native('observe', json.dumps(region))
                assert observed['stable'], observed['limitation']
                assert observed['regionContext'], observed['limitation']
                elements = observed['regionContext']['elements']
                text = json.dumps(elements)
                assert 'CAPTURE_VISIBLE_SENTINEL' in text, text
                assert 'READABLE_VALUE' in text, text
                assert 'NEVER_EXPOSE_PASSWORD' not in text
                assert 'NEVER_EXPOSE_HIDDEN' not in text
                assert 'OUTSIDE_SELECTION' not in text
                assert any(item['state']['toggle'] == 'on' for item in elements)
                ids = {item['id'] for item in elements}
                assert all(item['parentId'] is None or item['parentId'] in ids for item in elements)
                assert all(item['visibleBounds']['width'] > 0 and item['visibleBounds']['height'] > 0 for item in elements)
                png = base64.b64decode(observed['dataUrl'].split(',', 1)[1])
                assert struct.unpack('>II', png[16:24]) == (330, 290)
                observations.append(observed)
            assert all(item['regionContext'] == observations[0]['regionContext'] for item in observations)
            (directory / 'inside').write_text('change the selected input')
            assert any(not native('observe', json.dumps(region))['stable'] for _ in range(5)), 'Changing selected input was not detected'
            print('PASS X11 window identity, original region pixels and screen coordinates')
            print('PASS live GTK labels, values, checked state and retained parent references')
            print('PASS password, hidden and out-of-region content omitted')
            print('PASS five captures survive updates outside the selection')
            print('PASS changes inside the selection invalidate the observation')
        finally:
            process.terminate()
            process.wait(timeout=5)


if __name__ == '__main__':
    main()
