"""Exercise the WSL shell probe with terminal-only CLI installations."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
PROBE = ROOT / 'scripts/probe-wsl-runtimes.sh'


@unittest.skipUnless(sys.platform.startswith('linux'), 'WSL shell fixture requires Linux')
class WslDiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='zommi shell probe-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.tools = self.root / 'tools'
        self.tools.mkdir()
        self.runtime = self.root / '.hermes/node/bin'
        self.runtime.mkdir(parents=True)
        self.env = {'HOME': str(self.root), 'PATH': str(self.tools) + ':/usr/bin:/bin',
                    'SHELL': '/bin/bash', 'TERM': 'dumb'}
        self.program(self.tools / 'getent', '#!/bin/sh\nprintf "fixture:x:1000:1000::%s:/bin/bash\\n" "$HOME"\n')
        (self.root / '.bash_profile').write_text('. "$HOME/.bashrc"\n')
        self.rc = self.root / '.bashrc'
        self.rc.write_text('case $- in *i*) ;; *) return ;; esac\n'
                           'printf "shell startup banner\\n"\n'
                           'export PATH="$HOME/.hermes/node/bin:$PATH"\n')
        self.program(self.runtime / 'codex', '#!/bin/sh\nexit 0\n')

    def program(self, path, text):
        path.write_text(text)
        path.chmod(0o755)

    def probe(self, *names):
        return subprocess.run(['/bin/sh', str(PROBE), *names], env=self.env,
                              capture_output=True, text=True, timeout=10)

    def test_bash_terminal_path_is_discovered_and_preserved_for_node(self):
        before = subprocess.run(['/bin/bash', '-lc', 'command -v codex'],
                                env=self.env, capture_output=True, text=True)
        self.assertNotEqual(before.returncode, 0, 'Fixture must reproduce noninteractive discovery failure')
        result = self.probe('codex')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('shell startup banner', result.stdout)
        self.assertIn('__ZOMMI_RUNTIME_PATH__codex\t' + str(self.runtime / 'codex'), result.stdout)
        launch_path = next(line.removeprefix('__ZOMMI_RUNTIME_ENV_PATH__')
                           for line in result.stdout.splitlines() if line.startswith('__ZOMMI_RUNTIME_ENV_PATH__'))
        node = shutil.which('node')
        self.assertIsNotNone(node, 'Node is required by the WSL relay tests')
        self.program(self.runtime / 'node', '#!/bin/sh\nexport SELECTED_NODE=hermes\nexec "' + node + '" "$@"\n')
        self.program(self.runtime / 'codex', '#!/usr/bin/env node\nconsole.log(JSON.stringify({node:process.env.SELECTED_NODE,args:process.argv.slice(2)}));\n')
        launched = subprocess.run(['/usr/bin/env', 'PATH=' + launch_path, str(self.runtime / 'codex'), 'app-server'],
                                  env={'PATH': str(self.tools)}, capture_output=True, text=True, timeout=5)
        self.assertEqual(launched.returncode, 0, launched.stderr)
        self.assertEqual(json.loads(launched.stdout), {'node': 'hermes', 'args': ['app-server']})

    def test_all_agent_names_are_resolved_and_nonexecutables_are_ignored(self):
        for name in ['pi', 'opencode', 'gemini', 'hermes', 'openclaw', 'claude']:
            self.program(self.runtime / name, '#!/bin/sh\nexit 0\n')
        (self.runtime / 'not-executable').write_text('not a CLI')
        names = ['codex', 'pi', 'opencode', 'gemini', 'hermes', 'openclaw', 'claude']
        result = self.probe(*names, 'not-executable')
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in names:
            self.assertIn('__ZOMMI_RUNTIME_PATH__' + name + '\t', result.stdout)
        self.assertNotIn('__ZOMMI_RUNTIME_PATH__not-executable', result.stdout)

    def test_controlling_terminal_does_not_stop_interactive_shell_initialization(self):
        import fcntl
        import pty
        import termios
        master, slave = pty.openpty()
        def terminal_session():
            os.setsid()
            fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
        try:
            result = subprocess.run(['/bin/sh', str(PROBE), 'codex'], env=self.env,
                                    stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    text=True, preexec_fn=terminal_session, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('__ZOMMI_RUNTIME_PATH__codex\t' + str(self.runtime / 'codex'), result.stdout)
        finally:
            os.close(slave)
            os.close(master)

    def test_hung_or_early_exiting_shell_is_a_failed_probe_not_an_empty_catalog(self):
        self.rc.write_text('sleep 30\n')
        started = time.monotonic()
        result = self.probe('codex')
        self.assertNotEqual(result.returncode, 0)
        self.assertLess(time.monotonic() - started, 8)
        self.assertEqual(result.stdout, '')
        self.rc.write_text('exit 0\n')
        self.assertNotEqual(self.probe('codex').returncode, 0)

    def test_verbose_shell_cannot_block_the_probe_or_publish_unbounded_output(self):
        with self.rc.open('a') as stream:
            stream.write('head -c 300000 /dev/zero\n')
        result = self.probe('codex')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')

    @unittest.skipUnless(shutil.which('zsh'), 'zsh is not installed')
    def test_zsh_reads_zshrc_and_returns_the_terminal_cli(self):
        shell = shutil.which('zsh')
        self.program(self.tools / 'getent', '#!/bin/sh\nprintf "fixture:x:1000:1000::%s:' + shell + '\\n" "$HOME"\n')
        self.env['ZDOTDIR'] = str(self.root)
        (self.root / '.zshrc').write_text('export PATH="$HOME/.hermes/node/bin:$PATH"\n')
        result = self.probe('codex')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('__ZOMMI_RUNTIME_PATH__codex\t' + str(self.runtime / 'codex'), result.stdout)


if __name__ == '__main__':
    unittest.main()
