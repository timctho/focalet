#!/usr/bin/env python3
"""Probe a real packaged Mac app; report permission limits without calling them capture success."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import platform
import signal
import subprocess
import tempfile
import time


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('package', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--require-capture', action='store_true')
    parser.add_argument('--interactive', action='store_true', help='Drive the native rectangle selector and Escape using CGEvents; requires input permissions.')
    args = parser.parse_args()
    if platform.system() != 'Darwin':
        parser.error('This probe must run on a Mac with a graphical login session.')
    package = args.package.resolve()
    executable = package / 'Zommi.app/Contents/MacOS/Zommi'
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    report_path = output / 'capture-probe.json'
    report_path.unlink(missing_ok=True)
    manifest = json.loads((package / 'release-manifest.json').read_text())
    # The normal app initializer still launches the packaged core. This probe
    # runs inside that app process, so TCC status belongs to Zommi itself.
    environment = dict(os.environ, ZOMMI_MACOS_CAPTURE_PROBE=str(report_path),
                       ZOMMI_ACCEPTANCE_LOG=str(output / 'desktop-events.jsonl'))
    with tempfile.TemporaryDirectory(prefix='zommi-macos-') as temporary:
        input_driver = Path(temporary) / 'capture-input'
        if args.interactive:
            subprocess.run(['swiftc', str(Path(__file__).with_name('macos-capture-input.swift')), '-o', str(input_driver)], check=True)
            environment['ZOMMI_MACOS_INTERACTIVE_PROBE'] = '1'
        fixture = Path(temporary) / 'zommi-capture-fixture.txt'
        fixture.write_text('Zommi macOS capture acceptance fixture\n')
        subprocess.run(['open', '-a', 'TextEdit', str(fixture)], check=True)
        subprocess.run(['osascript', '-e', 'tell application "TextEdit" to activate'], check=True, timeout=10)
        time.sleep(0.5)
        with (output / 'startup.log').open('w') as log:
            process = subprocess.Popen([str(executable)], env=environment, stdout=log,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            try:
                deadline = time.monotonic() + (90 if args.interactive else 45)
                sent_gestures = {}
                selected_session = None
                while not report_path.exists():
                    if process.poll() is not None:
                        raise RuntimeError(f'Packaged app exited {process.returncode}; see startup.log')
                    if time.monotonic() >= deadline:
                        raise RuntimeError('Packaged capture probe timed out; see startup.log')
                    if args.interactive:
                        startup = (output / 'startup.log').read_text(errors='replace')
                        for mode in ('select', 'cancel'):
                            if (f'macOS probe: {mode} region' not in startup or
                                    (mode == 'select' and 'macOS probe: cancel region' in startup)):
                                continue
                            attempts, last_sent = sent_gestures.get(mode, (0, 0))
                            trace = output / 'desktop-events.jsonl'
                            frames = [json.loads(line) for line in trace.read_text().splitlines() if line.strip()] if trace.exists() else []
                            editor = next((item for item in reversed(frames) if item.get('event') == 'capture.editor.ready'), None)
                            selector = editor['session'] if editor else None
                            if mode == 'cancel' and selector == selected_session: continue
                            if selector is not None and attempts < 3 and time.monotonic() - last_sent >= 3:
                                # Retry only while this app's exact overlay is open.
                                time.sleep(0.7)
                                trace = output / 'desktop-events.jsonl'
                                frames = [json.loads(line) for line in trace.read_text().splitlines() if line.strip()] if trace.exists() else []
                                editor = next((item for item in reversed(frames) if item.get('event') == 'capture.editor.ready'), None)
                                if editor is None: continue
                                bounds = editor['bounds']
                                coordinates = [bounds['x'] + bounds['width'] * .25, bounds['y'] + bounds['height'] * .25,
                                               bounds['x'] + bounds['width'] * .45, bounds['y'] + bounds['height'] * .45]
                                subprocess.run([str(input_driver), mode, *map(str, coordinates)], check=True, timeout=10)
                                if mode == 'select': selected_session = selector
                                sent_gestures[mode] = (attempts + 1, time.monotonic())
                                print(f'{mode} gesture {attempts + 1} -> selector {selector}', flush=True)
                    time.sleep(0.25)
                report = json.loads(report_path.read_text())
                if process.poll() is not None:
                    raise RuntimeError('Packaged app exited after producing its probe.')
                if Path(report['executable']).resolve() != executable or report['processId'] != process.pid:
                    raise RuntimeError('Probe was not produced by the launched package.')
                report['inputAttempts'] = {mode: attempts for mode, (attempts, _) in sent_gestures.items()}
                report['releaseIdentity'] = manifest
                time.sleep(0.7)  # Allow the restored window to present its frame.
                shot = subprocess.run(['screencapture', '-x', str(output / 'desktop.png')],
                                      capture_output=True, text=True, timeout=10)
                report['desktopScreenshot'] = {'success': shot.returncode == 0, 'error': shot.stderr.strip()}
                if args.interactive and shot.returncode == 0:
                    report['renderedWindow'] = json.loads(subprocess.check_output([str(input_driver), 'inspect', str(output / 'desktop.png')], text=True, timeout=10))
                report_path.write_text(json.dumps(report, indent=2) + '\n')
                print(json.dumps({key: value for key, value in report.items() if key != 'releaseIdentity'}, indent=2))
                if args.interactive and report.get('renderedWindow', {}).get('nonBlackFraction', 0) < 0.2:
                    raise RuntimeError('The restored app window is blank or unavailable; inspect desktop.png.')
                if 'Impeller validation:' in (output / 'startup.log').read_text(errors='replace'):
                    raise RuntimeError('Native renderer validation failed; inspect startup.log.')
                if report['status'] != 'completed':
                    raise RuntimeError('Native permission/startup probe failed.')
                if any(report.get(key, {}).get('status') == 'failed' for key in ('context', 'pixels')):
                    raise RuntimeError('Capture failed despite granted permission; inspect the report.')
                if all(report.get('permissions', {}).values()) and not report['captureVerified']:
                    raise RuntimeError('Granted capture returned the wrong external context. Inspect the report.')
                if args.interactive and report.get('permissions', {}).get('screenRecording') and report.get('interactiveRegionCancellation') != 'passed':
                    raise RuntimeError('Interactive capture/cancellation did not complete.')
                if args.require_capture and not report['captureVerified']:
                    raise RuntimeError('Capture is unverified. Enable Zommi capture permissions, restart, and retry.')
            finally:
                log.flush()
                print('Packaged app startup log:', flush=True)
                print((output / 'startup.log').read_text(errors='replace'), flush=True)
                if report_path.exists():
                    print(report_path.read_text(), flush=True)
                # Only this app and its children, never existing user processes.
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                    process.wait(timeout=5)
                except ProcessLookupError:
                    pass
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=5)


if __name__ == '__main__':
    main()
