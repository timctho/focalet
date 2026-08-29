import { spawnSync } from 'node:child_process';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptPath = fileURLToPath(import.meta.url);
const defaultRepositoryRoot = resolve(dirname(scriptPath), '..');

export function assertReleaseBaseline({ repositoryRoot = defaultRepositoryRoot, refresh = true } = {}) {
  const root = resolve(repositoryRoot);
  if (refresh) runGit(root, ['fetch', '--quiet', '--no-tags', 'origin', 'main']);

  const head = runGit(root, ['rev-parse', 'HEAD']);
  const baselineRef = 'refs/remotes/origin/main';
  const baseline = runGit(root, ['rev-parse', '--verify', baselineRef]);
  const ancestry = spawnSync('git', ['-C', root, 'merge-base', '--is-ancestor', baseline, head], {
    encoding: 'utf8',
  });
  if (ancestry.error) throw ancestry.error;
  if (ancestry.status === 1) {
    throw new Error(
      `Refusing deployment from stale source ${head.slice(0, 12)}: it does not contain latest origin/main ${baseline.slice(0, 12)}.`,
    );
  }
  if (ancestry.status !== 0) {
    throw new Error(`Could not compare the release source with origin/main: ${ancestry.stderr.trim() || `git exited ${ancestry.status}`}`);
  }
  return { head, baseline, baselineRef };
}

function runGit(repositoryRoot, arguments_) {
  const result = spawnSync('git', ['-C', repositoryRoot, ...arguments_], { encoding: 'utf8' });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`git ${arguments_.join(' ')} failed: ${result.stderr.trim() || `exit ${result.status}`}`);
  }
  return result.stdout.trim();
}

if (process.argv[1] && resolve(process.argv[1]) === scriptPath) {
  try {
    process.stdout.write(`${JSON.stringify(assertReleaseBaseline())}\n`);
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}
