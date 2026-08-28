import { mkdir, writeFile } from 'node:fs/promises';

const portArgument = process.argv.find((argument) => argument.startsWith('--port='));
const port = Number(portArgument?.slice('--port='.length) || 9333);
const captureDirectory = process.argv
  .find((argument) => argument.startsWith('--capture-dir='))
  ?.slice('--capture-dir='.length);
const endpoint = `http://127.0.0.1:${port}/json/list`;

if (captureDirectory) await mkdir(captureDirectory, { recursive: true });

const page = await waitForPage(endpoint);
const socket = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((resolve, reject) => {
  socket.addEventListener('open', resolve, { once: true });
  socket.addEventListener('error', reject, { once: true });
});

let requestId = 0;
const pending = new Map();
socket.addEventListener('message', (event) => {
  const message = JSON.parse(String(event.data));
  const waiter = pending.get(message.id);
  if (!waiter) return;
  pending.delete(message.id);
  if (message.error) waiter.reject(new Error(message.error.message));
  else waiter.resolve(message.result);
});

async function call(method, params = {}) {
  const id = ++requestId;
  const response = new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
  socket.send(JSON.stringify({ id, method, params }));
  return response;
}

async function evaluate(expression) {
  const result = await call('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
  if (result.exceptionDetails) throw new Error(result.exceptionDetails.text || 'Renderer evaluation failed.');
  return result.result?.value;
}

const snapshotExpression = `(() => {
  const glass = document.querySelector('.glass');
  const shell = document.querySelector('.panel-shell');
  const surface = document.querySelector('.panel-surface');
  const orb = document.querySelector('#ZommiOrb');
  const shellStyle = getComputedStyle(shell);
  const surfaceStyle = getComputedStyle(surface);
  const orbStyle = getComputedStyle(orb);
  const matrix = new DOMMatrixReadOnly(shellStyle.transform);
  const orbBounds = orb.getBoundingClientRect();
  return {
    compact: glass.classList.contains('is-compact'),
    reducedMotion: matchMedia('(prefers-reduced-motion: reduce)').matches,
    scaleX: matrix.a,
    scaleY: matrix.d,
    surfaceOpacity: Number(surfaceStyle.opacity),
    transitionDuration: shellStyle.transitionDuration,
    orbOpacity: Number(orbStyle.opacity),
    orbWidth: orbBounds.width,
    orbHeight: orbBounds.height,
  };
})()`;

const samples = [];
await captureSample('compact', 0);
await evaluate('window.zommi.openPanel(); true');
await collect('opening', [25, 75, 150, 260, 420]);
await evaluate('window.zommi.setWindowHovered(false); true');
await collect('closing', [450, 525, 600, 720, 900]);

const opening = samples.filter((sample) => sample.phase === 'opening');
const closing = samples.filter((sample) => sample.phase === 'closing');
const result = {
  samples,
  passed: samples[0].compact
    && samples[0].surfaceOpacity > 0.99
    && opening.some((sample) => sample.scaleX > 0.1 && sample.scaleX < 0.9)
    && opening.filter((sample) => sample.scaleX > 0.1 && sample.scaleX < 0.9)
      .every((sample) => sample.surfaceOpacity > 0.99)
    && opening.at(-1).scaleX > 0.99
    && closing[0].scaleX > 0.99
    && closing.some((sample) => sample.scaleX > 0.1 && sample.scaleX < 0.9)
    && closing.filter((sample) => sample.scaleX > 0.1 && sample.scaleX < 0.9)
      .every((sample) => sample.surfaceOpacity > 0.99)
    && closing.at(-1).scaleX < 0.1,
};

if (captureDirectory) await captureVisualSequence();
process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
socket.close();
if (!result.passed) process.exitCode = 1;

async function collect(phase, checkpoints) {
  let elapsed = 0;
  for (const checkpoint of checkpoints) {
    await delay(checkpoint - elapsed);
    elapsed = checkpoint;
    await captureSample(phase, checkpoint);
  }
}

async function captureSample(phase, elapsedMs) {
  const sample = { phase, elapsedMs, ...await evaluate(snapshotExpression) };
  samples.push(sample);
}

async function captureVisualSequence() {
  await captureFrame('00-compact');
  await evaluate('window.zommi.openPanel(); true');
  await delay(50);
  await captureFrame('01-opening');
  await delay(500);
  await captureFrame('02-open');
  await evaluate('window.zommi.setWindowHovered(false); true');
  await delay(450);
  await captureFrame('03-before-close');
  await delay(100);
  await captureFrame('04-closing');
  await delay(550);
  await captureFrame('05-compact-again');
}

async function captureFrame(name) {
  const screenshot = await call('Page.captureScreenshot', {
    format: 'png',
    fromSurface: true,
    captureBeyondViewport: false,
  });
  await writeFile(`${captureDirectory}/${name}.png`, Buffer.from(screenshot.data, 'base64'));
}

async function waitForPage(url) {
  let lastError = null;
  for (let attempt = 0; attempt < 80; attempt += 1) {
    try {
      const pages = await fetch(url).then((response) => response.json());
      const match = pages.find((candidate) => candidate.type === 'page' && candidate.title.includes('Zommi'));
      if (match) return match;
    } catch (error) {
      lastError = error;
    }
    await delay(100);
  }
  throw lastError || new Error(`Zommi page did not appear at ${url}.`);
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, Math.max(0, milliseconds)));
}
