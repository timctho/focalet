import { createHash } from 'node:crypto';
import { execFile as nodeExecFile } from 'node:child_process';
import { EventEmitter } from 'node:events';
import { existsSync } from 'node:fs';
import { readFile, writeFile } from 'node:fs/promises';
import { delimiter, isAbsolute, join, normalize, resolve } from 'node:path';
import { promisify } from 'node:util';
import {
  RUNTIME_CATALOG,
  RUNTIME_CATALOG_VERSION,
  catalogEntry,
  catalogEntriesForExecutable,
  catalogExecutableNames,
} from './runtime-catalog.mjs';
import { RuntimeSettings } from './runtime-settings.mjs';

const execFileAsync = promisify(nodeExecFile);
const DETECTION_PREFIX = '__ZOMMI_RUNTIME_PATH__';
const HOME_PREFIX = '__ZOMMI_RUNTIME_HOME__';
const DEFAULT_CACHE_TTL_MS = 5 * 60 * 1000;
const DEFAULT_PROBE_TIMEOUT_MS = 8_000;

export class RuntimeDiscovery extends EventEmitter {
  constructor(options = {}) {
    super();
    this.platform = options.platform ?? process.platform;
    this.env = options.env ?? process.env;
    this.catalog = options.catalog ?? RUNTIME_CATALOG;
    this.catalogVersion = options.catalogVersion ?? RUNTIME_CATALOG_VERSION;
    this.cachePath = options.cachePath ?? null;
    this.cacheTtlMs = options.cacheTtlMs ?? DEFAULT_CACHE_TTL_MS;
    this.probeTimeoutMs = options.probeTimeoutMs ?? DEFAULT_PROBE_TIMEOUT_MS;
    this.execFile = options.execFile ?? defaultExecFile;
    this.resolveNativeCommand = options.resolveNativeCommand ?? resolveNativeCommand;
    this.now = options.now ?? (() => Date.now());
    this.settings = options.settings ?? new RuntimeSettings({ path: options.settingsPath, catalog: this.catalog });
    this.targets = [];
    this.hosts = [];
    this.backgroundPromise = null;
    this.cache = { version: this.catalogVersion, hosts: {} };
    this.cacheLoaded = false;
  }

