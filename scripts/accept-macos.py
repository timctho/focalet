#!/usr/bin/env python3
"""Probe a real packaged Mac app; report permission limits without calling them capture success."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import platform
import re
import signal
import subprocess
import tempfile
import time


def current_editor(trace: Path) -> dict | None:
    if not trace.exists():
        return None
    latest = None
    for line in trace.read_text().splitlines():
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue  # The app may be appending its next diagnostic line.
        if value.get('event') in ('capture.editor.ready', 'capture.editor.closed'):
            latest = value
    return latest if latest and latest['event'] == 'capture.editor.ready' else None



def probe_pid(log: Path, executable: Path) -> int | None:
    matches = re.findall(r'^macOS probe: process (\d+)$', log.read_text(errors='replace'), re.MULTILINE)
    if len(matches) != 1:
        return None
    process_id = int(matches[0])
    result = subprocess.run(['ps', '-p', str(process_id), '-o', 'comm='],
                            capture_output=True, text=True, check=False)
    return process_id if result.returncode == 0 and result.stdout.strip() == str(executable) else None


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('package', type=Path)
    parser.add_argument('--app', type=Path, help='Test the installed copy, e.g. /Applications/Zommi.app.')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--require-capture', action='store_true')
    parser.add_argument('--window-title', help='Use an existing uniquely titled fixture instead of opening TextEdit.')
    parser.add_argument('--expected-text', help='Text that must appear in the fixture region attachment.')
    parser.add_argument('--require-dom', action='store_true')
    parser.add_argument('--browser-endpoint', help='Authorized CDP endpoint for the browser fixture.')
    gestures = parser.add_mutually_exclusive_group()
    gestures.add_argument('--interactive', action='store_true', help='Drive the native rectangle selector and Escape using CGEvents; requires input permissions.')
    gestures.add_argument('--manual-interactive', action='store_true', help='Wait for native selection and cancellation driven by the user or Computer Use.')
    args = parser.parse_args()
    if args.window_title and not args.expected_text:
        parser.error('--window-title requires --expected-text.')
    if platform.system() != 'Darwin':
        parser.error('This probe must run on a Mac with a graphical login session.')
    package = args.package.resolve()
    application = (args.app or package / 'Zommi.app').resolve()
    executable = application / 'Contents/MacOS/Zommi'
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    report_path = output / 'capture-probe.json'
    report_path.unlink(missing_ok=True)
    manifest = json.loads((package / 'release-manifest.json').read_text())
    # LaunchServices gives Zommi its own TCC identity. Direct exec inherits the
    # terminal/automation host's responsible process and misreports permissions.
    environment = dict(ZOMMI_MACOS_CAPTURE_PROBE=str(report_path),
                       ZOMMI_ACCEPTANCE_LOG=str(output / 'desktop-events.jsonl'))
    if args.window_title:
        environment['ZOMMI_MACOS_PROBE_WINDOW_TITLE'] = args.window_title
        environment['ZOMMI_MACOS_PROBE_EXPECTED_TEXT'] = args.expected_text
    if args.require_dom:
        environment['ZOMMI_MACOS_PROBE_DOM'] = '1'
    if args.browser_endpoint:
        environment['ZOMMI_BROWSER_CDP_ENDPOINT'] = args.browser_endpoint
    with tempfile.TemporaryDirectory(prefix='zommi-macos-') as temporary:
        input_driver = Path(temporary) / 'capture-input'
        if args.interactive:
            subprocess.run(['swiftc', str(Path(__file__).with_name('macos-capture-input.swift')), '-o', str(input_driver)], check=True)
        if args.interactive or args.manual_interactive:
            environment['ZOMMI_MACOS_INTERACTIVE_PROBE'] = '1'
        if not args.window_title:
            # Distinguish this document from still-open fixtures of earlier runs.
            fixture = Path(temporary) / f'zommi-capture-fixture-{Path(temporary).name}.txt'
            # Place the text inside the probe's interior crop; keep the caret
            # on the next line at the left edge, outside that crop.
            fixture.write_text('\n' * 8 + ' ' * 18 + 'Zommi macOS capture acceptance fixture\n')
            environment['ZOMMI_MACOS_PROBE_WINDOW_TITLE'] = fixture.stem
            subprocess.run(['open', '-a', 'TextEdit', str(fixture)], check=True)
            time.sleep(0.5)
        with (output / 'startup.log').open('w') as log:
            command = ['open', '-W', '-n', '-a', str(application),
                       '--stdout', str(output / 'startup.log'),
                       '--stderr', str(output / 'startup.log')]
            for key, value in environment.items():
                command.extend(['--env', f'{key}={value}'])
            process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=log)
            app_pid = None
            try:
                deadline = time.monotonic() + (90 if args.interactive or args.manual_interactive else 45)
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
                            editor = current_editor(trace)
                            selector = editor['session'] if editor else None
                            if mode == 'cancel' and selector == selected_session: continue
                            if selector is not None and attempts < 3 and time.monotonic() - last_sent >= 3:
                                # Retry only while this app's exact overlay is open.
                                time.sleep(0.7)
                                trace = output / 'desktop-events.jsonl'
                                editor = current_editor(trace)
                                if editor is None or editor['session'] != selector: continue
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
                app_pid = probe_pid(output / 'startup.log', executable)
                if Path(report['executable']).resolve() != executable or report['processId'] != app_pid:
                    raise RuntimeError('Probe was not produced by the launched package.')
                report['inputAttempts'] = {mode: attempts for mode, (attempts, _) in sent_gestures.items()}
                report['inputMode'] = 'manual' if args.manual_interactive else 'cgevents' if args.interactive else 'none'
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
                if (args.interactive or args.manual_interactive) and report.get('permissions', {}).get('screenRecording') and report.get('interactiveRegionCancellation') != 'passed':
                    raise RuntimeError('Interactive capture/cancellation did not complete.')
                if (args.require_capture or args.require_dom) and not report['captureVerified']:
                    raise RuntimeError('Capture is unverified. Enable Zommi capture permissions, restart, and retry.')
            finally:
                log.flush()
                print('Packaged app startup log:', flush=True)
                print((output / 'startup.log').read_text(errors='replace'), flush=True)
                if report_path.exists():
                    print(report_path.read_text(), flush=True)
                # Quit only the exact process recorded by this probe. `open` is
                # a LaunchServices waiter, not the app's PID or process group.
                app_pid = probe_pid(output / 'startup.log', executable)
                if app_pid is not None:
                    try:
                        os.kill(app_pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.terminate()
                    process.wait(timeout=5)



if __name__ == '__main__':
    main()
