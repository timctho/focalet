import { RuntimeDiscovery } from '../src/Zommi.Electron/runtime-discovery.mjs';

const platformArgument = process.argv.find((value) => value.startsWith('--platform='));
const platform = platformArgument?.slice('--platform='.length) || process.platform;
const discovery = new RuntimeDiscovery({ platform, cacheTtlMs: 0 });
const eager = await discovery.discover({ force: true });
const complete = await discovery.waitForBackground();

process.stdout.write(`${JSON.stringify({
  hosts: discovery.hosts,
  eager: eager.map(project),
  complete: complete.map(project),
})}\n`);

function project(target) {
  return {
    runtimeId: target.runtimeId,
    adapterId: target.adapterId,
    executablePath: target.executablePath,
    host: target.executionHost.id,
    defaultHost: target.executionHost.isDefault,
  };
}
