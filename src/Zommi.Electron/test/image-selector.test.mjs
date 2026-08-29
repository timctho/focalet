import assert from 'node:assert/strict';
import test from 'node:test';
import { normalizeRectangle, scaleCropRectangle, selectorPreviewSize } from '../selection-geometry.mjs';

test('selection rectangles normalize reverse drags', () => {
  assert.deepEqual(normalizeRectangle({ x1: 300, y1: 220, x2: 100, y2: 80 }), {
    x: 100, y: 80, width: 200, height: 140,
  });
});

test('selection rectangles scale from display coordinates to captured pixels', () => {
  assert.deepEqual(
    scaleCropRectangle(
      { x: 100, y: 50, width: 200, height: 100 },
      { x: 0, y: 0, width: 1000, height: 500 },
      { width: 2000, height: 1000 }),
    { x: 200, y: 100, width: 400, height: 200 });
});

test('selection preview uses logical display pixels while retaining the full-resolution crop source', () => {
  assert.deepEqual(
    selectorPreviewSize({ width: 1920, height: 1080 }, { width: 3840, height: 2160 }),
    { width: 1920, height: 1080 },
  );
  assert.deepEqual(
    selectorPreviewSize({ width: 3840, height: 2160 }, { width: 3840, height: 2160 }),
    { width: 2560, height: 1440 },
  );
});