  async discover({ force = false } = {}) {
    await this.#loadCache();
    await this.settings.load();
    this.hosts = await enumerateExecutionHosts({
      platform: this.platform,
      execFile: this.execFile,
      timeoutMs: this.probeTimeoutMs,
    });
    const eagerHosts = this.hosts.filter((host) => host.kind === 'native' || host.isDefault);
    const backgroundHosts = this.hosts.filter((host) => !eagerHosts.includes(host));
    const eager = await Promise.all(eagerHosts.map((host) => this.#targetsForHost(host, force)));
    this.targets = deduplicateTargets([...eager.flat(), ...this.#configuredTargets()]);
    this.emit('targetsChanged', this.targets);
    this.backgroundPromise = backgroundHosts.length
      ? this.#discoverBackground(backgroundHosts, force)
      : Promise.resolve(this.targets);
    return this.targets;
  }

  async refresh(hostId = null) {
    if (!hostId) return this.discover({ force: true });
    await this.#loadCache();
    const host = this.hosts.find((candidate) => candidate.id === hostId)
      || (await enumerateExecutionHosts({
        platform: this.platform,
        execFile: this.execFile,
        timeoutMs: this.probeTimeoutMs,
      })).find((candidate) => candidate.id === hostId);
    if (!host) throw new Error(`Unknown Execution Host '${hostId}'.`);
    const refreshed = await this.#targetsForHost(host, true);
    this.targets = deduplicateTargets([
      ...this.targets.filter((target) => target.executionHost.id !== host.id),
      ...refreshed,
      ...this.#configuredTargets(),
    ]);
    this.emit('targetsChanged', this.targets);
    return this.targets;
  }

  async waitForBackground() {
    return this.backgroundPromise ? this.backgroundPromise : this.targets;
  }

  invalidateTarget(target) {
    if (!target?.executionHost?.id) return;
    delete this.cache.hosts[target.executionHost.id];
    void this.#saveCache();
  }

  getSettingsState() {
    return {
      hosts: this.hosts.map((host) => ({ ...host })),
      adapters: this.catalog.map((entry) => ({
        adapterId: entry.adapterId,
        displayName: entry.displayName,
        protocolName: entry.protocolName,
        hostKinds: [...(entry.hostKinds || [])],
        acceptsEndpoint: entry.adapterId === 'openclaw-gateway',
      })),
      overrides: this.settings.list(),
    };
  }

  async upsertOverride(value) {
    await this.settings.upsert(value);
    return this.discover({ force: true });
  }

  async removeOverride(id) {
    await this.settings.remove(id);
    return this.discover({ force: true });
  }

  async #discoverBackground(hosts, force) {
    const batches = await Promise.all(hosts.map((host) => this.#targetsForHost(host, force)));
    this.targets = deduplicateTargets([...this.targets, ...batches.flat(), ...this.#configuredTargets()]);
    this.emit('targetsChanged', this.targets);
    return this.targets;
  }

  async #targetsForHost(host, force) {
    const cached = this.cache.hosts[host.id];
    if (!force && cached?.catalogVersion === this.catalogVersion
      && this.now() - cached.detectedAtMs < this.cacheTtlMs) {
      return cached.targets || [];
    }
    let matches = [];
    let error = null;
    try {
      matches = host.kind === 'wsl'
        ? await detectWslExecutables(host, catalogExecutableNames(this.catalog), {
          execFile: this.execFile,
          timeoutMs: this.probeTimeoutMs,
        })
        : await detectNativeExecutables(catalogExecutableNames(this.catalog), {
          platform: this.platform,
          env: this.env,
          catalog: this.catalog,
          execFile: this.execFile,
          resolveCommand: this.resolveNativeCommand,
          timeoutMs: this.probeTimeoutMs,
        });
    } catch (caught) {
      error = String(caught?.message || caught);
    }
    const targets = targetsFromMatches(host, matches, this.catalog);
    this.cache.hosts[host.id] = {
      catalogVersion: this.catalogVersion,
      detectedAtMs: this.now(),
      targets,
      ...(error ? { error } : {}),
    };
    await this.#saveCache();
    if (error) this.emit('hostError', { host, error });
    return targets;
  }

  #configuredTargets() {
    return targetsFromRuntimeOverrides(this.hosts, this.settings.list(), this.catalog);
  }

  async #loadCache() {
    if (this.cacheLoaded) return;
    this.cacheLoaded = true;
    if (!this.cachePath) return;
    try {
      const parsed = JSON.parse(await readFile(this.cachePath, 'utf8'));
      if (parsed?.version === this.catalogVersion && parsed.hosts) this.cache = parsed;
    } catch {
      // A missing or stale cache is a normal cold start.
    }
  }

  async #saveCache() {
    if (!this.cachePath) return;
    try {
      await writeFile(this.cachePath, `${JSON.stringify(this.cache, null, 2)}\n`, 'utf8');
    } catch (error) {
      this.emit('cacheError', String(error?.message || error));
    }
  }
}

export async function enumerateExecutionHosts(options = {}) {
  const platform = options.platform ?? process.platform;
  const hosts = [{
    id: `native:${platform}`,
    kind: 'native',
    platform,
    displayName: platform === 'win32' ? 'Windows' : platform,
    isDefault: platform !== 'win32',
  }];
  if (platform !== 'win32') return hosts;
  const execFile = options.execFile ?? defaultExecFile;
  const timeoutMs = options.timeoutMs ?? DEFAULT_PROBE_TIMEOUT_MS;
  try {
    const [quiet, verbose] = await Promise.all([
      execFile('wsl.exe', ['--list', '--quiet'], { timeout: timeoutMs, windowsHide: true }),
      execFile('wsl.exe', ['--list', '--verbose'], { timeout: timeoutMs, windowsHide: true }),
    ]);
    const distributions = parseWslDistributions(quiet.stdout, verbose.stdout);
    for (const distribution of distributions) {
      hosts.push({
        id: `wsl:${distribution.name.toLowerCase()}`,
        kind: 'wsl',
        platform: 'linux',
        displayName: `WSL · ${distribution.name}`,
        name: distribution.name,
        isDefault: distribution.isDefault,
      });
    }
  } catch {
    // WSL is optional. Native discovery remains available.
  }
  return hosts;
}

export function parseWslDistributions(quietOutput, verboseOutput = '') {
  const quiet = normalizeCommandOutput(quietOutput)
    .split(/\r?\n/)
    .map((line) => line.trim().replace(/^\*\s*/, ''))
    .filter(Boolean);
  const verboseLines = normalizeCommandOutput(verboseOutput).split(/\r?\n/);
  const defaultName = verboseLines
    .map((line) => /^\s*\*\s+([^\s]+)/.exec(line)?.[1] || '')
    .find(Boolean) || '';
  return [...new Set(quiet)].map((name, index) => ({
    name,
    isDefault: defaultName ? name.toLowerCase() === defaultName.toLowerCase() : index === 0,
  }));
}

export async function detectNativeExecutables(names, options = {}) {
  const platform = options.platform ?? process.platform;
  const env = options.env ?? process.env;
  const resolveCommand = options.resolveCommand ?? resolveNativeCommand;
  const matches = [];
  const missed = [];
  for (const name of [...new Set(names)]) {
    const path = await resolveCommand(name, { platform, env, catalog: options.catalog });
    if (path) matches.push({ executableName: name, executablePath: path });
    else missed.push(name);
  }
  if (!missed.length || platform === 'win32') return matches;
  try {
    const shell = env.SHELL || '/bin/sh';
    const script = buildPosixDetectionScript(missed);
    const result = await (options.execFile ?? defaultExecFile)(shell, ['-lc', script], {
      env,
      timeout: options.timeoutMs ?? DEFAULT_PROBE_TIMEOUT_MS,
      windowsHide: true,
    });
    matches.push(...parseExecutableMatches(result.stdout));
  } catch {
    // The inherited PATH result remains useful if login-shell hydration fails.
  }
  return deduplicateMatches(matches);
}

export async function detectWslExecutables(host, names, options = {}) {
  if (host?.kind !== 'wsl' || !host.name) throw new Error('WSL detection requires a WSL Execution Host.');
  const script = buildPosixDetectionScript(names);
  const wrapper = buildLoginShellWrapper(script);
  const result = await (options.execFile ?? defaultExecFile)(
    'wsl.exe',
    ['-d', host.name, '-e', 'sh', '-lc', wrapper],
    { timeout: options.timeoutMs ?? DEFAULT_PROBE_TIMEOUT_MS, windowsHide: true },
  );
  return parseExecutableMatches(result.stdout);
}

export function buildPosixDetectionScript(names) {
  const safe = [...new Set(names)].filter((name) => /^[a-z0-9][a-z0-9._-]{0,127}$/i.test(name));
  const commandList = safe.map(quoteSh).join(' ');
  return [
    `printf '${HOME_PREFIX}%s\\n' "$HOME"`,
    `for zommi_command in ${commandList}; do`,
    '  zommi_path="$(command -v -- "$zommi_command" 2>/dev/null || true)"',
    '  case "$zommi_path" in',
    `    /*) printf '${DETECTION_PREFIX}%s\\t%s\\n' "$zommi_command" "$zommi_path" ;;`,
    '  esac',
    'done',
  ].join('\n');
}

export function buildLoginShellWrapper(script) {
  return [
    'zommi_shell=$(getent passwd $(id -un) 2>/dev/null | cut -d: -f7)',
    '[ -x "$zommi_shell" ] || zommi_shell="${SHELL:-/bin/sh}"',
    `exec "$zommi_shell" -lc ${quoteSh(script)}`,
  ].join('; ');
}

export function parseExecutableMatches(output) {
  const matches = [];
  const lines = normalizeCommandOutput(output).split(/\r?\n/);
  const runtimeHome = lines.find((line) => line.startsWith(HOME_PREFIX))?.slice(HOME_PREFIX.length) || null;
  for (const line of lines) {
    if (!line.startsWith(DETECTION_PREFIX)) continue;
    const [executableName, executablePath] = line.slice(DETECTION_PREFIX.length).split('\t');
    if (!/^[a-z0-9][a-z0-9._-]{0,127}$/i.test(executableName || '')) continue;
    if (!String(executablePath || '').startsWith('/')) continue;
    matches.push({ executableName, executablePath, ...(runtimeHome?.startsWith('/') ? { runtimeHome } : {}) });
  }
  return deduplicateMatches(matches);
}

export function targetsFromMatches(host, matches, catalog = RUNTIME_CATALOG) {
  const targets = [];
  for (const match of deduplicateMatches(matches)) {
    const entries = catalogEntriesForExecutable(match.executableName, host.kind, catalog);
    const acpRuntimeIds = new Set(entries
      .filter((entry) => entry.adapterId.endsWith('-acp'))
      .map((entry) => entry.runtimeId));
    for (const entry of entries.filter((candidate) =>
      !acpRuntimeIds.has(candidate.runtimeId) || candidate.adapterId.endsWith('-acp'))) {
      const profileId = match.profileId || 'default';
      const identity = [host.id, entry.adapterId, match.executablePath, profileId].join('\0');
      targets.push({
        id: `runtime-${createHash('sha256').update(identity).digest('hex').slice(0, 20)}`,
        runtimeId: entry.runtimeId,
        adapterId: entry.adapterId,
        displayName: entry.displayName,
        protocolName: entry.protocolName,
        machineMode: entry.machineMode,
        minimumProtocolVersion: entry.minimumProtocolVersion,
        protocolVersion: null,
        runtimeVersion: null,
        handshake: { ...entry.handshake },
        classification: entry.classification,
        priority: entry.priority,
        capabilities: [],
        capabilityHints: [...(entry.capabilityHints || [])],
        executableName: match.executableName,
        executablePath: match.executablePath,
        ...(match.runtimeHome ? { runtimeHome: match.runtimeHome } : {}),
        profileId,
        executionHost: { ...host },
        status: 'detected',
      });
    }
  }
  return deduplicateTargets(targets);
}

export function targetsFromRuntimeOverrides(hosts, overrides, catalog = RUNTIME_CATALOG) {
  const targets = [];
  for (const override of overrides || []) {
    const entry = catalogEntry(override.adapterId, catalog);
    if (!entry) continue;
    if (override.endpoint) {
      const endpoint = String(override.endpoint);
      const endpointUrl = new URL(endpoint);
      const host = {
        id: `remote:${createHash('sha256').update(endpoint).digest('hex').slice(0, 16)}`,
        kind: 'remote', platform: 'remote', displayName: endpointUrl.host, isDefault: false,
      };
      const identity = [host.id, entry.adapterId, endpoint, override.profileId || 'default'].join('\0');
      targets.push({
        id: `runtime-${createHash('sha256').update(identity).digest('hex').slice(0, 20)}`,
        runtimeId: entry.runtimeId, adapterId: entry.adapterId,
        displayName: entry.displayName, protocolName: entry.protocolName,
        machineMode: entry.machineMode, minimumProtocolVersion: entry.minimumProtocolVersion,
        protocolVersion: null, runtimeVersion: null, handshake: { ...entry.handshake },
        classification: entry.classification, priority: entry.priority,
        capabilities: [], capabilityHints: [...(entry.capabilityHints || [])],
        endpoint, profileId: override.profileId || 'default', executionHost: host,
        status: 'detected', source: 'configured', overrideId: override.id,
      });
      continue;
    }
    const host = (hosts || []).find((candidate) => candidate.id === override.executionHostId);
    if (!host || !entry.hostKinds?.includes(host.kind)) continue;
    const target = targetsFromMatches(host, [{
      executableName: entry.executables[0], executablePath: override.executablePath,
      profileId: override.profileId || 'default',
    }], [entry])[0];
    if (target) targets.push({ ...target, source: 'configured', overrideId: override.id });
  }
  return deduplicateTargets(targets);
}

export function selectDefaultTarget(targets, options = {}) {
  const usable = targets.filter((target) => !['unreachable', 'unsupported-version'].includes(target.status));
  const byId = new Map(usable.map((target) => [target.id, target]));
  if (options.boundTargetId && byId.has(options.boundTargetId)) return byId.get(options.boundTargetId);
  if (options.lastSelectedTargetId && byId.has(options.lastSelectedTargetId)) return byId.get(options.lastSelectedTargetId);
  return [...usable].sort((left, right) => {
    const leftClass = left.classification === 'native' ? 0 : 1;
    const rightClass = right.classification === 'native' ? 0 : 1;
    const leftHost = targetHostRank(left.executionHost);
    const rightHost = targetHostRank(right.executionHost);
    return leftClass - rightClass
      || leftHost - rightHost
      || Number(left.priority || 0) - Number(right.priority || 0)
      || String(left.id).localeCompare(String(right.id));
  })[0] || null;
}

export function commandForTarget(target, entry) {
  if (!target || !entry) throw new Error('A Runtime Target and catalog entry are required.');
  if (target.executionHost.kind === 'wsl') {
    return {
      command: 'wsl.exe',
      args: [
        '-d', target.executionHost.name,
        ...(target.runtimeHome ? ['--cd', target.runtimeHome] : []),
        '-e', target.executablePath, ...entry.launchArgs,
      ],
    };
  }
  if (target.executionHost.kind === 'native'
    && target.executionHost.platform === 'win32'
    && /\.(?:cmd|bat)$/i.test(target.executablePath)) {
    return {
      command: 'cmd.exe',
      args: ['/d', '/v:off', '/s', '/c', target.executablePath, ...entry.launchArgs],
    };
  }
  return { command: target.executablePath, args: [...entry.launchArgs] };
}

export async function resolveNativeCommand(command, options = {}) {
  const platform = options.platform ?? process.platform;
  const env = options.env ?? process.env;
  const pathKey = Object.keys(env).find((key) => key.toLowerCase() === 'path') || 'PATH';
  const pathValue = env[pathKey] || '';
  const extensions = platform === 'win32'
    ? windowsExtensions(command, env)
    : [''];
  const directories = [
    ...String(pathValue).split(platform === 'win32' ? ';' : delimiter),
    ...(platform === 'win32' ? knownWindowsInstallDirectories(env) : []),
  ].filter(Boolean);
  for (const directory of [...new Set(directories.map((value) => normalize(value)))]) {
    if (!isAbsolute(directory)) continue;
    for (const extension of extensions) {
      const candidate = resolve(join(directory, `${command}${extension}`));
      if (existsSync(candidate)) return candidate;
    }
  }
  return null;
}

export function knownWindowsInstallDirectories(env = process.env) {
  const values = [
    env.APPDATA ? join(env.APPDATA, 'npm') : null,
    env.LOCALAPPDATA ? join(env.LOCALAPPDATA, 'Microsoft', 'WinGet', 'Links') : null,
    env.LOCALAPPDATA ? join(env.LOCALAPPDATA, 'Programs') : null,
    env.USERPROFILE ? join(env.USERPROFILE, '.local', 'bin') : null,
  ];
  return values.filter(Boolean);
}

function windowsExtensions(command, env) {
  if (/\.[a-z0-9]+$/i.test(command)) return [''];
  const key = Object.keys(env).find((name) => name.toLowerCase() === 'pathext');
  return String(env[key] || '.COM;.EXE;.BAT;.CMD')
    .split(';')
    .filter(Boolean)
    .flatMap((extension) => [extension.toLowerCase(), extension.toUpperCase()]);
}

function targetHostRank(host) {
  if (host?.kind === 'wsl' && host.isDefault) return 0;
  if (host?.kind === 'native') return 1;
  if (host?.kind === 'wsl') return 2;
  return 3;
}

function deduplicateMatches(matches) {
  const unique = new Map();
  for (const match of matches || []) {
    if (!match?.executableName || !match?.executablePath) continue;
    unique.set(`${match.executableName}\0${match.executablePath}`, match);
  }
  return [...unique.values()];
}

function deduplicateTargets(targets) {
  return [...new Map((targets || []).map((target) => [target.id, target])).values()];
}

function normalizeCommandOutput(output) {
  return String(output || '').replaceAll('\0', '').replace(/^\uFEFF/, '');
}

function quoteSh(value) {
  return `'${String(value).replaceAll("'", "'\\''")}'`;
}

async function defaultExecFile(command, args, options) {
  return execFileAsync(command, args, { encoding: 'utf8', maxBuffer: 1024 * 1024, ...options });
}
