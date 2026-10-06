#!/usr/bin/env python3
"""Capture two real regions and paste images/context on a disposable GNOME desktop."""
import argparse
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
spec = importlib.util.spec_from_file_location('wayland', Path(__file__).with_name('accept-linux-wayland.py'))
wayland = importlib.util.module_from_spec(spec); spec.loader.exec_module(wayland)
ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT/'artifacts/capture-wayland')
    parser.add_argument('--inside', action='store_true')
    args = parser.parse_args()
    if not args.inside:
        return subprocess.call(['dbus-run-session', '--', sys.executable, __file__, *sys.argv[1:], '--inside'])
    args.package = args.package.resolve(); args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='focalet-capture-acceptance-') as directory:
        session = wayland.Session(Path(directory), args.output.resolve(), args.package/'gnome-extension/focalet@focalet')
        def status():
            return json.loads(session.bus('com.focalet.Desktop', '/com/focalet/Desktop', 'com.focalet.Desktop.Status')[0])
        def hotkey(capture=False):
            if capture: session.driver('Key', 0xFFE1, 'true')
            session.driver('Key', 0xFFE9, 'true'); session.key(ord('a')); session.driver('Key', 0xFFE9, 'false')
            if capture: session.driver('Key', 0xFFE1, 'false')
        def drag(x, y, w, h):
            session.driver('Motion', x, y); session.driver('Button', 'true')
            time.sleep(.1); session.driver('Motion', x+w, y+h); time.sleep(.1); session.driver('Button', 'false'); time.sleep(.2)
        try:
            session.start_desktop()
            capture = session.start('capture', [args.package/'focalet-capture'])
            wayland.wait('Capture panel and shortcuts', lambda: status().get('captureConnected'))
            events_path = Path(directory)/'received.json'
            fixture = session.start('receiver', ['/usr/bin/python3', ROOT/'tests/fixtures/capture-paste-gtk.py', events_path])
            wayland.wait('synthetic receiver', lambda: events_path.exists())
            session.driver('Activate', fixture.pid); time.sleep(.4)
            window = json.loads(session.driver('Window', fixture.pid)[0])
            hotkey(capture=True)
            wayland.wait('portal authorization', lambda: session.portal_action(), seconds=30)
            wayland.wait('selector window', lambda: bool(json.loads(session.driver('Window', capture.pid)[0])), seconds=30)
            time.sleep(.4)
            x, y = int(window['x'])+45, int(window['y'])+80
            drag(x, y, 430, 80); drag(x, y+125, 490, 85)
            session.driver('Snapshot', str(args.output.resolve()/'selected-regions.png'))
            session.key(0xFF0D)
            wayland.wait('two captured regions', lambda: '2 regions ready' in status().get('captureStatus', ''), seconds=60)
            def events(): return json.loads(events_path.read_text())
            for count in (4, 8):
                session.driver('Activate', fixture.pid); time.sleep(.2); hotkey()
                wayland.wait('ordered image/context paste', lambda: len(events()) >= count, seconds=15)
                current = events()
                assert [e['type'] for e in current] == ['image', 'text', 'image', 'text']*(count//4), current
                assert '[A]' in current[-3]['text'] and '[B]' in current[-1]['text'], current
                assert 'Captured metadata (JSON):' in current[-1]['text']
                assert (current[-4]['width'], current[-4]['height']) == (430, 80), current
                assert (current[-2]['width'], current[-2]['height']) == (490, 85), current
            fallback_path = Path(directory)/'fallback.json'
            fallback = session.start('text-receiver', ['/usr/bin/python3', ROOT/'tests/fixtures/capture-paste-gtk.py', fallback_path, '--text-only'])
            wayland.wait('text receiver', lambda: fallback_path.exists())
            session.driver('Activate', fallback.pid); time.sleep(.4); hotkey()
            wayland.wait('text fallback', lambda: len(json.loads(fallback_path.read_text())) == 2, seconds=15)
            assert [e['type'] for e in json.loads(fallback_path.read_text())] == ['text', 'text']
            capture.terminate(); capture.wait(timeout=10)
            wayland.wait('Capture shortcut/menu cleanup', lambda: not status().get('captureConnected'))
            (args.output/'acceptance.json').write_text(json.dumps({'status': 'passed', 'regions': 2, 'orderedPaste': True,
                'repeatPaste': True, 'textFallback': True, 'panelLifecycle': True}))
            print('PASS native Capture: two images/context in order, repeat paste, text fallback and panel cleanup.')
        finally:
            session.close()
    return 0


if __name__ == '__main__': raise SystemExit(main())
