import assert from 'node:assert/strict';
import test from 'node:test';
import { BoundedLineDecoder } from '../protocol-framing.mjs';

test('bounded protocol framing preserves split UTF-8 JSONL and CRLF boundaries', () => {
  const lines = [];
  const decoder = new BoundedLineDecoder({ onLine: (line) => lines.push(line), maxFrameBytes: 64 });
  decoder.push('{"text":"left');
  decoder.push('右"}\r\n{"ok":true}\n');
  assert.deepEqual(lines, ['{"text":"left右"}', '{"ok":true}']);
});

test('bounded protocol framing drops one oversized line and resumes at the next LF frame', () => {
  const lines = [];
  let oversized = 0;
  const decoder = new BoundedLineDecoder({
    onLine: (line) => lines.push(line),
    onOversized: () => { oversized += 1; },
    maxFrameBytes: 16,
  });
  decoder.push('x'.repeat(17));
  decoder.push('still discarded\n{"ok":true}\n');
  assert.equal(oversized, 1);
  assert.deepEqual(lines, ['{"ok":true}']);
});
