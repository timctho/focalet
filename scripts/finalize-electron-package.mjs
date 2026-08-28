import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { createReadStream } from 'node:fs';
import { access, cp, readdir, rename, rm, writeFile } from 'node:fs/promises';
import { basename, dirname, join, relative, resolve, sep } from 'node:path';

const options = parseArguments(process.argv.slice(2));
const repositoryRoot = resolve(dirname(new URL(import.meta.url).pathname), '..');
const artifactsRoot = join(repositoryRoot, 'artifacts');
const packageDirectory = resolve(options.directory || '');
const archivePath = resolve(options.archive || `${packageDirectory}.zip`);
if (dirname(packageDirectory) !== artifactsRoot || !basename(packageDirectory).startsWith('zommi-')) {
  throw new Error(`Package directory must be a direct zommi-* child of ${artifactsRoot}.`);
}
if (dirname(archivePath) !== artifactsRoot || !basename(archivePath).startsWith('zommi-') || !archivePath.endsWith('.zip')) {
  throw new Error(`Archive must be a direct zommi-*.zip child of ${artifactsRoot}.`);
}

for (const source of ['docs/windows-prototype.md', 'docs/windows-acceptance.md', 'docs/acceptance-report.md', 'scripts/Zommi.WslHook.ps1']) {
  await cp(join(repositoryRoot, source), join(packageDirectory, basename(source)));
}

for (const required of [
  'Zommi.exe', 'resources/native/Zommi.exe', 'resources/native/Zommi.Hook.exe',
  'resources/app/main.mjs', 'resources/app/runtime-broker.mjs', 'resources/app/runtime-settings.mjs',
  'resources/app/context-handoff.mjs', 'resources/app/protocol-framing.mjs',
  'resources/app/adapter-diagnostics.mjs', 'resources/app/transport-metrics.mjs',
  'resources/app/renderer/markdown.mjs', 'resources/app/node_modules/marked/lib/marked.esm.js',
]) await access(join(packageDirectory, required));

const hashPath = join(packageDirectory, 'SHA256SUMS.txt');
await rm(hashPath, { force: true });
const files = (await walkFiles(packageDirectory)).sort();
const lines = [];
for (const file of files) {
  lines.push(`${await sha256(file)}  ${relative(packageDirectory, file).split(sep).join('/')}`);
}
await writeFile(hashPath, `${lines.join('\n')}\n`, 'ascii');

const pendingArchive = `${archivePath}.pending-${process.pid}.zip`;
await rm(pendingArchive, { force: true });
execFileSync('zip', ['-q', '-r', pendingArchive, '.'], { cwd: packageDirectory, stdio: 'inherit' });
execFileSync('unzip', ['-tq', pendingArchive], { stdio: 'inherit' });
await rm(archivePath, { force: true });
await rename(pendingArchive, archivePath);
process.stdout.write(`${JSON.stringify({ packageDirectory, archivePath, files: files.length, sha256: await sha256(archivePath) })}\n`);

async function walkFiles(directory) {
  const files = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) files.push(...await walkFiles(path));
    else if (entry.isFile()) files.push(path);
  }
  return files;
}

function sha256(path) {
  return new Promise((resolveHash, reject) => {
    const hash = createHash('sha256');
    const input = createReadStream(path);
    input.on('error', reject);
    input.on('data', (chunk) => hash.update(chunk));
    input.on('end', () => resolveHash(hash.digest('hex')));
  });
}

function parseArguments(args) {
  const parsed = {};
  for (let index = 0; index < args.length; index += 2) {
    const key = args[index]?.replace(/^--/, '');
    if (!key || args[index + 1] === undefined) throw new Error(`Invalid argument near ${args[index] || '<end>'}.`);
    parsed[key] = args[index + 1];
  }
  return parsed;
}
