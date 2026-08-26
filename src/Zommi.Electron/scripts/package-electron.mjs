import { downloadArtifact } from '@electron/get';
import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { cp, mkdir, mkdtemp, readFile, rename, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { basename, dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const appDirectory = resolve(scriptDirectory, '..');
const browserMcpDirectory = join(appDirectory, 'browser-mcp');
const repositoryRoot = resolve(appDirectory, '..', '..');
const options = parseArguments(process.argv.slice(2));
const packageJson = JSON.parse(await readFile(join(appDirectory, 'package.json'), 'utf8'));
const platform = options.platform || process.platform;
const arch = options.arch || process.arch;
const runtimeName = platform === 'win32' ? 'win' : platform === 'darwin' ? 'mac' : 'linux';
const outputDirectory = resolve(options.output || join(repositoryRoot, 'artifacts', `zommi-${runtimeName}-${arch}`));
assertArtifactOutput(outputDirectory, repositoryRoot);

const archivePath = await downloadArtifact({
  version: packageJson.devDependencies.electron,
  artifactName: 'electron',
  platform,
  arch,
});
const temporaryRoot = await mkdtemp(join(tmpdir(), 'zommi-electron-package-'));
const extracted = join(temporaryRoot, 'extracted');
const pending = `${outputDirectory}.pending-electron-${process.pid}`;
const backup = `${outputDirectory}.backup-electron-${process.pid}`;

try {
  installBrowserMcpRuntime();
  await mkdir(extracted, { recursive: true });
  if (process.platform === 'win32') {
    execFileSync('tar', ['-xf', archivePath, '-C', extracted], { stdio: 'inherit' });
  } else {
    execFileSync('unzip', ['-q', archivePath, '-d', extracted], { stdio: 'inherit' });
  }
  await rm(pending, { recursive: true, force: true });
  const nativeDirectory = options.nativeDir || join(repositoryRoot, 'artifacts', `zommi-native-${runtimeName}-${arch}`);
  await assemblePlatformPackage(extracted, pending, platform, nativeDirectory);
  if (existsSync(outputDirectory)) await rename(outputDirectory, backup);
  await rename(pending, outputDirectory);
  await rm(backup, { recursive: true, force: true });
  process.stdout.write(`${JSON.stringify({ platform, arch, electronVersion: packageJson.devDependencies.electron, outputDirectory })}\n`);
} catch (error) {
  if (!existsSync(outputDirectory) && existsSync(backup)) await rename(backup, outputDirectory);
  throw error;
} finally {
  await rm(pending, { recursive: true, force: true });
  await rm(temporaryRoot, { recursive: true, force: true });
}

async function assemblePlatformPackage(extracted, output, targetPlatform, nativeDirectory) {
  if (targetPlatform === 'darwin') {
    const sourceApp = join(extracted, 'Electron.app');
    const targetApp = join(output, 'Zommi.app');
    await cp(sourceApp, targetApp, { recursive: true });
    const executable = join(targetApp, 'Contents', 'MacOS', 'Electron');
    await rename(executable, join(targetApp, 'Contents', 'MacOS', 'Zommi'));
    const plistPath = join(targetApp, 'Contents', 'Info.plist');
    const plist = (await readFile(plistPath, 'utf8'))
      .replaceAll('<string>Electron</string>', '<string>Zommi</string>')
      .replaceAll('com.github.Electron', 'com.zommi.desktop');
    await writeFile(plistPath, plist);
    await copyApplication(join(targetApp, 'Contents', 'Resources', 'app'));
    await copyBrowserMcp(join(targetApp, 'Contents', 'Resources', 'browser-mcp'));
    return;
  }

  await cp(extracted, output, { recursive: true });
  const electronExecutable = targetPlatform === 'win32' ? join(output, 'electron.exe') : join(output, 'electron');
  const productExecutable = targetPlatform === 'win32' ? join(output, 'Zommi.exe') : join(output, 'zommi');
  await rename(electronExecutable, productExecutable);
  await rm(join(output, 'resources', 'default_app.asar'), { force: true });
  await copyApplication(join(output, 'resources', 'app'));
  await copyBrowserMcp(join(output, 'resources', 'browser-mcp'));
  if (targetPlatform === 'win32') {
    if (!nativeDirectory || !existsSync(nativeDirectory)) throw new Error('Windows Electron packages require --native-dir.');
    await cp(resolve(nativeDirectory), join(output, 'resources', 'native'), { recursive: true });
  }
}

function installBrowserMcpRuntime() {
  const npm = process.platform === 'win32' ? 'npm.cmd' : 'npm';
  execFileSync(npm, ['ci', '--omit=dev', '--ignore-scripts'], {
    cwd: browserMcpDirectory,
    stdio: 'inherit',
  });
}

async function copyBrowserMcp(destination) {
  await cp(browserMcpDirectory, destination, {
    recursive: true,
    filter: (source) => !['.bin', '.package-lock.json'].includes(basename(source)),
  });
}

async function copyApplication(destination) {
  await mkdir(destination, { recursive: true });
  const files = [
    'main.mjs', 'preload.cjs', 'native-host.mjs', 'codex-bridge.mjs', 'platform-capture.mjs',
    'image-selector.mjs', 'selection-geometry.mjs', 'renderer', 'selection',
  ];
  for (const file of files) await cp(join(appDirectory, file), join(destination, file), { recursive: true });
  const sourcePackage = JSON.parse(await readFile(join(appDirectory, 'package.json'), 'utf8'));
  await writeFile(join(destination, 'package.json'), `${JSON.stringify({
    name: sourcePackage.name,
    version: sourcePackage.version,
    private: true,
    type: 'module',
    main: 'main.mjs',
  }, null, 2)}\n`);
}

function parseArguments(args) {
  const parsed = {};
  for (let index = 0; index < args.length; index += 2) {
    const key = args[index]?.replace(/^--/, '').replace(/-([a-z])/g, (_match, character) => character.toUpperCase());
    const value = args[index + 1];
    if (!key || value == null) throw new Error(`Invalid packaging argument near ${args[index] || '<end>'}.`);
    parsed[key] = value;
  }
  return parsed;
}

function assertArtifactOutput(output, root) {
  const artifacts = resolve(root, 'artifacts');
  if (dirname(output) !== artifacts || !basename(output).startsWith('zommi-')) {
    throw new Error(`Refusing to replace a package outside ${artifacts}.`);
  }
}
