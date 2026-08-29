import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { assertReleaseBaseline } from '../../../scripts/assert-release-baseline.mjs';

test('release baseline rejects a checkout behind current origin/main and accepts it after update', async () => {
  const temporaryRoot = await mkdtemp(join(tmpdir(), 'zommi-release-baseline-'));
  const remote = join(temporaryRoot, 'remote.git');
  const workspace = join(temporaryRoot, 'workspace');
  const updater = join(temporaryRoot, 'updater');
  try {
    git(temporaryRoot, ['init', '--bare', remote]);
    git(temporaryRoot, ['init', '--initial-branch=main', workspace]);
    configureIdentity(workspace);
    await writeFile(join(workspace, 'version.txt'), 'accepted orb\n');
    git(workspace, ['add', 'version.txt']);
    git(workspace, ['commit', '-m', 'accepted orb']);
    git(workspace, ['remote', 'add', 'origin', remote]);
    git(workspace, ['push', '-u', 'origin', 'main']);

    git(temporaryRoot, ['clone', remote, updater]);
    configureIdentity(updater);
    await writeFile(join(updater, 'version.txt'), 'newer accepted orb\n');
    git(updater, ['add', 'version.txt']);
    git(updater, ['commit', '-m', 'newer accepted orb']);
    git(updater, ['push', 'origin', 'main']);

    assert.throws(
      () => assertReleaseBaseline({ repositoryRoot: workspace }),
      /Refusing deployment from stale source.*does not contain latest origin\/main/,
    );

    git(workspace, ['merge', '--ff-only', 'origin/main']);
    const result = assertReleaseBaseline({ repositoryRoot: workspace });
    assert.equal(result.head, result.baseline);
  } finally {
    await rm(temporaryRoot, { recursive: true, force: true });
  }
});

function configureIdentity(repository) {
  git(repository, ['config', 'user.name', 'Zommi Test']);
  git(repository, ['config', 'user.email', 'zommi-test@example.invalid']);
}

function git(workingDirectory, arguments_) {
  return execFileSync('git', arguments_, { cwd: workingDirectory, encoding: 'utf8', stdio: 'pipe' }).trim();
}
