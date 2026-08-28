import { createHash, randomUUID } from 'node:crypto';
import { readFile, rename, writeFile } from 'node:fs/promises';
import { dirname, isAbsolute, win32 } from 'node:path';
import { mkdir } from 'node:fs/promises';
import { RUNTIME_CATALOG, catalogEntry } from './runtime-catalog.mjs';

export const RUNTIME_SETTINGS_VERSION = 1;

export class RuntimeSettings {
  constructor(options = {}) {
    this.path = options.path || null;
    this.catalog = options.catalog || RUNTIME_CATALOG;
    this.loaded = false;
    this.overrides = [];
  }

  async load() {
    if (this.loaded) return this.list();
    this.loaded = true;
    if (!this.path) return this.list();
    try {
      const parsed = JSON.parse(await readFile(this.path, 'utf8'));
      if (parsed?.version === RUNTIME_SETTINGS_VERSION && Array.isArray(parsed.overrides)) {
        this.overrides = parsed.overrides.map((value) => validateRuntimeOverride(value, this.catalog));
      }
    } catch {
      this.overrides = [];
    }
    return this.list();
  }

  list() {
    return this.overrides.map((value) => ({ ...value }));
  }

  async upsert(value) {
    await this.load();
    const next = validateRuntimeOverride(value, this.catalog);
    const id = next.id || `override-${createHash('sha256').update(JSON.stringify(next)).digest('hex').slice(0, 16)}`;
    const saved = { ...next, id };
    this.overrides = [...this.overrides.filter((item) => item.id !== id), saved];
    await this.#save();
    return { ...saved };
  }

  async remove(id) {
    await this.load();
    const previousLength = this.overrides.length;
    this.overrides = this.overrides.filter((item) => item.id !== String(id));
    if (this.overrides.length !== previousLength) await this.#save();
    return this.list();
  }

  async #save() {
    if (!this.path) return;
    await mkdir(dirname(this.path), { recursive: true });
    const pending = `${this.path}.pending-${process.pid}-${randomUUID()}`;
    await writeFile(pending, `${JSON.stringify({ version: RUNTIME_SETTINGS_VERSION, overrides: this.overrides }, null, 2)}\n`, {
      encoding: 'utf8', mode: 0o600,
    });
    await rename(pending, this.path);
  }
}

export function validateRuntimeOverride(value, catalog = RUNTIME_CATALOG) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Runtime override must be an object.');
  const adapterId = String(value.adapterId || '');
  const entry = catalogEntry(adapterId, catalog);
  if (!entry) throw new Error(`Unknown Runtime Adapter '${adapterId}'.`);
  const profileId = safeId(value.profileId || 'default', 'profileId');
  const id = value.id ? safeId(value.id, 'override id') : null;
  if (value.endpoint) {
    if (adapterId !== 'openclaw-gateway') throw new Error('Only OpenClaw Gateway accepts an endpoint override.');
    const endpoint = validateEndpoint(value.endpoint);
    return { ...(id ? { id } : {}), adapterId, profileId, endpoint };
  }
  if (!entry.executables?.length) {
    throw new Error(`${entry.displayName} ${entry.protocolName} accepts only an endpoint override.`);
  }
  const executionHostId = safeId(value.executionHostId, 'Execution Host');
  const executablePath = String(value.executablePath || '').trim();
  const windowsPath = /^[a-z]:[\\/]/i.test(executablePath) || /^\\\\/.test(executablePath);
  if (!isAbsolute(executablePath) && !windowsPath && !win32.isAbsolute(executablePath)) {
    throw new Error('Executable override must be an absolute native or WSL path.');
  }
  if (/[\u0000-\u001f\u007f]/.test(executablePath) || executablePath.length > 2_048) {
    throw new Error('Executable override path is invalid.');
  }
  return { ...(id ? { id } : {}), adapterId, profileId, executionHostId, executablePath };
}

function validateEndpoint(value) {
  let endpoint;
  try {
    endpoint = new URL(String(value));
  } catch {
    throw new Error('Gateway endpoint must be a valid ws:// or wss:// URL.');
  }
  if (!['ws:', 'wss:'].includes(endpoint.protocol) || endpoint.username || endpoint.password) {
    throw new Error('Gateway endpoint must use ws:// or wss:// and cannot embed credentials.');
  }
  for (const key of endpoint.searchParams.keys()) {
    if (/token|password|secret|key|auth/i.test(key)) throw new Error('Gateway endpoint cannot contain credential query parameters.');
  }
  return endpoint.toString();
}

function safeId(value, label) {
  const id = String(value || '');
  if (!id || id.length > 256 || /[\u0000-\u001f\u007f]/.test(id)) throw new Error(`${label} is invalid.`);
  return id;
}
