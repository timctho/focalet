import assert from 'node:assert/strict';
import test from 'node:test';
import {
  artifactKindFromPath,
  artifactsFromText,
  artifactsFromThreadItem,
  sandboxHtmlDocument,
} from '../artifacts.mjs';

test('generated image items become inline image artifacts with their saved path', () => {
  const artifacts = artifactsFromThreadItem({
    id: 'image-1', type: 'imageGeneration', status: 'completed', result: 'aGVsbG8=',
    savedPath: '/workspace/generated/result.webp', failure: null,
  }, { cwd: '/workspace' });
  assert.equal(artifacts.length, 1);
  assert.equal(artifacts[0].kind, 'image');
  assert.equal(artifacts[0].path, '/workspace/generated/result.webp');
  assert.equal(artifacts[0].dataUrl, 'data:image/webp;base64,aGVsbG8=');
  assert.equal(artifacts[0].cwd, '/workspace');
});

test('completed file changes expose image and HTML previews but not deleted or unrelated files', () => {
  const artifacts = artifactsFromThreadItem({
    id: 'change-1', type: 'fileChange', status: 'completed', changes: [
      { path: 'out/gallery.html', kind: 'add' },
      { path: 'out/render.png', kind: 'update' },
      { path: 'out/old.html', kind: 'delete' },
      { path: 'README.md', kind: 'update' },
    ],
  }, { cwd: '/workspace' });
  assert.deepEqual(artifacts.map(({ kind, path }) => ({ kind, path })), [
    { kind: 'html', path: 'out/gallery.html' },
    { kind: 'image', path: 'out/render.png' },
  ]);
});

test('tool image content and embedded HTML resources remain displayable', () => {
  const image = artifactsFromThreadItem({
    id: 'dynamic-1', type: 'dynamicToolCall', contentItems: [{ type: 'inputImage', imageUrl: 'data:image/png;base64,aGVsbG8=' }],
  });
  const html = artifactsFromThreadItem({
    id: 'mcp-1', type: 'mcpToolCall', result: { content: [{
      type: 'resource', resource: { uri: 'preview.html', mimeType: 'text/html', text: '<h1>Preview</h1>' },
    }] },
  });
  assert.equal(image[0].kind, 'image');
  assert.equal(html[0].kind, 'html');
  assert.equal(html[0].html, '<h1>Preview</h1>');
});

test('assistant links detect local previewable artifacts and ignore remote URLs', () => {
  const artifacts = artifactsFromText('See [demo](./demo.html), ![render](/tmp/render.png), and [remote](https://example.test/x.png).');
  assert.deepEqual(artifacts.map(({ kind, path }) => ({ kind, path })), [
    { kind: 'html', path: './demo.html' },
    { kind: 'image', path: '/tmp/render.png' },
  ]);
  assert.equal(artifactKindFromPath('demo.HTML?cache=1'), 'html');
});

test('HTML previews inject a network-blocking policy before generated content', () => {
  const preview = sandboxHtmlDocument('<html><head><style>body{color:red}</style></head><body><script>bad()</script></body></html>');
  assert.match(preview, /Content-Security-Policy/);
  assert.match(preview, /default-src 'none'/);
  assert.ok(preview.indexOf('Content-Security-Policy') < preview.indexOf('<script>'));
});
