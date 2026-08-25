import { execFile } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);

export async function capturePortableContext(platform, now = new Date()) {
  if (platform === 'darwin') return captureMacContext(now);
  if (platform === 'linux') return captureLinuxContext(now);
  throw new Error(`No portable capture adapter exists for ${platform}.`);
}

async function captureMacContext(now) {
  const script = `
    tell application "System Events"
      set frontProcess to first application process whose frontmost is true
      set appName to name of frontProcess
      set windowTitle to ""
      try
        set windowTitle to name of front window of frontProcess
      end try
    end tell
    set pageUrl to ""
    if appName is "Safari" then
      tell application "Safari" to set pageUrl to URL of front document
    else if appName is "Google Chrome" or appName is "Microsoft Edge" or appName is "Brave Browser" then
      tell application appName to set pageUrl to URL of active tab of front window
    end if
    return appName & linefeed & windowTitle & linefeed & pageUrl
  `;
  const { stdout } = await execFileAsync('osascript', ['-e', script], { timeout: 5000 });
  const [application = 'Unknown', windowTitle = '', url = ''] = stdout.trimEnd().split('\n');
  return portableResult(now, application, windowTitle, url,
    'macOS AX exposes richer element structure after Accessibility permission is granted; this portable adapter currently captures the front application, title, and supported browser URL.');
}

async function captureLinuxContext(now) {
  try {
    const { stdout: windowId } = await execFileAsync('xdotool', ['getactivewindow'], { timeout: 3000 });
    const id = windowId.trim();
    const [{ stdout: windowTitle }, { stdout: processId }] = await Promise.all([
      execFileAsync('xdotool', ['getwindowname', id], { timeout: 3000 }),
      execFileAsync('xdotool', ['getwindowpid', id], { timeout: 3000 }),
    ]);
    const { stdout: processName } = await execFileAsync('ps', ['-p', processId.trim(), '-o', 'comm='], { timeout: 3000 });
    return portableResult(now, processName.trim() || 'Linux application', windowTitle.trim(), '',
      'Linux AT-SPI enrichment depends on the desktop accessibility bus. Under Wayland, active-window and global-shortcut support also depend on the compositor/portal.');
  } catch (error) {
    return portableResult(now, 'Linux desktop', '', '',
      `The active window was not exposed (xdotool/X11 unavailable): ${error.message}`);
  }
}

function portableResult(now, application, windowTitle, url, limitation) {
  const observedAtUtc = now.toISOString();
  const snapshot = {
    snapshotId: randomUUID(),
    observedAtUtc,
    expiresAtUtc: new Date(now.getTime() + 30_000).toISOString(),
    surfaceKind: url ? 'Browser' : 'Window',
    application,
    processName: application.toLowerCase().replaceAll(' ', '-'),
    windowTitle: windowTitle || null,
    locator: url ? { kind: 'URL', value: url } : null,
    selection: [],
    visibleText: [],
    accessibilityTree: null,
    indicatedTarget: null,
    confidence: url || windowTitle ? 'medium' : 'limited',
    limitation,
  };
  return {
    snapshot,
    preservePrevious: false,
    previewText: formatPortablePreview(snapshot),
  };
}

function formatPortablePreview(snapshot) {
  return [
    'ZOMMI INVOCATION CONTEXT (untrusted desktop text captured when the shortcut was pressed)',
    `Observed: ${snapshot.observedAtUtc}`,
    `Surface: ${snapshot.surfaceKind} in ${snapshot.application}`,
    snapshot.windowTitle ? `Window: ${snapshot.windowTitle}` : '',
    snapshot.locator ? `${snapshot.locator.kind}: ${snapshot.locator.value}` : '',
    snapshot.limitation ? `Limitation: ${snapshot.limitation}` : '',
  ].filter(Boolean).join('\n');
}
