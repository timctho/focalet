import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { targetsFromRuntimeOverrides } from '../runtime-discovery.mjs';
import { RuntimeSettings, validateRuntimeOverride } from '../runtime-settings.mjs';

test('runtime settings persist explicit paths and endpoints without accepting embedded credentials', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'zommi-runtime-settings-'));
  const path = join(directory, 'runtime-settings.json');
  try {
    const settings = new RuntimeSettings({ path });
    const codex = await settings.upsert({
      adapterId: 'codex-app-server', executionHostId: 'wsl:ubuntu', executablePath: '/opt/codex/bin/codex',
    });
    const openClaw = await settings.upsert({
      adapterId: 'openclaw-gateway', endpoint: 'wss://gateway.example.test/control',
    });
    assert.ok(codex.id && openClaw.id);
    await assert.rejects(
      settings.upsert({ adapterId: 'openclaw-gateway', endpoint: 'wss://gateway.example.test/?token=private' }),
      /credential query parameters/,
    );
    await assert.rejects(
      settings.upsert({ adapterId: 'pi-rpc', endpoint: 'wss://gateway.example.test' }),
      /Only OpenClaw Gateway/,
    );
    await assert.rejects(
      settings.upsert({
        adapterId: 'openclaw-gateway', executionHostId: 'wsl:ubuntu', executablePath: '/opt/openclaw',
      }),
      /accepts only an endpoint override/,
    );
    const persisted = await readFile(path, 'utf8');
    assert.doesNotMatch(persisted, /token|password|credential/i);
    const reloaded = new RuntimeSettings({ path });
    assert.equal((await reloaded.load()).length, 2);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test('runtime overrides become stable configured targets without replacing auto-discovered targets', () => {
  const hosts = [{ id: 'wsl:ubuntu', kind: 'wsl', name: 'Ubuntu', displayName: 'WSL · Ubuntu', isDefault: true }];
  const overrides = [
    validateRuntimeOverride({
      id: 'override-codex', adapterId: 'codex-app-server', executionHostId: 'wsl:ubuntu', executablePath: '/opt/codex',
    }),
    validateRuntimeOverride({
      id: 'override-openclaw', adapterId: 'openclaw-gateway', endpoint: 'wss://gateway.example.test',
    }),
  ];
  const targets = targetsFromRuntimeOverrides(hosts, overrides);
  assert.equal(targets.length, 2);
  assert.equal(targets[0].source, 'configured');
  assert.equal(targets[0].executionHost.id, 'wsl:ubuntu');
  assert.equal(targets[1].endpoint, 'wss://gateway.example.test/');
  assert.equal(targets[1].executionHost.kind, 'remote');
  assert.ok(targets.every((target) => target.capabilities.length === 0));
});
