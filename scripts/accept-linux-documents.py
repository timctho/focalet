#!/usr/bin/env python3
"""Test packaged floating HTML, thumbnails and capture recovery on an isolated X11 desktop."""
import argparse
import base64
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

from PIL import Image, ImageChops


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('package', type=Path)
    args = parser.parse_args()
    package = args.package.resolve()
    spec = importlib.util.spec_from_file_location('x11_acceptance', Path(__file__).with_name('accept-linux-x11.py'))
    native = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(native)
    x11 = native.X11()
    with tempfile.TemporaryDirectory(prefix='zommi-document-acceptance-') as temporary:
        directory = Path(temporary)
        fixture = directory / 'deck.html'
        fixture.write_text('''<!doctype html><html><head><style>
body{background:#123344;color:#fff;font:24px sans-serif}section{display:none;padding:30px}
section:target{display:grid;grid-template-columns:1fr 1fr;gap:24px}.card{background:#246080;padding:30px}
</style></head><body><section id="slide-12"><div class="card">Ocean preview</div>
<div class="card">Styled grid</div></section><script>document.title='Synthetic document'</script></body></html>''')
        config = directory / 'config'
        (config / 'zommi').mkdir(parents=True)
        (config / 'zommi/settings.json').write_text('{"runtimeSetupCompleted":true}')
        report_path = directory / 'report.json'
        events = directory / 'events.jsonl'
        environment = {**os.environ, 'GDK_BACKEND': 'x11', 'LIBGL_ALWAYS_SOFTWARE': '1',
            'ZOMMI_RUNTIME_DISCOVERY_MODE': 'configured-only', 'ZOMMI_CORE_HOST': str(package / 'zommi-core-host'),
            'ZOMMI_X11_CAPTURE_HOST': str(package / 'zommi-x11-capture'),
            'XDG_CONFIG_HOME': str(config), 'XDG_STATE_HOME': str(directory / 'state'),
            'ZOMMI_DOCUMENT_PREVIEW_PATH': fixture.as_uri() + '#slide-12',
            'ZOMMI_DOCUMENT_PREVIEW_PROBE': str(report_path), 'ZOMMI_DOCUMENT_THUMBNAIL_PROBE': '1',
            'ZOMMI_ACCEPTANCE_LOG': str(events)}
        with (directory / 'startup.log').open('w') as log:
            process = subprocess.Popen([str(package / 'zommi')], env=environment, stdout=log,
                stderr=subprocess.STDOUT, start_new_session=True)
            try:
                def wait(description, predicate, seconds=25):
                    deadline = time.monotonic() + seconds
                    while time.monotonic() < deadline:
                        if process.poll() is not None:
                            raise RuntimeError('The document test app exited')
                        value = predicate()
                        if value:
                            return value
                        time.sleep(.1)
                    raise RuntimeError('Timed out waiting for ' + description)

                def document_bounds():
                    snapshot = json.loads(subprocess.check_output([str(package / 'zommi-x11-capture'), 'snapshot'],
                        env=environment, text=True, timeout=15))
                    png = base64.b64decode(snapshot['frames'][0]['dataUrl'].split(',')[1])
                    image = Image.open(io.BytesIO(png)).convert('RGB')
                    mask = None
                    for plane, color in zip(image.split(), (18, 51, 68)):
                        selected = plane.point(lambda value: 255 if value == color else 0)
                        mask = selected if mask is None else ImageChops.multiply(mask, selected)
                    return mask.getbbox()

                wait('the rendered document', report_path.exists)
                report = json.loads(report_path.read_text())
                assert report['status'] == 'opened', report
                page = report['document']
                assert page['target']['display'] == 'grid' and page['hash'] == '#slide-12', page
                assert page['stylesheets'] >= 1 and page['scripts'] >= 1, page
                assert page['viewport']['width'] > 300 and page['viewport']['height'] > 200, page
                assert report['thumbnail']['width'] == 1280 and report['thumbnail']['height'] == 720
                window = wait('the app window', x11.find_zommi_window)
                assert x11.pid(window) == process.pid, 'The probe must drive only its own app'
                original = wait('visible document pixels', document_bounds)
                assert original[2] - original[0] == page['viewport']['width']
                assert original[3] - original[1] == page['viewport']['height']
                x11.click_point((original[0] + 100, original[1] + 100))
                x11.send_shortcut(shift=False)
                wait('the capture editor', lambda: native.event(events, 'capture.editor.ready'))
                time.sleep(.3)
                assert document_bounds() is None, 'The native document covers the capture editor'
                x11.send_key(0xFF1B)
                cancelled = wait('capture cancellation', lambda: native.event(events, 'selection.content'))
                assert cancelled['count'] == 0
                wait('the restored document bounds', lambda: document_bounds() == original)
                x11.click_point((original[0] - 15, original[1] + 20))
                wait('outside-click dismissal', lambda: document_bounds() is None)
                assert process.poll() is None
                print('PASS floating HTML preserves CSS, JavaScript, slide fragment and full-layout thumbnail')
                print('PASS native document is suspended during capture and restores its exact panel bounds')
                print('PASS outside-click dismissal and capture cancellation leave the app usable')
            except Exception:
                print((directory / 'startup.log').read_text(errors='replace'))
                raise
            finally:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGTERM)
                    process.wait(timeout=10)
                x11.close()


if __name__ == '__main__':
    main()
