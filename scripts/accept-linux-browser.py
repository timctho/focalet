#!/usr/bin/env python3
"""Verify X11 window binding, AT-SPI viewport and DOM on a real Chromium window.

Run inside an isolated Xvfb and D-Bus session with a window manager, after
building zommi-x11-capture and Zommi.BrowserCapture. Only synthetic data is used.
"""
import argparse
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--browser', type=Path, required=True)
    parser.add_argument('--capture-host', type=Path, default=ROOT / 'target/debug/zommi-x11-capture')
    parser.add_argument('--browser-host', type=Path, default=ROOT / 'src/Zommi.BrowserCapture/bin/Release/net8.0/zommi-browser-capture.dll')
    args = parser.parse_args()
    environment = {**os.environ, 'GDK_BACKEND': 'x11', 'NO_AT_BRIDGE': '0'}
    subprocess.run(['gdbus', 'call', '--session', '--dest', 'org.a11y.Bus', '--object-path', '/org/a11y/bus',
                    '--method', 'org.freedesktop.DBus.Properties.Set', 'org.a11y.Status', 'IsEnabled', '<true>'],
                   check=True, capture_output=True)
    with tempfile.TemporaryDirectory(prefix='zommi-native-browser-') as temporary:
        directory = Path(temporary)
        fixture = directory / 'fixture.html'
        fixture.write_text('''<!doctype html><html><head><title>Zommi DOM fixture</title>
<style>body{margin:0;background:#eef6fa;font:24px sans-serif}
main{margin:30px;background:#acdcee;padding:40px;width:500px;height:320px}
.spacer{height:2200px}</style></head><body><main><button>CAPTURE_DOM_SENTINEL</button>
<p>Native viewport plus shared DOM</p></main><div class="spacer">Below the fold</div></body></html>''')
        profile = directory / 'profile'
        port_file = profile / 'DevToolsActivePort'
        with (directory / 'browser.log').open('w') as log:
            browser = subprocess.Popen([
                str(args.browser.resolve()), '--no-sandbox', '--disable-dev-shm-usage',
                '--force-renderer-accessibility', '--no-first-run', '--no-default-browser-check',
                '--disable-background-networking', '--disable-component-update', '--disable-sync',
                '--remote-debugging-port=0', f'--user-data-dir={profile}', '--window-size=1000,800', fixture.as_uri(),
            ], env=environment, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            host = None
            try:
                def native(*arguments):
                    return json.loads(subprocess.check_output([str(args.capture_host.resolve()), *arguments],
                        env=environment, text=True, timeout=15))

                source = None
                deadline = time.monotonic() + 25
                while time.monotonic() < deadline:
                    if browser.poll() is not None:
                        raise RuntimeError('The fixture browser exited; ' + (directory / 'browser.log').read_text())
                    if port_file.exists():
                        frame = native('snapshot')['frames'][0]
                        source = next((window for window in frame['windows'] if 'Zommi DOM fixture' in window['windowTitle']), None)
                        if source:
                            break
                    time.sleep(.25)
                assert source, 'The native reader could not find the browser inside the window manager frame'
                bounds = source['bounds']
                # First ask AT-SPI for the actual page viewport. Browser chrome
                # and optional infobars must not become an assumed page offset.
                anchor = {'x': bounds['x'] + 100, 'y': bounds['y'] + 350, 'width': 8, 'height': 8}
                viewport = native('observe', json.dumps(anchor)).get('browserViewport')
                assert viewport, 'The accessible browser page viewport was unavailable'
                region = {'x': viewport['x'] + 20, 'y': viewport['y'] + 20, 'width': 600, 'height': 290}
                current = native('observe', json.dumps(region))
                assert current['stable'], current['limitation']
                assert current.get('browserViewport'), current['limitation']
                endpoint = 'http://127.0.0.1:' + port_file.read_text().splitlines()[0]
                executable = args.browser_host.resolve()
                command = ['dotnet', str(executable)] if executable.suffix == '.dll' else [str(executable)]
                host = subprocess.Popen(command, env={**environment, 'ZOMMI_BROWSER_CDP_ENDPOINT': endpoint},
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True)

                def request(method, parameters=None):
                    host.stdin.write(json.dumps({'id': method, 'method': method, 'params': parameters or {}}) + '\n')
                    host.stdin.flush()
                    if not select.select([host.stdout], [], [], 30)[0]:
                        raise RuntimeError(f'The browser host timed out handling {method}')
                    result = json.loads(host.stdout.readline())
                    assert result['ok'], result
                    return result['result']

                observed = request('observe', {'source': current['source'], 'windows': current['windows'],
                    'viewport': current['browserViewport'], 'bounds': region, 'imageWidth': 600, 'imageHeight': 290})
                assert observed['available'], observed
                confirmed = request('confirm')
                assert confirmed['available'], confirmed
                elements = confirmed['regionContext']['elements']
                assert 'CAPTURE_DOM_SENTINEL' in json.dumps(elements), elements
                for element in elements:
                    visible = element['visibleBounds']
                    assert visible['x'] >= -.01 and visible['y'] >= -.01
                    assert visible['x'] + visible['width'] <= 600.01
                    assert visible['y'] + visible['height'] <= 290.01
                request('shutdown')
                host.wait(timeout=5)
                print('PASS real Ubuntu browser window, AT-SPI viewport and shared DOM on a scrolling page')
                print('PASS native source binding tolerates decoration windows without process IDs')
                print('PASS captured text and DOM geometry map into the selected image')
            finally:
                if host and host.poll() is None:
                    host.terminate()
                    host.wait(timeout=5)
                if browser.poll() is None:
                    os.killpg(browser.pid, signal.SIGTERM)
                    browser.wait(timeout=10)


if __name__ == '__main__':
    main()
