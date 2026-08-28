import { randomUUID } from 'node:crypto';
import { once } from 'node:events';
import { writeFile } from 'node:fs/promises';
import { performance } from 'node:perf_hooks';
import { CodexAppServerAdapter } from '../src/Zommi.Electron/codex-bridge.mjs';

const budgets = {
  coldStartupMilliseconds: 10_000,
  acceptedMilliseconds: 1_000,
  firstAgentOutputMilliseconds: 10_000,
  completedMilliseconds: 30_000,
};
const imageToken = 'ZOMMI_IMAGE_4827';
const outputArgument = process.argv.find((value) => value.startsWith('--output='));
const outputPath = outputArgument?.slice('--output='.length) || null;
const selectedImage = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAtAAAADcAQAAAABxcatjAAADkElEQVR42u2aPY7jNhSAP8rCmsUCYZEinYWcIOV2Vm6yuUcAc26QI+Qm4RFyBE2XLlxgseBOOHopZMukbUmTAAFSPFYSTX58/4/CjBH+q9GgaEUrWtGKVrSiFa1oRSta0YpWtKIVrWhFK1rRila0ohWtaEUr+n+F/rp9jJi+en9u4dPiNhGRDBwkcJRhJyPHsJfMKRxEJO4zJwl7GTmKRIwEOIqIjJzEIwKnfObUoziy53cYGYFMLk4PhPPTL4i/zI4gnv4Vft0yyCt8XrHFyAC+mMgwwgDELfS0VMjASCrWDBfk7R9r84RNW+h0v7XGRMZyIpUnrKOjSXjwCZBKySgz4xSus5B2Q2I/LAjTAuwE0/Hu3VbsJeO//sbhymodfHAjYBalFhisIcxOGWoXQiIRG/aFB8BaCJad5GWDjPQ4PJzjzN9b1U46zr+E6clMijeL6IwPt7Lej8EWL74ErEidDHT04Iahhy6Eq9xNzhYiGVyx07yxhsTt+vHtTYFowKZky3BYCj4/uTAGgKE09piAgZFQTrZAjndBfoceWujpwIIHV6prrobobiL3tXOQm7OTH6PD/FPyAH9WukeA7+dKanogW2jmw+Ky1N7NNjOArYLJ00G4KQPJgfEESC21gyu0XFX9C4Av1aKP89Onuhd4PET7OGqbu/cGaCuP9/TAj/XC2MFUq4cHXriiR/oyqW9TIEwBVKXo0F+KanBUsVOj87xtytum8nhXQwt77wbAd2spkzZTS/D+LNpBwqWEvP8uIQTw/RK6SEZvAVN53D06eJ57MWv1+mLR1epkODJ8E07zvYHdT67NpOauVJZSD+dq6Va67uS5+xHbhc7X3CQjvePWNbbZrLRmEe0dMDwMoVrCB3PBUffjCi100E+B33UAfal7206BHrtHBc53C1fH5pomcSl8WbwWxIzQL1wXmksu0yWhh0MAOJan7BKkvcTkCsVP4n+exHpqHnaCCZ15Mo6Xly2hrfgAz+biY/f5j3axExTHObH45w34E8fy9bXbv+V+bVc7abTYfHsHspfuEu0qut3+RDD3Kru3SL2D91vG9tDXm89md+utIPDDSs452pGP7HytRX9/jas+OKaRjGyNPH1rzGPYryw2+r+Tiv73aGPMwve0adTW/3hoNipa0YpWtKIVrWhFK1rRila0ohWtaEUrWtGKVrSiFa1oRSta0YpWtKIVrWhFv3X8Df+aij9bPtceAAAAAElFTkSuQmCC';
const bridge = new CodexAppServerAdapter({ cwd: process.cwd() });

