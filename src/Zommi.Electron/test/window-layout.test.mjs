import assert from 'node:assert/strict';
import test from 'node:test';
import {
  COMPACT_WINDOW_SIZE,
  PANEL_BOTTOM_GAP,
  calculateAdaptiveWindowSize,
  calculateAnchoredWindowBounds,
  calculateCompactWindowBounds,
  interpolateWindowBounds,
} from '../window-layout.mjs';

test('compact orb is centered just above the taskbar work-area edge', () => {
  const workArea = { x: 1920, y: 0, width: 1920, height: 1040 };
  const bounds = calculateCompactWindowBounds(workArea);
  assert.deepEqual(bounds, {
    x: 1920 + Math.round((1920 - COMPACT_WINDOW_SIZE) / 2),
    y: 1040 - COMPACT_WINDOW_SIZE - PANEL_BOTTOM_GAP,
    width: COMPACT_WINDOW_SIZE,
    height: COMPACT_WINDOW_SIZE,
  });
});

test('expanded panel preserves the same centered bottom anchor', () => {
  const workArea = { x: -1600, y: 80, width: 1600, height: 900 };
  const size = calculateAdaptiveWindowSize(workArea, false);
  const bounds = calculateAnchoredWindowBounds(workArea, size);
  assert.equal(bounds.x + bounds.width / 2, workArea.x + workArea.width / 2);
  assert.equal(workArea.y + workArea.height - (bounds.y + bounds.height), PANEL_BOTTOM_GAP);
  assert.deepEqual(size, { width: 896, height: 648 });
});

test('bounds interpolation keeps every animation frame on integer pixels', () => {
  const start = { x: 916, y: 934, width: 56, height: 56 };
  const target = { x: 400, y: 282, width: 1120, height: 720 };
  assert.deepEqual(interpolateWindowBounds(start, target, 0), start);
  assert.deepEqual(interpolateWindowBounds(start, target, 1), target);
  assert.deepEqual(interpolateWindowBounds(start, target, 0.5), { x: 658, y: 608, width: 588, height: 388 });
});
