import assert from 'node:assert/strict';
import test from 'node:test';
import {
  activityOpenState,
  activityKey,
  effortsForModel,
  extractDisplayUserText,
  initialHistoryStart,
  isNearBottom,
  mergeActivityText,
  mergeDistinctTextSections,
  previousHistoryStart,
  sessionStatus,
  sessionTitle,
  wheelScrollContainer,
} from '../renderer/renderer-logic.mjs';

test('reasoning and commentary share one thinking card per turn', () => {
  assert.equal(activityKey('thinking', 'reasoning-1', 'Thinking'), 'turn-thinking');
  assert.equal(activityKey('thinking', 'commentary-2', 'Thinking'), 'turn-thinking');
  assert.equal(activityKey('tool', 'command-1', 'Command'), 'command-1');
});

test('tool activity cannot collapse thinking that is still being followed or user-expanded', () => {
  assert.equal(activityOpenState({
    currentOpen: true,
    userControlled: false,
    kind: 'thinking',
    lifecycle: 'completed',
  }), true);
  assert.equal(activityOpenState({
    currentOpen: true,
    userControlled: true,
    kind: 'thinking',
    lifecycle: 'completed',
    turnCompleted: true,
  }), true);
  assert.equal(activityOpenState({
    currentOpen: false,
    userControlled: true,
    kind: 'thinking',
    lifecycle: 'delta',
  }), false);
  assert.equal(activityOpenState({
    currentOpen: true,
    userControlled: false,
    kind: 'thinking',
    lifecycle: 'completed',
    turnCompleted: true,
  }), false);
});

test('completed thinking replaces streamed text instead of duplicating it', () => {
  const live = mergeActivityText('', 'Inspecting the structure.', 'thinking', 'delta');
  assert.equal(mergeActivityText(live, 'Inspecting the structure.', 'thinking', 'completed'), live);
  assert.equal(
    mergeActivityText('Inspecting', 'Inspecting the structure.', 'thinking', 'completed'),
    'Inspecting the structure.',
  );
});

test('persisted thinking prefers the fuller section instead of showing summary and content twice', () => {
  assert.equal(mergeDistinctTextSections(['Inspecting files.', 'Inspecting files.']), 'Inspecting files.');
  assert.equal(
    mergeDistinctTextSections(['Inspecting', 'Inspecting files and tests.']),
    'Inspecting files and tests.',
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

test('wheel input follows the hovered thinking body instead of the outer chat', () => {
  const thinking = {};
  const transcript = { contains: (candidate) => candidate === thinking };
  const thinkingChild = { closest: (selector) => selector === '.activity-content' ? thinking : null };
  const chatChild = { closest: () => null };
  assert.equal(wheelScrollContainer(thinkingChild, transcript), thinking);
  assert.equal(wheelScrollContainer(chatChild, transcript), transcript);
  assert.equal(wheelScrollContainer({ closest: () => ({}) }, transcript), transcript);
});

test('long histories reveal older turns in bounded pages', () => {
  assert.equal(initialHistoryStart(53, 18), 35);
  assert.equal(previousHistoryStart(35, 18), 17);
  assert.equal(previousHistoryStart(17, 18), 0);
});

test('session status prioritizes running and unread work', () => {
  const running = new Set(['running']);
  const unread = new Set(['unread']);
  assert.equal(sessionStatus('running', 'active', running, unread), 'running');
  assert.equal(sessionStatus('unread', 'active', running, unread), 'unread');
  assert.equal(sessionStatus('active', 'active', running, unread), 'read');
  assert.equal(sessionStatus('done', 'active', running, unread), 'done');
});

test('reasoning levels come from the selected model catalog entry', () => {
  assert.deepEqual(effortsForModel({ supportedReasoningEfforts: [
    { reasoningEffort: 'low' }, { reasoningEffort: 'high' },
  ] }), ['low', 'high']);
});