try {
  const startupAt = performance.now();
  await bridge.ensureStarted();
  const startupMilliseconds = Math.round(performance.now() - startupAt);
  assertWithin('Codex cold startup', startupMilliseconds, budgets.coldStartupMilliseconds);

  const now = new Date().toISOString();
  const sheetToken = `ZOMMI_SHEET_${randomUUID().replaceAll('-', '').slice(0, 12)}`.toUpperCase();
  const slideToken = `ZOMMI_SLIDE_${randomUUID().replaceAll('-', '').slice(0, 12)}`.toUpperCase();
  const sheet = {
    snapshotId: randomUUID(),
    observedAtUtc: now,
    surfaceKind: 'Browser',
    application: 'Chrome',
    processName: 'chrome',
    windowTitle: 'Quarterly plan',
    locator: { kind: 'URL', value: 'https://docs.google.com/spreadsheets/d/synthetic-latency-fixture' },
    selection: ['Revenue table'],
    selectionElements: [{
      controlType: 'GoogleSheetsRange', name: 'B2:F18', value: sheetToken, bounds: '100,200,700,420',
    }],
    selectionElementCount: 1,
    visibleText: ['Revenue', 'Q1', 'Q2', 'Q3', 'Q4'],
    accessibilityTree: {
      truncated: false,
      roots: [{
        role: 'Table', name: 'Revenue', rowCount: 17, columnCount: 5,
        children: [{ role: 'DataItem', name: 'Q1', row: 0, column: 1, isSelected: true }],
      }],
    },
    indicatedTarget: {
      controlType: 'DataItem', name: 'Revenue', row: 1, column: 1, bounds: '120,240,90,24',
    },
  };
  const slide = {
    ...sheet,
    snapshotId: randomUUID(),
    surfaceKind: 'Presentation',
    application: 'Microsoft PowerPoint',
    processName: 'POWERPNT',
    windowTitle: 'Quarterly review',
    locator: { kind: 'Slide', value: '4: Results' },
    selection: [],
    selectionElements: [{
      controlType: 'PowerPointShape', name: 'Chart 3', value: slideToken, bounds: '220,160,640,360',
    }],
    accessibilityTree: null,
  };

  const simpleToken = `ZOMMI_SIMPLE_${randomUUID().replaceAll('-', '').slice(0, 12)}`;
  const simple = await measureTurn(
    'simple',
    `Reply with exactly ${simpleToken} and nothing else.`,
    [],
    [],
    [simpleToken]);
  assertTurnWithin(simple);

  const selection = await measureTurn(
    'selection-rich',
    'Read the attached spreadsheet selection and reply with only the uppercase token beginning ZOMMI_SHEET_.',
    [sheet],
    [],
    [sheetToken]);
  assertTurnWithin(selection);

  const multi = await measureTurn(
    'multi-context-plus-image',
    'Read the selected PowerPoint shape and the selected image. Reply with their two uppercase tokens, PowerPoint first, separated by one space.',
    [sheet, slide],
    [selectedImage],
    [slideToken, imageToken]);
  assertTurnWithin(multi);

  const rendered = `${JSON.stringify({
    observedAtUtc: new Date().toISOString(), budgets, startupMilliseconds, simple, selection, multi,
  }, null, 2)}\n`;
  if (outputPath) await writeFile(outputPath, rendered, 'utf8');
  process.stdout.write(rendered);
} finally {
  bridge.stop();
}

async function measureTurn(label, message, snapshots, images, expectedTokens) {
  let firstAgentOutputAt = null;
  let assistantText = '';
  const onStream = (update) => {
    if (firstAgentOutputAt === null) firstAgentOutputAt = performance.now();
    if (update.kind === 'assistant') {
      assistantText = update.replace ? (update.text || '') : `${assistantText}${update.text || ''}`;
    }
  };
  bridge.on('streamUpdate', onStream);
  const completion = once(bridge, 'turnCompleted');
  const startedAt = performance.now();
  try {
    await bridge.startTurn(message, snapshots, images);
    const acceptedAt = performance.now();
    await withTimeout(completion, budgets.completedMilliseconds + 5_000, `${label} turn timed out`);
    const completedAt = performance.now();
    for (const expectedToken of expectedTokens) {
      if (!assistantText.includes(expectedToken)) {
        throw new Error(`${label} response omitted ${expectedToken}. Response: ${assistantText.trim()}`);
      }
    }
    return {
      acceptedMilliseconds: Math.round(acceptedAt - startedAt),
      firstAgentOutputMilliseconds: firstAgentOutputAt === null
        ? null
        : Math.round(firstAgentOutputAt - startedAt),
      completedMilliseconds: Math.round(completedAt - startedAt),
    };
  } finally {
    bridge.off('streamUpdate', onStream);
  }
}

function assertTurnWithin(result) {
  if (result.firstAgentOutputMilliseconds === null) {
    throw new Error('The turn completed without visible agent output.');
  }
  assertWithin('Send acceptance', result.acceptedMilliseconds, budgets.acceptedMilliseconds);
  assertWithin('First agent output', result.firstAgentOutputMilliseconds, budgets.firstAgentOutputMilliseconds);
  assertWithin('Turn completion', result.completedMilliseconds, budgets.completedMilliseconds);
}

function assertWithin(label, actual, maximum) {
  if (actual > maximum) throw new Error(`${label} took ${actual} ms; budget is ${maximum} ms.`);
}

async function withTimeout(promise, milliseconds, message) {
  let timeout;
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => {
        timeout = setTimeout(() => reject(new Error(message)), milliseconds);
      }),
    ]);
  } finally {
    clearTimeout(timeout);
  }
}
