import assert from 'node:assert/strict';
import test from 'node:test';
import {
  effortsForModel,
  extractDisplayUserText,
  isNearBottom,
  mergeActivityText,
  sessionTitle,
} from '../renderer/renderer-logic.mjs';

test('completed thinking replaces streamed text instead of duplicating it', () => {
  const live = mergeActivityText('', 'Inspecting the structure.', 'thinking', 'delta');
  assert.equal(mergeActivityText(live, 'Inspecting the structure.', 'thinking', 'completed'), live);
  assert.equal(
    mergeActivityText('Inspecting', 'Inspecting the structure.', 'thinking', 'completed'),
    'Inspecting the structure.',
  );
});

test('user-facing session labels exclude Zommi context envelopes', () => {
  const value = '<zommi_invocation_context>untrusted context</zommi_invocation_context>\n<user_message>Compare these rows</user_message>';
  assert.equal(extractDisplayUserText(value), 'Compare these rows');
  assert.equal(sessionTitle({ preview: value }), 'Compare these rows');
  assert.equal(sessionTitle({ name: 'Zommi · Compare these rows' }), 'Compare these rows');
});

test('stream following only considers a transcript near its bottom', () => {
  assert.equal(isNearBottom({ scrollHeight: 1000, scrollTop: 650, clientHeight: 300 }), false);
  assert.equal(isNearBottom({ scrollHeight: 1000, scrollTop: 675, clientHeight: 300 }), true);
});

test('reasoning levels come from the selected model catalog entry', () => {
  assert.deepEqual(effortsForModel({ supportedReasoningEfforts: [
    { reasoningEffort: 'low' }, { reasoningEffort: 'high' },
  ] }), ['low', 'high']);
});
