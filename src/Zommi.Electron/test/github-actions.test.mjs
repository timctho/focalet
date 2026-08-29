import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const repositoryRoot = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const workflowPath = join(repositoryRoot, '.github', 'workflows', 'ci.yml');

test('GitHub CI runs Electron and managed tests before the release job', async () => {
  const workflow = await readFile(workflowPath, 'utf8');
  assert.match(workflow, /pull_request:/);
  assert.match(workflow, /push:\n\s+branches:\n\s+- main/);
  assert.match(workflow, /workflow_dispatch:/);
  assert.match(workflow, /permissions:\n\s+contents: read/);
  assert.match(workflow, /run: npm test/);
  assert.match(workflow, /dotnet run --project tests\/Zommi\.Tests\/Zommi\.Tests\.csproj --configuration Release --no-restore/);
  assert.match(workflow, /dotnet build Zommi\.sln --configuration Release --no-restore/);
  assert.match(workflow, /windows-release:\n[\s\S]*needs: test/);
});

test('GitHub CI packages and verifies the portable Windows executable artifact', async () => {
  const workflow = await readFile(workflowPath, 'utf8');
  assert.match(workflow, /runs-on: windows-latest/);
  assert.match(workflow, /\.\/scripts\/package-windows\.ps1 -Runtime win-x64/);
  assert.match(workflow, /resources\/native\/Zommi\.exe/);
  assert.match(workflow, /resources\/native\/Zommi\.Hook\.exe/);
  assert.match(workflow, /SHA256SUMS\.txt/);
  assert.match(workflow, /Get-FileHash -Algorithm SHA256/);
  assert.match(workflow, /uses: actions\/upload-artifact@v4/);
  assert.match(workflow, /artifacts\/zommi-win-x64\.zip\.sha256/);
  assert.match(workflow, /if-no-files-found: error/);
  assert.doesNotMatch(workflow, /DeployToDownloads/);
});
