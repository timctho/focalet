import assert from 'node:assert/strict';
import test from 'node:test';
import { collectImageSelection } from '../image-selection-flow.mjs';

test('image selector starts without waiting for slow pointer context', async () => {
  let resolvePointer;
  let pointerStarted = false;
  let selectorStarted = false;
  const pointer = new Promise((resolve) => { resolvePointer = resolve; });
  const resultPromise = collectImageSelection({
    capturePointerContext: () => {
      pointerStarted = true;
      return pointer;
    },
    selectImage: async () => {
      selectorStarted = true;
      assert.equal(pointerStarted, true);
      return { cancelled: false, dataUrl: 'data:image/png;base64,aGVsbG8=', bounds: { width: 10, height: 10 } };
    },
    pointerGraceMs: 0,
  });

  const result = await resultPromise;
  assert.equal(selectorStarted, true);
  assert.equal(result.pointerTimedOut, true);
  assert.equal(result.pointerContext, null);
  resolvePointer({ snapshot: { application: 'Browser' } });
});

test('image selection keeps pointer context that finishes while the user is selecting', async () => {
  let finishSelection;
  const selection = new Promise((resolve) => { finishSelection = resolve; });
  const resultPromise = collectImageSelection({
    capturePointerContext: async () => ({ snapshot: { application: 'Browser' } }),
    selectImage: () => selection,
  });
  await new Promise((resolve) => setImmediate(resolve));
  finishSelection({ cancelled: false, dataUrl: 'data:image/png;base64,aGVsbG8=', bounds: { width: 10, height: 10 } });
  const result = await resultPromise;
  assert.equal(result.pointerTimedOut, false);
  assert.equal(result.pointerContext.snapshot.application, 'Browser');
});

test('cancelling image selection never waits for pointer capture', async () => {
  const result = await collectImageSelection({
    capturePointerContext: () => new Promise(() => {}),
    selectImage: async () => ({ cancelled: true }),
  });
  assert.equal(result.selection.cancelled, true);
  assert.equal(result.pointerContext, null);
});
