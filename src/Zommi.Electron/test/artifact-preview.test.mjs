import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { loadArtifactPreview, resolveArtifactPath } from '../artifact-preview.mjs';

test('WSL artifacts map to the selected distribution UNC path on Windows', () => {
  const runtimeState = {
    targets: [{ id: 'wsl-agent', executionHost: { kind: 'wsl', name: 'Ubuntu-24.04' } }],
  };
  assert.equal(resolveArtifactPath({
    path: 'dist/preview.html', cwd: '/home/user/project', runtimeTargetId: 'wsl-agent',
  }, runtimeState, 'win32'), '\\\\wsl.localhost\\Ubuntu-24.04\\home\\user\\project\\dist\\preview.html');
});

test('local generated images and HTML are loaded into bounded renderer payloads', async () => {
  const root = await mkdtemp(join(tmpdir(), 'zommi-artifact-test-'));
  try {
    const imagePath = join(root, 'render.png');
    const htmlPath = join(root, 'preview.html');
    await writeFile(imagePath, Buffer.from('png bytes'));
    await writeFile(htmlPath, '<h1>Safe preview</h1>');
    const image = await loadArtifactPreview({ kind: 'image', path: imagePath });
    const html = await loadArtifactPreview({ kind: 'html', path: htmlPath });
    assert.equal(image.dataUrl, 'data:image/png;base64,cG5nIGJ5dGVz');
    assert.equal(html.html, '<h1>Safe preview</h1>');
    await assert.rejects(loadArtifactPreview({ kind: 'html', path: imagePath }), /Only generated image and HTML/);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
